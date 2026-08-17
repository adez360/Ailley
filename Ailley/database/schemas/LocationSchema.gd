class_name LocationSchema
extends RefCounted


static func create(db) -> bool:

	var sql := """
	CREATE TABLE IF NOT EXISTS location (

		location_id TEXT PRIMARY KEY,

		name TEXT NOT NULL,

		description TEXT DEFAULT '',

		location_type TEXT DEFAULT '',

		is_active INTEGER NOT NULL DEFAULT 1
			CHECK (is_active IN (0, 1))
	);
	"""

	if not db.query(sql):

		push_error(
			"[LocationSchema] Failed to create location."
		)

		return false

	return true
