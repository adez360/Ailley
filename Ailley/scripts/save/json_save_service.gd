extends "res://scripts/save/save_service.gd"

## SaveService 的 JSON 實作：一個角色／世界各自一個 JSON 檔，存在
## user://saves_<hash>/ 底下（跟 ai_config_<hash>.json 同一層 user://，但分子目錄
## 避免混在一起；hash 依 checkout 隔離，見 CHARACTERS_DIR/WORLDS_DIR）。
##
## 本地多存檔槽位（issue #810）：世界檔以 world_NNN 命名共存多個，角色檔放
## per-world 子目錄 CHARACTERS_DIR/<active_world_id>/——目錄即歸屬，跨世界
## 不會互相覆蓋（固定 NPC 與 Player 的 character_id 跨世界共用，扁平檔名
## 會讓世界 B 的存檔蓋掉世界 A 的同一隻角色）。檔內的 world_id 只當除錯
## 戳記。legacy 平鋪檔（子目錄化之前寫的）屬於 world_001，僅在
## active_world_id == DEFAULT_WORLD_ID 時讀取 fallback。都在角色讀寫三個
## 函式收口，呼叫端不用管現在玩的是哪個世界。
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
## 跟 DatabaseManager.DATABASE_PATH（issue #334）同一個病根：用 CheckoutIsolation
## 算出的雜湊接在子目錄後，讓不同 checkout 落地成不同實體檔案，不會互相
## 覆寫（issue #769／#987）
var CHARACTERS_DIR := _compute_saves_dir("characters")
var WORLDS_DIR := _compute_saves_dir("worlds")
const LOCK_SUFFIX := ".lock"
const LOCK_INFO_FILENAME := "info.json"


static func _compute_saves_dir(kind: String) -> String:
	return "user://saves_%s/%s" % [CheckoutIsolation.compute_hash(), kind]

var _held_locks: Dictionary = {} # lock_dir(String) -> true，這個 process 目前持有寫入權的存檔


func has_character(id: String) -> bool:
	var path := _character_path(id)
	if FileAccess.file_exists(path):
		# 檔案存在（含解析不出來的損毀檔）：維持「存過但讀不出來」的既有
		# 語意——呼叫端靠 has_character()==true 且 get_character()=={} 看到
		# 讀檔失敗（見 save_service.gd has_character() 的註解）
		return true
	if _use_legacy_character_fallback():
		return FileAccess.file_exists(_legacy_character_path(id))
	return false


func get_character(id: String) -> Dictionary:
	var path := _character_path(id)
	if FileAccess.file_exists(path):
		return _read(path)
	if _use_legacy_character_fallback():
		return _read(_legacy_character_path(id))
	return {}


## 角色檔的路徑（issue #810）：per-world 子目錄，目錄即歸屬——世界 B 的
## 存檔寫進自己的子目錄，不會蓋掉世界 A 同 id 的角色檔。save_character()
## 寫入與 has_character()/get_character() 讀取都走這裡收口
func _character_path(id: String) -> String:
	return "%s/%s/%s.json" % [CHARACTERS_DIR, GameManager.active_world_id, id]


## legacy 平鋪檔（子目錄化之前寫的，單一世界時代）的路徑。那些檔案是在
## world_001 底下產生的，只代表 DEFAULT_WORLD_ID——別的世界沒有 legacy 檔
## 可翻
func _legacy_character_path(id: String) -> String:
	return "%s/%s.json" % [CHARACTERS_DIR, id]


## legacy 平鋪檔只有在讀 world_001 時才該看得到：active 世界是自己的
## 子目錄（可能還沒有任何檔案）時，翻到平鋪檔會把 world_001 的舊狀態
## 套到新世界頭上
func _use_legacy_character_fallback() -> bool:
	return GameManager.active_world_id == GameManager.DEFAULT_WORLD_ID


## 整包覆蓋，不做局部欄位更新（見《14》§2.2）。version 在這裡遞增，
## 不是呼叫端的事——呼叫端只管資料本身長什麼樣。寫入前要先拿到這份存檔的
## session 鎖，鎖被別的活著的 process 持有時拒絕寫入（見檔頭說明）
##
## 世界歸屬在這裡收口（issue #810）：寫進 active_world_id 的子目錄，並把
## GameManager.active_world_id 戳進 world_id 欄位留作除錯資訊——歸屬由
## 目錄決定，讀取端不再比對檔內欄位。呼叫端（Character.get_save_data() 等）
## 不用知道目前玩哪個世界。直接改到呼叫端傳進來的 Dictionary——它都是
## 當場 get_save_data() 新造的，沒有其他人引用
func save_character(id: String, data: Dictionary) -> bool:
	data["world_id"] = GameManager.active_world_id
	var path := _character_path(id)
	if not _acquire_write_lock(path):
		return false
	return _write(path.get_base_dir(), id, data)


func has_world(id: String) -> bool:
	return FileAccess.file_exists("%s/%s.json" % [WORLDS_DIR, id])


func get_world(id: String) -> Dictionary:
	return _read("%s/%s.json" % [WORLDS_DIR, id])


func save_world(id: String, data: Dictionary) -> bool:
	var path := "%s/%s.json" % [WORLDS_DIR, id]
	if not _acquire_write_lock(path):
		return false
	return _write(WORLDS_DIR, id, data)


## WORLDS_DIR 底下所有 world_<純整數>.json 的世界 id，依數值排序（issue
## #810，主選單的「繼續遊戲」世界選擇面板用）。字尾不是純整數的檔案不收
## ——.tmp 殘留、玩家手動放的雜訊檔不該出現在槽位清單裡。排序按編號數值
## 而不是字典序（world_1000 要排在 world_999 後面）。目錄不存在（一個
## 世界都沒存過）回傳空清單
func list_world_ids() -> Array[String]:
	var ids: Array[String] = []
	var dir := DirAccess.open(WORLDS_DIR)
	if dir == null:
		return ids
	dir.list_dir_begin()
	var filename := dir.get_next()
	while filename != "":
		if not dir.current_is_dir() and filename.begins_with("world_") and filename.ends_with(".json"):
			var id := filename.trim_suffix(".json")
			if id.trim_prefix("world_").is_valid_int():
				ids.append(id)
		filename = dir.get_next()
	dir.list_dir_end()
	ids.sort_custom(_world_id_lesser)
	return ids


## list_world_ids() 的排序比較子：比 world_ 後綴的編號數值，不是字典序
static func _world_id_lesser(a: String, b: String) -> bool:
	return int(a.trim_prefix("world_")) < int(b.trim_prefix("world_"))


## 下一個空槽位的 id（issue #810，主選單「開始新遊戲」的新槽位建議用）：
## 取現有 world_NNN 的最大號 +1，三位數補零（world_001 之後是 world_002…）。
## 一個世界都沒有時回到 DEFAULT_WORLD_ID 起算。檔名編號超過三位數（玩家
## 手動建到 world_1000）時 %03d 不會截斷，照原樣四位輸出
func next_free_world_id() -> String:
	var max_num := 0
	for id in list_world_ids():
		max_num = maxi(max_num, int(id.trim_prefix("world_")))
	return "world_%03d" % (max_num + 1)


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
