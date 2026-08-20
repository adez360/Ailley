extends Node

## =====================================================
## CharacterStateIntegrationTest
##
## 用途：
##   驗證「實際遊戲中的 Character / Stats」
##   是否能透過 CharacterStatePersistence 正確寫入 SQLite。
##
## 本測試不修改正式 Schema，也不建立假的 Character。
## 它只抓目前遊戲場景中第一個 Character，
## 寫入一組明確測試數值，再由 SQLite 讀回驗證。
##
## 驗證項目：
##   satiety
##   hydration
##   stamina
##   wakefulness
##   hygiene
##   alcohol
##   health
##   injury
##
## 同時驗證：
##   npc record 是否建立
##   home_location_id 是否存在
##   npc_state UPDATE 是否能覆蓋既有資料
##
## 注意：
##   CharacterStatePersistence 已透過 _load_inventory_once() 持久化 Inventory，
##   但本測試目前只驗證 npc_state 這條路徑，尚未涵蓋 Inventory -> SQLite 的
##   比對，故仍只回報 [INFO] 而不判定 PASS/FAIL。
## =====================================================


const TEST_VALUES := {
	"satiety": 61.0,
	"hydration": 72.0,
	"stamina": 83.0,
	"wakefulness": 54.0,
	"hygiene": 67.0,
	"alcohol": 18.0,
	"health": 91.0,
	"injury": 7.0
}


var passed := 0
var failed := 0


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	print("")
	print("=====================================================")
	print("[CharacterStateIntegrationTest] START")
	print("=====================================================")

	var ready_wait_frames := 0
	const READY_WAIT_TIMEOUT_FRAMES := 300

	while not DatabaseManager.is_ready:
		ready_wait_frames += 1
		if ready_wait_frames > READY_WAIT_TIMEOUT_FRAMES:
			_fail(
				"DatabaseManager.is_ready",
				"等待逾時（%d frames），資料庫可能初始化失敗" % READY_WAIT_TIMEOUT_FRAMES
			)
			_finish()
			return
		await get_tree().process_frame

	var character := _find_test_character()

	if character == null:
		_fail(
			"Character",
			"場景中找不到 Character。請在正常遊戲場景執行本測試，不要在空白測試場景執行。"
		)
		_finish()
		return

	if character.stats == null:
		_fail(
			"Character.stats",
			"Character 沒有 Stats。"
		)
		_finish()
		return

	print(
		"[CharacterStateIntegrationTest] Character = %s | id = %s"
		% [
			character.character_name,
			character.character_id
		]
	)

	# -------------------------------------------------
	# 1. 備份原始 Stats
	# -------------------------------------------------

	var original_stats := {}
	for key in TEST_VALUES:
		original_stats[key] = character.stats.get_value(key)

	# -------------------------------------------------
	# 2. 設定實際遊戲角色的 Stats
	# -------------------------------------------------

	for key in TEST_VALUES:
		character.stats.set_value(
			key,
			float(TEST_VALUES[key])
		)

	print("[CharacterStateIntegrationTest] Stats 測試值已寫入 runtime。")

	# -------------------------------------------------
	# 2. 呼叫正式 persistence layer
	# -------------------------------------------------

	var persistence := DatabaseManager.get_node_or_null(
		"CharacterStatePersistence"
	)

	if persistence == null:
		_fail(
			"Persistence",
			"找不到 DatabaseManager/CharacterStatePersistence"
		)
		_restore_stats(character, original_stats, null)
		_finish()
		return

	if not _sync_now(persistence):
		_fail(
			"initial_sync",
			"寫入測試 Stats 時同步失敗"
		)
		_restore_stats(character, original_stats, persistence)
		_finish()
		return

	# -------------------------------------------------
	# 3. 驗證 npc record
	# -------------------------------------------------

	var npc_rows := DatabaseManager.select(
		"npc",
		"npc_id = '%s'" % _escape_sql(character.character_id),
		[
			"npc_id",
			"home_location_id",
			"decision_source",
			"model_name"
		]
	)

	if npc_rows.is_empty():
		_fail(
			"npc",
			"CharacterStatePersistence 沒有建立 npc record"
		)
	else:
		var npc_row: Dictionary = npc_rows[0]

		if str(npc_row.get("home_location_id", "")).is_empty():
			_fail(
				"npc.home_location_id",
				"home_location_id 是空值"
			)
		else:
			_pass("npc.home_location_id")

		if str(npc_row.get("decision_source", "")) != "local":
			_fail(
				"npc.decision_source",
				"不是 local"
			)
		else:
			_pass("npc.decision_source")

	# -------------------------------------------------
	# 4. SELECT npc_state
	# -------------------------------------------------

	var state_rows := DatabaseManager.select(
		"npc_state",
		"npc_id = '%s'" % _escape_sql(character.character_id),
		[
			"npc_id",
			"satiety",
			"hydration",
			"stamina",
			"wakefulness",
			"hygiene",
			"alcohol",
			"health",
			"injury"
		]
	)

	if state_rows.is_empty():
		_fail(
			"npc_state",
			"找不到 CharacterStatePersistence 寫入的 npc_state"
		)
		_restore_stats(character, original_stats, persistence)
		_finish()
		return

	var row: Dictionary = state_rows[0]

	# -------------------------------------------------
	# 5. 逐欄位比對 runtime → SQLite
	# -------------------------------------------------

	for key in TEST_VALUES:
		var expected := float(TEST_VALUES[key])
		var actual := float(row.get(key, -999.0))

		if is_equal_approx(expected, actual):
			_pass("npc_state.%s = %.1f" % [key, actual])
		else:
			_fail(
				"npc_state.%s" % key,
				"預期 %.1f，實際 %.1f" % [expected, actual]
			)

	# -------------------------------------------------
	# 6. 第二次修改 runtime，驗證 UPDATE 路徑
	# -------------------------------------------------

	character.stats.set_value("hydration", 33.0)
	character.stats.set_value("alcohol", 44.0)
	character.stats.set_value("injury", 21.0)

	if _sync_now(persistence):
		var updated_rows := DatabaseManager.select(
			"npc_state",
			"npc_id = '%s'" % _escape_sql(character.character_id),
			[
				"hydration",
				"alcohol",
				"injury"
			]
		)

		if updated_rows.is_empty():
			_fail(
				"npc_state.UPDATE",
				"第二次同步後找不到資料"
			)
		else:
			var updated: Dictionary = updated_rows[0]

			_check_value(
				"UPDATE hydration",
				33.0,
				float(updated.get("hydration", -999.0))
			)

			_check_value(
				"UPDATE alcohol",
				44.0,
				float(updated.get("alcohol", -999.0))
			)

			_check_value(
				"UPDATE injury",
				21.0,
				float(updated.get("injury", -999.0))
			)

	# -------------------------------------------------
	# 7. 報告 Inventory 狀態
	# -------------------------------------------------

	if character.inventory == null:
		print(
			"[INFO] Character 沒有 Inventory，"
			+ "因此本次無法做 runtime inventory 檢查。"
		)
	else:
		print(
			"[INFO] Inventory runtime 存在。"
			+ "CharacterStatePersistence 會寫入 npc_inventory，"
			+ "但本測試尚未涵蓋這條比對，故不將它判定為 PASS。"
		)

	# -------------------------------------------------
	# 8. 還原 Stats 並同步
	# -------------------------------------------------

	_restore_stats(character, original_stats, persistence)

	print("[CharacterStateIntegrationTest] Stats 已還原並同步。")

	# -------------------------------------------------
	# 9. 結果
	# -------------------------------------------------

	_finish()


