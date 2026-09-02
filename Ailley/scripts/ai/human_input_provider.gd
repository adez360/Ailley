class_name HumanInputProvider
extends DecisionProvider

## 《12》§3.4 HumanInput：真人接管決策位（《10》§2.3，issue #156）。不發送任何
## 網路請求：plan 決策（envelope 的 response_format 帶 tasks）跳出
## HumanDecisionPanel 讓真人選動作，輸出走跟 LLM 來源同一條 validate_tasks()
## 驗證路徑；其餘請求類型（對話台詞、反思、檢查點、遺言……）本期沒有對應的
## 真人表單，直接回 no_response 讓呼叫端走既有的失敗 fallback——不假裝有輸入。
##
## 逾時（《99》P-22 #2 定案，數值權威定義在那裡，實測後可調）：
## - 短逾時 30 秒：面板 UI 提醒／催促（顯示由 HumanDecisionPanel 自行處理）
## - 中逾時 120 秒：視同真人離線，decide() 回失敗，agent.gd 的既有失敗分支
##   走 enter_offline_sleep()（《10》§6.4 入眠流程）——本類不自己碰入眠狀態，
##   觸發點與 LLM 來源共用同一個（agent.gd::_request_next_decision() 的失敗分支）

const SHORT_TIMEOUT_SEC := 30.0
const MID_TIMEOUT_SEC := 120.0

## 看門狗預算：中逾時再加緩衝。負值是「自管逾時」的標記（見
## DecisionProvider.watchdog_timeout_sec()），絕對值才是 agent.gd 看門狗
## 實際會等的秒數——面板自己會在中逾時收掉，這裡只是保底
const WATCHDOG_BUDGET_SEC := -(MID_TIMEOUT_SEC + 15.0)

## 持有建立自己的那隻 Agent：面板要掛進場景樹、target 下拉要問視野、
## 等待期間角色死亡要能提前收面板。Agent 是 Node、本類是 RefCounted，
## 引用隨 Agent 一起釋放，不會留懸掛節點
var _agent: Agent


func _init(agent: Agent) -> void:
	_agent = agent
	_provider_name = "human"


func decide(envelope: Dictionary, _requester_id: String, _policy: AIService.Policy, _context: DecisionContext = DecisionContext.new()) -> Dictionary:
	# 用 schema 判別請求類型（《12》§2.1「契約以 JSON Schema 為唯一真相來源」）：
	# 帶 tasks 的才是 plan 決策，其他類型不提供真人表單
	var schema: Dictionary = envelope.get("response_format", {})
	if not (schema.get("properties", {}) as Dictionary).has("tasks"):
		return {"ok": false, "data": {}, "error": "no_response"}

	if _agent == null or not is_instance_valid(_agent):
		return {"ok": false, "data": {}, "error": "no_response"}

	# target 下拉的名單跟 agent.gd::_request_next_decision() 給 validator 的
	# 白名單同一套來源：在場角色來自 vision，遺體來自 characters group 掃描
	# （bury 的 target 不在 context.visible 裡，見 ai_schema.gd::_is_valid_target()）。
	# 等待期間視野可能變動，差異由 validate_tasks() 那關兜底，這裡只負責
	# 「下拉選單物理上選不到白名單外的值」（《12》§3.4 表單欄位由 schema 生成）
	var visible_names := PackedStringArray()
	if _agent.vision != null:
		for character in _agent.vision.get_visible_characters():
			visible_names.append(character.character_name)
	var corpse_names := PackedStringArray()
	for node in _agent.get_tree().get_nodes_in_group("characters"):
		var corpse := node as Character
		if corpse != null and corpse.is_dead and not corpse.is_buried:
			corpse_names.append(corpse.character_name)

	var action_enum: Array = schema.get("properties", {}).get("tasks", {}).get("items", {}).get("properties", {}).get("action", {}).get("enum", AISchema.ALLOWED_ACTIONS)
	var panel := HumanDecisionPanel.new(
		_agent.character_name, action_enum, visible_names, corpse_names
	)
	_agent.get_tree().root.add_child(panel)

	# 輪詢等待面板收尾（跟 agent.gd 看門狗同一個理由：GDScript 沒有 race
	# 原語，訊號競賽不如輪詢）。逾時計時在面板自己的 _process()；這裡每
	# 0.5 秒確認一次面板還活著（場景轉換可能把它連根拔掉）跟角色還活著，
	# 變了就當中逾時處理，不留永遠不 resolve 的 await（issue #860 同款顧慮）
	while is_instance_valid(panel) and not panel.settled:
		if _agent == null or not is_instance_valid(_agent) or _agent.is_dead:
			panel.cancel()
			break
		await _agent.get_tree().create_timer(0.5).timeout

	var result: Dictionary
	if is_instance_valid(panel) and panel.settled and panel.decided_ok:
		result = {"ok": true, "data": panel.decision_data, "error": ""}
	else:
		result = {"ok": false, "data": {}, "error": "no_response"}
	if is_instance_valid(panel):
		panel.queue_free()
	return result


## 表單欄位是下拉／滑桿／帶範圍的數字，真人物理上填不出驗證會拒絕的值
## （《12》§3.4 L1 由表單欄位限制保證），沒有「重試一次」的語意——出錯代表
## 表單跟 schema 兜不起來，是更根本的問題，比照 LocalLLMProvider 回 0
func max_validation_retries() -> int:
	return 0


## 真人不在 AIService 的網路就緒探測範圍裡，永遠視為就緒（agent.gd::
## get_provider_readiness() 與 game_manager／main_scene 的開關判定都吃這個）
func always_ready() -> bool:
	return true


## 逾時由本類與面板自管（P-22 #2），agent.gd 看門狗只吃保底預算
func watchdog_timeout_sec() -> float:
	return WATCHDOG_BUDGET_SEC
