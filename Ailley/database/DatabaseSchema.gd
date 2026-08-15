class_name DatabaseSchema
extends RefCounted


## =====================================================
## DatabaseSchema
##
## 職責：
## 1. 統一管理所有資料表 Schema
## 2. 決定資料表建立順序
## 3. 將 SQLite db 傳給各個 Schema
## 4. 不直接撰寫資料表 SQL
##
## 每張資料表一支 .gd，各自提供：
##
##     static func create(db) -> bool
##
## =====================================================


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

		LocationSchema,


		# -------------------------------------------------
		# 02. NPC Core
		# -------------------------------------------------

		NPCSchema,
		NPCStateSchema,
		NPCScheduleSchema,

		# Player + NPC 共用即時狀態
		CharacterStateSchema,

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
		ItemTransactionSchema
	]


	# =================================================
	# 整批包在一個 transaction 裡。
	#
	# SQLite 的 DDL 可以進 transaction，所以中間任何一張表失敗
	# 就整個回滾。否則會留下一個建到一半的資料庫，而且因為用的是
	# CREATE TABLE IF NOT EXISTS，下次開機也不會自己修好。
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


	if not db.query("COMMIT;"):
		push_error(
			"[DatabaseSchema] COMMIT failed: "
			+ db.error_message
		)

		db.query("ROLLBACK;")
		return false


	print(
		"[DatabaseSchema] %d schemas created."
		% schemas.size()
	)

	return true


## schema 是 GDScript class，直接 str() 出來會是 <GDScript#...>，
## 看不出是哪張表。
static func _schema_name(schema) -> String:
	return str(schema.resource_path).get_file().get_basename()
