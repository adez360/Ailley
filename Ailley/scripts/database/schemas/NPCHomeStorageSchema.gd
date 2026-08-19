class_name NPCHomeStorageSchema
extends RefCounted


static func create(db) -> bool:

	var sql := """
	CREATE TABLE IF NOT EXISTS npc_home_storage (

		storage_id INTEGER PRIMARY KEY AUTOINCREMENT,

		npc_id TEXT NOT NULL,

		item_id TEXT NOT NULL,

		count INTEGER NOT NULL DEFAULT 0
			CHECK (count BETWEEN 0 AND 30),

		decay INTEGER NOT NULL DEFAULT 0
			CHECK (decay BETWEEN 0 AND 100),

		durability INTEGER NOT NULL DEFAULT 100
			CHECK (durability BETWEEN 0 AND 100),

		-- 家中倉庫：0-49，共 50 格
		slot INTEGER NOT NULL
			CHECK (slot BETWEEN 0 AND 49),

		updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,

		FOREIGN KEY (npc_id)
			REFERENCES npc(npc_id)
			ON DELETE CASCADE,

		FOREIGN KEY (item_id)
			REFERENCES item(item_id)
			ON DELETE RESTRICT,

		UNIQUE (npc_id, slot)
	);
	"""

	if not db.query(sql):
		push_error("[NPCHomeStorageSchema] Failed to create npc_home_storage table.")
		return false

	return true
