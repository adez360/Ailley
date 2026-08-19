class_name MemorySchema
extends RefCounted


static func create(db) -> bool:

	var memory_sql := """
	CREATE TABLE IF NOT EXISTS memories (

		memory_id TEXT PRIMARY KEY,

		npc_id TEXT NOT NULL,

		level INTEGER NOT NULL DEFAULT 1
			CHECK(level BETWEEN 1 AND 4),

		content TEXT NOT NULL
			CHECK(length(content) <= 60),

		valence TEXT NOT NULL DEFAULT 'neutral'
			CHECK(
				valence IN ('positive', 'negative', 'neutral')
			),

		importance INTEGER NOT NULL DEFAULT 0
			CHECK(importance BETWEEN 0 AND 100),

		decay_value INTEGER NOT NULL DEFAULT 100
			CHECK(decay_value BETWEEN 0 AND 100),

		-- 遊戲時間
		created_tick INTEGER NOT NULL,
		created_day INTEGER NOT NULL,

		-- 記憶發生地點
		location_id TEXT,

		created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,

		embedding TEXT,

		FOREIGN KEY (npc_id)
			REFERENCES npc(npc_id)
			ON DELETE CASCADE,

		FOREIGN KEY (location_id)
			REFERENCES location(location_id)
			ON DELETE SET NULL
	);

	CREATE INDEX IF NOT EXISTS
	idx_memories_npc_level
	ON memories(npc_id, level);

	CREATE INDEX IF NOT EXISTS
	idx_memories_decay
	ON memories(decay_value);

	CREATE INDEX IF NOT EXISTS
	idx_memories_npc_day
	ON memories(npc_id, created_day);
	"""

	if not db.query(memory_sql):
		push_error("[MemorySchema] Failed to create memories.")
		return false


	var related_npcs_sql := """
	CREATE TABLE IF NOT EXISTS memory_related_npcs (

		memory_id TEXT NOT NULL,

		npc_id TEXT NOT NULL,

		PRIMARY KEY (memory_id, npc_id),

		FOREIGN KEY (memory_id)
			REFERENCES memories(memory_id)
			ON DELETE CASCADE,

		FOREIGN KEY (npc_id)
			REFERENCES npc(npc_id)
			ON DELETE CASCADE,

		CHECK(memory_id IS NOT NULL),
		CHECK(npc_id IS NOT NULL)
	);

	CREATE INDEX IF NOT EXISTS
	idx_memory_related_npcs_npc
	ON memory_related_npcs(npc_id);
	"""

	if not db.query(related_npcs_sql):
		push_error("[MemorySchema] Failed to create memory_related_npcs.")
		return false

	return true
