class_name DatabaseSchema
extends RefCounted


## =====================================================
## DatabaseSchema
##
## Ailley Database Schema Controller
##
## 職責：
## 1. 統一管理所有資料表 Schema
## 2. 決定資料表建立順序
## 3. 將 SQLite db 傳給各個 Schema
## 4. 不直接撰寫資料表 SQL
##
## 每張資料表應該獨立存在：
##
## LocationSchema.gd
## NPCSchema.gd
## NPCStateSchema.gd
## ...
##
## 每個 Schema 都必須提供：
##
## static func create(db) -> bool
##
## =====================================================


## =====================================================
## 初始化所有資料表
## =====================================================

static func initialize(db) -> bool:

	print(
		"[DatabaseSchema] initialize() entered."
	)


	# =================================================
	# 檢查 Database
	# =================================================

	if db == null:

		push_error(
			"[DatabaseSchema] Database object is null."
		)

		return false


	print(
		"[DatabaseSchema] Creating database schema..."
	)


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
		# 05. Item
		# -------------------------------------------------

		ItemSchema,


		# -------------------------------------------------
		# 06. Inventory / Storage
		# -------------------------------------------------

		NPCInventorySchema,
		NPCHomeStorageSchema,


		# -------------------------------------------------
		# 07. Relations
		# -------------------------------------------------

		NPCRelationsSchema,


		# -------------------------------------------------
		# 08. Economy
		# -------------------------------------------------

		NPCWalletSchema,
		MoneyTransactionSchema,
		ItemTransactionSchema
	]


	print(
		"[DatabaseSchema] Schema count: ",
		schemas.size()
	)


	# =================================================
	# 逐一建立資料表
	# =================================================

	for i in range(schemas.size()):

		var schema = schemas[i]


		print(
			"[DatabaseSchema] [",
			i + 1,
			"/",
			schemas.size(),
			"] Creating: ",
			schema
		)


		# ---------------------------------------------
		# Schema 是否存在
		# ---------------------------------------------

		if schema == null:

			push_error(
				"[DatabaseSchema] Schema is null at index "
				+ str(i)
			)

			return false


		# ---------------------------------------------
		# 建立資料表
		# ---------------------------------------------

		if not schema.create(db):

			push_error(
				"[DatabaseSchema] Failed to create schema: "
				+ str(schema)
			)

			return false


		print(
			"[DatabaseSchema] Successfully created: ",
			schema
		)


	# =================================================
	# 完成
	# =================================================

	print(
		"[DatabaseSchema] All tables created successfully."
	)


	return true
