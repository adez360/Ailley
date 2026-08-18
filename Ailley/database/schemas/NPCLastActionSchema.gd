class_name NPCLastActionSchema
extends RefCounted


static func create(db) -> bool:

	var sql := """
	CREATE TABLE IF NOT EXISTS npc_last_action (

		npc_id TEXT PRIMARY KEY,

		-- 規格 L3：last_action_result.action
		action TEXT NOT NULL DEFAULT '',

		-- 規格 L3：last_action_result.target
		target TEXT NOT NULL DEFAULT '',

		-- NULL = 尚未有結果；0 = 失敗；1 = 成功
		success INTEGER
			CHECK (success IS NULL OR success IN (0, 1)),

		-- 失敗時必填；成功時為 NULL
		reason TEXT
			CHECK (
				CASE
					WHEN success = 0 AND reason IS NOT NULL AND reason <> '' THEN 1
					WHEN success = 1 AND reason IS NULL THEN 1
					WHEN success IS NULL AND reason IS NULL THEN 1
					ELSE 0
				END = 1
			),

		-- runtime / debug metadata；不取代上面的規格欄位
		location_id TEXT,
		target_npc_id TEXT,
		target_item_id TEXT,
		action_started_at TEXT,
		action_finished_at TEXT,

		updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,

		FOREIGN KEY (npc_id)
			REFERENCES npc(npc_id)
			ON DELETE CASCADE,

		FOREIGN KEY (location_id)
			REFERENCES location(location_id)
			ON DELETE SET NULL,

		FOREIGN KEY (target_npc_id)
			REFERENCES npc(npc_id)
			ON DELETE SET NULL,

		FOREIGN KEY (target_item_id)
			REFERENCES item(item_id)
			ON DELETE SET NULL
	);
	"""

	if not db.query(sql):
		push_error("[NPCLastActionSchema] Failed to create npc_last_action.")
		return false

	return true
