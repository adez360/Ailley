class_name NPCDailyPlanSchema
extends RefCounted


static func create(db) -> bool:

	var sql := """
	CREATE TABLE IF NOT EXISTS npc_daily_plan (

		plan_id INTEGER PRIMARY KEY AUTOINCREMENT,

		npc_id TEXT NOT NULL,

		text TEXT DEFAULT '',

		-- 行程起始時間，用tick計算
--		start_time INTEGER NOT NULL DEFAULT 0
--			CHECK (
--				start_time BETWEEN 0 AND 1439
--			),

--		action TEXT NOT NULL DEFAULT '',

--		location_id TEXT,

--		優先權
--		priority INTEGER NOT NULL DEFAULT 50
--			CHECK (
--				priority BETWEEN 0 AND 100
--			),

		-- 是否完成
		is_done INTEGER NOT NULL DEFAULT 0
			CHECK (
				is_done IN (0, 1)
			),



		created_at TEXT NOT NULL
			DEFAULT CURRENT_TIMESTAMP,

		updated_at TEXT NOT NULL
			DEFAULT CURRENT_TIMESTAMP,

		FOREIGN KEY (npc_id)
			REFERENCES npc(npc_id)
			ON DELETE CASCADE

--		FOREIGN KEY (location_id)
--			REFERENCES location(location_id)
--			ON DELETE SET NULL
	);

	CREATE INDEX IF NOT EXISTS
	idx_npc_daily_plan_npc_id
	ON npc_daily_plan(npc_id);
	"""

	if not db.query(sql):

		push_error(
			"[NPCDailyPlanSchema] "
			+ "Failed to create npc_daily_plan."
		)

		return false

	return true
