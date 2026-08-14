class_name MemoryDatabase
extends RefCounted


# ============================================================
# MemoryDatabase
#
# Memory 資料操作層
#
# DatabaseManager
#       ↓
# MemoryDatabase
#       ↓
# ┌───────────────────────┐
# │ memories              │
# │ memory_related_npcs   │
# └───────────────────────┘
# ============================================================


# ============================================================
# 建立 Memory
#
# related_npcs 可以直接傳：
#
# [
#     "npc_002",
#     "npc_003"
# ]
#
# ============================================================

static func create_memory(
	memory_id: String,
	npc_id: String,
	level: int,
	content: String,
	valence: String,
	importance: int,
	related_npcs: Array = [],
	decay_value: int = 100,
	embedding: String = ""
) -> bool:

	# --------------------------------------------------------
	# 驗證
	# --------------------------------------------------------

	if memory_id.is_empty():
		push_error(
			"[MemoryDatabase] memory_id is empty."
		)
		return false


	if npc_id.is_empty():
		push_error(
			"[MemoryDatabase] npc_id is empty."
		)
		return false


	if level < 1 or level > 4:
		push_error(
			"[MemoryDatabase] level must be 1~4."
		)
		return false


	if content.is_empty():
		push_error(
			"[MemoryDatabase] content is empty."
		)
		return false


	if content.length() > 60:
		push_error(
			"[MemoryDatabase] content exceeds 60 characters."
		)
		return false


	if (
		valence != "positive"
		and valence != "negative"
		and valence != "neutral"
	):
		push_error(
			"[MemoryDatabase] invalid valence."
		)
		return false


	if importance < 0 or importance > 100:
		push_error(
			"[MemoryDatabase] importance must be 0~100."
		)
		return false


	if decay_value < 0 or decay_value > 100:
		push_error(
			"[MemoryDatabase] decay_value must be 0~100."
		)
		return false


	# --------------------------------------------------------
	# 開始 Transaction
	# --------------------------------------------------------

	if not DatabaseManager.begin_transaction():
		return false


	# --------------------------------------------------------
	# 建立 Memory
	# --------------------------------------------------------

	var memory_data := {
		"memory_id": memory_id,
		"npc_id": npc_id,
		"level": level,
		"content": content,
		"valence": valence,
		"importance": importance,
		"decay_value": decay_value
	}


	if not embedding.is_empty():
		memory_data["embedding"] = embedding


	if not DatabaseManager.insert(
		"memories",
		memory_data
	):

		DatabaseManager.rollback_transaction()

		push_error(
			"[MemoryDatabase] Failed to insert memory."
		)

		return false


	# --------------------------------------------------------
	# 建立 Related NPC
	# --------------------------------------------------------

	for related_npc in related_npcs:

		var related_npc_id := str(related_npc)

		if related_npc_id.is_empty():
			continue


		# 自己不需要成為自己的 related NPC
		if related_npc_id == npc_id:
			continue


		var relation_data := {
			"memory_id": memory_id,
			"npc_id": related_npc_id
		}


		if not DatabaseManager.insert(
			"memory_related_npcs",
			relation_data
		):

			DatabaseManager.rollback_transaction()

			push_error(
				"[MemoryDatabase] Failed to insert "
				+ "related NPC: "
				+ related_npc_id
			)

			return false


	# --------------------------------------------------------
	# 完成
	# --------------------------------------------------------

	if not DatabaseManager.commit_transaction():

		DatabaseManager.rollback_transaction()

		return false


	return true


# ============================================================
# 取得單筆 Memory
# ============================================================

static func get_memory(
	memory_id: String
) -> Dictionary:

	var result := DatabaseManager.select(
		"""
		SELECT
			memory_id,
			npc_id,
			level,
			content,
			valence,
			importance,
			decay_value,
			created_at,
			embedding
		FROM memories
		WHERE memory_id = '%s'
		LIMIT 1;
		"""
		% _escape(memory_id)
	)


	if result.is_empty():
		return {}


	var memory: Dictionary = result[0]

	memory["related_npcs"] = get_related_npcs(
		memory_id
	)


	return memory


