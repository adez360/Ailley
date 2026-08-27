class_name GraveEpitaphPersistence
extends RefCounted

## 悼詞讀寫（#385）。`grave`／`grave_epitaphs` 兩張表在這之前完全沒有任何
## 呼叫端寫過（只在 schema 定義與 DatabaseCRUDTest.gd 出現過，見《99》P-50
## 查證紀錄）——這裡是第一個真正的寫入路徑。
##
## grave 那一列採「第一次留悼詞時懶建立」（2026-08-27 拍板）：不碰
## bury()／_die()，改動範圍只留在悼詞這條路徑本身。只對已安葬
## （is_buried == true）的角色成立——墓碑是「已安葬」這個狀態的產物，
## 跟《規格書09》§4-3「未安葬不顯示遺言/生平」同一種「沒有墓碑」的語意，
## 這裡延伸到悼詞。
##
## grave 表其餘欄位（death_cause／last_words／words_to_creator）故意不填：
## 《99》P-50 已經定案這幾欄是跟 JSON 存檔重複的快照欄位、沒有任何讀取端
## 使用，schema 本身也都有 DEFAULT，不補值不影響任何功能。


## 找 corpse 對應的 grave_id，沒有就建立一筆。回傳 -1 代表失敗或未安葬。
static func ensure_grave_id(corpse: Character) -> int:
	if corpse == null or not corpse.is_buried:
		return -1

	var npc_id := corpse.character_id
	var existing := DatabaseManager.select_where("grave", "npc_id = ?", [npc_id], ["grave_id"])
	if not existing.is_empty():
		return int(existing[0]["grave_id"])

	var location_id := _ensure_cemetery_location_id()
	if location_id.is_empty():
		return -1

	var grave_data := {
		"npc_id": npc_id,
		"location_id": location_id,
		"buried_by": corpse.buried_by,
		"buried_tick": corpse.buried_tick,
	}
	if not DatabaseManager.insert("grave", grave_data):
		return -1

	var inserted := DatabaseManager.select_where("grave", "npc_id = ?", [npc_id], ["grave_id"])
	if inserted.is_empty():
		return -1
	return int(inserted[0]["grave_id"])


## grave.location_id 外鍵指向 location(location_id)，但 SQL 的 location 表
## 目前完全沒有真正跟著 places.gd／PlaceAnchors 的世界地點同步——現況只有
## _resolve_home_location()（CharacterStatePersistence.gd）懶建立的
## home_001 佔位列，"loc_cemetery" 這個規格書 §6 寫的 id 從沒被建過（稽查
## #385 時發現，跟 grave 表本身沒人寫過是同一種缺口）。這裡照抄同一招：
## 找不到就懶建立一筆最小可用的佔位列，不等 location 表真正跟世界地圖同步
## 回傳空字串代表建立失敗——呼叫端（ensure_grave_id）要能分辨「真的建好了」
## 跟「建立失敗但硬塞一個 id 回去」，不然失敗的 location 列會讓 grave 帶著
## 一個實際上不存在的外鍵去 INSERT，錯誤會延後到 grave 那層才爆、訊息不直觀
## （CodeRabbit review 抓到，PR #622）
static func _ensure_cemetery_location_id() -> String:
	const CEMETERY_LOCATION_ID := "loc_cemetery"

	var existing := DatabaseManager.select_where(
		"location", "location_id = ?", [CEMETERY_LOCATION_ID], ["location_id"]
	)
	if not existing.is_empty():
		return CEMETERY_LOCATION_ID

	if not DatabaseManager.insert("location", {
		"location_id": CEMETERY_LOCATION_ID,
		"name": "Cemetery",
		"description": "The village cemetery.",
		"location_type": "cemetery",
		"capacity": 6,
		"danger": 0,
		"is_active": 1,
	}):
		return ""
	return CEMETERY_LOCATION_ID


## 留言／覆寫悼詞。author 是留言的人，corpse 是墓碑主人。回傳空字串代表成功，
## 否則是失敗原因碼。40 字上限交給 grave_epitaphs 的 CHECK 約束擋
## （GraveEpitaphSchema.gd），這裡不重複驗證——UI 端用 LineEdit.max_length
## 事前防呆就夠，見 epitaph_input.gd
static func write_epitaph(author: Character, corpse: Character, content: String) -> String:
	if author == null or corpse == null:
		return "TARGET_NOT_FOUND"

	var trimmed := content.strip_edges()
	if trimmed.is_empty():
		return "EMPTY"

	var grave_id := ensure_grave_id(corpse)
	if grave_id < 0:
		return "GRAVE_UNAVAILABLE"

	# 悼詞作者要先有 npc 記錄，grave_epitaphs.npc_id 才有外鍵可以指——玩家
	# 也會被 _ensure_npc_record() 收進 npc 表（見 CharacterStatePersistence.gd），
	# 不是只有 AI 角色才有
	var persistence := DatabaseManager.get_node_or_null("CharacterStatePersistence")
	if persistence == null or not persistence.sync_character(author):
		return "AUTHOR_SYNC_FAILED"

	var author_id := author.character_id
	var existing := DatabaseManager.select_where(
		"grave_epitaphs", "grave_id = ? AND npc_id = ?", [grave_id, author_id], ["epitaph_id"]
	)

	if existing.is_empty():
		var ok := DatabaseManager.insert(
			"grave_epitaphs", {"grave_id": grave_id, "npc_id": author_id, "content": trimmed}
		)
		return "" if ok else "WRITE_FAILED"

	# 覆寫——每人對同一座墓限 1 條（UNIQUE (grave_id, npc_id)），舊的不保留
	var epitaph_id := int(existing[0]["epitaph_id"])
	var ok := DatabaseManager.update(
		"grave_epitaphs", {"content": trimmed}, "epitaph_id = %d" % epitaph_id
	)
	return "" if ok else "WRITE_FAILED"
