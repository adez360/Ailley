@tool
class_name TestSpeechHeard
extends McpTestSuite

## 驗證「聽到聲音／聽到說話」的感測反應邏輯（issue #669／#949）。
##
## character.gd::say()／make_noise() 怎麼把訊號廣播給 3 格範圍內每個角色，
## 依賴 get_tree().get_nodes_in_group("characters")，在 test_run 這個沒有活場景樹的
## @tool 環境測不到（見 note/技術/自動化測試.md）——這裡只驗證收到訊號之後
## agent.gd::_on_speech_heard()／_on_noise_heard() 本身的反應邏輯。
##
## llm_decision_enabled=true 那個分支會 await _request_next_decision()，會碰
## AIService／GameClock，不在這個環境的涵蓋範圍內（同 test_persuade_pending.gd）——
## 這裡測 is_dead／is_in_conversation 的提前 return，以及排程模式
## （llm_decision_enabled=false，預設值）不冒寫死氣泡、改記進 _daily_events
## 的行為（issue #949：引擎不替角色決定反應，事件仍留著等下次反思）。

func suite_name() -> String:
	return "speech_heard"


func test_dead_agent_ignores_overheard_speech() -> void:
	var target := track(Agent.new()) as Agent
	target.llm_decision_enabled = true
	target.is_dead = true
	var source := track(Character.new()) as Character
	source.character_name = "阿吉"

	target._on_speech_heard(source, "哈囉")

	assert_true(target._pending_reaction_lines.is_empty(), "死亡角色不該把聽到的話排進反應事實句佇列")
	assert_true(target._daily_events.is_empty(), "死亡角色不該把聽到的話記進 _daily_events")


func test_agent_in_conversation_ignores_overheard_speech() -> void:
	var target := track(Agent.new()) as Agent
	target.llm_decision_enabled = true
	target.enter_conversation(track(Node.new()) as Node)
	var source := track(Character.new()) as Character
	source.character_name = "阿吉"

	target._on_speech_heard(source, "哈囉")

	assert_true(target._pending_reaction_lines.is_empty(), "對話中的角色不該被旁聽到的話打斷")
	assert_true(target._daily_events.is_empty(), "對話中的角色不該把旁聽到的話記進 _daily_events")


func test_schedule_mode_records_overheard_speech_as_daily_event() -> void:
	# 排程模式（llm_decision_enabled 預設 false）：issue #949 之前是冒一句寫死的
	# 「!?」、什麼都不留；現在不冒氣泡，改把客觀事實記進 _daily_events，等之後
	# （若 AI 開啟）的睡前反思一併處理
	var target := track(Agent.new()) as Agent
	var source := track(Character.new()) as Character
	source.character_name = "阿吉"

	target._on_speech_heard(source, "今天天氣不錯")

	assert_true(target._pending_reaction_lines.is_empty(), "排程模式不即時觸發任何反應")
	assert_eq(target._daily_events.size(), 1, "排程模式聽到說話應記一筆 _daily_events，不是整個丟掉")
	assert_contains(target._daily_events[0]["content"], "阿吉", "事實句要帶上說話者")
	assert_contains(target._daily_events[0]["content"], "今天天氣不錯", "事實句要帶上聽到的內容")


func test_noise_heard_records_daily_event() -> void:
	# _on_noise_heard 不分模式都記 _daily_events（issue #949）——noise（make_noise／
	# shout）本來就低頻，不會洗版
	var target := track(Agent.new()) as Agent
	var source := track(Character.new()) as Character
	source.character_name = "阿吉"

	target._on_noise_heard(source)

	assert_eq(target._daily_events.size(), 1, "聽到聲音應記一筆 _daily_events")
	assert_contains(target._daily_events[0]["content"], "聲音", "事實句是中性的「聽到聲音」陳述")


func test_dead_agent_ignores_noise() -> void:
	var target := track(Agent.new()) as Agent
	target.is_dead = true
	var source := track(Character.new()) as Character

	target._on_noise_heard(source)

	assert_true(target._daily_events.is_empty(), "死亡角色不該記聽到聲音")
