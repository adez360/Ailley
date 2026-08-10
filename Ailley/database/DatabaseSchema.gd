class_name DatabaseSchema
extends RefCounted


## ============================================================
## Ailley Database Schema
## ============================================================
##
## 負責：
## 1. 建立 SQLite 所有資料表
## 2. 建立 NPC 相關資料表
## 3. 建立必要的基礎資料表
## 4. 建立 Index
##
## ============================================================
##
## NPC 主要資料表：
##
## 01. npc
## 02. npc_personality
## 03. npc_appearance
## 04. npc_occupation
## 05. npc_creator_message
## 06. npc_taboo
## 07. npc_state
## 08. npc_emotion
## 09. npc_condition
## 10. npc_goal
## 11. npc_daily_plan
## 12. npc_last_action
## 13. npc_inventory
## 14. npc_home_storage
## 15. npc_relations
##
## 目前專案 Seeder 額外需要：
##
## 16. location
## 17. npc_schedule
##
## ============================================================
##
## 注意：
##
## Memory 暫時不建立。
##
## item / event 目前規格尚未完成，因此暫時只保存
## item_id / cause_event_id，不建立 FK。
##
## ============================================================


# ============================================================
# 初始化
# ============================================================

func initialize() -> bool:

	print("========================================")
	print("[DatabaseSchema] Starting initialization...")
	print("========================================")

	# 確認 DatabaseManager 已經開啟資料庫
	if DatabaseManager.db == null:
		push_error(
			"[DatabaseSchema] DatabaseManager.db is null."
		)
		return false

	var db = DatabaseManager.db

	# 啟用 Foreign Key
	db.query("PRAGMA foreign_keys = ON;")

	# ========================================================
	# 基礎資料表
	# ========================================================

	if not _create_location_table(db):
		return false

	if not _create_npc_schedule_table(db):
		return false

	# ========================================================
	# NPC 主表
	# ========================================================

	if not _create_npc_table(db):
		return false

	# ========================================================
	# NPC 身分 / 人格
	# ========================================================

	if not _create_npc_personality_table(db):
		return false

	if not _create_npc_appearance_table(db):
		return false

	if not _create_npc_occupation_table(db):
		return false

	if not _create_npc_creator_message_table(db):
		return false

	if not _create_npc_taboo_table(db):
		return false

	# ========================================================
	# NPC 狀態
	# ========================================================

	if not _create_npc_state_table(db):
		return false

	if not _create_npc_emotion_table(db):
		return false

	if not _create_npc_condition_table(db):
		return false

	if not _create_npc_goal_table(db):
		return false

	if not _create_npc_daily_plan_table(db):
		return false

	if not _create_npc_last_action_table(db):
		return false

	# ========================================================
	# NPC 經濟
	# ========================================================

	if not _create_npc_inventory_table(db):
		return false

	if not _create_npc_home_storage_table(db):
		return false

	# ========================================================
	# NPC 社會
	# ========================================================

	if not _create_npc_relations_table(db):
		return false

	# ========================================================
	# Index
	# ========================================================

	if not _create_indexes(db):
		return false

	print("========================================")
	print("[DatabaseSchema] Initialization completed.")
	print("========================================")

	return true


# ============================================================
# 01. location
# ============================================================
#
# 目前 DatabaseSeeder 已經會寫入這張表。
#
# 來源：
# res://data/places.json
#
# ============================================================

func _create_location_table(db) -> bool:

	var sql := """
	CREATE TABLE IF NOT EXISTS location (

		location_id TEXT PRIMARY KEY,

		name TEXT NOT NULL,

		description TEXT DEFAULT '',

		location_type TEXT DEFAULT '',

		is_active INTEGER NOT NULL DEFAULT 1
			CHECK (
				is_active IN (0, 1)
			)
	);
	"""

	if not db.query(sql):
		push_error(
			"[DatabaseSchema] Failed to create location table."
		)
		return false

	return true


# ============================================================
# 02. npc_schedule
# ============================================================
#
# NPC 每日行程。
#
# 目前 npc_schedule.json 已存在，
# 因此從零建立此表。
#
# ============================================================