# ============================================================
# 取得某 NPC 的所有 Memory
# ============================================================

static func get_memories_by_npc(
	npc_id: String
) -> Array:

	var result := DatabaseManager.select(
		"""
		SELECT
			memory_id,
			npc_id,
			level,
			content,
			valence,
			importance,
			decay_value,
			created_at,
			embedding
		FROM memories
		WHERE npc_id = '%s'
		ORDER BY
			level DESC,
			importance DESC,
			created_at DESC;
		"""
		% _escape(npc_id)
	)


	return _attach_related_npcs(result)


# ============================================================
# 取得某 NPC 指定 Level 的 Memory
#
# 例如：
#
# get_memories_by_level("npc_001", 3)
#
# → NPC_001 的所有 L3 記憶
# ============================================================

static func get_memories_by_level(
	npc_id: String,
	level: int
) -> Array:

	if level < 1 or level > 4:
		return []


	var result := DatabaseManager.select(
		"""
		SELECT
			memory_id,
			npc_id,
			level,
			content,
			valence,
			importance,
			decay_value,
			created_at,
			embedding
		FROM memories
		WHERE npc_id = '%s'
		AND level = %d
		ORDER BY
			importance DESC,
			created_at DESC;
		"""
		% [
			_escape(npc_id),
			level
		]
	)


	return _attach_related_npcs(result)


# ============================================================
# 查詢：
#
# 「NPC A 對 NPC B 有哪些記憶？」
#
# 例如：
#
# npc_001
#    ↓
# related
#    ↓
# npc_002
# ============================================================

static func get_memories_about_npc(
	owner_npc_id: String,
	related_npc_id: String
) -> Array:

	var result := DatabaseManager.select(
		"""
		SELECT
			m.memory_id,
			m.npc_id,
			m.level,
			m.content,
			m.valence,
			m.importance,
			m.decay_value,
			m.created_at,
			m.embedding
		FROM memories AS m

		INNER JOIN memory_related_npcs AS r
			ON m.memory_id = r.memory_id

		WHERE m.npc_id = '%s'
		AND r.npc_id = '%s'

		ORDER BY
			m.level DESC,
			m.importance DESC,
			m.created_at DESC;
		"""
		% [
			_escape(owner_npc_id),
			_escape(related_npc_id)
		]
	)


	return _attach_related_npcs(result)


# ============================================================
# 取得某筆 Memory 的 related_npcs
#
# SQLite：
#
# memory_001 | npc_002
# memory_001 | npc_003
#
# ↓
#
# Godot：
#
# ["npc_002", "npc_003"]
# ============================================================

static func get_related_npcs(
	memory_id: String
) -> Array:

	var result := DatabaseManager.select(
		"""
		SELECT npc_id
		FROM memory_related_npcs
		WHERE memory_id = '%s'
		ORDER BY npc_id;
		"""
		% _escape(memory_id)
	)


	var related_npcs: Array = []


	for row in result:

		if row.has("npc_id"):
			related_npcs.append(
				str(row["npc_id"])
			)


	return related_npcs


# ============================================================
# 新增 Related NPC
# ============================================================

static func add_related_npc(
	memory_id: String,
	npc_id: String
) -> bool:

	if memory_id.is_empty():
		return false


	if npc_id.is_empty():
		return false


	var existing := DatabaseManager.select(
		"""
		SELECT memory_id
		FROM memory_related_npcs
		WHERE memory_id = '%s'
		AND npc_id = '%s'
		LIMIT 1;
		"""
		% [
			_escape(memory_id),
			_escape(npc_id)
		]
	)


	# 已存在就不用再新增
	if not existing.is_empty():
		return true


	return DatabaseManager.insert(
		"memory_related_npcs",
		{
			"memory_id": memory_id,
			"npc_id": npc_id
		}
	)


