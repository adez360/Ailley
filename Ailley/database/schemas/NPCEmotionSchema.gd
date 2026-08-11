class_name NPCEmotionSchema
extends RefCounted


static func create(db) -> bool:

	var sql := """
	CREATE TABLE IF NOT EXISTS npc_emotion (

		npc_id TEXT PRIMARY KEY,

		emotion TEXT NOT NULL DEFAULT 'neutral',

		intensity INTEGER NOT NULL DEFAULT 0
			CHECK (intensity BETWEEN 0 AND 100),

		happiness INTEGER NOT NULL DEFAULT 50
			CHECK (happiness BETWEEN 0 AND 100),

		anger INTEGER NOT NULL DEFAULT 0
			CHECK (anger BETWEEN 0 AND 100),

		fear INTEGER NOT NULL DEFAULT 0
			CHECK (fear BETWEEN 0 AND 100),

		sadness INTEGER NOT NULL DEFAULT 0
			CHECK (sadness BETWEEN 0 AND 100),

		stress INTEGER NOT NULL DEFAULT 0
			CHECK (stress BETWEEN 0 AND 100),

		updated_at TEXT NOT NULL
			DEFAULT CURRENT_TIMESTAMP,

		FOREIGN KEY (npc_id)
			REFERENCES npc(npc_id)
			ON DELETE CASCADE
	);
	"""

	if not db.query(sql):

		push_error(
			"[NPCEmotionSchema] "
			+ "Failed to create npc_emotion."
		)

		return false

	return true
