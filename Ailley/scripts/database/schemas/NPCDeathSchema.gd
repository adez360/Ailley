# 規格尚未定案，欄位可能異動

class_name NPCDeathSchema
extends RefCounted


static func create(db) -> bool:

	var sql := """
	CREATE TABLE IF NOT EXISTS npc_death (

		-- =================================================
		-- Primary Key
		-- =================================================

		death_id INTEGER PRIMARY KEY AUTOINCREMENT,


		-- =================================================
		-- NPC
		-- =================================================

		npc_id TEXT NOT NULL UNIQUE,


		-- =================================================
		-- Death State
		-- =================================================

		is_dead INTEGER NOT NULL DEFAULT 1
			CHECK (
				is_dead IN (0, 1)
			),


		-- =================================================
		-- Death Time
		-- =================================================

		death_tick INTEGER,

		death_day INTEGER,


		-- =================================================
		-- Death Information
		-- =================================================

		-- 引擎彙整的自然語言死因
		death_cause TEXT NOT NULL DEFAULT '',


		-- =================================================
		-- Death Location 死亡地點
		-- =================================================

		death_location_id TEXT,


		-- =================================================
		-- Last Words 遺言
		-- =================================================

		-- LLM 產生
		-- 可以是 NULL
		last_words TEXT,


		-- =================================================
		-- Corpse 屍體
		-- =================================================

		-- 0 ~ 100，REAL 而非 INTEGER——《09》§3-3 每 tick 累加 0.7，INTEGER 會把
		-- 小數進度捨掉，讓實際腐壞時間偏離規格（見 #451 CodeRabbit review）
		-- 100 = 腐壞完成
		-- 達 100 且尚未安葬 → 自動建立無名碑
		corpse_decay REAL NOT NULL DEFAULT 0
			CHECK (
				corpse_decay BETWEEN 0 AND 100
			),


		-- =================================================
		-- Burial 是否安葬
		-- =================================================

		is_buried INTEGER NOT NULL DEFAULT 0
			CHECK (
				is_buried IN (0, 1)
			),

		-- =================================================
		-- Timestamp
		-- =================================================

		created_at TEXT NOT NULL
			DEFAULT CURRENT_TIMESTAMP,

		updated_at TEXT NOT NULL
			DEFAULT CURRENT_TIMESTAMP,


		-- =================================================
		-- Foreign Keys
		-- =================================================

		FOREIGN KEY (npc_id)
			REFERENCES npc(npc_id)
			ON DELETE CASCADE,

		FOREIGN KEY (death_location_id)
			REFERENCES location(location_id)
			ON DELETE SET NULL
	);


	-- =====================================================
	-- Index
	-- =====================================================

	-- npc_id 是 NOT NULL UNIQUE，SQLite 自己就會建 index，不用再建一次。
	-- is_dead / is_buried 只有兩種值，query planner 不會用。

	CREATE INDEX IF NOT EXISTS
	idx_npc_death_location
	ON npc_death(death_location_id);
	"""


	if not db.query(sql):

		push_error(
			"[NPCDeathSchema] Failed to create npc_death."
		)

		return false


	return true
