# 規格尚未定案，欄位可能異動

class_name NPCEmotionSchema
extends RefCounted


static func create(db) -> bool:

	var sql := """
	CREATE TABLE IF NOT EXISTS npc_emotion (

		npc_id TEXT PRIMARY KEY,
		-- 八種情緒
		emotion TEXT NOT NULL DEFAULT 'neutral'
			CHECK(
				emotion IN (
					'joy',
					'anger',
					'sadness',
					'fear',
					'surprise',
					'disgust',
					'anticipation',
					'neutral'
				)
			),

		intensity INTEGER NOT NULL DEFAULT 0
			CHECK (intensity BETWEEN 0 AND 100),

		-- 起因事件
		cause_event_id TEXT,

		-- 剩餘 tick，每 tick 減 1
		duration_left  INTEGER NOT NULL DEFAULT 0
			CHECK (duration_left >= 0),

		updated_at TEXT NOT NULL
			DEFAULT CURRENT_TIMESTAMP,

		FOREIGN KEY (npc_id)
			REFERENCES npc(npc_id)
			ON DELETE CASCADE,

		FOREIGN KEY (cause_event_id)
			REFERENCES event_memory(event_id)
			ON DELETE SET NULL
	);
	"""

	if not db.query(sql):

		push_error(
			"[NPCEmotionSchema] "
			+ "Failed to create npc_emotion."
		)

		return false

	return true