func _create_npc_schedule_table(db) -> bool:

	var sql := """
	CREATE TABLE IF NOT EXISTS npc_schedule (

		schedule_id INTEGER PRIMARY KEY AUTOINCREMENT,

		npc_id TEXT NOT NULL,

		start_time TEXT NOT NULL,

		end_time TEXT,

		location_id TEXT,

		action TEXT,

		FOREIGN KEY (location_id)
			REFERENCES location(location_id)
			ON DELETE SET NULL,

		UNIQUE (
			npc_id,
			start_time
		)
	);
	"""

	if not db.query(sql):
		push_error(
			"[DatabaseSchema] Failed to create npc_schedule table."
		)
		return false

	return true


# ============================================================
# 03. npc
# ============================================================
#
# L0 Identity
#
# identity.id
# identity.name
# identity.age
# identity.gender
# identity.village_id
# identity.character
# identity.created_at
#
# L2
#
# reputation
# economy.money
#
# system_prompt
#
# ============================================================
#
# description / is_active：
#
# 這兩個欄位是目前 DatabaseSeeder 使用的相容欄位。
#
# ============================================================

func _create_npc_table(db) -> bool:

	var sql := """
	CREATE TABLE IF NOT EXISTS npc (

		npc_id TEXT PRIMARY KEY,

		name TEXT NOT NULL,

		age INTEGER NOT NULL DEFAULT 18
			CHECK (
				age BETWEEN 16 AND 70
			),

		gender TEXT NOT NULL DEFAULT 'other'
			CHECK (
				gender IN (
					'male',
					'female',
					'other'
				)
			),

		village_id TEXT NOT NULL DEFAULT 'default_village',

		character TEXT
			CHECK (
				character IS NULL
				OR length(character) <= 250
			),

		reputation INTEGER NOT NULL DEFAULT 0
			CHECK (
				reputation BETWEEN -100 AND 100
			),

		money INTEGER NOT NULL DEFAULT 0
			CHECK (
				money >= 0
			),

		system_prompt TEXT DEFAULT '',

		created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,

		-- --------------------------------------------
		-- 專案目前使用的相容欄位
		-- --------------------------------------------

		description TEXT DEFAULT '',

		is_active INTEGER NOT NULL DEFAULT 1
			CHECK (
				is_active IN (0, 1)
			)
	);
	"""

	if not db.query(sql):
		push_error(
			"[DatabaseSchema] Failed to create npc table."
		)
		return false

	return true


# ============================================================
# 04. npc_personality
# ============================================================

func _create_npc_personality_table(db) -> bool:

	var sql := """
	CREATE TABLE IF NOT EXISTS npc_personality (

		npc_id TEXT PRIMARY KEY,

		-- ==========================
		-- HEXACO
		-- ==========================

		hex_honesty INTEGER NOT NULL DEFAULT 50
			CHECK (hex_honesty BETWEEN 0 AND 100),

		hex_emotionality INTEGER NOT NULL DEFAULT 50
			CHECK (hex_emotionality BETWEEN 0 AND 100),

		hex_extraversion INTEGER NOT NULL DEFAULT 50
			CHECK (hex_extraversion BETWEEN 0 AND 100),

		hex_agreeableness INTEGER NOT NULL DEFAULT 50
			CHECK (hex_agreeableness BETWEEN 0 AND 100),

		hex_conscientiousness INTEGER NOT NULL DEFAULT 50
			CHECK (hex_conscientiousness BETWEEN 0 AND 100),

		hex_openness INTEGER NOT NULL DEFAULT 50
			CHECK (hex_openness BETWEEN 0 AND 100),

		-- ==========================
		-- 自訂人格
		-- ==========================

		diligence INTEGER NOT NULL DEFAULT 50
			CHECK (diligence BETWEEN 0 AND 100),

		courage INTEGER NOT NULL DEFAULT 50
			CHECK (courage BETWEEN 0 AND 100),

		sociability INTEGER NOT NULL DEFAULT 50
			CHECK (sociability BETWEEN 0 AND 100),

		morality INTEGER NOT NULL DEFAULT 50
			CHECK (morality BETWEEN 0 AND 100),

		stability INTEGER NOT NULL DEFAULT 50
			CHECK (stability BETWEEN 0 AND 100),

		romanticism INTEGER NOT NULL DEFAULT 50
			CHECK (romanticism BETWEEN 0 AND 100),

		curiosity INTEGER NOT NULL DEFAULT 50
			CHECK (curiosity BETWEEN 0 AND 100),

		grudge INTEGER NOT NULL DEFAULT 50
			CHECK (grudge BETWEEN 0 AND 100),

		greed INTEGER NOT NULL DEFAULT 50
			CHECK (greed BETWEEN 0 AND 100),

		honesty INTEGER NOT NULL DEFAULT 50
			CHECK (honesty BETWEEN 0 AND 100),

		FOREIGN KEY (npc_id)
			REFERENCES npc(npc_id)
			ON DELETE CASCADE
	);
	"""

	if not db.query(sql):
		push_error(
			"[DatabaseSchema] Failed to create npc_personality table."
		)
		return false

	return true


