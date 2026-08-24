@tool
class_name TestTaskPreconditions
extends McpTestSuite

## 測試 Issue #477：Task.preconditions 求值——_preconditions_met() 是
## _reevaluate_once() 候選迴圈用的濾網，這裡直接呼叫它驗證，不跑整套仲裁。

var _agent: Agent


func suite_name() -> String:
	return "task_preconditions"


func setup() -> void:
	_agent = track(Agent.new())
	var stats := track(Stats.new())
	var relationships := track(Relationships.new())
	_agent.stats = stats
	_agent.relationships = relationships


func test_empty_preconditions_always_met() -> void:
	# schedule／llm 建構的任務目前一律填 []，這是最常見的形狀，必須恆為 true
	var task := {"preconditions": []}
	assert_true(_agent._preconditions_met(task), "空陣列應視為前提成立")


func test_stats_condition_met() -> void:
	_agent.stats.values["satiety"] = 50.0
	var task := {"preconditions": [
		{"field": "stats.satiety", "op": ">=", "value": 20.0},
	]}
	assert_true(_agent._preconditions_met(task), "satiety 50 >= 20 應成立")


func test_stats_condition_not_met() -> void:
	_agent.stats.values["satiety"] = 50.0
	var task := {"preconditions": [
		{"field": "stats.satiety", "op": ">=", "value": 80.0},
	]}
	assert_false(_agent._preconditions_met(task), "satiety 50 >= 80 不應成立")


# relations.* 命名空間刻意不支援（2026-08-24 拿掉，見全專案盤點的原則二
# 審查）：允許用 trust／met_count 當 precondition，等於引擎在 AI 看到任務
# 之前就依信任度濾掉候選，跟《07》§5「社會性限制不過濾，AI 能選、由引擎
# 判定失敗並給理由」的既有方向相反。改成跟其他不認得的命名空間一樣
# fail-closed，不特別處理
func test_relations_namespace_fails_closed() -> void:
	var task := {"preconditions": [
		{"field": "relations.trust", "target": "bob", "op": ">=", "value": 10.0},
	]}
	assert_false(_agent._preconditions_met(task), "relations.* 不是支援的命名空間，應 fail-closed")


func test_unknown_stat_key_fails_closed() -> void:
	# 錯字／不存在的 key 要視為不成立，不能靜默當成「數值 0」剛好卡過條件
	var task := {"preconditions": [
		{"field": "stats.no_such_stat", "op": ">=", "value": 0.0},
	]}
	assert_false(_agent._preconditions_met(task), "不存在的 stats key 應 fail-closed")


func test_unknown_namespace_fails_closed() -> void:
	var task := {"preconditions": [
		{"field": "money.amount", "op": ">=", "value": 10.0},
	]}
	assert_false(_agent._preconditions_met(task), "不認得的命名空間應 fail-closed")


func test_all_conditions_must_hold() -> void:
	_agent.stats.values["satiety"] = 50.0
	var task := {"preconditions": [
		{"field": "stats.satiety", "op": ">=", "value": 20.0},
		{"field": "stats.satiety", "op": ">=", "value": 80.0},
	]}
	assert_false(_agent._preconditions_met(task), "AND 語意：其中一筆不成立整體就不成立")


func test_non_array_preconditions_fails_closed() -> void:
	# CodeRabbit review（PR #530）：preconditions 本身型別不對（不是 Array）
	# 一樣要 fail-closed，不能讓 for-in 迭代到非預期的東西
	var task := {"preconditions": {"field": "stats.satiety", "op": ">=", "value": 20.0}}
	assert_false(_agent._preconditions_met(task), "preconditions 不是 Array 應 fail-closed")


func test_non_numeric_value_fails_closed() -> void:
	# CodeRabbit review（PR #530）：value 缺欄位或型別不對（例如字串）不能直接
	# 拿去跟數字比較——_compare_precondition() 對不相容型別的 >=/<=/>/< 會直接
	# 丟 runtime error，不是安全地回傳 false，這裡要先擋下來
	_agent.stats.values["satiety"] = 50.0
	var missing_value := {"preconditions": [
		{"field": "stats.satiety", "op": ">="},
	]}
	assert_false(_agent._preconditions_met(missing_value), "缺 value 應 fail-closed")

	var string_value := {"preconditions": [
		{"field": "stats.satiety", "op": ">=", "value": "high"},
	]}
	assert_false(_agent._preconditions_met(string_value), "value 是字串應 fail-closed")


func test_non_string_field_fails_closed() -> void:
	# CodeRabbit review（PR #530）：field 是數字這類非字串值時，
	# `var field: String = cond.get("field", "")` 的型別化指派會直接丟
	# runtime error 中止 _reevaluate_once()，不是安全地回傳 false——
	# 這裡要在指派前先擋下來
	var task := {"preconditions": [
		{"field": 5, "op": ">=", "value": 20.0},
	]}
	assert_false(_agent._preconditions_met(task), "field 不是字串應 fail-closed")


func test_non_string_op_fails_closed() -> void:
	# CodeRabbit review（PR #530）：op 是數字這類非字串值時，
	# _compare_precondition() 的 op 參數型別化成 String，非字串 Variant 傳
	# 進去會在呼叫當下直接丟 runtime error，不是安全地回傳 false——
	# 跟 field 那則同一種型別漏洞，一樣要在呼叫前擋下來
	_agent.stats.values["satiety"] = 50.0
	var task := {"preconditions": [
		{"field": "stats.satiety", "op": 5, "value": 20.0},
	]}
	assert_false(_agent._preconditions_met(task), "op 不是字串應 fail-closed")


func test_current_task_treated_as_invalid_when_preconditions_become_false() -> void:
	# CodeRabbit review（PR #530）：preconditions 不只濾候選，_current_task 本身
	# 執行中途前提轉為不成立時，也要跟過期／出窗同一組條件，讓 _consider_switch()
	# 不再用「還沒過期、還在窗內」的承諾保護擋住換任務
	_agent.stats.values["satiety"] = 50.0
	var current_task := {
		"id": "current",
		"action": "idle",
		"priority": 10.0,
		"window": null,
		"expires_at": 0,
		"source": "llm",
		"preconditions": [{"field": "stats.satiety", "op": "<", "value": 80.0}],
	}
	_agent._current_task = current_task
	_agent._current_task_started_at = 0

	var fallback_task := {
		"id": "fallback",
		"action": "idle",
		"priority": 1.0,
		"window": null,
		"expires_at": 0,
		"source": "schedule",
		"preconditions": [],
	}

	_agent.stats.values["satiety"] = 90.0  # current 的前提從成立變成不成立（50 < 80 → 90 < 80 為 false）
	_agent._consider_switch(fallback_task, 1.0, "12:00", 720)

	assert_eq(_agent._current_task.get("id", ""), "fallback",
			"目前任務前提失效後，優先度較低的候選也應該能換上")
