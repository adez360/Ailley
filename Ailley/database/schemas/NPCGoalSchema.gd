class_name NPCGoalSchema
extends RefCounted

static func create(db) -> bool:
	var sql := """
	CREATE TABLE IF NOT EXISTS npc_goal (

		goal_id INTEGER PRIMARY KEY AUTOINCREMENT,

		npc_id TEXT NOT NULL,

		-- 當前目標
		current_goal TEXT NOT NULL DEFAULT '',

		-- 上次動作
		last_action TEXT NOT NULL DEFAULT '',

		-- 上次動作的目標
		last_target TEXT NOT NULL DEFAULT '',

		-- 上次動作是否成功
		-- NULL = 尚未有結果
		-- 0 = 失敗
		-- 1 = 成功
		is_success INTEGER
			CHECK (
				is_success IS NULL
				OR is_success IN (0, 1)
			),

		-- 失敗原因
		-- 失敗時必須填寫
		-- 成功時必須為 NULL
		action_reason TEXT
			CHECK (
				(is_success = 0 AND action_reason IS NOT NULL AND action_reason <> '')
				OR
				(is_success = 1 AND action_reason IS NULL)
				OR
				(is_success IS NULL AND action_reason IS NULL)
			),

		created_at TEXT NOT NULL
			DEFAULT CURRENT_TIMESTAMP,

		updated_at TEXT NOT NULL
			DEFAULT CURRENT_TIMESTAMP,

		FOREIGN KEY (npc_id)
			REFERENCES npc(npc_id)
			ON DELETE CASCADE
	);

	CREATE INDEX IF NOT EXISTS
	idx_npc_goal_npc_id
	ON npc_goal(npc_id);
	"""

	if not db.query(sql):
		push_error(
			"[NPCGoalSchema] "
			+ "Failed to create npc_goal."
		)
		return false

	return true
