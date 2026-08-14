# 隨身背包
class_name NPCInventorySchema
extends RefCounted


static func create(db) -> bool:

	var sql := """
	CREATE TABLE IF NOT EXISTS npc_inventory (

		inventory_id INTEGER PRIMARY KEY AUTOINCREMENT,

		npc_id TEXT NOT NULL,

		slot INTEGER NOT NULL,

		item_id TEXT NOT NULL,

		-- 數量
		count INTEGER NOT NULL DEFAULT 1
			CHECK (count > 0),
			
		-- 腐壞值，100 = 完全腐壞
		decay INTEGER NOT NULL DEFAULT 0
			CHECK (decay BETWEEN 0 AND 100),
			
		-- 耐久值，0 = 損毀
		durability INTEGER NOT NULL DEFAULT 100
			CHECK (durability BETWEEN 0 AND 100),

		FOREIGN KEY (npc_id)
			REFERENCES npc(npc_id)
			ON DELETE CASCADE,

		FOREIGN KEY (item_id)
			REFERENCES item(item_id)
			ON DELETE RESTRICT,

		UNIQUE (
			npc_id,
			slot
		)
	);
	"""

	if not db.query(sql):

		push_error(
			"[NPCInventorySchema] Failed to create npc_inventory."
		)

		return false

	return true
