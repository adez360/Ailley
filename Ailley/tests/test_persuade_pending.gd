@tool
class_name TestPersuadePending
extends McpTestSuite

## 驗證 Agent 的說服待回應記錄機制（issue #227，社交類行動的一環）。
## `try_record_pending_persuade()` 本身是純狀態機（只碰 `_pending_persuade`
## 這個 Dictionary 欄位），不碰場景樹或 GameClock，可以直接對一個沒掛進
## 場景樹的 Agent 呼叫（同 test_bury.gd 的寫法）。
##
## 送達後注入哪句事實句（`_fact_lines_summary()`）依賴 `_now_minutes()`
## → GameClock，在 test_run 這個 @tool 環境呼叫會炸（見
## note/技術/自動化測試.md），不在本套件涵蓋範圍內。

func suite_name() -> String:
	return "persuade_pending"


func test_first_attempt_is_recorded() -> void:
	var target := track(Agent.new()) as Agent

	var accepted := target.try_record_pending_persuade("阿吉", "aji", "一起去吃飯", {})

	assert_true(accepted, "沒有既有待回應記錄時應接受")
	assert_eq(target._pending_persuade.get("persuader", ""), "阿吉", "應記下發起者名稱")
	assert_eq(target._pending_persuade.get("persuader_id", ""), "aji", "應記下發起者 id")
	assert_eq(target._pending_persuade.get("reason", ""), "一起去吃飯", "應記下理由")
	assert_false(target._pending_persuade.has("proposed_task"), "沒提供 proposed_task 時不該多出這個 key")


func test_second_attempt_rejected_while_pending() -> void:
	var target := track(Agent.new()) as Agent
	target.try_record_pending_persuade("阿吉", "aji", "一起去吃飯", {})

	var accepted := target.try_record_pending_persuade("小滿", "xiaoman", "去打獵", {})

	assert_false(accepted, "已有待回應記錄時，第二個說服者應被拒絕")
	assert_eq(target._pending_persuade.get("persuader", ""), "阿吉", "既有記錄不該被新的嘗試覆蓋")


func test_proposed_task_included_when_given() -> void:
	var target := track(Agent.new()) as Agent
	var proposed := {"action": "move_to", "params": {"place": "tavern"}}

	target.try_record_pending_persuade("阿吉", "aji", "去餐酒館坐坐", proposed)

	assert_eq(target._pending_persuade.get("proposed_task", {}), proposed, "有提供 proposed_task 時應原樣存入")


func test_accepted_again_after_pending_cleared() -> void:
	var target := track(Agent.new()) as Agent
	var first_accepted := target.try_record_pending_persuade("阿吉", "aji", "一起去吃飯", {})

	# 用真正清空 _pending_persuade 的生產路徑 _resolve_pending_persuade()，
	# 不是直接指派——這樣測試才驗證得到「production resolver 真的有清掉」，
	# 不會在 resolver 停止清空時還誤判通過。persuaded=false 避免碰到
	# _now_minutes()／GameClock（見檔頭說明的涵蓋範圍限制）
	target._resolve_pending_persuade({"persuaded": false})

	var accepted := target.try_record_pending_persuade("小滿", "xiaoman", "去打獵", {})

	assert_true(first_accepted, "第一次嘗試應被接受")
	assert_true(accepted, "清空舊記錄後應能接受新的說服嘗試")
