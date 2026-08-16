extends Node


## =====================================================
## CharacterStatePersistence
##
## 將目前遊戲中的 Player + NPC
## 統一寫入既有 npc_state。
##
## 注意：
## npc_state 原本設計給 NPC，
## 所以 Player 會先在 npc 表建立一筆對應資料，
## 再寫入 npc_state。
## =====================================================


const STATE_TABLE := "npc_state"
const NPC_TABLE := "npc"


func _ready() -> void:
	# 等主場景中的 Character 全部建立完成
	# 再做第一次同步。
	call_deferred("_sync_all_characters")

	# GameClock 每一遊戲分鐘觸發一次。
	if not GameClock.time_changed.is_connected(_on_time_changed):
		GameClock.time_changed.connect(_on_time_changed)


func _on_time_changed(_hour: int, _minute: int) -> void:
	_sync_all_characters()


func _sync_all_characters() -> void:
	if not DatabaseManager.is_ready:
		push_warning(
			"[CharacterStatePersistence] DatabaseManager 尚未準備完成。"
		)
		return

	var characters := get_tree().get_nodes_in_group("characters")

	if characters.is_empty():
		push_warning(
			"[CharacterStatePersistence] 找不到任何 Character。"
		)
		return

	var success_count := 0

	for node in characters:
		var character := node as Character

		if character == null:
			continue

		if _save_character(character):
			success_count += 1

	print(
		"[CharacterStatePersistence] npc_state 同步完成：%d / %d"
		% [success_count, characters.size()]
	)


func _save_character(character: Character) -> bool:
	if character == null:
		return false

	if character.stats == null:
		push_warning(
			"[CharacterStatePersistence] %s 沒有 Stats。"
			% character.name
		)
		return false

	if character.character_id.is_empty():
		push_warning(
			"[CharacterStatePersistence] %s 沒有 character_id。"
			% character.name
		)
		return false

	# -------------------------------------------------
	# 1. 先確保角色存在 npc 表
	# -------------------------------------------------

	if not _ensure_npc_record(character):
		return false


	# -------------------------------------------------
	# 2. 讀取目前 Stats
	# -------------------------------------------------

	var hunger := character.stats.get_value("hunger")
	var thirst := character.stats.get_value("thirst")
	var stamina := character.stats.get_value("stamina")
	var sleepiness := character.stats.get_value("sleepiness")
	var hygiene := character.stats.get_value("hygiene")
	var alcohol := character.stats.get_value("alcohol")
	var injury := character.stats.get_value("injury")

	# -------------------------------------------------
	# 3. Stats 0~100
	#    npc_state 0~1
	# -------------------------------------------------

	var hunger_db := _round_2(clampf(hunger / 100.0, 0.0, 1.0))
	var thirst_db := _round_2(clampf(thirst / 100.0, 0.0, 1.0))
	var stamina_db := _round_2(clampf(stamina / 100.0, 0.0, 1.0))
	var sleepiness_db := _round_2(clampf(sleepiness / 100.0, 0.0, 1.0))
	var hygiene_db := _round_2(clampf(hygiene / 100.0, 0.0, 1.0))
	var alcohol_db := _round_2(clampf(alcohol / 100.0, 0.0, 1.0))
	var injury_db := _round_2(clampf(injury / 100.0, 0.0, 1.0))

	# -------------------------------------------------
	# 4. 準備 npc_state
	# -------------------------------------------------

	var state_data := {
		"npc_id": character.character_id,
		"hunger": hunger_db,
		"thirst": thirst_db,
		"stamina": stamina_db,
		"sleepiness": sleepiness_db,
		"hygiene": hygiene_db,
		"alcohol": alcohol_db,
		"injury": injury_db
	}


	# -------------------------------------------------
	# 5. 檢查 npc_state 是否已經存在
	# -------------------------------------------------

	var existing := DatabaseManager.select(
		STATE_TABLE,
		"npc_id = '%s'" % _escape_sql(character.character_id),
		["npc_id"]
	)


	# -------------------------------------------------
	# 6. 第一次：INSERT
	# -------------------------------------------------

	if existing.is_empty():
		var inserted := DatabaseManager.insert(
			STATE_TABLE,
			state_data
		)

		if inserted:
			print(
				"[CharacterStatePersistence] INSERT npc_state: %s | %s | hunger=%.2f stamina=%.2f"
				% [
					character.character_name,
					_get_character_type(character),
					hunger_db,
					stamina_db
				]
			)

		return inserted


	# -------------------------------------------------
	# 7. 已存在：UPDATE
	# -------------------------------------------------

	var updated := DatabaseManager.update(
		STATE_TABLE,
		state_data,
		"npc_id = '%s'" % _escape_sql(character.character_id)
	)

	if updated:
		print(
			"[CharacterStatePersistence] UPDATE npc_state: %s | %s | hunger=%.2f stamina=%.2f"
			% [
				character.character_name,
				_get_character_type(character),
				hunger_db,
				stamina_db
			]
		)

	return updated


func _ensure_npc_record(character: Character) -> bool:
	var character_id := character.character_id

	var existing := DatabaseManager.select(
		NPC_TABLE,
		"npc_id = '%s'" % _escape_sql(character_id),
		["npc_id"]
	)

	if not existing.is_empty():
		return true


	# -------------------------------------------------
	# Player / NPC 都建立一筆 npc 基本資料。
	#
	# 這是因為 npc_state.npc_id 有 FOREIGN KEY：
	#
	# npc_state.npc_id
	#        ↓
	# npc.npc_id
	# -------------------------------------------------

	var npc_data := {
		"npc_id": character_id,

		"name": character.character_name,

		"age": 18,

		"gender": "other",

		"village_id": "default_village",

		"character": _get_character_type(character),

		"reputation": 0,

		"system_prompt": "",

		"words_to_creator": "",

		"is_spoken": 0,

		"is_active": 1
	}


	var inserted := DatabaseManager.insert(
		NPC_TABLE,
		npc_data
	)

	if not inserted:
		push_error(
			"[CharacterStatePersistence] 無法建立 npc 記錄：%s"
			% character_id
		)

		return false


	print(
		"[CharacterStatePersistence] 建立 npc 基本資料：%s (%s)"
		% [
			character.character_name,
			_get_character_type(character)
		]
	)

	return true


func _get_character_type(character: Character) -> String:
	if character.is_in_group("player"):
		return "player"

	return "npc"


func _escape_sql(value: String) -> String:
	return value.replace("'", "''")


## -----------------------------------------------------
## 手動測試
## -----------------------------------------------------

func sync_now() -> void:
	_sync_all_characters()


## -----------------------------------------------------
## 查看目前 npc_state
## -----------------------------------------------------

func get_all_states() -> Array:
	if not DatabaseManager.is_ready:
		return []

	return DatabaseManager.select(
		STATE_TABLE,
		"",
		[
			"npc_id",
			"hunger",
			"thirst",
			"stamina",
			"sleepiness",
			"hygiene",
			"alcohol",
			"health",
			"injury",
			"location_id"
		]
	)

func _round_2(value: float) -> float:
	return roundf(value * 100.0) / 100.0
