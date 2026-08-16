class_name NPCRelationsSchema
extends RefCounted


static func create(db) -> bool:

	var sql := """
	CREATE TABLE IF NOT EXISTS npc_relations (

		relation_id INTEGER PRIMARY KEY AUTOINCREMENT,

		character_id TEXT NOT NULL,

		target_id TEXT NOT NULL,

		trust INTEGER NOT NULL DEFAULT 20
			CHECK (trust BETWEEN 0 AND 100),

		appearance_cache TEXT NOT NULL DEFAULT ''
			CHECK (LENGTH(appearance_cache) <= 20),

		updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,

		FOREIGN KEY (character_id)
			REFERENCES npc(npc_id)
			ON DELETE CASCADE,

		FOREIGN KEY (target_id)
			REFERENCES npc(npc_id)
			ON DELETE CASCADE,

		UNIQUE (character_id, target_id),

		CHECK (character_id <> target_id)
	);

	CREATE INDEX IF NOT EXISTS
	idx_npc_relations_character
	ON npc_relations(character_id);

	CREATE INDEX IF NOT EXISTS
	idx_npc_relations_target
	ON npc_relations(target_id);
	"""

	if not db.query(sql):
		push_error("[NPCRelationsSchema] Failed to create npc_relations.")
		return false

	return true
