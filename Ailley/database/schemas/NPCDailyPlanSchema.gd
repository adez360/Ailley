class_name NPCDailyPlanSchema
extends RefCounted


static func create(db) -> bool:

	# 一列 = today_plan 清單裡的一個項目，同一 npc_id/game_day 本來就允許
	# 多列，不加 UNIQUE 約束（見《規格書 10》§5.4、99 清單 P-41）。
	# 寫入固定是整批覆蓋：delete 該 npc 全部舊列再整批 insert，
	# 跟 npc_taboo／npc_inventory／memories 同一套模式。
	var sql := """
	CREATE TABLE IF NOT EXISTS npc_daily_plan (

		plan_id INTEGER PRIMARY KEY AUTOINCREMENT,

		npc_id TEXT NOT NULL,

		-- 遊戲日；不能用現實 created_at 推算
		game_day INTEGER NOT NULL,

		-- 清單中單一項目的文字內容（例：「找 TAMMY 聊天」）
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