# ============================================================
# 移除 Related NPC
# ============================================================

static func remove_related_npc(
	memory_id: String,
	npc_id: String
) -> bool:

	return DatabaseManager.delete(
		"memory_related_npcs",
		"""
		memory_id = '%s'
		AND npc_id = '%s'
		"""
		% [
			_escape(memory_id),
			_escape(npc_id)
		]
	)


# ============================================================
# 完整替換 Related NPC
#
# 舊：
# ["npc_002", "npc_003"]
#
# 新：
# ["npc_005"]
#
# 執行後只剩 npc_005
# ============================================================

static func set_related_npcs(
	memory_id: String,
	related_npcs: Array
) -> bool:

	if not DatabaseManager.begin_transaction():
		return false


	if not DatabaseManager.delete(
		"memory_related_npcs",
		"memory_id = '%s'" % _escape(memory_id)
	):

		DatabaseManager.rollback_transaction()

		return false


	for related_npc in related_npcs:

		var npc_id := str(related_npc)

		if npc_id.is_empty():
			continue


		if not add_related_npc(
			memory_id,
			npc_id
		):

			DatabaseManager.rollback_transaction()

			return false


	if not DatabaseManager.commit_transaction():

		DatabaseManager.rollback_transaction()

		return false


	return true


# ============================================================
# 更新 Memory
#
# related_npcs 如果存在：
# → 一起更新
#
# related_npcs 如果不存在：
# → 保持原本關聯
# ============================================================

static func update_memory(
	memory_id: String,
	data: Dictionary
) -> bool:

	if memory_id.is_empty():
		return false


	if data.is_empty():
		return false


	var update_data := data.duplicate(true)


	var has_related_npcs := update_data.has(
		"related_npcs"
	)


	var related_npcs: Array = []


	if has_related_npcs:

		related_npcs = update_data[
			"related_npcs"
		]

		update_data.erase(
			"related_npcs"
		)


	# --------------------------------------------------------
	# Whitelist allowed columns for memories table
	# --------------------------------------------------------

	const ALLOWED_COLUMNS := [
		"level",
		"content",
		"valence",
		"importance",
		"decay_value",
		"embedding"
	]


	# Remove any columns not in whitelist
	for key in update_data.keys():
		if not key in ALLOWED_COLUMNS:
			update_data.erase(key)


	# --------------------------------------------------------
	# 驗證
	# --------------------------------------------------------

	if update_data.has("level"):

		var level := int(
			update_data["level"]
		)

		if level < 1 or level > 4:
			return false


	if update_data.has("content"):

		var content := str(
			update_data["content"]
		)

		if content.length() > 60:
			return false


	if update_data.has("importance"):

		var importance := int(
			update_data["importance"]
		)

		if importance < 0 or importance > 100:
			return false


	if update_data.has("decay_value"):

		var decay := int(
			update_data["decay_value"]
		)

		if decay < 0 or decay > 100:
			return false


	# --------------------------------------------------------
	# Transaction
	# --------------------------------------------------------

	if not DatabaseManager.begin_transaction():
		return false


	# --------------------------------------------------------
	# 更新 Memory
	# --------------------------------------------------------

	if not update_data.is_empty():

		if not DatabaseManager.update(
			"memories",
			update_data,
			"memory_id = '%s'"
			% _escape(memory_id)
		):

			DatabaseManager.rollback_transaction()

			return false


	# --------------------------------------------------------
	# 更新 Related NPC
	# --------------------------------------------------------

	if has_related_npcs:

		if not DatabaseManager.delete(
			"memory_related_npcs",
			"memory_id = '%s'"
			% _escape(memory_id)
		):

			DatabaseManager.rollback_transaction()

			return false


		for related_npc in related_npcs:

			var npc_id := str(
				related_npc
			)

			if npc_id.is_empty():
				continue


			if not DatabaseManager.insert(
				"memory_related_npcs",
				{
					"memory_id": memory_id,
					"npc_id": npc_id
				}
			):

				DatabaseManager.rollback_transaction()

				return false


	# --------------------------------------------------------
	# Commit
	# --------------------------------------------------------

	if not DatabaseManager.commit_transaction():

		DatabaseManager.rollback_transaction()

		return false


	return true


