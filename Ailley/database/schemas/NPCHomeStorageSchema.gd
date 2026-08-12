class_name NPCHomeStorageSchema
extends RefCounted


static func create(db) -> bool:

	var sql := """
	CREATE TABLE IF NOT EXISTS npc_home_storage (

		storage_id INTEGER PRIMARY KEY AUTOINCREMENT,

		npc_id TEXT NOT NULL,

		item_id TEXT NOT NULL,

		-- 數量
		count INTEGER NOT NULL DEFAULT 0
			CHECK (count >= 0),

		-- 腐壞值，100 = 完全腐壞
		decay INTEGER NOT NULL DEFAULT 0
			CHECK (decay BETWEEN 0 AND 100),

		-- 耐久值，0 = 損毀
		durability INTEGER NOT NULL DEFAULT 100
			CHECK (durability BETWEEN 0 AND 100),

		slot_index INTEGER,

		updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,

		FOREIGN KEY (npc_id)
			REFERENCES npc(npc_id)
			ON DELETE CASCADE,

		FOREIGN KEY (item_id)
			REFERENCES item(item_id)
			ON DELETE RESTRICT,

		CHECK (count > 0),

		UNIQUE (npc_id, item_id, slot_index)
	);
	"""

	if not db.query(sql):

		push_error(
			"[NPCHomeStorageSchema] Failed to create npc_home_storage table."
		)

		return false

	return true
