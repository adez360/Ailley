extends "res://scripts/save/save_service.gd"

## SaveService 的 JSON 實作：一個角色／世界各自一個 JSON 檔，存在
## user://saves_<hash>/ 底下（跟 ai_config.json 同一層 user://，但分子目錄
## 避免混在一起；hash 依 checkout 隔離，見 CHARACTERS_DIR/WORLDS_DIR）。
##
## 只管檔案讀寫與 version 欄位遞增，不知道 character／world 的資料形狀——那是
## 呼叫端（Character.get_save_data() 等）的事，這裡收到什麼 Dictionary 就存什麼，
## 見 note/規格書/14_存檔資料存取層規格書.md §2.2「整包讀寫」。
##
## 並行寫入保護：單一 session 寫入鎖（#23）。每份存檔配一個同名 .lock 目錄
## 當互斥閘門，但閘門*不是*先建空目錄再補內容——先前那版有洞：
## DirAccess.make_dir_absolute() 建立閘門與寫入 info.json（{ pid, acquired_at }）
## 是兩個分開的步驟，剛贏得閘門的 process 若在寫 info.json 前被排程延遲，
## 另一個 process 會看到「閘門存在但讀不到內容」的中間態，不管用什麼超時
## 判斷都只能降低誤判機率、無法真正消除：對方的延遲一旦超過超時值，還是會
## 被誤判成孤兒鎖搶走，然後兩個 process 都以為自己拿到手。
##
## 現在改成「私有暫存目錄先把完整內容寫好，再原子 rename 到公開的固定名字」：
## DirAccess.rename_absolute() 目的地已存在時會直接失敗、不覆寫、不部分成功
## （實測驗證過），所以公開名字底下要嘛不存在、要嘛一出現就是內容完整的——
## 不會再有「閘門存在但內容還沒寫完」這種可能被誤判的中間態，搶輸的人只是
## rename 失敗、清掉自己的暫存目錄即可，不會弄丟任何東西。細節見
## _publish_lock_claim()。
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
## 死鎖——下一個 process 來搶鎖時發現 pid 已經不在跑，透過 _reclaim_stale_lock()
## 接手：接手本身也是先原子搬走再檢查內容，證實真的死了才清掉、發現其實還
## 活著就搬回去，見該函式註解。兩個 process 同時判定死鎖並搶接手時，只有
## 一個能贏得那次搬走，另一個會正確地拿到失敗或把東西還回去，不會誤判成功。
##
## 已知殘留限制：這一整套只靠 rename/mkdir 的原子性做互斥，沒有真正的作業系統
## 鎖（flock／LockFileEx，GDScript 沒有介面能叫）。正常的兩個 process 互搶
## 已經涵蓋（含死鎖接手），但三個以上 process 同時對同一個 id 搶死鎖接手時，
## _reclaim_stale_lock() 的「搬回去」那一步理論上仍可能因為第三者插隊而失敗
## ——這個專案單機、最多兩個 process 會碰同一份存檔，用不到為了這個機率去接
## 原生擴充套件換真正的系統鎖。

## user:// 只依 project.godot 的 project name 解析，不分 worktree/checkout，
## 跟 DatabaseManager.DATABASE_PATH（issue #334）同一個病根：用這個 checkout
## 的 res:// 絕對路徑算完整 sha256 接在子目錄後，讓不同 checkout 落地成不同
## 實體檔案，不會互相覆寫（issue #769）
var CHARACTERS_DIR := _compute_saves_dir("characters")
var WORLDS_DIR := _compute_saves_dir("worlds")
const LOCK_SUFFIX := ".lock"
const LOCK_INFO_FILENAME := "info.json"


static func _compute_saves_dir(kind: String) -> String:
	var checkout_hash := ProjectSettings.globalize_path("res://").sha256_text()
	return "user://saves_%s/%s" % [checkout_hash, kind]

var _held_locks: Dictionary = {} # lock_dir(String) -> true，這個 process 目前持有寫入權的存檔


func has_character(id: String) -> bool:
	return FileAccess.file_exists("%s/%s.json" % [CHARACTERS_DIR, id])


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


func has_world(id: String) -> bool:
	return FileAccess.file_exists("%s/%s.json" % [WORLDS_DIR, id])


func get_world(id: String) -> Dictionary:
	return _read("%s/%s.json" % [WORLDS_DIR, id])


func save_world(id: String, data: Dictionary) -> bool:
	var path := "%s/%s.json" % [WORLDS_DIR, id]
	if not _acquire_write_lock(path):
		return false
	return _write(WORLDS_DIR, id, data)


## process 正常結束時釋放這個 process 持有的所有鎖。_held_locks 只會記這個
## process 自己發布成功的鎖（見 _publish_lock_claim()），不需要重讀 info.json
## 再三確認是不是自己的。當機（沒走到這裡）留下的鎖靠 _acquire_write_lock()
## 的存活判定接手，不靠這裡清
func _exit_tree() -> void:
	for lock_dir in _held_locks.keys():
		_remove_lock_dir(lock_dir)
	_held_locks.clear()


