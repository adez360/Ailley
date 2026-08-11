class_name NPCGoalSchema
extends RefCounted


static func create(db) -> bool:

	var sql := """
	CREATE TABLE IF NOT EXISTS npc_goal (

		goal_id INTEGER PRIMARY KEY AUTOINCREMENT,

		npc_id TEXT NOT NULL,

		goal_type TEXT NOT NULL DEFAULT '',

		description TEXT NOT NULL DEFAULT '',

		priority INTEGER NOT NULL DEFAULT 50
			CHECK (priority BETWEEN 0 AND 100),

		status TEXT NOT NULL DEFAULT 'active',

		target_id TEXT DEFAULT '',

		target_value TEXT DEFAULT '',

		progress INTEGER NOT NULL DEFAULT 0
			CHECK (progress BETWEEN 0 AND 100),

		deadline TEXT,

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

	CREATE INDEX IF NOT EXISTS
	idx_npc_goal_status
	ON npc_goal(status);
	"""

	if not db.query(sql):

		push_error(
			"[NPCGoalSchema] "
			+ "Failed to create npc_goal."
		)

		return false

	return true
