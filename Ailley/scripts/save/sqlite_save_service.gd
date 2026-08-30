extends "res://scripts/save/save_service.gd"
class_name SqliteSaveService

## SaveService 的 SQLite 實作，走 DatabaseManager autoload 存取
## DatabaseManager.DATABASE_PATH。
## 介面定義見 note/規格書/14_存檔資料存取層規格書.md §2。
##
## 《14》§5 要求兩個實作的資料形狀必須一致——這裡讀寫的 Dictionary 形狀
## 對齊的是 JsonSaveService 實際存的內容（Character.get_save_data() /
## GameManager.get_world_save_data() 現在真正吐出來的東西），不是《06 資料
## 欄位對應表》§1 那份完整形狀——後者描述的 identity/hexaco/economy/
## state.emotion 現在還沒有任何 Character 欄位在產生，接了也沒有呼叫端能
## 餵資料進來。
##
## `memory` 是另一種情況：**已經由上游產生（#170），只是這裡（SQLite 這條
## 路線）還沒接**，不是「上游還沒做」，見下方「schema 缺口」。`personality`／
## `today_plan`（#429 起由 Character/Agent.get_save_data() 產生）原本也是
## 同一種缺口（《99》P-52），`npc_personality`／`npc_daily_plan` 兩張表其實
## 早就存在（`DatabaseCRUDTest.gd` 有測，只是沒被 get_character()/
## save_character() 用過），已經接上，見下方 get_character()/save_character()。
##
## 缺值一律補預設值，不回傳 null 也不省略 key——少一個 key 跟值是預設值，
## 對呼叫端是兩種不同的東西。整包讀寫，不做局部欄位更新（《14》§2.2）。
## save_* 一律包在 DatabaseManager.begin_transaction() / commit_transaction()
## 裡，中途任何一步失敗就 rollback_transaction() 並回傳 false。
##
## 並行寫入保護走 SQLite 的 transaction，不是 version 欄位 CAS——npc 表沒有
## version 欄位，這條路線是 note/技術/存檔.md「鎖只管寫入」那段定的，
## JsonSaveService 的 session 鎖不會被這裡重用。


## npc_state 跟 Stats.SPEC 同名的 8 個欄位。mood/social/fun 這 3 個
## SPEC 有但 npc_state 沒有掛靠欄位（見「schema 缺口」），round-trip
## 之後這 3 項會遺失，靠 Stats.load_save_data() 用 SPEC 的 start 值補回。
const STATE_COLUMNS := [
	"satiety", "hydration", "stamina", "wakefulness",
	"hygiene", "alcohol", "health", "injury",
]

## npc_personality 跟 Character.personality（Personality.hexaco_to_personality()
## 實際產出）同名的 10 個欄位。npc_personality 表另外還有 6 個 hex_* 欄位
## （HEXACO 原始輸入），Character.personality 沒有這 6 項，這裡不讀不寫它們——
## HEXACO 輸入不是這個表的職責範圍，見 Personality.from_identity()
const PERSONALITY_COLUMNS := [
	"diligence", "courage", "sociability", "morality", "stability",
	"romanticism", "curiosity", "grudge", "greed", "honesty",
]

## npc_state 撈不到那一列時（例如 npc 存在但還沒存過狀態）用這份補齊
## STATE_COLUMNS，不要回傳空 stats——跟檔頭「缺值補預設值，不省略 key」
## 一致。數值抄自 NPCStateSchema.gd 的 DEFAULT，兩邊要一起改
const STATE_DEFAULTS := {
	"satiety": 100.0, "hydration": 80.0, "stamina": 80.0, "wakefulness": 90.0,
	"hygiene": 70.0, "alcohol": 0.0, "health": 100.0, "injury": 0.0,
}


