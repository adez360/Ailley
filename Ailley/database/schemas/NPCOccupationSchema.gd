class_name NPCOccupationSchema
extends RefCounted


static func create(db) -> bool:

	var sql := """
	CREATE TABLE IF NOT EXISTS npc_occupation (

		npc_id TEXT PRIMARY KEY,

		occupation TEXT NOT NULL DEFAULT '',

		occupation_level INTEGER NOT NULL DEFAULT 1
			CHECK (occupation_level >= 1),

		workplace_id TEXT,

		work_start_time TEXT DEFAULT '',

		work_end_time TEXT DEFAULT '',

		salary INTEGER NOT NULL DEFAULT 0
			CHECK (salary >= 0),

		working_days TEXT DEFAULT '',

		occupation_description TEXT DEFAULT '',

		is_employed INTEGER NOT NULL DEFAULT 0
			CHECK (is_employed IN (0, 1)),

		updated_at TEXT NOT NULL
			DEFAULT CURRENT_TIMESTAMP,

		FOREIGN KEY (npc_id)
			REFERENCES npc(npc_id)
			ON DELETE CASCADE,

		FOREIGN KEY (workplace_id)
			REFERENCES location(location_id)
			ON DELETE SET NULL
	);
	"""

	if not db.query(sql):

		push_error(
			"[NPCOccupationSchema] "
			+ "Failed to create npc_occupation."
		)

		return false

	return true
