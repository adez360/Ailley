class_name NPCConditionSchema
extends RefCounted


static func create(db) -> bool:

	var sql := """
	CREATE TABLE IF NOT EXISTS npc_condition (

		condition_id INTEGER PRIMARY KEY AUTOINCREMENT,

		npc_id TEXT NOT NULL,

		type TEXT NOT NULL
			CHECK(
				type IN (
					'injured',
					'bleeding',
					'drunk',
					'starving',
					'dehydrated',
					'exhausted',
					'filthy',
					'sleepy',
					'detained',
					'outcast',
					'sleeping',
					'napping',
					'working',
					'talking',
					'petrified'
				)
			),

		turns_left INTEGER NOT NULL DEFAULT 0,

		updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,

		FOREIGN KEY (npc_id)
			REFERENCES npc(npc_id)
			ON DELETE CASCADE,

		UNIQUE (npc_id, type)
	);

	CREATE INDEX IF NOT EXISTS
	idx_npc_condition_npc_id
	ON npc_condition(npc_id);
	"""

	if not db.query(sql):
		push_error("[NPCConditionSchema] Failed to create npc_condition.")
		return false

	return true
