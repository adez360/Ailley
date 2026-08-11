class_name NPCTabooSchema
extends RefCounted


static func create(db) -> bool:

	var sql := """
	CREATE TABLE IF NOT EXISTS npc_taboo (

		taboo_id INTEGER PRIMARY KEY AUTOINCREMENT,

		npc_id TEXT NOT NULL,

		taboo_type TEXT NOT NULL DEFAULT '',

		description TEXT NOT NULL DEFAULT '',

		severity INTEGER NOT NULL DEFAULT 50
			CHECK (severity BETWEEN 0 AND 100),

		is_active INTEGER NOT NULL DEFAULT 1
			CHECK (is_active IN (0, 1)),

		created_at TEXT NOT NULL
			DEFAULT CURRENT_TIMESTAMP,

		updated_at TEXT NOT NULL
			DEFAULT CURRENT_TIMESTAMP,

		FOREIGN KEY (npc_id)
			REFERENCES npc(npc_id)
			ON DELETE CASCADE
	);

	CREATE INDEX IF NOT EXISTS
	idx_npc_taboo_npc_id
	ON npc_taboo(npc_id);
	"""

	if not db.query(sql):

		push_error(
			"[NPCTabooSchema] "
			+ "Failed to create npc_taboo."
		)

		return false

	return true
