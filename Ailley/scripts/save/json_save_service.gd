extends "res://scripts/save/save_service.gd"

## SaveService 的 JSON 實作：一個角色／世界各自一個 JSON 檔，存在 user://saves/
## 底下（跟 ai_config.json 同一層 user://，但分子目錄避免混在一起）。
##
## 只管檔案讀寫與 version 欄位遞增，不知道 character／world 的資料形狀——那是
## 呼叫端（Character.get_save_data() 等）的事，這裡收到什麼 Dictionary 就存什麼，
## 見 note/規格書/14_存檔資料存取層規格書.md §2.2「整包讀寫」。
##
## 並行寫入保護：單一 session 寫入鎖（#23）。每份存檔配一個同名 .lock「目錄」
## 當互斥閘門——DirAccess.make_dir_absolute() 在目的地已存在時回傳
## ERR_ALREADY_EXISTS，兩個 process 同時搶只會有一個拿到 OK，這是作業系統
## 保證的原子操作，不會像「先讀鎖檔內容、判斷沒人持有、再寫檔」那樣中間有
## 空窗期讓兩個 process 都以為自己搶到。鎖目錄底下放一個 info.json 記
## { pid, acquired_at }，只有原子搶到閘門的那個 process 會寫它，不會跟人搶寫；
## 寫失敗就把閘門讓出來（見 _finish_acquire()），不留下搶到閘門卻沒人知道
## 是誰的孤兒鎖。閘門建立跟 info.json 寫入這兩步不是同一個原子操作，看到
## 閘門存在但讀不到 info.json 時用短暫重試分辨「剛贏的人還沒寫完」跟
## 「真的是孤兒鎖」（見 _read_lock_info_confirmed()），不會把剛贏的人誤判成
## 死鎖搶走。
##
## 存活判定問系統的 process 清單（_is_pid_alive()）——這一層要防的是兩個各自
## 獨立的 Godot process（例如兩個世界各自的 session）搶寫同一份存檔，PID 存活
## 即可判斷，不需要心跳。OS.is_process_running() 只認得 OS.create_process()
## 自己開出來的子行程，拿另一個獨立啟動的 Godot process 的 pid 去問一律回傳
## false（實測驗證過），用不了，所以自己呼叫系統指令查。
##
## 鎖的授予範圍是「這個 process 的存活期間」：第一次成功寫入某個 id 時取得，
## 直到 process 正常結束（_exit_tree）才釋放；不會每次寫入都重新搶鎖，因為同一
## process 重複取自己持有的鎖必定成功，等於沒有互斥效果。當機留下的鎖不會造成
## 死鎖——下一個 process 來搶鎖時發現 pid 已經不在跑，重新搶一次閘門接手，
## 不用玩家手動砍檔。接手那一刻（清掉舊閘門、重建新閘門）本身仍有極窄的競態
## 窗口——兩個 process 同時判定死鎖並搶接手時，只有一個會贏（第二次
## make_dir_absolute() 一樣是原子的），另一個會正確地拿到失敗、不會誤判成功；
## 單機小規模遊戲用不到更重的機制（例如檔案系統鎖）去補這個窗口。

const CHARACTERS_DIR := "user://saves/characters"
const WORLDS_DIR := "user://saves/worlds"
const LOCK_SUFFIX := ".lock"
const LOCK_INFO_FILENAME := "info.json"

var _held_locks: Dictionary = {} # lock_dir(String) -> true，這個 process 目前持有寫入權的存檔


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


## process 正常結束時釋放這個 process 持有的所有鎖。_held_locks 只會記這個
## process 自己確認寫入成功的鎖（見 _finish_acquire()），不需要重讀 info.json
## 再三確認是不是自己的。當機（沒走到這裡）留下的鎖靠 _acquire_write_lock()
## 的存活判定接手，不靠這裡清
func _exit_tree() -> void:
	for lock_dir in _held_locks.keys():
		_remove_lock_dir(lock_dir)
	_held_locks.clear()


