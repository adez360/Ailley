class_name NPCStateSchema
extends RefCounted


static func create(db) -> bool:

	var sql := """
	CREATE TABLE IF NOT EXISTS npc_state (

		npc_id TEXT PRIMARY KEY,

		hunger INTEGER NOT NULL DEFAULT 0
			CHECK (hunger BETWEEN 0 AND 100),

		thirst INTEGER NOT NULL DEFAULT 0
			CHECK (thirst BETWEEN 0 AND 100),

		stamina INTEGER NOT NULL DEFAULT 100
			CHECK (stamina BETWEEN 0 AND 100),

		sleepiness INTEGER NOT NULL DEFAULT 0
			CHECK (sleepiness BETWEEN 0 AND 100),

		hygiene INTEGER NOT NULL DEFAULT 100
			CHECK (hygiene BETWEEN 0 AND 100),

		alcohol INTEGER NOT NULL DEFAULT 0
			CHECK (alcohol BETWEEN 0 AND 100),

		health INTEGER NOT NULL DEFAULT 100
			CHECK (health BETWEEN 0 AND 100),

		injury INTEGER NOT NULL DEFAULT 0
			CHECK (injury BETWEEN 0 AND 100),

		location_id TEXT,

		FOREIGN KEY (npc_id)
			REFERENCES npc(npc_id)
			ON DELETE CASCADE,

		FOREIGN KEY (location_id)
			REFERENCES location(location_id)
			ON DELETE SET NULL
	);
	"""

	if not db.query(sql):

		push_error(
			"[NPCStateSchema] Failed to create npc_state."
		)

		return false

	return true
