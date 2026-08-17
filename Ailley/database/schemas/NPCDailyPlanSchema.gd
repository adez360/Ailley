class_name NPCDailyPlanSchema
extends RefCounted


static func create(db) -> bool:

	var sql := """
	CREATE TABLE IF NOT EXISTS npc_daily_plan (

		plan_id INTEGER PRIMARY KEY AUTOINCREMENT,

		npc_id TEXT NOT NULL,

		-- 遊戲日；不能用現實 created_at 推算
		game_day INTEGER NOT NULL,

		-- LLM 產生的當日計畫
		text TEXT DEFAULT '',

		is_done INTEGER NOT NULL DEFAULT 0
			CHECK (is_done IN (0, 1)),

		created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,

		updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,

		FOREIGN KEY (npc_id)
			REFERENCES npc(npc_id)
			ON DELETE CASCADE
	);

	CREATE INDEX IF NOT EXISTS
	idx_npc_daily_plan_npc_day
	ON npc_daily_plan(npc_id, game_day);
	"""

	if not db.query(sql):
		push_error("[NPCDailyPlanSchema] Failed to create npc_daily_plan.")
		return false

	return true
