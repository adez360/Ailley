class_name DatabaseSchema
extends RefCounted


## =====================================================
## DatabaseSchema
##
## 統一建立所有 SQLite tables。
##
## 注意：
## SQLite 的 CREATE TABLE 本身不要求父表先存在；
## 啟用 FK 後，真正要求父表存在的是 INSERT / UPDATE。
## 因此這裡仍依賴順序建立父表，但不把它描述成 SQLite
## 的 CREATE TABLE 強制規則。
##
## 版本控管：
## 全部 table 都用 CREATE TABLE IF NOT EXISTS，schema 改了
## 也不會補進已存在的舊資料庫。用 PRAGMA user_version 記錄
## 目前的 schema 版本；偵測到既有資料庫的版本對不上，代表
## 那個 user://game.db 是用舊 schema 建的，直接拒絕啟動，
## 不要靜默帶著不完整的欄位跑下去。目前沒有 migration 機制，
## 版本不符時只能刪掉 user://game.db 重來。
## =====================================================


## schema 有不相容變動（新增/刪除欄位、table）時要遞增。
const SCHEMA_VERSION := 1


static func initialize(db) -> bool:
	if db == null:
		push_error("[DatabaseSchema] Database object is null.")
		return false

	var existing_table_count := _count_tables(db)
	var stored_version := _get_user_version(db)

	if existing_table_count > 0 and stored_version != SCHEMA_VERSION:
		push_error(
			"[DatabaseSchema] 偵測到舊版資料庫（user_version=%d，目前程式需要 %d），"
			% [stored_version, SCHEMA_VERSION]
			+ "沒有 migration 機制可以補齊欄位，拒絕啟動。"
			+ "請刪除 user://game.db 後重新啟動（會遺失既有存檔）。"
		)
		return false

	var schemas := [

		# -------------------------------------------------
		# 01. World
		# -------------------------------------------------

		WorldSchema,
		LocationSchema,

		# NPC Core
		NPCSchema,
		NPCStateSchema,
		NPCScheduleSchema,

		# NPC Profile
		NPCPersonalitySchema,
		NPCAppearanceSchema,
		NPCOccupationSchema,
		NPCTabooSchema,

		# NPC AI
		NPCEmotionSchema,
		NPCConditionSchema,
		NPCGoalSchema,
		NPCDailyPlanSchema,
		NPCLastActionSchema,

		# NPC Memory
		MemorySchema,

		# NPC Death
		NPCDeathSchema,
		GraveSchema,
		GraveHighlightSchema,
		GraveEpitaphSchema,

		# Item
		ItemSchema,

		# Inventory / Storage
		NPCInventorySchema,
		NPCHomeStorageSchema,

		# Relations
		NPCRelationsSchema,

		# Economy
		NPCWalletSchema,
		MoneyTransactionSchema,
		ItemTransactionSchema,


		# -------------------------------------------------
		# 11. World Character State
		# -------------------------------------------------

		WorldCharacterStateSchema
	]

	if not db.query("BEGIN TRANSACTION;"):
		push_error(
			"[DatabaseSchema] BEGIN failed: "
			+ db.error_message
		)
		return false

	for schema in schemas:
		if schema.create(db):
			continue

		push_error(
			"[DatabaseSchema] Failed to create %s: %s"
			% [_schema_name(schema), db.error_message]
		)

		db.query("ROLLBACK;")
		return false

	if not db.query("COMMIT;"):
		push_error(
			"[DatabaseSchema] COMMIT failed: "
			+ db.error_message
		)
		db.query("ROLLBACK;")
		return false

	if not _set_user_version(db, SCHEMA_VERSION):
		push_error(
			"[DatabaseSchema] 寫入 PRAGMA user_version 失敗：%s"
			% db.error_message
		)
		return false

	var table_count := _count_tables(db)

	print(
		"[DatabaseSchema] Schema classes: %d | SQLite tables: %d"
		% [
			schemas.size(),
			table_count
		]
	)

	return true


static func _schema_name(schema) -> String:
	return str(schema.resource_path).get_file().get_basename()


## 實際算出目前建立了幾張 table，不用手動維護的數字——
## schema class 數量跟 table 數量本來就不是一對一
## （例如 MemorySchema 額外建立 memory_related_npcs）。
static func _count_tables(db) -> int:
	if not db.query(
		"SELECT COUNT(*) AS table_count FROM sqlite_master "
		+ "WHERE type = 'table' AND name NOT LIKE 'sqlite_%';"
	):
		return -1

	if db.query_result.is_empty():
		return -1

	return int(db.query_result[0].get("table_count", -1))


## SQLite 檔案沒設過 PRAGMA user_version 時預設是 0，
## 全新建立的資料庫檔案也是 0 —— 呼叫端要自己配合
## existing_table_count 判斷是「全新」還是「舊版沒記錄版本」。
static func _get_user_version(db) -> int:
	if not db.query("PRAGMA user_version;"):
		return -1

	if db.query_result.is_empty():
		return -1

	return int(db.query_result[0].get("user_version", -1))


static func _set_user_version(db, version: int) -> bool:
	return db.query(
		"PRAGMA user_version = %d;"
		% version
	)