## 查 npc_state 而不是 npc：npc 這一列在角色 _ready() 掛進場景、還沒真的
## save_character() 過的時候就可能已經存在（見「schema 缺口」對 npc 表的
## 說明），查 npc 會把「場上有這隻角色」誤判成「這隻角色存過檔」。npc_state
## 只有 save_character() 才會寫，是這裡要的「真的存過」訊號
func has_character(id: String) -> bool:
	var rows := DatabaseManager.select("npc_state", "npc_id = '%s'" % _esc(id))
	if DatabaseManager.last_query_failed:
		push_error(
			"SqliteSaveService: has_character(%s) 查詢失敗，"
			% id
			+ "無法判斷這筆存檔存不存在——不是「從沒存過」，是讀不到（issue #439）"
		)
	return not rows.is_empty()


## 讀一個角色的完整資料，找不到回傳空 Dictionary
##
## 回傳形狀跟 Character.get_save_data() 一致：
##     { character_id, character_name, stats{8 項}, relationships{ <target_id>: {met_count, appearance_cache} },
##       personality?{ 10 項 }, today_plan?[ {text, is_done} ] }
##
## personality／today_plan 是選填欄位（跟 get_save_data() 只在有資料時才給
## 這兩個 key 同一個道理）：`npc_personality`／`npc_daily_plan` 沒有這個角色
## 的資料時完全不加這兩個 key，不是補一份預設值——沒存過人格漂移／今日計畫
## 的角色，讓 Character.load_save_data()／Agent.load_save_data() 維持它們
## 自己 `_ready()` 算出來的值，跟 JsonSaveService／stats 的「省略 key 就是
## 不覆寫」語意一致
func get_character(id: String) -> Dictionary:
	var npc_rows := DatabaseManager.select("npc", "npc_id = '%s'" % _esc(id))
	if npc_rows.is_empty():
		return {}

	var data := {
		"character_id": id,
		"character_name": String(npc_rows[0].get("name", "")),
	}

	var stats := {}
	var state_rows := DatabaseManager.select("npc_state", "npc_id = '%s'" % _esc(id))
	var state_row: Dictionary = state_rows[0] if not state_rows.is_empty() else {}
	for key in STATE_COLUMNS:
		stats[key] = state_row.get(key, STATE_DEFAULTS[key])
	data["stats"] = stats

	var relationships := {}
	for row in DatabaseManager.select("npc_relations", "character_id = '%s'" % _esc(id)):
		relationships[row["target_id"]] = {
			"met_count": int(row["relations_met_count"]),
			"appearance_cache": row["relations_appearance_cache"],
		}
	data["relationships"] = relationships

	var personality_rows := DatabaseManager.select("npc_personality", "npc_id = '%s'" % _esc(id))
	if not personality_rows.is_empty():
		var personality_row: Dictionary = personality_rows[0]
		var personality := {}
		for key in PERSONALITY_COLUMNS:
			personality[key] = float(personality_row[key])
		data["personality"] = personality

	# ORDER BY plan_id：SQLite 不保證沒下 ORDER BY 的查詢結果順序，
	# today_plan 是有序清單（顯示順序、模型讀到的順序都看它），少排序的話
	# 每次讀出來的順序可能不一樣，等於每次讀檔都悄悄打亂計畫清單
	# （CodeRabbit review 抓到）。plan_id 是 AUTOINCREMENT，插入順序＝
	# 遞增順序，直接排它就對齊寫入時的原始順序
	var plan_rows := DatabaseManager.select(
		"npc_daily_plan", "npc_id = '%s' ORDER BY plan_id" % _esc(id)
	)
	if not plan_rows.is_empty():
		var today_plan: Array[Dictionary] = []
		for row in plan_rows:
			today_plan.append({
				"text": String(row.get("text", "")),
				"is_done": bool(int(row.get("is_done", 0))),
			})
		data["today_plan"] = today_plan

	return data


