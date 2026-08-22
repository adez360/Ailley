@tool
class_name TestAIRequestPriority
extends McpTestSuite

## 測試 Issue #492：AIService 的請求佇列依 Policy 出隊——玩家等在畫面前的
## CONVERSATION 先出隊，同一種 Policy 之內維持進場順序

const AI_SERVICE := preload("res://scripts/ai/ai_service.gd")


## _next_job_index() 只讀 job.policy，用假工作就夠，不必湊出真的 _Job
## 需要的 envelope 與 AIConfig.Provider
class _FakeJob extends RefCounted:
	var policy: int
	var tag: String

	func _init(p: int, t: String) -> void:
		policy = p
		tag = t


func suite_name() -> String:
	return "ai_request_priority"


func test_conversation_dequeues_before_scheduled() -> void:
	var order := _dequeue_order([
		[AI_SERVICE.Policy.SCHEDULED, "s1"],
		[AI_SERVICE.Policy.SCHEDULED, "s2"],
		[AI_SERVICE.Policy.CONVERSATION, "c1"],
	])
	assert_eq(order, ["c1", "s1", "s2"], "對話應搶在行程請求之前")


func test_same_policy_keeps_arrival_order() -> void:
	var order := _dequeue_order([
		[AI_SERVICE.Policy.CONVERSATION, "c1"],
		[AI_SERVICE.Policy.CONVERSATION, "c2"],
		[AI_SERVICE.Policy.SCHEDULED, "s1"],
		[AI_SERVICE.Policy.SCHEDULED, "s2"],
	])
	assert_eq(order, ["c1", "c2", "s1", "s2"], "同優先權之內應維持先進先出")


func test_scheduled_retry_does_not_jump_conversation() -> void:
	# 重試走 _queue.push_front()（見 _on_request_completed()）：那只是排到
	# 同優先權的最前面，不該讓 SCHEDULED 搶到還在等的 CONVERSATION 前面
	var svc := AI_SERVICE.new()
	track(svc)
	svc._queue.append(_FakeJob.new(AI_SERVICE.Policy.SCHEDULED, "s1"))
	svc._queue.append(_FakeJob.new(AI_SERVICE.Policy.CONVERSATION, "c1"))
	svc._queue.push_front(_FakeJob.new(AI_SERVICE.Policy.SCHEDULED, "retry"))

	assert_eq(_drain(svc), ["c1", "retry", "s1"], "重試只在行程請求之內插隊")


func _dequeue_order(specs: Array) -> Array:
	var svc := AI_SERVICE.new()
	track(svc)
	for spec in specs:
		svc._queue.append(_FakeJob.new(spec[0], spec[1]))
	return _drain(svc)


func _drain(svc: Node) -> Array:
	var order: Array = []
	while not svc._queue.is_empty():
		order.append(svc._queue.pop_at(svc._next_job_index()).tag)
	return order
