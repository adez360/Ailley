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
## =====================================================


static func initialize(db) -> bool:
	if db == null:
		push_error("[DatabaseSchema] Database object is null.")
		return false

	var schemas := [
		# World
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
		ItemTransactionSchema
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

	print(
		"[DatabaseSchema] %d schema classes created."
		% schemas.size()
	)

	# 25 個 Schema class 目前建立 26 張 SQLite table：
	# MemorySchema 另外建立 memory_related_npcs。
	print(
		"[DatabaseSchema] Schema classes: %d | SQLite tables: 26"
		% schemas.size()
	)

	return true


static func _schema_name(schema) -> String:
	return str(schema.resource_path).get_file().get_basename()
