class_name DatabaseSchema
extends RefCounted


## =====================================================
## DatabaseSchema
##
## 職責：
## 1. 統一管理所有資料表 Schema
## 2. 決定資料表建立順序
## 3. 將 SQLite db 傳給各個 Schema
## 4. 用 PRAGMA user_version 追蹤 schema 版本，套用落後的 migration
## 5. 不直接撰寫資料表 SQL
##
## 每張資料表一支 .gd，各自提供：
##
##     static func create(db) -> bool
##
## =====================================================


## schema 目前的版本。哪一支 *Schema.gd 的欄位／CHECK／FK／索引改了，
## 導致既有 user://game.db 建出來的 table 跟新版 CREATE TABLE 對不上時，
## 這裡加一，並在 MIGRATIONS 補上對應 entry。純新增 table 不算——
## CREATE TABLE IF NOT EXISTS 自己會建，不需要 migration。
const CURRENT_VERSION := 1


## 版本落後時依序套用的變更，每個 entry：
##
##     { "version": <int>, "name": <String>, "apply": <Callable(db)->bool> }
##
## apply 只處理「既有 table 的結構變更」（ALTER TABLE／重建搬資料），
## 不要重複 CREATE TABLE——新表由 initialize() 裡的 schemas 陣列建立，
## 兩者跑在同一個 transaction 裡。
##
## 版本必須遞增排列。目前沒有版本落後的既有安裝要處理，所以是空的——
## 下次 schema 出現不相容變更時，在這裡按版本加一項，同時把
## CURRENT_VERSION 加一。
const MIGRATIONS: Array[Dictionary] = []


static func initialize(db) -> bool:
	if db == null:
		push_error("[DatabaseSchema] Database object is null.")
		return false


	# =================================================
	# 所有 Schema
	#
	# 注意：
	# 這裡的順序非常重要。
	#
	# 有 Foreign Key 的資料表，
	# 必須在被參照的資料表建立之後建立。
	# =================================================

	var schemas := [

		# -------------------------------------------------
		# 01. World
		# -------------------------------------------------

		WorldSchema,
		LocationSchema,


		# -------------------------------------------------
		# 02. NPC Core
		# -------------------------------------------------

		NPCSchema,
		NPCStateSchema,
		NPCScheduleSchema,


		# -------------------------------------------------
		# 03. NPC Profile
		# -------------------------------------------------

		NPCPersonalitySchema,
		NPCAppearanceSchema,
		NPCOccupationSchema,
		NPCTabooSchema,


		# -------------------------------------------------
		# 04. NPC AI
		# -------------------------------------------------

		NPCEmotionSchema,
		NPCConditionSchema,
		NPCGoalSchema,
		NPCDailyPlanSchema,
		NPCLastActionSchema,


		# -------------------------------------------------
		# 05. NPC Memory
		# -------------------------------------------------

		MemorySchema,


		# -------------------------------------------------
		# 06. NPC Death
		# -------------------------------------------------

		NPCDeathSchema,
		GraveSchema,
		GraveHighlightSchema,
		GraveEpitaphSchema,


		# -------------------------------------------------
		# 07. Item
		# -------------------------------------------------

		ItemSchema,


		# -------------------------------------------------
		# 08. Inventory / Storage
		# -------------------------------------------------

		NPCInventorySchema,
		NPCHomeStorageSchema,


		# -------------------------------------------------
		# 09. Relations
		# -------------------------------------------------

		NPCRelationsSchema,


		# -------------------------------------------------
		# 10. Economy
		# -------------------------------------------------

		NPCWalletSchema,
		MoneyTransactionSchema,
		ItemTransactionSchema,


		# -------------------------------------------------
		# 11. World Character State
		# -------------------------------------------------

		WorldCharacterStateSchema
	]


	var stored_version := _get_user_version(db)


	# =================================================
	# 整批包在一個 transaction 裡。
	#
	# SQLite 的 DDL 可以進 transaction，所以中間任何一張表失敗
	# 就整個回滾。否則會留下一個建到一半的資料庫，而且因為用的是
	# CREATE TABLE IF NOT EXISTS，下次開機也不會自己修好。
	#
	# PRAGMA user_version 的寫入也在同一個 transaction 裡——
	# migration 沒套完就不該讓版本號提前跳到新的。
	# =================================================

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


	if not _apply_migrations(db, stored_version, MIGRATIONS):
		db.query("ROLLBACK;")
		return false


	if not _set_user_version(db, CURRENT_VERSION):
		push_error(
			"[DatabaseSchema] Failed to set user_version to %d: %s"
			% [CURRENT_VERSION, db.error_message]
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


	print(
		"[DatabaseSchema] %d schemas created, schema version %d."
		% [schemas.size(), CURRENT_VERSION]
	)

	return true


## 依序套用版本 > from_version 的 migration，任何一個失敗就中止
## （呼叫端負責 ROLLBACK）。migrations 走參數傳入而不是直接讀
## MIGRATIONS 常數，是為了讓測試可以餵一份假清單進來驗證套用順序／
## 失敗中止的邏輯，不需要真的改動 schema。
static func _apply_migrations(
	db,
	from_version: int,
	migrations: Array[Dictionary]
) -> bool:
	var pending := migrations.filter(
		func(m): return m["version"] > from_version
	)

	pending.sort_custom(func(a, b): return a["version"] < b["version"])

	for migration in pending:
		if migration["apply"].call(db):
			print(
				"[DatabaseSchema] Migration %d (%s) applied."
				% [migration["version"], migration["name"]]
			)
			continue

		push_error(
			"[DatabaseSchema] Migration %d (%s) failed: %s"
			% [migration["version"], migration["name"], db.error_message]
		)
		return false

	return true


## PRAGMA user_version 是存在資料庫檔頭的整數，新資料庫預設是 0。
static func _get_user_version(db) -> int:
	if not db.query("PRAGMA user_version;"):
		push_error(
			"[DatabaseSchema] Failed to read user_version: "
			+ db.error_message
		)
		return 0

	var result: Array = db.query_result

	if result.is_empty():
		return 0

	return int(result[0].values()[0])


static func _set_user_version(db, version: int) -> bool:
	return db.query("PRAGMA user_version = %d;" % version)


## schema 是 GDScript class，直接 str() 出來會是 <GDScript#...>，
## 看不出是哪張表。
static func _schema_name(schema) -> String:
	return str(schema.resource_path).get_file().get_basename()
