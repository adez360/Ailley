class_name NPCStateSchema
extends RefCounted


static func create(db) -> bool:

	var sql := """
	CREATE TABLE IF NOT EXISTS npc_state (

		npc_id TEXT PRIMARY KEY,

		-- 生理狀態：0.0 ~ 1.0（hunger 例外，見下方）
		-- 0.0 = 0%
		-- 1.0 = 100%

		-- hunger 改用 0-100，跟規格書《01》§4-1／實際引擎 stats.gd 對齊：
		-- 越高越飽，預設 100（見《99》P-32，2026-08-16）
		hunger REAL NOT NULL DEFAULT 100.0
			CHECK (hunger BETWEEN 0.0 AND 100.0),

		thirst REAL NOT NULL DEFAULT 0.0
			CHECK (thirst BETWEEN 0.0 AND 1.0),

		stamina REAL NOT NULL DEFAULT 1.0
			CHECK (stamina BETWEEN 0.0 AND 1.0),

		sleepiness REAL NOT NULL DEFAULT 0.0
			CHECK (sleepiness BETWEEN 0.0 AND 1.0),

		hygiene REAL NOT NULL DEFAULT 1.0
			CHECK (hygiene BETWEEN 0.0 AND 1.0),

		alcohol REAL NOT NULL DEFAULT 0.0
			CHECK (alcohol BETWEEN 0.0 AND 1.0),

		health REAL NOT NULL DEFAULT 1.0
			CHECK (health BETWEEN 0.0 AND 1.0),

		injury REAL NOT NULL DEFAULT 0.0
			CHECK (injury BETWEEN 0.0 AND 1.0),

		-- 當前所在位置
		location_id TEXT,

		FOREIGN KEY (npc_id)
			REFERENCES npc(npc_id)
			ON DELETE CASCADE,

		FOREIGN KEY (location_id)
			REFERENCES location(location_id)
			ON DELETE SET NULL
	);
	"""

	if not db.query(sql):

		push_error(
			"[NPCStateSchema] Failed to create npc_state."
		)

		return false

	return true