func _restore_stats(
	character: Character,
	original_stats: Dictionary,
	persistence: Node
) -> void:

	for key in original_stats:
		character.stats.set_value(key, original_stats[key])

	if persistence != null:
		if not _sync_now(persistence):
			_fail(
				"restore_sync",
				"還原 Stats 後同步失敗，SQLite 可能仍保留測試值"
			)


func _sync_now(persistence: Node) -> bool:
	if not persistence.has_method("sync_now"):
		_fail(
			"sync_now",
			"CharacterStatePersistence 沒有 sync_now() 方法"
		)
		return false

	return persistence.sync_now()


func _find_test_character() -> Character:
	var characters := get_tree().get_nodes_in_group("characters")

	for node in characters:
		var character := node as Character

		if character != null:
			return character

	return null


func _check_value(
	label: String,
	expected: float,
	actual: float
) -> void:

	if is_equal_approx(expected, actual):
		_pass(
			"%s = %.1f"
			% [label, actual]
		)
	else:
		_fail(
			label,
			"預期 %.1f，實際 %.1f"
			% [expected, actual]
		)


func _pass(label: String) -> void:
	passed += 1
	print("[PASS] %s" % label)


func _fail(label: String, message: String) -> void:
	failed += 1
	push_error(
		"[FAIL] %s: %s"
		% [label, message]
	)


func _finish() -> void:
	print("")
	print("=====================================================")
	print("[CharacterStateIntegrationTest] RESULT")
	print("=====================================================")
	print("PASS: ", passed)
	print("FAIL: ", failed)

	if failed == 0:
		print(
			"[CharacterStateIntegrationTest] "
			+ "RUNTIME -> SQLite STATE PASSED"
		)
	else:
		push_error(
			"[CharacterStateIntegrationTest] "
			+ "%d test(s) failed."
			% failed
		)

	print("=====================================================")

	queue_free()


func _escape_sql(value: String) -> String:
	return value.replace("'", "''")
