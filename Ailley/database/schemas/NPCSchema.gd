class_name NPCSchema
extends RefCounted


static func create(db) -> bool:

	var sql := """
	CREATE TABLE IF NOT EXISTS npc (
		-- 角色 ID
		npc_id TEXT PRIMARY KEY,
		-- 姓名 <= 12
		name TEXT NOT NULL,
		-- 年齡
		age INTEGER NOT NULL DEFAULT 18,
		-- 性別 male/female/other
		gender TEXT NOT NULL DEFAULT 'other',
		-- 所屬村莊
		village_id TEXT NOT NULL DEFAULT 'default_village',
		-- 角色特色 自由文本
		character TEXT DEFAULT '',
		-- 名聲
		reputation INTEGER NOT NULL DEFAULT 0
			CHECK (
				reputation BETWEEN -100 AND 100
			),
		-- 給AI看的 : 你正在扮演一個遊戲角色。
		system_prompt TEXT DEFAULT '',
		
		-- 角色對造物主的話
		words_to_creator TEXT DEFAULT '',
		-- 是否已說出
		is_spoken INTEGER NOT NULL DEFAULT 1
			CHECK (
				is_active IN (0, 1)
			),

		is_active INTEGER NOT NULL DEFAULT 1
			CHECK (
				is_active IN (0, 1)
			),
			
		-- =================================================
		-- Timestamp
		-- =================================================

		created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
		updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP

			
	);
	"""

	if not db.query(sql):

		push_error(
			"[NPCSchema] Failed to create npc."
		)

		return false

	return true
