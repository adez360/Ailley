# 規格尚未定案，欄位可能異動

class_name MemorySchema
extends RefCounted


static func create(db) -> bool:

	# =====================================================
	# memories
	#
	# 一筆資料 = 一個 NPC 的一段記憶
	# =====================================================

	var memory_sql := """
	CREATE TABLE IF NOT EXISTS memories (

		-- 記憶唯一 ID
		memory_id TEXT PRIMARY KEY,

		-- 擁有這段記憶的 NPC
		npc_id TEXT NOT NULL,

		-- 記憶層級
		-- 1 = L1
		-- 2 = L2
		-- 3 = L3
		-- 4 = L4
		level INTEGER NOT NULL DEFAULT 1
			CHECK(level BETWEEN 1 AND 4),

		-- LLM 產生的記憶內容
		content TEXT NOT NULL
			CHECK(length(content) <= 60),

		-- 情緒價值
		valence TEXT NOT NULL DEFAULT 'neutral'
			CHECK(
				valence IN (
					'positive',
					'negative',
					'neutral'
				)
			),

		-- 重要程度
		importance INTEGER NOT NULL DEFAULT 0
			CHECK(importance BETWEEN 0 AND 100),

		-- 記憶衰減值
		-- 100 = 完整
		-- 0 = 刪除
		decay_value INTEGER NOT NULL DEFAULT 100
			CHECK(decay_value BETWEEN 0 AND 100),

		-- 建立時間
		created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,

		-- =================================================
		-- Embedding
		--
		-- SQLite 本身沒有 vector 型別。
		--
		-- 目前使用 TEXT 儲存 JSON 格式的向量。
		--
		-- 例如：
		-- [0.123,-0.456,0.789,...]
		--
		-- 等未來確定 Vector DB / vector extension
		-- 再進行 migration。
		-- =================================================
		embedding TEXT,

		FOREIGN KEY (npc_id)
			REFERENCES npc(npc_id)
			ON DELETE CASCADE
	);

	-- 單獨的 npc_id index 不用建：它是 idx_memories_npc_level 的前綴。
	CREATE INDEX IF NOT EXISTS
	idx_memories_npc_level
	ON memories(npc_id, level);

	CREATE INDEX IF NOT EXISTS
	idx_memories_decay
	ON memories(decay_value);
	"""

	if not db.query(memory_sql):

		push_error(
			"[MemorySchema] Failed to create memories."
		)

		return false


	# =====================================================
	# memory_related_npcs
	#
	# 用來取代 related_npcs Array
	#
	# 例如：
	#
	# Memory A
	#   ├── NPC 002
	#   ├── NPC 003
	#   └── NPC 005
	#
	# 實際資料：
	#
	# memory_A | npc_002
	# memory_A | npc_003
	# memory_A | npc_005
	# =====================================================

	var related_npcs_sql := """
	CREATE TABLE IF NOT EXISTS memory_related_npcs (

		memory_id TEXT NOT NULL,

		npc_id TEXT NOT NULL,

		PRIMARY KEY (
			memory_id,
			npc_id
		),

		FOREIGN KEY (memory_id)
			REFERENCES memories(memory_id)
			ON DELETE CASCADE,

		FOREIGN KEY (npc_id)
			REFERENCES npc(npc_id)
			ON DELETE CASCADE,

		CHECK(memory_id IS NOT NULL),
		CHECK(npc_id IS NOT NULL)
	);

	-- memory_id 是 PRIMARY KEY (memory_id, npc_id) 的前綴，不用另外建。
	CREATE INDEX IF NOT EXISTS
	idx_memory_related_npcs_npc
	ON memory_related_npcs(npc_id);
	"""

	if not db.query(related_npcs_sql):

		push_error(
			"[MemorySchema] Failed to create memory_related_npcs."
		)

		return false


	return true
