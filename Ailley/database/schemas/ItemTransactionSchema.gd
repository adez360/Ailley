class_name ItemTransactionSchema
extends RefCounted


static func create(db) -> bool:

	var sql := """
	CREATE TABLE IF NOT EXISTS item_transaction (

		transaction_id INTEGER PRIMARY KEY AUTOINCREMENT,

		from_npc_id TEXT,

		to_npc_id TEXT,

		item_id TEXT NOT NULL,

		quantity INTEGER NOT NULL,

		transaction_type TEXT NOT NULL DEFAULT 'trade',

		description TEXT NOT NULL DEFAULT '',

		created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,

		FOREIGN KEY (from_npc_id)
			REFERENCES npc(npc_id)
			ON DELETE SET NULL,

		FOREIGN KEY (to_npc_id)
			REFERENCES npc(npc_id)
			ON DELETE SET NULL,

		FOREIGN KEY (item_id)
			REFERENCES item(item_id)
			ON DELETE RESTRICT,

		CHECK (quantity > 0),

		CHECK (
			from_npc_id IS NOT NULL
			OR
			to_npc_id IS NOT NULL
		)
	);
	"""

	if not db.query(sql):

		push_error(
			"[ItemTransactionSchema] Failed to create item_transaction table."
		)

		return false

	return true
