class_name NPCGoalSchema
extends RefCounted


static func create(db) -> bool:

	var sql := """
	CREATE TABLE IF NOT EXISTS npc_goal (

		npc_id TEXT PRIMARY KEY,

		current_goal TEXT NOT NULL DEFAULT ''
			CHECK (LENGTH(current_goal) <= 40),

		updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,

		FOREIGN KEY (npc_id)
			REFERENCES npc(npc_id)
			ON DELETE CASCADE
	);
	"""

	if not db.query(sql):
		push_error("[NPCGoalSchema] Failed to create npc_goal.")
		return false

	return true
