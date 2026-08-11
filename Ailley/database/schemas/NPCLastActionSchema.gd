class_name NPCLastActionSchema
extends RefCounted


static func create(db) -> bool:

	var sql := """
	CREATE TABLE IF NOT EXISTS npc_last_action (

		npc_id TEXT PRIMARY KEY,

		action_type TEXT NOT NULL DEFAULT '',

		action_description TEXT DEFAULT '',

		action_result TEXT DEFAULT '',

		location_id TEXT,

		target_npc_id TEXT,

		target_item_id TEXT,

		success INTEGER NOT NULL DEFAULT 1
			CHECK (
				success IN (0, 1)
			),

		action_started_at TEXT,

		action_finished_at TEXT,

		updated_at TEXT NOT NULL
			DEFAULT CURRENT_TIMESTAMP,

		FOREIGN KEY (npc_id)
			REFERENCES npc(npc_id)
			ON DELETE CASCADE,

		FOREIGN KEY (location_id)
			REFERENCES location(location_id)
			ON DELETE SET NULL,

		FOREIGN KEY (target_npc_id)
			REFERENCES npc(npc_id)
			ON DELETE SET NULL,

		FOREIGN KEY (target_item_id)
			REFERENCES item(item_id)
			ON DELETE SET NULL
	);
	"""

	if not db.query(sql):

		push_error(
			"[NPCLastActionSchema] "
			+ "Failed to create npc_last_action."
		)

		return false

	return true
