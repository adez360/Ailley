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

		max_stack INTEGER NOT NULL DEFAULT 30
			CHECK (max_stack BETWEEN 1 AND 30),

		-- carry 類由資料列設定 max_stack = 1
		is_consumable INTEGER NOT NULL DEFAULT 0
			CHECK (is_consumable IN (0, 1)),

		is_perishable INTEGER NOT NULL DEFAULT 0
			CHECK (is_perishable IN (0, 1)),

		-- 腐壞速率（/tick）
		decay_rate REAL NOT NULL DEFAULT 0
			CHECK (decay_rate >= 0),

		-- 工具每次使用的耐久消耗
		durability_cost INTEGER NOT NULL DEFAULT 0
			CHECK (durability_cost >= 0),

		-- 使用效果
		effect_satiety INTEGER NOT NULL DEFAULT 0,
		effect_hydration INTEGER NOT NULL DEFAULT 0,
		effect_alcohol INTEGER NOT NULL DEFAULT 0,
		effect_injury INTEGER NOT NULL DEFAULT 0,

		is_active INTEGER NOT NULL DEFAULT 1
			CHECK (is_active IN (0, 1))
	);
	"""

	if not db.query(sql):
		push_error("[ItemSchema] Failed to create item.")
		return false

	return true
