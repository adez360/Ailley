extends "res://scripts/save/save_service.gd"

## SaveService 的 JSON 實作：一個角色／世界各自一個 JSON 檔，存在 user://saves/
## 底下（跟 ai_config.json 同一層 user://，但分子目錄避免混在一起）。
##
## 只管檔案讀寫與 version 欄位遞增，不知道 character／world 的資料形狀——那是
## 呼叫端（Character.get_save_data() 等）的事，這裡收到什麼 Dictionary 就存什麼，
## 見 note/規格書/14_存檔資料存取層規格書.md §2.2「整包讀寫」。
##
## 並行寫入保護：單一 session 寫入鎖（#23）。鎖檔跟資料檔同目錄，副檔名
## 加 .lock，內容只有 { pid, acquired_at }。存活判定問系統的 process 清單
## （_is_pid_alive()）——這一層要防的是兩個各自獨立的 Godot process（例如
## 兩個世界各自的 session）搶寫同一份存檔，PID 存活即可判斷，不需要心跳。
##
## 注意：OS.is_process_running() 只認得 OS.create_process() 自己開出來的子行程，
## 拿另一個獨立啟動的 Godot process 的 pid 去問一律回傳 false（實測驗證過），
## 用不了，所以自己呼叫系統指令查。
##
## 鎖的授予範圍是「這個 process 的存活期間」：第一次成功寫入某個 id 時取得，
## 直到 process 正常結束（_exit_tree）才釋放；不會每次寫入都重新搶鎖，因為同一
## process 重複取自己持有的鎖必定成功，等於沒有互斥效果。當機留下的鎖不會造成
## 死鎖——下一個 process 來搶鎖時發現 pid 已經不在跑，直接接手，不用玩家手動砍檔。

const CHARACTERS_DIR := "user://saves/characters"
const WORLDS_DIR := "user://saves/worlds"
const LOCK_SUFFIX := ".lock"

var _held_locks: Dictionary = {} # lock_path(String) -> true，這個 process 目前持有寫入權的存檔


func get_character(id: String) -> Dictionary:
	return _read("%s/%s.json" % [CHARACTERS_DIR, id])


## 整包覆蓋，不做局部欄位更新（見《14》§2.2）。version 在這裡遞增，
## 不是呼叫端的事——呼叫端只管資料本身長什麼樣。寫入前要先拿到這份存檔的
## session 鎖，鎖被別的活著的 process 持有時拒絕寫入（見檔頭說明）
func save_character(id: String, data: Dictionary) -> bool:
	var path := "%s/%s.json" % [CHARACTERS_DIR, id]
	if not _acquire_write_lock(path):
		return false
	return _write(CHARACTERS_DIR, id, data)


func get_world(id: String) -> Dictionary:
	return _read("%s/%s.json" % [WORLDS_DIR, id])


func save_world(id: String, data: Dictionary) -> bool:
	var path := "%s/%s.json" % [WORLDS_DIR, id]
	if not _acquire_write_lock(path):
		return false
	return _write(WORLDS_DIR, id, data)


## process 正常結束時釋放這個 process 持有的所有鎖。當機（沒走到這裡）留下的
## 鎖檔靠 _acquire_write_lock() 的存活判定接手，不靠這裡清
func _exit_tree() -> void:
	for lock_path in _held_locks.keys():
		var holder := _read_lock(lock_path)
		if int(holder.get("pid", -1)) == OS.get_process_id():
			DirAccess.remove_absolute(lock_path)
	_held_locks.clear()


## 成功（這個 process 已經持有或剛拿到鎖）回傳 true；鎖被別的活著的 process
## 持有時回傳 false，並用 push_error 告知是哪個 pid、何時取得的
func _acquire_write_lock(path: String) -> bool:
	var lock_path := path + LOCK_SUFFIX
	if _held_locks.has(lock_path):
		return true

	var holder := _read_lock(lock_path)
	var holder_pid := int(holder.get("pid", -1))
	if holder_pid > 0 and holder_pid != OS.get_process_id() and _is_pid_alive(holder_pid):
		push_error("JsonSaveService: %s 寫入權目前被 PID %d 持有（於 %s 取得），本次寫入被拒絕" % [
			path, holder_pid, Time.get_datetime_string_from_unix_time(int(holder.get("acquired_at", 0)))
		])
		return false

	var dir := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)

	var tmp_path := lock_path + ".tmp"
	var file := FileAccess.open(tmp_path, FileAccess.WRITE)
	if file == null:
		push_error("JsonSaveService: 無法建立鎖檔 %s（%s）" % [tmp_path, error_string(FileAccess.get_open_error())])
		return false
	file.store_string(JSON.stringify({
		"pid": OS.get_process_id(),
		"acquired_at": Time.get_unix_time_from_system(),
	}))
	file.close()
	DirAccess.rename_absolute(tmp_path, lock_path)

	_held_locks[lock_path] = true
	return true


## 問系統這個 pid 還在不在跑。Windows 用 tasklist（找 CSV 那一行是不是以引號
## 開頭，比對 "no tasks" 那句本地化文字不可靠，語系不同字串就不同）；
## POSIX 用 kill -0（只檢查存不存在／有沒有權限，不會真的送出訊號）
func _is_pid_alive(pid: int) -> bool:
	var output := []
	if OS.get_name() == "Windows":
		OS.execute("tasklist", ["/FI", "PID eq %d" % pid, "/FO", "CSV", "/NH"], output)
		for line: String in output:
			if line.begins_with("\""):
				return true
		return false

	return OS.execute("kill", ["-0", str(pid)], output) == 0


func _read_lock(lock_path: String) -> Dictionary:
	if not FileAccess.file_exists(lock_path):
		return {}

	var file := FileAccess.open(lock_path, FileAccess.READ)
	if file == null:
		return {}

	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	return parsed if parsed is Dictionary else {}


func _read(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("JsonSaveService: 讀取失敗 %s（%s）" % [path, error_string(FileAccess.get_open_error())])
		return {}

	var parsed = JSON.parse_string(file.get_as_text())
	file.close()

	# 解析失敗或不是物件都當成沒有這份存檔，不當機——缺存檔是正常路徑
	# （新角色第一次存檔前就是這樣），呼叫端一律用空 Dictionary 判斷「沒有」
	if parsed == null or not parsed is Dictionary:
		push_error("JsonSaveService: %s 不是合法的 JSON 物件" % path)
		return {}

	return parsed


## 先寫暫存檔再 DirAccess.rename_absolute() 換名，讀檔的人不會撞見寫到一半的
## 半份 JSON（見《14》§3「Atomic write」）
func _write(dir: String, id: String, data: Dictionary) -> bool:
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)

	var path := "%s/%s.json" % [dir, id]
	var previous := _read(path)
	data["version"] = int(previous.get("version", 0)) + 1

	var tmp_path := path + ".tmp"
	var file := FileAccess.open(tmp_path, FileAccess.WRITE)
	if file == null:
		push_error("JsonSaveService: 寫入失敗 %s（%s）" % [tmp_path, error_string(FileAccess.get_open_error())])
		return false

	file.store_string(JSON.stringify(data, "\t"))
	file.close()

	var err := DirAccess.rename_absolute(tmp_path, path)
	if err != OK:
		push_error("JsonSaveService: 換名失敗 %s → %s（%s）" % [tmp_path, path, error_string(err)])
		return false

	return true
