class_name NPCAppearanceSchema
extends RefCounted


static func create(db) -> bool:

	var sql := """
	CREATE TABLE IF NOT EXISTS npc_appearance (

		-- 對應NPC
		npc_id TEXT NOT NULL PRIMARY KEY,
		-- 髮型
		hair_id TEXT DEFAULT '',
		-- 臉型
		face_id TEXT DEFAULT '',
		-- 衣服
		clothes_id TEXT DEFAULT '',
		-- 配件1
		decoration1_id TEXT DEFAULT '',
		-- 配件2
		decoration2_id TEXT DEFAULT '',

		updated_at TEXT NOT NULL
			DEFAULT CURRENT_TIMESTAMP,

		FOREIGN KEY (npc_id)
			REFERENCES npc(npc_id)
			ON DELETE CASCADE
	);
	"""

	if not db.query(sql):

		push_error(
			"[NPCAppearanceSchema] "
			+ "Failed to create npc_appearance."
		)

		return false

	return true