## 成功（這個 process 已經持有或剛原子搶到鎖）回傳 true；鎖被別的活著的
## process 持有時回傳 false，並用 push_error 告知是哪個 pid、何時取得的
func _acquire_write_lock(path: String) -> bool:
	var lock_dir := path + LOCK_SUFFIX
	if _held_locks.has(lock_dir):
		return true

	var dir := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)

	if DirAccess.make_dir_absolute(lock_dir) == OK:
		return _finish_acquire(lock_dir, path)

	# 閘門已存在：可能是活著的別人持有、剛搶到閘門但 info.json 還沒寫完
	# （用短暫重試分辨，見 _read_lock_info_confirmed() 註解），也可能是
	# 當機留下的死鎖
	var holder := _read_lock_info_confirmed(lock_dir)
	var holder_pid := int(holder.get("pid", -1))
	if holder_pid > 0 and holder_pid != OS.get_process_id() and _is_pid_alive(holder_pid):
		push_error("JsonSaveService: %s 寫入權目前被 PID %d 持有（於 %s 取得），本次寫入被拒絕" % [
			path, holder_pid, Time.get_datetime_string_from_unix_time(int(holder.get("acquired_at", 0)))
		])
		return false

	# 死鎖：接手。清掉殘留的閘門後重新原子搶一次——輸給同時接手的別人時
	# make_dir_absolute() 一樣會回傳 ERR_ALREADY_EXISTS，不會誤判成功
	_remove_lock_dir(lock_dir)
	if DirAccess.make_dir_absolute(lock_dir) != OK:
		push_error("JsonSaveService: %s 接手死鎖失敗，可能被別的 process 搶先接手，本次寫入被拒絕" % path)
		return false

	return _finish_acquire(lock_dir, path)


## 原子搶到閘門之後才會呼叫：把鎖資訊寫進去確認所有權，寫失敗就把閘門讓出來
## （fail-closed，不留一個「搶到閘門但沒人知道是誰」的孤兒鎖），不設定
## _held_locks、回傳 false
func _finish_acquire(lock_dir: String, path: String) -> bool:
	if not _write_lock_info(lock_dir):
		push_error("JsonSaveService: %s 鎖資訊寫入失敗，讓出鎖定，本次寫入被拒絕" % path)
		_remove_lock_dir(lock_dir)
		return false
	_held_locks[lock_dir] = true
	return true


func _write_lock_info(lock_dir: String) -> bool:
	var file := FileAccess.open(lock_dir.path_join(LOCK_INFO_FILENAME), FileAccess.WRITE)
	if file == null:
		push_error("JsonSaveService: 無法寫入鎖資訊 %s（%s）" % [lock_dir, error_string(FileAccess.get_open_error())])
		return false
	file.store_string(JSON.stringify({
		"pid": OS.get_process_id(),
		"acquired_at": Time.get_unix_time_from_system(),
	}))
	file.close()
	return true


## 閘門目錄跟 info.json 不是同一個原子操作寫進去的（閘門的原子性只保證
## 「只有一個 process 能成功建立目錄」，不保證它建完的瞬間 info.json 已經
## 存在）。剛贏得閘門的 process 緊接著就會寫 info.json，正常情況下幾乎
## 瞬間完成；如果讀到閘門存在但 info.json 還沒出現，用短暫重試分辨兩種情況：
## 剛贏的人還沒寫完（重試幾次就會出現），或是真的當機／寫入失敗留下的孤兒
## 閘門（重試完還是沒有）。
##
## 讀不到確認的持有者資訊——不管是還沒寫完就重試完了、閘門在重試期間被釋放、
## 還是內容壞掉——一律回傳空 Dictionary，呼叫端會走死鎖接手路徑，不會卡死：
## 這裡要 fail-closed 的只有「這一次搶鎖」本身（讀不到活著的持有者就不能
## 貿然宣告拿到手），不能連下一次搶鎖都一起卡住，否則等於要玩家手動砍檔
## 案才能復原，違背 #23 的當機復原要求。
func _read_lock_info_confirmed(lock_dir: String) -> Dictionary:
	const RETRIES := 3
	const RETRY_DELAY_MSEC := 20

	var info_path := lock_dir.path_join(LOCK_INFO_FILENAME)
	for attempt in RETRIES:
		if not DirAccess.dir_exists_absolute(lock_dir):
			return {} # 閘門在重試期間被原本的持有者釋放了，視同沒有鎖

		if FileAccess.file_exists(info_path):
			var file := FileAccess.open(info_path, FileAccess.READ)
			if file != null:
				var parsed = JSON.parse_string(file.get_as_text())
				file.close()
				if parsed is Dictionary:
					return parsed

		if attempt < RETRIES - 1:
			OS.delay_msec(RETRY_DELAY_MSEC)

	return {}


func _remove_lock_dir(lock_dir: String) -> void:
	DirAccess.remove_absolute(lock_dir.path_join(LOCK_INFO_FILENAME))
	DirAccess.remove_absolute(lock_dir)


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
