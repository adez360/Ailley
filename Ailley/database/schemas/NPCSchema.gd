class_name NPCSchema
extends RefCounted


static func create(db) -> bool:

	var sql := """
	CREATE TABLE IF NOT EXISTS npc (

		npc_id TEXT PRIMARY KEY,

		name TEXT NOT NULL,

		age INTEGER NOT NULL DEFAULT 18,

		gender TEXT NOT NULL DEFAULT 'other',

		village_id TEXT NOT NULL DEFAULT 'default_village',

		character TEXT DEFAULT '',

		reputation INTEGER NOT NULL DEFAULT 0
			CHECK (
				reputation BETWEEN -100 AND 100
			),

		system_prompt TEXT DEFAULT '',

		description TEXT DEFAULT '',

		is_active INTEGER NOT NULL DEFAULT 1
			CHECK (
				is_active IN (0, 1)
			)
	);
	"""

	if not db.query(sql):

		push_error(
			"[NPCSchema] Failed to create npc."
		)

		return false

	return true
