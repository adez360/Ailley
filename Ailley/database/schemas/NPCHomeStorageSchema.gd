class_name NPCHomeStorageSchema
extends RefCounted


static func create(db) -> bool:

	var sql := """
	CREATE TABLE IF NOT EXISTS npc_home_storage (

		storage_id INTEGER PRIMARY KEY AUTOINCREMENT,

		npc_id TEXT NOT NULL,

		item_id TEXT NOT NULL,

		quantity INTEGER NOT NULL DEFAULT 1,

		slot_index INTEGER,

		stored_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,

		updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,

		FOREIGN KEY (npc_id)
			REFERENCES npc(npc_id)
			ON DELETE CASCADE,

		FOREIGN KEY (item_id)
			REFERENCES item(item_id)
			ON DELETE RESTRICT,

		CHECK (quantity > 0),

		UNIQUE (npc_id, item_id, slot_index)
	);
	"""

	if not db.query(sql):

		push_error(
			"[NPCHomeStorageSchema] Failed to create npc_home_storage table."
		)

		return false

	return true
