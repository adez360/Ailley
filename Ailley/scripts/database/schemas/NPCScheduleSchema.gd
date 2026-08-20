class_name NPCScheduleSchema
extends RefCounted


static func create(db) -> bool:

	var sql := """
	CREATE TABLE IF NOT EXISTS npc_schedule (

		schedule_id INTEGER PRIMARY KEY AUTOINCREMENT,

		npc_id TEXT NOT NULL,

		start_time TEXT NOT NULL,

		end_time TEXT,

		location_id TEXT,

		action TEXT DEFAULT '',

		FOREIGN KEY (npc_id)
			REFERENCES npc(npc_id)
			ON DELETE CASCADE,

		FOREIGN KEY (location_id)
			REFERENCES location(location_id)
			ON DELETE SET NULL
	);

	CREATE INDEX IF NOT EXISTS
	idx_npc_schedule_npc
	ON npc_schedule(npc_id, start_time);
	"""

	if not db.query(sql):

		push_error(
			"[NPCScheduleSchema] Failed to create npc_schedule."
		)

		return false

	return true