## 寫入一個角色的完整資料（整包覆蓋，不做局部欄位更新）
##
## 收的 Dictionary 形狀跟 get_character() 回傳的一致。
##
## npc_relations 的 target_id 有 FK 指向 npc(npc_id)：目標角色這時如果還沒
## 存過（例如場上另一個角色在同一輪 debug console `save` 迴圈裡還沒輪到），
## 那一筆關係先跳過、記警告，不讓整包寫入失敗——下次雙方都存過之後這筆
## 關係就補得回來，見 PR 討論。
##
## personality／today_plan 沒有給（`data` 沒有這個 key）時完全不動既有
## 資料——跟 `_upsert_npc_state()` 用 `stats.has(key)` 逐欄位判斷不同，這兩項
## 是整包才有意義（10 項人格數值、一整份計畫清單），沒收到就是這次呼叫端
## 沒有這份資料可存，不是「清空」的意思
func save_character(id: String, data: Dictionary) -> bool:
	if not DatabaseManager.begin_transaction():
		return false

	var ok := _upsert_npc(id, data)

	if ok:
		ok = _upsert_npc_state(id, data.get("stats", {}))

	if ok:
		ok = DatabaseManager.delete("npc_relations", "character_id = '%s'" % _esc(id))

	if ok:
		ok = _replace_relationships(id, data.get("relationships", {}))

	if ok and data.has("personality"):
		ok = _upsert_npc_personality(id, data["personality"])

	if ok and data.has("today_plan"):
		ok = DatabaseManager.delete("npc_daily_plan", "npc_id = '%s'" % _esc(id))
		if ok:
			ok = _replace_daily_plan(id, data["today_plan"])

	if not ok:
		DatabaseManager.rollback_transaction()
		return false

	if DatabaseManager.commit_transaction():
		return true

	# COMMIT 失敗不保證交易已經結束（SQLite 可能因為 SQLITE_BUSY 之類的原因
	# 讓交易繼續留著）——沒有這個 rollback，下一次 begin_transaction() 會
	# 因為交易還在跑而失敗，之後所有存檔都會跟著壞掉
	DatabaseManager.rollback_transaction()
	return false


func has_world(id: String) -> bool:
	var rows := DatabaseManager.select("world", "world_id = '%s'" % _esc(id))
	if DatabaseManager.last_query_failed:
		push_error(
			"SqliteSaveService: has_world(%s) 查詢失敗，"
			% id
			+ "無法判斷這筆存檔存不存在——不是「從沒存過」，是讀不到（issue #439）"
		)
	return not rows.is_empty()


## 讀一個世界的完整資料
##
## 回傳形狀跟 GameManager.get_world_save_data() 一致：
##     { day, allow_player_join, characters{ <npc_id>: {position[x,y], current_place?, current_state?, following_id?} } }
func get_world(id: String) -> Dictionary:
	var world_rows := DatabaseManager.select("world", "world_id = '%s'" % _esc(id))
	if world_rows.is_empty():
		return {}

	var characters := {}
	for row in DatabaseManager.select("world_character_state", "world_id = '%s'" % _esc(id)):
		var entry := {
			"position": [float(row["pos_x"]), float(row["pos_y"])],
		}
		# current_place / current_state 只有 Agent 才有意義，Player 存進來的
		# 是 NULL——跟 GameManager.get_world_save_data() 的條件式加欄位對齊。
		# 兩欄在 schema 上各自獨立可為 NULL，current_place 有值但
		# current_state 是 NULL 時不能把 null 塞進回傳的 Dictionary——跟檔頭
		# 「不回傳 null」的規則一致，正規化成空字串
		var current_place = row.get("current_place")
		if current_place != null:
			entry["current_place"] = String(current_place)
			var current_state = row.get("current_state")
			entry["current_state"] = "" if current_state == null else String(current_state)
		# following_npc_id（issue #576）跟 current_place 同一種可為 NULL
		# 欄位，但沒有 current_place 那種「有 current_place 就一定順便帶
		# current_state」的耦合關係，各自獨立判斷 null 就好
		var following_npc_id = row.get("following_npc_id")
		if following_npc_id != null:
			entry["following_id"] = String(following_npc_id)
		characters[row["npc_id"]] = entry

	return {
		"day": int(world_rows[0]["day"]),
		"allow_player_join": bool(world_rows[0]["allow_player_join"]),
		"characters": characters,
	}


