class_name WorldSchema
extends RefCounted

## 世界層的日曆與旗標，見 note/技術/存檔.md「兩層：角色與世界」。
## 只有一份世界存檔的整體屬性，每個角色在這個世界裡的位置另外在
## world_character_state（見該表）。


static func create(db) -> bool:

	var sql := """
	CREATE TABLE IF NOT EXISTS world (

		world_id TEXT NOT NULL PRIMARY KEY,

		-- GameClock.day，從 1 起算
		day INTEGER NOT NULL DEFAULT 1
			CHECK (day >= 1),

		-- 建立世界時決定，不是「現在有沒有 player」，見《技術/存檔》
		allow_player_join INTEGER NOT NULL DEFAULT 0
			CHECK (allow_player_join IN (0, 1)),

		created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
		updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
	);
	"""

	if not db.query(sql):

		push_error(
			"[WorldSchema] Failed to create world."
		)

		return false

	return true