# ============================================================
# 05. npc_appearance
# ============================================================

func _create_npc_appearance_table(db) -> bool:

	var sql := """
	CREATE TABLE IF NOT EXISTS npc_appearance (

		appearance_id INTEGER PRIMARY KEY AUTOINCREMENT,

		npc_id TEXT NOT NULL,

		slot TEXT NOT NULL,

		item_id TEXT NOT NULL,

		label TEXT,

		FOREIGN KEY (npc_id)
			REFERENCES npc(npc_id)
			ON DELETE CASCADE,

		UNIQUE (
			npc_id,
			slot
		)
	);
	"""

	if not db.query(sql):
		push_error(
			"[DatabaseSchema] Failed to create npc_appearance table."
		)
		return false

	return true


# ============================================================
# 06. npc_occupation
# ============================================================

func _create_npc_occupation_table(db) -> bool:

	var sql := """
	CREATE TABLE IF NOT EXISTS npc_occupation (

		npc_id TEXT PRIMARY KEY,

		occupation_id TEXT,

		occupation_name TEXT,

		since_day INTEGER,

		FOREIGN KEY (npc_id)
			REFERENCES npc(npc_id)
			ON DELETE CASCADE
	);
	"""

	if not db.query(sql):
		push_error(
			"[DatabaseSchema] Failed to create npc_occupation table."
		)
		return false

	return true


# ============================================================
# 07. npc_creator_message
# ============================================================

func _create_npc_creator_message_table(db) -> bool:

	var sql := """
	CREATE TABLE IF NOT EXISTS npc_creator_message (

		npc_id TEXT PRIMARY KEY,

		content TEXT
			CHECK (
				content IS NULL
				OR length(content) <= 60
			),

		generated_at TEXT,

		is_spoken INTEGER NOT NULL DEFAULT 0
			CHECK (
				is_spoken IN (0, 1)
			),

		spoken_at TEXT,

		trigger TEXT,

		FOREIGN KEY (npc_id)
			REFERENCES npc(npc_id)
			ON DELETE CASCADE
	);
	"""

	if not db.query(sql):
		push_error(
			"[DatabaseSchema] Failed to create npc_creator_message table."
		)
		return false

	return true


# ============================================================
# 08. npc_taboo
# ============================================================

func _create_npc_taboo_table(db) -> bool:

	var sql := """
	CREATE TABLE IF NOT EXISTS npc_taboo (

		taboo_id INTEGER PRIMARY KEY AUTOINCREMENT,

		npc_id TEXT NOT NULL,

		content TEXT NOT NULL,

		FOREIGN KEY (npc_id)
			REFERENCES npc(npc_id)
			ON DELETE CASCADE
	);
	"""

	if not db.query(sql):
		push_error(
			"[DatabaseSchema] Failed to create npc_taboo table."
		)
		return false

	return true


