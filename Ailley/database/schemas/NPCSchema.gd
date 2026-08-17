class_name NPCSchema
extends RefCounted


static func create(db) -> bool:

	var sql := """
	CREATE TABLE IF NOT EXISTS npc (
		-- 角色 ID
		npc_id TEXT PRIMARY KEY,

		-- 姓名 <= 12
		name TEXT NOT NULL
			CHECK (LENGTH(name) <= 12),

		-- 年齡 16-70
		age INTEGER NOT NULL DEFAULT 30
			CHECK (age BETWEEN 16 AND 70),

		-- 性別 male/female/other
		gender TEXT NOT NULL DEFAULT 'other'
			CHECK (gender IN ('male', 'female', 'other')),

		-- 所屬村莊
		village_id TEXT NOT NULL DEFAULT 'default_village',

		-- 角色特色自由文本，<= 250 字
		character TEXT DEFAULT ''
			CHECK (LENGTH(character) <= 250),

		-- 名聲
		reputation INTEGER NOT NULL DEFAULT 0
			CHECK (reputation BETWEEN -100 AND 100),

		-- 給 AI 看的系統提示
		system_prompt TEXT DEFAULT '',

		-- 角色對造物主的話，<= 60 字
		words_to_creator TEXT DEFAULT ''
			CHECK (LENGTH(words_to_creator) <= 60),

		-- 角色對造物主的話是否已說出
		is_spoken INTEGER NOT NULL DEFAULT 0
			CHECK (is_spoken IN (0, 1)),

		-- 生成時間；尚未生成時可為 NULL
		generated_at TEXT,

		-- 實際說出口的時間；尚未說出時可為 NULL
		spoken_at TEXT,

		-- 觸發來源；規格標示待定，因此先允許 NULL
		trigger TEXT,

		-- 角色的家
		home_location_id TEXT NOT NULL,

		-- 決策來源；投放後不可改
		decision_source TEXT NOT NULL DEFAULT 'local'
			CHECK (decision_source IN ('local', 'cloud', 'human')),

		-- 角色面板顯示用模型名稱；投放後不可改
		model_name TEXT DEFAULT '',

		-- 角色是否啟用
		is_active INTEGER NOT NULL DEFAULT 1
			CHECK (is_active IN (0, 1)),

		created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
		updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,

		FOREIGN KEY (home_location_id)
			REFERENCES location(location_id)
			ON DELETE RESTRICT
	);
	"""

	if not db.query(sql):
		push_error("[NPCSchema] Failed to create npc.")
		return false

	return true
