class_name NPCEmotionSchema
extends RefCounted


static func create(db) -> bool:

	var sql := """
	CREATE TABLE IF NOT EXISTS npc_emotion (

		npc_id TEXT PRIMARY KEY,

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

		-- 規格目前沒有 event_memory 資料表，因此保留為純 TEXT。
		cause_event_id TEXT,

		duration_left INTEGER NOT NULL DEFAULT 0
			CHECK (duration_left >= 0),

		updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,

		FOREIGN KEY (npc_id)
			REFERENCES npc(npc_id)
			ON DELETE CASCADE
	);
	"""

	if not db.query(sql):
		push_error("[NPCEmotionSchema] Failed to create npc_emotion.")
		return false

	return true
