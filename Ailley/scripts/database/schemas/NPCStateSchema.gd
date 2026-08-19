class_name NPCStateSchema
extends RefCounted


static func create(db) -> bool:

	var sql := """
	CREATE TABLE IF NOT EXISTS npc_state (

		npc_id TEXT PRIMARY KEY,

		-- 生理狀態：全部 0-100，跟規格書《01》§4-1 對齊（2026-08-16，見《99》P-32）。
		-- satiety/hydration/wakefulness 原欄位名 hunger/thirst/sleepiness 已改名，理由見《01》§4-1 的說明
		satiety REAL NOT NULL DEFAULT 100.0
			CHECK (satiety BETWEEN 0.0 AND 100.0),

		hydration REAL NOT NULL DEFAULT 80.0
			CHECK (hydration BETWEEN 0.0 AND 100.0),

		stamina REAL NOT NULL DEFAULT 80.0
			CHECK (stamina BETWEEN 0.0 AND 100.0),

		wakefulness REAL NOT NULL DEFAULT 90.0
			CHECK (wakefulness BETWEEN 0.0 AND 100.0),

		hygiene REAL NOT NULL DEFAULT 70.0
			CHECK (hygiene BETWEEN 0.0 AND 100.0),

		alcohol REAL NOT NULL DEFAULT 0.0
			CHECK (alcohol BETWEEN 0.0 AND 100.0),

		health REAL NOT NULL DEFAULT 100.0
			CHECK (health BETWEEN 0.0 AND 100.0),

		injury REAL NOT NULL DEFAULT 0.0
			CHECK (injury BETWEEN 0.0 AND 100.0),

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
