class_name WorldCharacterStateSchema
extends RefCounted

## 每個角色在某個世界裡的位置與行程狀態——這些屬於世界層，不屬於角色層，
## 見 note/技術/存檔.md「位置屬於世界，不屬於角色」。同一個角色可以出現在
## 多個世界存檔裡（帶自己的 agent 進別人的村莊），各自有各自的座標，
## 所以主鍵是 (world_id, npc_id) 而不是單獨的 npc_id。
##
## current_place / current_state 只有 Agent（行程仲裁器）才有意義，Player
## 沒有這兩個欄位，見 scripts/core/game_manager.gd::get_world_save_data()，
## 所以兩欄都允許 NULL。


static func create(db) -> bool:

	var sql := """
	CREATE TABLE IF NOT EXISTS world_character_state (

		world_id TEXT NOT NULL,
		npc_id TEXT NOT NULL,

		pos_x REAL NOT NULL DEFAULT 0.0,
		pos_y REAL NOT NULL DEFAULT 0.0,

		current_place TEXT,
		current_state TEXT,

		updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,

		PRIMARY KEY (world_id, npc_id),

		FOREIGN KEY (world_id)
			REFERENCES world(world_id)
			ON DELETE CASCADE,

		FOREIGN KEY (npc_id)
			REFERENCES npc(npc_id)
			ON DELETE CASCADE
	);

	CREATE INDEX IF NOT EXISTS
	idx_world_character_state_npc
	ON world_character_state(npc_id);
	"""

	if not db.query(sql):

		push_error(
			"[WorldCharacterStateSchema] Failed to create world_character_state."
		)

		return false

	return true
