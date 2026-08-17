class_name ItemSchema
extends RefCounted


static func create(db) -> bool:

	var sql := """
	CREATE TABLE IF NOT EXISTS item (

		item_id TEXT PRIMARY KEY,

		name TEXT NOT NULL,

		item_type TEXT NOT NULL DEFAULT 'misc',

		description TEXT DEFAULT '',

		base_price INTEGER NOT NULL DEFAULT 0
			CHECK (base_price >= 0),

		max_stack INTEGER NOT NULL DEFAULT 99
			CHECK (max_stack > 0),

		is_consumable INTEGER NOT NULL DEFAULT 0
			CHECK (is_consumable IN (0, 1)),

		is_perishable INTEGER NOT NULL DEFAULT 0
			CHECK (is_perishable IN (0, 1)),

		is_active INTEGER NOT NULL DEFAULT 1
			CHECK (is_active IN (0, 1))
	);
	"""

	if not db.query(sql):

		push_error(
			"[ItemSchema] Failed to create item."
		)

		return false

	return true
