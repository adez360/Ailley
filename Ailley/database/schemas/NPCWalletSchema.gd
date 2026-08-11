class_name NPCWalletSchema
extends RefCounted


static func create(db) -> bool:

	var sql := """
	CREATE TABLE IF NOT EXISTS npc_wallet (

		wallet_id INTEGER PRIMARY KEY AUTOINCREMENT,

		npc_id INTEGER NOT NULL UNIQUE,

		balance INTEGER NOT NULL DEFAULT 0,

		updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,

		FOREIGN KEY (npc_id)
			REFERENCES npc(npc_id)
			ON DELETE CASCADE,

		CHECK (balance >= 0)
	);
	"""

	if not db.query(sql):

		push_error(
			"[NPCWalletSchema] Failed to create npc_wallet table."
		)

		return false

	return true
