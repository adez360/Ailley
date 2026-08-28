@tool
class_name TestSpeechHeard
extends McpTestSuite

## 驗證「一般說話能被 NPC 聽到」的反應邏輯（issue #669）。
##
## character.gd::say() 怎麼把 speech_heard 廣播給 3 格範圍內每個角色（_broadcast_speech()）
## 依賴 get_tree().get_nodes_in_group("characters")，在 test_run 這個沒有活場景樹的
## @tool 環境測不到（見 note/技術/自動化測試.md），這裡跟 test_shout_reaches_player.gd
## 同一種做法——不重測那段，只驗證收到訊號之後 agent.gd::_on_speech_heard() 本身的反應邏輯。
##
## llm_decision_enabled=true 那個分支會 await _request_next_decision()，會碰
## AIService／GameClock，同樣不在這個環境的涵蓋範圍內（同 test_persuade_pending.gd
## 的說明）——這裡只測 is_dead／is_in_conversation 的提前 return（在碰到 await 之前
## 就結束，呼叫端不需要真的 await）跟排程模式（llm_decision_enabled=false，預設值）
## 刻意不冒 !? 的行為。

func suite_name() -> String:
	return "speech_heard"


func test_dead_agent_does_not_queue_reaction() -> void:
	var target := track(Agent.new()) as Agent
	target.llm_decision_enabled = true
	target.is_dead = true
	var source := track(Character.new()) as Character
	source.character_name = "阿吉"

	target._on_speech_heard(source, "哈囉")

	assert_true(target._pending_reaction_lines.is_empty(), "死亡角色不該把聽到的話排進反應事實句佇列")


func test_agent_in_conversation_does_not_queue_reaction() -> void:
	var target := track(Agent.new()) as Agent
	target.llm_decision_enabled = true
	target.enter_conversation(track(Node.new()) as Node)
	var source := track(Character.new()) as Character
	source.character_name = "阿吉"

	target._on_speech_heard(source, "哈囉")

	assert_true(target._pending_reaction_lines.is_empty(), "對話中的角色不該被旁聽到的話打斷、排進反應事實句佇列")


func test_schedule_mode_does_not_queue_reaction() -> void:
	# llm_decision_enabled 預設 false（排程模式）。跟 _on_noise_heard() 的排程模式
	# fallback 不同，一般說話刻意不冒 !?——見 agent.gd::_on_speech_heard() 的說明
	var target := track(Agent.new()) as Agent
	var source := track(Character.new()) as Character
	source.character_name = "阿吉"

	target._on_speech_heard(source, "哈囉")

	assert_true(target._pending_reaction_lines.is_empty(), "排程模式不該有事實句被排進佇列（也不冒 !?）")