## 寫入一個世界的完整資料
##
## world_character_state 的 npc_id 有 FK 指向 npc(npc_id)：呼叫順序（debug
## console `save` 指令的順序）是先把場上每個角色各自 save_character()
## 過一輪、才呼叫這裡，所以正常情況下 npc row 都已存在；萬一沒有（呼叫端
## 沒照這個順序），一樣跳過那一筆、記警告，不讓整包寫入失敗
func save_world(id: String, data: Dictionary) -> bool:
	if not DatabaseManager.begin_transaction():
		return false

	var ok := _upsert_world(id, data)

	if ok:
		ok = DatabaseManager.delete("world_character_state", "world_id = '%s'" % _esc(id))

	if ok:
		ok = _replace_world_characters(id, data.get("characters", {}))

	if not ok:
		DatabaseManager.rollback_transaction()
		return false

	if DatabaseManager.commit_transaction():
		return true

	# 同 save_character() 的理由：COMMIT 失敗不代表交易已經結束，沒有這個
	# rollback 下一次 begin_transaction() 會跟著失敗
	DatabaseManager.rollback_transaction()
	return false


## ===================================================================
## 內部：角色
## ===================================================================


func _upsert_npc(id: String, data: Dictionary) -> bool:
	var row := {"name": String(data.get("character_name", ""))}

	if DatabaseManager.select("npc", "npc_id = '%s'" % _esc(id)).is_empty():
		row["npc_id"] = id
		return DatabaseManager.insert("npc", row)

	return DatabaseManager.update("npc", row, "npc_id = '%s'" % _esc(id))


func _upsert_npc_state(id: String, stats: Dictionary) -> bool:
	var row := {}
	for key in STATE_COLUMNS:
		if stats.has(key):
			row[key] = stats[key]

	if DatabaseManager.select("npc_state", "npc_id = '%s'" % _esc(id)).is_empty():
		row["npc_id"] = id
		return DatabaseManager.insert("npc_state", row)

	# 沒有任何一項對得上（例如 stats 是空 Dictionary）就不必發一次空 UPDATE
	if row.is_empty():
		return true

	return DatabaseManager.update("npc_state", row, "npc_id = '%s'" % _esc(id))


func _replace_relationships(id: String, relationships: Dictionary) -> bool:
	for target_id in relationships:
		if DatabaseManager.select("npc", "npc_id = '%s'" % _esc(target_id)).is_empty():
			push_warning(
				"SqliteSaveService: npc_relations 跳過 %s → %s，目標角色不存在"
				% [id, target_id]
			)
			continue

		var record: Dictionary = relationships[target_id]
		var row := {
			"character_id": id,
			"target_id": target_id,
			"relations_appearance_cache": String(record.get("appearance_cache", "")),
			"relations_met_count": int(record.get("met_count", 0)),
		}

		if not DatabaseManager.insert("npc_relations", row):
			return false

	return true