# ============================================================
# 09. npc_state
# ============================================================
#
# 生理狀態：
#
# hunger
# thirst
# stamina
# sleepiness
# hygiene
# alcohol
# health
# injury
#
# location_id
#
# ============================================================

func _create_npc_state_table(db) -> bool:

	var sql := """
	CREATE TABLE IF NOT EXISTS npc_state (

		npc_id TEXT PRIMARY KEY,

		hunger REAL NOT NULL DEFAULT 0
			CHECK (hunger BETWEEN 0 AND 100),

		thirst REAL NOT NULL DEFAULT 0
			CHECK (thirst BETWEEN 0 AND 100),

		stamina REAL NOT NULL DEFAULT 100
			CHECK (stamina BETWEEN 0 AND 100),

		sleepiness REAL NOT NULL DEFAULT 0
			CHECK (sleepiness BETWEEN 0 AND 100),

		hygiene REAL NOT NULL DEFAULT 100
			CHECK (hygiene BETWEEN 0 AND 100),

		alcohol REAL NOT NULL DEFAULT 0
			CHECK (alcohol BETWEEN 0 AND 100),

		health REAL NOT NULL DEFAULT 100
			CHECK (health BETWEEN 0 AND 100),

		injury REAL NOT NULL DEFAULT 0
			CHECK (injury BETWEEN 0 AND 100),

		location_id TEXT,

		FOREIGN KEY (npc_id)
			REFERENCES npc(npc_id)
			ON DELETE CASCADE,

		FOREIGN KEY (location_id)
			REFERENCES location(location_id)
			ON DELETE SET NULL
	);
	"""

	if not db.query(sql):
		push_error(
			"[DatabaseSchema] Failed to create npc_state table."
		)
		return false

	return true


# ============================================================
# 10. npc_emotion
# ============================================================

func _create_npc_emotion_table(db) -> bool:

	var sql := """
	CREATE TABLE IF NOT EXISTS npc_emotion (

		npc_id TEXT PRIMARY KEY,

		emotion_type TEXT NOT NULL DEFAULT 'neutral',

		intensity INTEGER NOT NULL DEFAULT 0
			CHECK (intensity BETWEEN 0 AND 100),

		cause_event_id TEXT,

		duration_left INTEGER NOT NULL DEFAULT 0
			CHECK (duration_left >= 0),

		FOREIGN KEY (npc_id)
			REFERENCES npc(npc_id)
			ON DELETE CASCADE
	);
	"""

	if not db.query(sql):
		push_error(
			"[DatabaseSchema] Failed to create npc_emotion table."
		)
		return false

	return true


# ============================================================
# 11. npc_condition
# ============================================================

func _create_npc_condition_table(db) -> bool:

	var sql := """
	CREATE TABLE IF NOT EXISTS npc_condition (

		condition_id INTEGER PRIMARY KEY AUTOINCREMENT,

		npc_id TEXT NOT NULL,

		condition_type TEXT NOT NULL,

		turns_left INTEGER NOT NULL DEFAULT 0
			CHECK (turns_left >= 0),

		FOREIGN KEY (npc_id)
			REFERENCES npc(npc_id)
			ON DELETE CASCADE,

		UNIQUE (
			npc_id,
			condition_type
		)
	);
	"""

	if not db.query(sql):
		push_error(
			"[DatabaseSchema] Failed to create npc_condition table."
		)
		return false

	return true


# ============================================================
# 12. npc_goal
# ============================================================

func _create_npc_goal_table(db) -> bool:

	var sql := """
	CREATE TABLE IF NOT EXISTS npc_goal (

		npc_id TEXT PRIMARY KEY,

		current_goal TEXT
			CHECK (
				current_goal IS NULL
				OR length(current_goal) <= 40
			),

		FOREIGN KEY (npc_id)
			REFERENCES npc(npc_id)
			ON DELETE CASCADE
	);
	"""

	if not db.query(sql):
		push_error(
			"[DatabaseSchema] Failed to create npc_goal table."
		)
		return false

	return true


