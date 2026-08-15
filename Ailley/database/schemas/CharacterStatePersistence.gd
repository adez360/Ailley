extends Node


## =====================================================
## CharacterStatePersistence
##
## 職責：
## 1. 找到目前場景中的所有 Character
## 2. 讀取每個 Character 的 Stats
## 3. 將 Player / NPC 寫入同一張 character_state
## 4. 由 GameClock 控制同步頻率
##
## 不直接處理 Stats 計算。
## 不直接修改 Character。
## SQLite 操作全部交給 DatabaseManager。
## =====================================================


const TABLE_NAME := "character_state"


func _ready() -> void:
	# GameClock 每個遊戲分鐘發出一次。
	# 目前設定為 1 現實秒 = 1 遊戲分鐘。
	if not GameClock.time_changed.is_connected(_on_game_time_changed):
		GameClock.time_changed.connect(_on_game_time_changed)

	# 等主場景角色建立完成後做第一次同步。
	call_deferred("_sync_all_characters")


func _on_game_time_changed(hour: int, minute: int) -> void:
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
			"[CharacterStatePersistence] 目前場景沒有 Character。"
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
		"[CharacterStatePersistence] 同步完成：%d / %d characters"
		% [success_count, characters.size()]
	)


func _save_character(character: Character) -> bool:
	if character == null:
		return false

	if character.stats == null:
		push_warning(
			"[CharacterStatePersistence] %s 沒有 Stats 元件。"
			% character.name
		)
		return false

	var character_id := character.character_id

	if character_id.is_empty():
		push_warning(
			"[CharacterStatePersistence] %s 沒有 character_id。"
			% character.name
		)
		return false

	var character_type := _get_character_type(character)

	var data := {
		"character_id": character_id,
		"character_type": character_type,

		"hunger": character.stats.get_value("hunger"),
		"energy": character.stats.get_value("energy"),
		"social": character.stats.get_value("social"),
		"fun": character.stats.get_value("fun"),
		"mood": character.stats.get_value("mood"),

		"last_day": GameClock.day,
		"last_hour": GameClock.hour,
		"last_minute": GameClock.minute
	}

	var escaped_id := _escape_sql_string(character_id)

	var existing := DatabaseManager.select(
		TABLE_NAME,
		"character_id = '%s'" % escaped_id,
		["character_id"]
	)

	# 第一次看到這個 Character：
	# INSERT
	if existing.is_empty():
		var inserted := DatabaseManager.insert(
			TABLE_NAME,
			data
		)

		if inserted:
			print(
				"[CharacterStatePersistence] INSERT %s (%s)"
				% [character.character_name, character_type]
			)

		return inserted

	# 已經存在：
	# UPDATE
	var updated := DatabaseManager.update(
		TABLE_NAME,
		data,
		"character_id = '%s'" % escaped_id
	)

	if updated:
		print(
			"[CharacterStatePersistence] UPDATE %s (%s) hunger=%.2f energy=%.2f social=%.2f fun=%.2f mood=%.2f"
			% [
				character.character_name,
				character_type,
				data["hunger"],
				data["energy"],
				data["social"],
				data["fun"],
				data["mood"]
			]
		)

	return updated


func _get_character_type(character: Character) -> String:
	if character.is_in_group("player"):
		return "player"

	return "npc"


func _escape_sql_string(value: String) -> String:
	return value.replace("'", "''")


## 手動測試用。
## 可以從其他 Debug 程式呼叫：
##
## CharacterStatePersistence.sync_now()
##
func sync_now() -> void:
	_sync_all_characters()


## 查詢目前資料庫內所有角色狀態。
## 測試階段非常方便。
func get_all_states() -> Array:
	if not DatabaseManager.is_ready:
		return []

	return DatabaseManager.select(
		TABLE_NAME,
		"",
		[
			"character_id",
			"character_type",
			"hunger",
			"energy",
			"social",
			"fun",
			"mood",
			"last_day",
			"last_hour",
			"last_minute"
		]
	)