## npc_id UNIQUE，跟 _upsert_npc_state() 同一種先查後決定 insert/update 的寫法。
##
## 這裡不驗證 personality 的結構，直接信任呼叫端——不是因為存檔路徑一定會
## 先經過 Character.load_save_data() 的驗證（正常自動存檔路徑，例如睡醒
## 觸發的存檔、debug console 的 save 指令，都是直接把 get_save_data() 的
## 結果餵給 save_character()，不會經過 load_save_data()），而是因為
## Character.personality 這個欄位本身在記憶體裡永遠保持結構完整：只有三個
## 地方會寫它——Personality.from_identity()（建構時，10 項齊全）、
## load_save_data()（已驗證過才覆寫）、睡前反思的 personality_delta 套用
## （對既有的合法 10 項加總後 clampf，不改變鍵集合）。上一版註解誤把「存檔
## 路徑會先驗證」當成信任的理由，實際上不成立（CodeRabbit review 抓到）
func _upsert_npc_personality(id: String, personality: Dictionary) -> bool:
	var row := {}
	for key in PERSONALITY_COLUMNS:
		if personality.has(key):
			row[key] = personality[key]

	if row.is_empty():
		return true

	if DatabaseManager.select("npc_personality", "npc_id = '%s'" % _esc(id)).is_empty():
		row["npc_id"] = id
		return DatabaseManager.insert("npc_personality", row)

	return DatabaseManager.update("npc_personality", row, "npc_id = '%s'" % _esc(id))


## 呼叫端（save_character()）已經先 delete 過這個 npc 的舊列——這裡只管
## insert，跟 _replace_relationships() 同一種「整批覆蓋」模式（見 header）。
## game_day 用現在的 GameClock.day：npc_daily_plan 設計上允許同一 npc/day
## 有多列（今日計畫本來就有好幾項），不是拿它當唯一性鍵
func _replace_daily_plan(id: String, today_plan: Array) -> bool:
	for item in today_plan:
		if not item is Dictionary:
			continue
		var entry: Dictionary = item
		var row := {
			"npc_id": id,
			"game_day": GameClock.day,
			"text": String(entry.get("text", "")),
			"is_done": 1 if entry.get("is_done", false) else 0,
		}
		if not DatabaseManager.insert("npc_daily_plan", row):
			return false

	return true


## ===================================================================
## 內部：世界
## ===================================================================


func _upsert_world(id: String, data: Dictionary) -> bool:
	var row := {
		"day": int(data.get("day", 1)),
		"allow_player_join": 1 if data.get("allow_player_join", false) else 0,
	}

	if DatabaseManager.select("world", "world_id = '%s'" % _esc(id)).is_empty():
		row["world_id"] = id
		return DatabaseManager.insert("world", row)

	return DatabaseManager.update("world", row, "world_id = '%s'" % _esc(id))


func _replace_world_characters(world_id: String, characters: Dictionary) -> bool:
	for npc_id in characters:
		if DatabaseManager.select("npc", "npc_id = '%s'" % _esc(npc_id)).is_empty():
			push_warning(
				"SqliteSaveService: world_character_state 跳過 %s，npc 表裡沒有這筆角色"
				% npc_id
			)
			continue

		var entry: Dictionary = characters[npc_id]
		var position: Array = entry.get("position", [0.0, 0.0])
		var row := {
			"world_id": world_id,
			"npc_id": npc_id,
			"pos_x": float(position[0]) if position.size() > 0 else 0.0,
			"pos_y": float(position[1]) if position.size() > 1 else 0.0,
		}
		var current_place = entry.get("current_place")
		if current_place != null:
			row["current_place"] = String(current_place)
			var current_state = entry.get("current_state")
			row["current_state"] = "" if current_state == null else String(current_state)

		# following_id（issue #576）空字串代表沒在跟隨任何人，跟
		# GameManager.get_world_save_data() 存進來的規則一致（見那邊
		# following_id.is_empty() 判斷），這裡才不寫入 following_npc_id，
		# 讓 row 沿用 INSERT 時的隱含 NULL。
		#
		# 跟隨對象存不存在也要先查（CodeRabbit review 抓到，跟
		# _replace_relationships() 對 target_id 同一套防呆）：跟隨對象可能
		# 在下次存檔前就離開世界（npc 表裡已經沒有這筆），這裡的外鍵是
		# ON DELETE SET NULL，但那只保護「已經存進去之後，對方後來被刪」
		# 這個情境，保護不了「這次 INSERT 當下對方就已經不在」——直接塞一個
		# 查無此人的 npc_id 會讓這筆 INSERT 違反外鍵限制，害整個
		# _replace_world_characters() 的整批覆蓋 rollback
		var following_id = entry.get("following_id")
		if following_id != null and not String(following_id).is_empty():
			var following_npc_id := String(following_id)
			if DatabaseManager.select("npc", "npc_id = '%s'" % _esc(following_npc_id)).is_empty():
				push_warning(
					"SqliteSaveService: world_character_state 的 %s following_id 跳過，%s 不在 npc 表裡"
					% [npc_id, following_npc_id]
				)
			else:
				row["following_npc_id"] = following_npc_id

		if not DatabaseManager.insert("world_character_state", row):
			return false

	return true