# ============================================================
# 更新衰減
#
# decay_value = 0
# → 自動刪除 Memory
# ============================================================

static func update_decay(
	memory_id: String,
	decay_value: int
) -> bool:

	decay_value = clampi(
		decay_value,
		0,
		100
	)


	if decay_value <= 0:
		return delete_memory(memory_id)


	return DatabaseManager.update(
		"memories",
		{
			"decay_value": decay_value
		},
		"memory_id = '%s'"
		% _escape(memory_id)
	)


# ============================================================
# 批次降低所有 Memory 的 decay
#
# 例如每天：
#
# decay_amount = 5
#
# 100 → 95
# 95  → 90
# ...
# 5   → 0 → 刪除
# ============================================================

static func decay_memories(
	npc_id: String,
	decay_amount: int
) -> bool:

	if decay_amount <= 0:
		return false


	var result := DatabaseManager.select(
		"""
		SELECT
			memory_id,
			decay_value
		FROM memories
		WHERE npc_id = '%s';
		"""
		% _escape(npc_id)
	)


	if not DatabaseManager.begin_transaction():
		return false


	for row in result:

		var memory_id := str(
			row["memory_id"]
		)

		var current_decay := int(
			row["decay_value"]
		)

		var new_decay := current_decay - decay_amount


		if new_decay <= 0:

			if not DatabaseManager.delete(
				"memories",
				"memory_id = '%s'"
				% _escape(memory_id)
			):

				DatabaseManager.rollback_transaction()

				return false

		else:

			if not DatabaseManager.update(
				"memories",
				{
					"decay_value": new_decay
				},
				"memory_id = '%s'"
				% _escape(memory_id)
			):

				DatabaseManager.rollback_transaction()

				return false


	if not DatabaseManager.commit_transaction():

		DatabaseManager.rollback_transaction()

		return false


	return true


# ============================================================
# 刪除 Memory
#
# 因為 MemorySchema：
#
# memory_related_npcs
#        ↓
# ON DELETE CASCADE
#
# 所以刪除 Memory 時，
# related NPC 關聯也會自動刪除。
# ============================================================

static func delete_memory(
	memory_id: String
) -> bool:

	return DatabaseManager.delete(
		"memories",
		"memory_id = '%s'"
		% _escape(memory_id)
	)


# ============================================================
# Memory 數量
# ============================================================

static func get_memory_count(
	npc_id: String
) -> int:

	var result := DatabaseManager.select(
		"""
		SELECT COUNT(*) AS count
		FROM memories
		WHERE npc_id = '%s';
		"""
		% _escape(npc_id)
	)


	if result.is_empty():
		return 0


	return int(
		result[0]["count"]
	)


# ============================================================
# 某 Level 的 Memory 數量
# ============================================================

static func get_memory_count_by_level(
	npc_id: String,
	level: int
) -> int:

	var result := DatabaseManager.select(
		"""
		SELECT COUNT(*) AS count
		FROM memories
		WHERE npc_id = '%s'
		AND level = %d;
		"""
		% [
			_escape(npc_id),
			level
		]
	)


	if result.is_empty():
		return 0


	return int(
		result[0]["count"]
	)


# ============================================================
# 內部：
# 把 related_npcs 加回 Memory Dictionary
# ============================================================

static func _attach_related_npcs(
	memories: Array
) -> Array:

	for memory in memories:

		if memory.has("memory_id"):

			memory["related_npcs"] = get_related_npcs(
				str(memory["memory_id"])
			)


	return memories


# ============================================================
# SQL Escape
# ============================================================

static func _escape(
	value: String
) -> String:

	return value.replace(
		"'",
		"''"
	)
