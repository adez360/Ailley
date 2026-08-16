class_name CharacterStateSchema
extends RefCounted


static func create(db) -> bool:
	var sql := """
	CREATE TABLE IF NOT EXISTS character_state (

		character_id TEXT PRIMARY KEY,

		-- 角色類型
		-- player / npc
		character_type TEXT NOT NULL,

		-- 生理數值（規格書 §4.1 定義的八項）
		-- 範圍：0.0 ~ 100.0

		hunger REAL NOT NULL DEFAULT 20.0
			CHECK (hunger BETWEEN 0.0 AND 100.0),

		thirst REAL NOT NULL DEFAULT 20.0
			CHECK (thirst BETWEEN 0.0 AND 100.0),

		stamina REAL NOT NULL DEFAULT 80.0
			CHECK (stamina BETWEEN 0.0 AND 100.0),

		sleepiness REAL NOT NULL DEFAULT 10.0
			CHECK (sleepiness BETWEEN 0.0 AND 100.0),

		hygiene REAL NOT NULL DEFAULT 70.0
			CHECK (hygiene BETWEEN 0.0 AND 100.0),

		alcohol REAL NOT NULL DEFAULT 0.0
			CHECK (alcohol BETWEEN 0.0 AND 100.0),

		health REAL NOT NULL DEFAULT 100.0
			CHECK (health BETWEEN 0.0 AND 100.0),

		injury REAL NOT NULL DEFAULT 0.0
			CHECK (injury BETWEEN 0.0 AND 100.0),

		-- 保留舊欄位以支援現有 Stats.gd（待遷移）
		energy REAL NOT NULL DEFAULT 80.0
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
