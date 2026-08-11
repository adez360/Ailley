class_name NPCDailyPlanSchema
extends RefCounted


static func create(db) -> bool:

	var sql := """
	CREATE TABLE IF NOT EXISTS npc_daily_plan (

		plan_id INTEGER PRIMARY KEY AUTOINCREMENT,

		npc_id TEXT NOT NULL,

		day_of_week INTEGER NOT NULL DEFAULT 0
			CHECK (
				day_of_week BETWEEN 0 AND 6
			),

		start_time TEXT NOT NULL,

		end_time TEXT,

		action TEXT NOT NULL DEFAULT '',

		location_id TEXT,

		priority INTEGER NOT NULL DEFAULT 50
			CHECK (
				priority BETWEEN 0 AND 100
			),

		is_flexible INTEGER NOT NULL DEFAULT 1
			CHECK (
				is_flexible IN (0, 1)
			),

		description TEXT DEFAULT '',

		created_at TEXT NOT NULL
			DEFAULT CURRENT_TIMESTAMP,

		updated_at TEXT NOT NULL
			DEFAULT CURRENT_TIMESTAMP,

		FOREIGN KEY (npc_id)
			REFERENCES npc(npc_id)
			ON DELETE CASCADE,

		FOREIGN KEY (location_id)
			REFERENCES location(location_id)
			ON DELETE SET NULL
	);

	CREATE INDEX IF NOT EXISTS
	idx_npc_daily_plan_npc_id
	ON npc_daily_plan(npc_id);

	CREATE INDEX IF NOT EXISTS
	idx_npc_daily_plan_day
	ON npc_daily_plan(npc_id, day_of_week);
	"""

	if not db.query(sql):

		push_error(
			"[NPCDailyPlanSchema] "
			+ "Failed to create npc_daily_plan."
		)

		return false

	return true
