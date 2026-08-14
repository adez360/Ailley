class_name GraveSchema
extends RefCounted


static func create(db) -> bool:

	var sql := """
	CREATE TABLE IF NOT EXISTS grave (

		-- =================================================
		-- Primary Key
		-- =================================================

		grave_id INTEGER PRIMARY KEY AUTOINCREMENT,


		-- =================================================
		-- Dead NPC 死亡角色
		-- =================================================

		npc_id TEXT NOT NULL UNIQUE,


		-- =================================================
		-- Anonymous Grave 墓碑
		-- =================================================

		-- 0 = 有名字
		-- 1 = 無名碑
		is_anonymous INTEGER NOT NULL DEFAULT 0
			CHECK (
				is_anonymous IN (0, 1)
			),


		-- =================================================
		-- Cemetery Location 墓碑位置
		-- =================================================

		location_id TEXT NOT NULL,


		-- =================================================
		-- Burial 葬禮
		-- =================================================

		-- 安葬時間
		buried_tick INTEGER,

		-- 誰安葬了你
		buried_by TEXT,


		-- =================================================
		-- Death Information Snapshot
		-- =================================================

		death_cause TEXT NOT NULL DEFAULT '',

		last_words TEXT,


		-- =================================================
		-- Character Information
		-- =================================================

		words_to_creator TEXT DEFAULT '',


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

		FOREIGN KEY (location_id)
			REFERENCES location(location_id)
			ON DELETE RESTRICT,

		FOREIGN KEY (buried_by)
			REFERENCES npc(npc_id)
			ON DELETE SET NULL
	);


	-- =====================================================
	-- Index
	-- =====================================================

	-- npc_id 是 NOT NULL UNIQUE，SQLite 自己就會建 index。
	-- is_anonymous 只有兩種值，query planner 不會用。

	CREATE INDEX IF NOT EXISTS
	idx_grave_location
	ON grave(location_id);


	CREATE INDEX IF NOT EXISTS
	idx_grave_buried_by
	ON grave(buried_by);
	"""


	if not db.query(sql):

		push_error(
			"[GraveSchema] Failed to create grave."
		)

		return false


	return true