# ============================================================
# 13. npc_daily_plan
# ============================================================

func _create_npc_daily_plan_table(db) -> bool:

	var sql := """
	CREATE TABLE IF NOT EXISTS npc_daily_plan (

		plan_id INTEGER PRIMARY KEY AUTOINCREMENT,

		npc_id TEXT NOT NULL,

		plan_order INTEGER NOT NULL,

		plan_content TEXT NOT NULL,

		FOREIGN KEY (npc_id)
			REFERENCES npc(npc_id)
			ON DELETE CASCADE,

		UNIQUE (
			npc_id,
			plan_order
		),

		CHECK (
			plan_order BETWEEN 1 AND 4
		)
	);
	"""

	if not db.query(sql):
		push_error(
			"[DatabaseSchema] Failed to create npc_daily_plan table."
		)
		return false

	return true


# ============================================================
# 14. npc_last_action
# ============================================================

func _create_npc_last_action_table(db) -> bool:

	var sql := """
	CREATE TABLE IF NOT EXISTS npc_last_action (

		npc_id TEXT PRIMARY KEY,

		action TEXT NOT NULL,

		target TEXT,

		success INTEGER NOT NULL DEFAULT 0
			CHECK (
				success IN (0, 1)
			),

		reason TEXT NOT NULL,

		FOREIGN KEY (npc_id)
			REFERENCES npc(npc_id)
			ON DELETE CASCADE
	);
	"""

	if not db.query(sql):
		push_error(
			"[DatabaseSchema] Failed to create npc_last_action table."
		)
		return false

	return true


# ============================================================
# 15. npc_inventory
# ============================================================

func _create_npc_inventory_table(db) -> bool:

	var sql := """
	CREATE TABLE IF NOT EXISTS npc_inventory (

		inventory_id INTEGER PRIMARY KEY AUTOINCREMENT,

		npc_id TEXT NOT NULL,

		slot INTEGER NOT NULL,

		item_id TEXT NOT NULL,

		count INTEGER NOT NULL DEFAULT 1
			CHECK (
				count >= 0
			),

		decay INTEGER NOT NULL DEFAULT 0
			CHECK (
				decay BETWEEN 0 AND 100
			),

		durability INTEGER NOT NULL DEFAULT 100
			CHECK (
				durability BETWEEN 0 AND 100
			),

		FOREIGN KEY (npc_id)
			REFERENCES npc(npc_id)
			ON DELETE CASCADE,

		UNIQUE (
			npc_id,
			slot
		),

		CHECK (
			slot BETWEEN 1 AND 8
		)
	);
	"""

	if not db.query(sql):
		push_error(
			"[DatabaseSchema] Failed to create npc_inventory table."
		)
		return false

	return true


# ============================================================
# 16. npc_home_storage
# ============================================================

func _create_npc_home_storage_table(db) -> bool:

	var sql := """
	CREATE TABLE IF NOT EXISTS npc_home_storage (

		storage_id INTEGER PRIMARY KEY AUTOINCREMENT,

		npc_id TEXT NOT NULL,

		slot INTEGER NOT NULL,

		item_id TEXT NOT NULL,

		count INTEGER NOT NULL DEFAULT 1
			CHECK (
				count >= 0
			),

		decay INTEGER NOT NULL DEFAULT 0
			CHECK (
				decay BETWEEN 0 AND 100
			),

		durability INTEGER NOT NULL DEFAULT 100
			CHECK (
				durability BETWEEN 0 AND 100
			),

		FOREIGN KEY (npc_id)
			REFERENCES npc(npc_id)
			ON DELETE CASCADE,

		UNIQUE (
			npc_id,
			slot
		),

		CHECK (
			slot BETWEEN 1 AND 20
		)
	);
	"""

	if not db.query(sql):
		push_error(
			"[DatabaseSchema] Failed to create npc_home_storage table."
		)
		return false

	return true


# ============================================================
# 17. npc_relations
# ============================================================
#
# NPC ↔ NPC
#
# character_id
# target_id
# affinity
# trust
# familiarity
# debt
#
# reputation 已經放在 npc.reputation。
#
# ============================================================

