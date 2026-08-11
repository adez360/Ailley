class_name NPCCreatorMessageSchema
extends RefCounted


static func create(db) -> bool:

	var sql := """
	CREATE TABLE IF NOT EXISTS npc_creator_message (

		npc_id TEXT PRIMARY KEY,

		system_message TEXT DEFAULT '',

		personality_instruction TEXT DEFAULT '',

		behavior_instruction TEXT DEFAULT '',

		world_instruction TEXT DEFAULT '',

		relationship_instruction TEXT DEFAULT '',

		custom_instruction TEXT DEFAULT '',

		is_enabled INTEGER NOT NULL DEFAULT 1
			CHECK (is_enabled IN (0, 1)),

		updated_at TEXT NOT NULL
			DEFAULT CURRENT_TIMESTAMP,

		FOREIGN KEY (npc_id)
			REFERENCES npc(npc_id)
			ON DELETE CASCADE
	);
	"""

	if not db.query(sql):

		push_error(
			"[NPCCreatorMessageSchema] "
			+ "Failed to create npc_creator_message."
		)

		return false

	return true
