class_name MoneyTransactionSchema
extends RefCounted


static func create(db) -> bool:

	var sql := """
	CREATE TABLE IF NOT EXISTS money_transaction (

		transaction_id INTEGER PRIMARY KEY AUTOINCREMENT,

		from_npc_id TEXT,

		to_npc_id TEXT,

		amount INTEGER NOT NULL,

		transaction_type TEXT NOT NULL DEFAULT 'trade',

		description TEXT NOT NULL DEFAULT '',

		created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,

		FOREIGN KEY (from_npc_id)
			REFERENCES npc(npc_id)
			ON DELETE SET NULL,

		FOREIGN KEY (to_npc_id)
			REFERENCES npc(npc_id)
			ON DELETE SET NULL,

		CHECK (amount > 0),

		CHECK (
			from_npc_id IS NOT NULL
			OR
			to_npc_id IS NOT NULL
		)
	);
	"""

	if not db.query(sql):

		push_error(
			"[MoneyTransactionSchema] Failed to create money_transaction table."
		)

		return false

	return true
