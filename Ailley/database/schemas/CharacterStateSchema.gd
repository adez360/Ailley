class_name CharacterStateSchema
extends RefCounted


static func create(db) -> bool:
	var sql := """
	CREATE TABLE IF NOT EXISTS character_state (

		character_id TEXT PRIMARY KEY,

		-- 角色類型
		-- player / npc
		character_type TEXT NOT NULL,

		-- 目前 Stats.gd 使用的五項數值
		-- 範圍：0.0 ~ 100.0

		hunger REAL NOT NULL DEFAULT 100.0
			CHECK (hunger BETWEEN 0.0 AND 100.0),

		energy REAL NOT NULL DEFAULT 100.0
			CHECK (energy BETWEEN 0.0 AND 100.0),

		social REAL NOT NULL DEFAULT 100.0
			CHECK (social BETWEEN 0.0 AND 100.0),

		fun REAL NOT NULL DEFAULT 100.0
			CHECK (fun BETWEEN 0.0 AND 100.0),

		mood REAL NOT NULL DEFAULT 50.0
			CHECK (mood BETWEEN 0.0 AND 100.0),

		-- 最後一次同步的遊戲時間
		last_day INTEGER NOT NULL DEFAULT 1,
		last_hour INTEGER NOT NULL DEFAULT 8,
		last_minute INTEGER NOT NULL DEFAULT 0
	);
	"""

	if not db.query(sql):
		push_error(
			"[CharacterStateSchema] Failed to create character_state."
		)
		return false

	return true