## ===================================================================
## 內部：共用
## ===================================================================


## WHERE 子句裡的字串一律過這裡——character_id/npc_id 正常來說是
## Character.generate_id() 生的 UUID v4，不會含單引號，但這裡不假設呼叫端
## 一定守規矩（DatabaseManager.gd 檔頭已經講過這條界線：conditions 只能由
## 程式碼自己組，不可以放模型或玩家輸入的字串，這裡多一層防線不吃虧）
func _esc(value: String) -> String:
	return value.replace("'", "''")


## ===================================================================
## schema 缺口
##
## 下列是《06》／《技術/存檔》有、Ailley/database/schemas/ 沒有的東西。
## 目前用預設值頂著或直接遺失，實際要不要加欄位要先拍板（登記在
## 《99 待規劃項目清單》）：
##
## npc 沒有 version     《14》§2 講的並行寫入保護欄位沒有掛靠——SQLite 這邊
##                      實際靠 transaction 保護，不是 version CAS，見檔頭
## npc_relations        少了 last_seen（#497 之後 Relationships.DEFAULT_RECORD
##                      新增的欄位，SQLite 後端 round-trip 之後會變回 -1「從沒
##                      見過」，見 #497；met_count 已由 #704 補上）
## npc_state            少了 mood/social/fun 三項（Stats.SPEC 有這三項，
##                      npc_state 只對到《01》§4-1 的 8 項生理狀態）
## npc_emotion          NPCEmotionSchema.gd 已建表，但 get_character()/
##                      save_character() 沒有讀寫它——Character.get_save_data()
##                      現在會產生 emotion 欄位（issue #688），round-trip 之後
##                      SQLite 這條路徑會遺失情緒殘留，退回中性。
##                      JsonSaveService（目前使用中）不受影響
## memory                Character.get_save_data() 現在會產生 memory 欄位
##                      （#170，只有 L2/L4），但 get_character()/save_character()
##                      沒有讀寫它——round-trip 之後整段記憶遺失。schema 已有
##                      MemorySchema.gd（memories／memory_related_npcs 兩張表），
##                      要接上是把既有表接進這裡的四個函式，不是新增 schema
## world 沒有 type／     get_world_save_data()（#344）多存的角色 type
## character_library    （agent／player）跟 character_library（#342）都沒有
##                      對應欄位——world／world_character_state schema 沒有
##                      這兩欄，get_world()/save_world() 也沒讀寫。round-trip
##                      之後 character_library 會變空清單，缺席角色重生只能
##                      預設當 Agent、遺失角色庫身分。JsonSaveService（目前
##                      使用中）不受影響
##
## 下列是《06》定義、但目前 Character/GameManager 根本沒有在存的欄位——
## 不是這裡的 schema 缺口，是上游還沒做，SqliteSaveService 目前故意不接：
## identity 的 age/gender/village_id/home_location_id/decision_source/
## model_name、hexaco_input、economy、
## state.conditions/current_goal/appointment（emotion 已於 issue #688 接上
## Character.get_save_data()，移到上面的 schema 缺口清單）
## ===================================================================
