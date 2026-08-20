extends "res://scripts/save/save_service.gd"
class_name SqliteSaveService

## SaveService 的 SQLite 實作，走 DatabaseManager autoload 存取
## DatabaseManager.DATABASE_PATH。
## 介面定義見 note/規格書/14_存檔資料存取層規格書.md §2。
##
## 《14》§5 要求兩個實作的資料形狀必須一致——這裡讀寫的 Dictionary 形狀
## 對齊的是 JsonSaveService 實際存的內容（Character.get_save_data() /
## GameManager.get_world_save_data() 現在真正吐出來的東西），不是《06 資料
## 欄位對應表》§1 那份完整形狀——後者描述的 identity/hexaco/personality/
## economy/state.emotion/memory 現在還沒有任何 Character 欄位在產生，接了
## 也沒有呼叫端能餵資料進來，見 note/技術/存檔.md「現況」與下方「schema 缺口」。
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

## npc_state 撈不到那一列時（例如 npc 存在但還沒存過狀態）用這份補齊
## STATE_COLUMNS，不要回傳空 stats——跟檔頭「缺值補預設值，不省略 key」
## 一致。數值抄自 NPCStateSchema.gd 的 DEFAULT，兩邊要一起改
const STATE_DEFAULTS := {
	"satiety": 100.0, "hydration": 80.0, "stamina": 80.0, "wakefulness": 90.0,
	"hygiene": 70.0, "alcohol": 0.0, "health": 100.0, "injury": 0.0,
}


## 讀一個角色的完整資料，找不到回傳空 Dictionary
##
## 回傳形狀跟 Character.get_save_data() 一致：
##     { character_id, character_name, stats{8 項}, relationships{ <target_id>: {trust, appearance_cache} } }
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
			"trust": row["relations_trust"],
			"appearance_cache": row["relations_appearance_cache"],
		}
	data["relationships"] = relationships

	return data


## 寫入一個角色的完整資料（整包覆蓋，不做局部欄位更新）
##
## 收的 Dictionary 形狀跟 get_character() 回傳的一致。
##
## npc_relations 的 target_id 有 FK 指向 npc(npc_id)：目標角色這時如果還沒
## 存過（例如場上另一個角色在同一輪 debug console `save` 迴圈裡還沒輪到），
## 那一筆關係先跳過、記警告，不讓整包寫入失敗——下次雙方都存過之後這筆
## 關係就補得回來，見 PR 討論。
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


## 讀一個世界的完整資料
##
## 回傳形狀跟 GameManager.get_world_save_data() 一致：
##     { day, allow_player_join, characters{ <npc_id>: {position[x,y], current_place?, current_state?} } }
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
			"relations_trust": record.get("trust", 20.0),
			"relations_appearance_cache": String(record.get("appearance_cache", "")),
		}

		if not DatabaseManager.insert("npc_relations", row):
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
## npc_relations        少了 met_count（Relationships.DEFAULT_RECORD 有，
##                      round-trip 之後這個數字會遺失，重開後從 0 起算）
## npc_state            少了 mood/social/fun 三項（Stats.SPEC 有這三項，
##                      npc_state 只對到《01》§4-1 的 8 項生理狀態）
## memory                Character.get_save_data() 現在會產生 memory 欄位
##                      （#170，只有 L2/L4），但 get_character()/save_character()
##                      沒有讀寫它——round-trip 之後整段記憶遺失。schema 已有
##                      MemorySchema.gd（memories／memory_related_npcs 兩張表），
##                      要接上是把既有表接進這裡的四個函式，不是新增 schema
##
## 下列是《06》定義、但目前 Character/GameManager 根本沒有在存的欄位——
## 不是這裡的 schema 缺口，是上游還沒做，SqliteSaveService 目前故意不接：
## identity 的 age/gender/village_id/home_location_id/decision_source/
## model_name、hexaco_input、personality、economy、
## state.emotion/conditions/current_goal/today_plan/appointment
## ===================================================================