## 成功（這個 process 已經持有或剛贏得鎖）回傳 true；鎖被別的活著的
## process 持有時回傳 false，並用 push_error 告知是哪個 pid、何時取得的
func _acquire_write_lock(path: String) -> bool:
	var lock_dir := path + LOCK_SUFFIX
	if _held_locks.has(lock_dir):
		return true

	var dir := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)

	if _publish_lock_claim(lock_dir):
		_held_locks[lock_dir] = true
		return true

	# 發布失敗：鎖已經被別人合法持有（見 _publish_lock_claim()，公開名字
	# 底下要嘛不存在、要嘛內容一定完整，不會有中間態），可能活著、也可能是
	# 當機留下的死鎖
	var holder := _read_lock_info(lock_dir)
	var holder_pid := int(holder.get("pid", -1))
	if holder_pid > 0 and holder_pid != OS.get_process_id() and _is_pid_alive(holder_pid):
		push_error("JsonSaveService: %s 寫入權目前被 PID %d 持有（於 %s 取得），本次寫入被拒絕" % [
			path, holder_pid, Time.get_datetime_string_from_unix_time(int(holder.get("acquired_at", 0)))
		])
		return false

	# 死鎖：接手。_reclaim_stale_lock() 內部會再驗一次，防止「兩個 process
	# 都判斷死鎖、其中一個接手成功後，另一個把它剛發布的新鎖也清掉」
	if _reclaim_stale_lock(lock_dir) and _publish_lock_claim(lock_dir):
		_held_locks[lock_dir] = true
		return true

	push_error("JsonSaveService: %s 接手死鎖失敗，可能被別的 process 搶先接手或搶先發布新鎖，本次寫入被拒絕" % path)
	return false


## 把「這是死鎖」的判斷跟「移除它」合成同一個不可被插隊的步驟：先用
## DirAccess.rename_absolute() 把 lock_dir 整個搬到只有這次呼叫看得到的
## 隔離目錄——來源不存在時 rename 一樣會失敗，所以兩個 process 同時想搬走
## 同一個 lock_dir，只有一個搬得走，這一步本身沒有競態。
##
## 搬走之後才檢查內容：如果證實真的是死掉的持有者，清掉、回傳 true 讓呼叫端
## 接著發布新鎖；如果搬走後發現其實是活著的（代表判斷死鎖到真正搬走這段
## 極短的時間內，原本的死鎖已經被別的 process 清掉、且已經發布了合法的新
## 鎖），原封不動搬回去，不動任何人的東西，回傳 false 讓這次接手失敗。
##
## 殘留的極端邊緣情況：搬回去那一步本身如果又被第三個 process 搶先佔用
## 目的地，會導致這份內容真的遺失——這是三個以上 process 同時對同一份存檔
## 搶死鎖接手才會踩到的極窄窗口，用純檔案系統原語（沒有 flock／LockFileEx
## 這類作業系統原生鎖）做不到完全杜絕，單機、最多 2 個 process 的規模用不到
## 為了它去接原生擴充套件。
func _reclaim_stale_lock(lock_dir: String) -> bool:
	var quarantine_dir := "%s.reclaiming.%d.%d" % [lock_dir, OS.get_process_id(), Time.get_ticks_usec()]
	if DirAccess.rename_absolute(lock_dir, quarantine_dir) != OK:
		return false

	var holder := _read_lock_info(quarantine_dir)
	var holder_pid := int(holder.get("pid", -1))
	if holder_pid > 0 and holder_pid != OS.get_process_id() and _is_pid_alive(holder_pid):
		if DirAccess.rename_absolute(quarantine_dir, lock_dir) != OK:
			push_error("JsonSaveService: %s 接手死鎖後發現原持有者其實還活著，但已無法歸還鎖（可能有第三個 process 同時搶鎖），這份鎖資訊遺失" % lock_dir)
		return false

	DirAccess.remove_absolute(quarantine_dir.path_join(LOCK_INFO_FILENAME))
	DirAccess.remove_absolute(quarantine_dir)
	return true


## 把完整鎖資訊（{ pid, acquired_at }）先寫進一個只有這次呼叫看得到的私有
## 暫存目錄，再用 DirAccess.rename_absolute() 一步發布成公開的固定名字
## lock_dir。目的地已存在時 rename 會直接失敗、不覆寫（實測驗證過），所以
## 這是唯一一個決勝點：贏的人發布的內容從一開始就是完整的，輸的人只是清掉
## 自己的暫存、不影響任何人，不會像「先建空目錄再補內容」那樣暴露出一個
## 內容不完整、可能被誤判成孤兒鎖的中間態。
func _publish_lock_claim(lock_dir: String) -> bool:
	var staging_dir := "%s.staging.%d.%d" % [lock_dir, OS.get_process_id(), Time.get_ticks_usec()]
	if DirAccess.make_dir_absolute(staging_dir) != OK:
		push_error("JsonSaveService: 無法建立暫存鎖目錄 %s" % staging_dir)
		return false

	var file := FileAccess.open(staging_dir.path_join(LOCK_INFO_FILENAME), FileAccess.WRITE)
	if file == null:
		push_error("JsonSaveService: 無法寫入鎖資訊 %s（%s）" % [staging_dir, error_string(FileAccess.get_open_error())])
		DirAccess.remove_absolute(staging_dir)
		return false
	file.store_string(JSON.stringify({
		"pid": OS.get_process_id(),
		"acquired_at": Time.get_unix_time_from_system(),
	}))
	file.close()

	if DirAccess.rename_absolute(staging_dir, lock_dir) != OK:
		DirAccess.remove_absolute(staging_dir.path_join(LOCK_INFO_FILENAME))
		DirAccess.remove_absolute(staging_dir)
		return false

	return true


func _read_lock_info(lock_dir: String) -> Dictionary:
	var info_path := lock_dir.path_join(LOCK_INFO_FILENAME)
	if not FileAccess.file_exists(info_path):
		return {}

	var file := FileAccess.open(info_path, FileAccess.READ)
	if file == null:
		return {}

	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	return parsed if parsed is Dictionary else {}


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
