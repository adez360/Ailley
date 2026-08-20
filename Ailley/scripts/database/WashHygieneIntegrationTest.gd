extends Node

## =====================================================
## WashHygieneIntegrationTest
##
## 用途：
##   驗證 wash 動作透過 Agent._apply_action_recovery() 正確回復 hygiene（#241）。
##
## 跟 CharacterStateIntegrationTest／InventoryPurchaseIntegrationTest 同一種
## 「抓場景裡真實存在的角色、寫入明確測試值、呼叫正式流程、比對結果」慣例，
## 不建立假的 Agent、不 mock Stats。
##
## 驗證項目：
##   current_state == "wash" 時呼叫 _apply_action_recovery()，
##   hygiene 是否精確增加 Agent.ACTION_RECOVERY["wash"]["amount"]
## =====================================================


var passed := 0
var failed := 0


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	print("")
	print("=====================================================")
	print("[WashHygieneIntegrationTest] START")
	print("=====================================================")

	var agent := _find_test_agent()

	if agent == null:
		_fail(
			"Agent",
			"場景中找不到 Agent。請在正常遊戲場景執行本測試，不要在空白測試場景執行。"
		)
		_finish()
		return

	if agent.stats == null:
		_fail("Agent.stats", "Agent 沒有 Stats。")
		_finish()
		return

	print(
		"[WashHygieneIntegrationTest] Agent = %s | id = %s"
		% [agent.character_name, agent.character_id]
	)

	# -------------------------------------------------
	# 1. 備份原始狀態
	# -------------------------------------------------

	var original_hygiene := agent.stats.get_value("hygiene")
	var original_state := agent.current_state
	var was_moving := agent.is_moving()

	if was_moving:
		agent.stop_moving()

	# -------------------------------------------------
	# 2. 設定測試狀態：hygiene 壓低、current_state 設成 wash
	# -------------------------------------------------

	agent.stats.set_value("hygiene", 20.0)
	agent.current_state = "wash"

	# -------------------------------------------------
	# 3. 呼叫正式流程（_on_time_changed() 每遊戲分鐘會呼叫的同一個方法）
	# -------------------------------------------------

	agent._apply_action_recovery()

	# -------------------------------------------------
	# 4. 比對：hygiene 是否精確增加 ACTION_RECOVERY["wash"] 陣列中 hygiene 項的 amount
	# -------------------------------------------------

	var recovery_list: Array = Agent.ACTION_RECOVERY.get("wash", [])

	if recovery_list.is_empty():
		_fail(
			"ACTION_RECOVERY[\"wash\"]",
			"表裡沒有 wash 這個鍵——回復邏輯還沒接上"
		)
	else:
		# 從 wash 的回復陣列中找 hygiene 項
		var hygiene_recovery: Dictionary = {}
		for recovery in recovery_list:
			if recovery.get("stat") == "hygiene":
				hygiene_recovery = recovery
				break

		if hygiene_recovery.is_empty():
			_fail(
				"ACTION_RECOVERY[\"wash\"][hygiene]",
				"wash 的回復陣列沒有 hygiene 項"
			)
		else:
			var expected := 20.0 + float(hygiene_recovery["amount"])
			var actual := agent.stats.get_value("hygiene")

			if is_equal_approx(expected, actual):
				_pass("wash 後 hygiene = %.1f（預期 %.1f）" % [actual, expected])
			else:
				_fail(
					"wash hygiene",
					"預期 %.1f，實際 %.1f" % [expected, actual]
				)

		if recovery.get("stat", "") != "hygiene":
			_fail(
				"ACTION_RECOVERY[\"wash\"].stat",
				"目標欄位是 %s，不是 hygiene" % recovery.get("stat", "")
			)
		else:
			_pass("ACTION_RECOVERY[\"wash\"].stat == hygiene")

	# -------------------------------------------------
	# 5. 還原狀態
	# -------------------------------------------------

	agent.stats.set_value("hygiene", original_hygiene)
	agent.current_state = original_state

	# stop_moving() 會清空 _path，不是單純暫停——原本正在走的 Agent
	# 測試前後要「狀態已還原」，得靠 move_to(last_move_target) 重新
	# 算一條路徑走過去，不能只是把旗標翻回去，也沒有原始路徑可以恢復
	if was_moving:
		agent.move_to(agent.last_move_target)

	print("[WashHygieneIntegrationTest] 狀態已還原。")

	_finish()


func _find_test_agent() -> Agent:
	for node in get_tree().get_nodes_in_group("agents"):
		var agent := node as Agent

		if agent != null:
			return agent

	return null


func _pass(label: String) -> void:
	passed += 1
	print("[PASS] %s" % label)


func _fail(label: String, message: String) -> void:
	failed += 1
	push_error("[FAIL] %s: %s" % [label, message])


func _finish() -> void:
	print("")
	print("=====================================================")
	print("[WashHygieneIntegrationTest] RESULT")
	print("=====================================================")
	print("PASS: ", passed)
	print("FAIL: ", failed)

	if failed == 0:
		print("[WashHygieneIntegrationTest] wash -> hygiene PASSED")
	else:
		push_error(
			"[WashHygieneIntegrationTest] %d test(s) failed." % failed
		)

	print("=====================================================")

	queue_free()
