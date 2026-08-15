class_name NPCConditionSchema
extends RefCounted

# "conditions": [
#    {
#        "type": "injured",
#        "turns_left": 8
#    }
#]

static func create(db) -> bool:

	var sql := """
	CREATE TABLE IF NOT EXISTS npc_condition (

		condition_id INTEGER PRIMARY KEY AUTOINCREMENT,

		npc_id TEXT NOT NULL,

		-- 生理衍生（由 state.physical 自動觸發） / 社會狀態 / 行動佔用 / 終局狀態
		type TEXT NOT NULL
			CHECK(
				type IN (
					'injured',
					'drunk',
					'starving',
					'dehydrated',
					'exhausted',
					'filthy',
					'sleepy',
					'detained',
					'outcast',
					'sleeping',
					'napping',
					'working',
					'talking',
					'petrified'
				)
			),

		-- 剩餘 tick。-1 表示持續到條件解除為止
		turns_left INTEGER NOT NULL DEFAULT 0,

		updated_at TEXT NOT NULL
			DEFAULT CURRENT_TIMESTAMP,

		FOREIGN KEY (npc_id)
			REFERENCES npc(npc_id)
			ON DELETE CASCADE,

		-- 同一個 NPC 身上多種 condition 會並存（injured + working），
		-- 但同一種不重複
		UNIQUE (npc_id, type)
	);

	CREATE INDEX IF NOT EXISTS
	idx_npc_condition_npc_id
	ON npc_condition(npc_id);
	"""

	if not db.query(sql):

		push_error(
			"[NPCConditionSchema] "
			+ "Failed to create npc_condition."
		)

		return false

	return true
