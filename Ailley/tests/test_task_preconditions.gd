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


func test_relations_condition_with_explicit_target() -> void:
	# 沒呼叫過 note_meeting()／add_trust()，"bob" 吃 DEFAULT_RECORD（trust 20）
	var task := {"preconditions": [
		{"field": "relations.trust", "target": "bob", "op": ">=", "value": 10.0},
	]}
	assert_true(_agent._preconditions_met(task), "陌生人預設 trust 20 >= 10 應成立")


func test_relations_condition_falls_back_to_params_target() -> void:
	# 沒填 target 時退回 task.params.target——卡「對現在這個任務對象」最常見的用法
	var task := {
		"params": {"target": "bob"},
		"preconditions": [
			{"field": "relations.met_count", "op": ">=", "value": 1},
		],
	}
	assert_false(_agent._preconditions_met(task), "從沒 note_meeting() 過，met_count 0 >= 1 不應成立")

	_agent.relationships.note_meeting("bob")
	assert_true(_agent._preconditions_met(task), "note_meeting() 一次後 met_count 1 >= 1 應成立")


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