func _create_npc_relations_table(db) -> bool:

	var sql := """
	CREATE TABLE IF NOT EXISTS npc_relations (

		relation_id INTEGER PRIMARY KEY AUTOINCREMENT,

		character_id TEXT NOT NULL,

		target_id TEXT NOT NULL,

		relations_affinity INTEGER NOT NULL DEFAULT 0
			CHECK (
				relations_affinity BETWEEN -100 AND 100
			),

		relations_trust INTEGER NOT NULL DEFAULT 0
			CHECK (
				relations_trust BETWEEN 0 AND 100
			),

		relations_familiarity INTEGER NOT NULL DEFAULT 0
			CHECK (
				relations_familiarity BETWEEN 0 AND 100
			),

		relations_debt INTEGER NOT NULL DEFAULT 0
			CHECK (
				relations_debt BETWEEN -100 AND 100
			),

		FOREIGN KEY (character_id)
			REFERENCES npc(npc_id)
			ON DELETE CASCADE,

		FOREIGN KEY (target_id)
			REFERENCES npc(npc_id)
			ON DELETE CASCADE,

		UNIQUE (
			character_id,
			target_id
		),

		CHECK (
			character_id != target_id
		)
	);
	"""

	if not db.query(sql):
		push_error(
			"[DatabaseSchema] Failed to create npc_relations table."
		)
		return false

	return true


# ============================================================
# Index
# ============================================================

func _create_indexes(db) -> bool:

	var indexes := [

		"""
		CREATE INDEX IF NOT EXISTS idx_npc_village
		ON npc(village_id);
		""",

		"""
		CREATE INDEX IF NOT EXISTS idx_npc_active
		ON npc(is_active);
		""",

		"""
		CREATE INDEX IF NOT EXISTS idx_npc_appearance_npc
		ON npc_appearance(npc_id);
		""",

		"""
		CREATE INDEX IF NOT EXISTS idx_npc_occupation
		ON npc_occupation(occupation_id);
		""",

		"""
		CREATE INDEX IF NOT EXISTS idx_npc_taboo_npc
		ON npc_taboo(npc_id);
		""",

		"""
		CREATE INDEX IF NOT EXISTS idx_npc_state_location
		ON npc_state(location_id);
		""",

		"""
		CREATE INDEX IF NOT EXISTS idx_npc_emotion_event
		ON npc_emotion(cause_event_id);
		""",

		"""
		CREATE INDEX IF NOT EXISTS idx_npc_condition_npc
		ON npc_condition(npc_id);
		""",

		"""
		CREATE INDEX IF NOT EXISTS idx_npc_daily_plan_npc
		ON npc_daily_plan(npc_id);
		""",

		"""
		CREATE INDEX IF NOT EXISTS idx_npc_inventory_npc
		ON npc_inventory(npc_id);
		""",

		"""
		CREATE INDEX IF NOT EXISTS idx_npc_inventory_item
		ON npc_inventory(item_id);
		""",

		"""
		CREATE INDEX IF NOT EXISTS idx_npc_home_storage_npc
		ON npc_home_storage(npc_id);
		""",

		"""
		CREATE INDEX IF NOT EXISTS idx_npc_home_storage_item
		ON npc_home_storage(item_id);
		""",

		"""
		CREATE INDEX IF NOT EXISTS idx_npc_relations_character
		ON npc_relations(character_id);
		""",

		"""
		CREATE INDEX IF NOT EXISTS idx_npc_relations_target
		ON npc_relations(target_id);
		""",

		"""
		CREATE INDEX IF NOT EXISTS idx_npc_schedule_npc
		ON npc_schedule(npc_id);
		""",

		"""
		CREATE INDEX IF NOT EXISTS idx_npc_schedule_location
		ON npc_schedule(location_id);
		"""
	]

	for sql in indexes:

		if not db.query(sql):
			push_error(
				"[DatabaseSchema] Failed to create index."
			)
			return false

	return true
