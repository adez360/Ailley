@tool
class_name TestThinkingIndicator
extends McpTestSuite

## 驗證「思考中」指示的收斂點（issue #949 B 類，R1 review nit 5）。
##
## 跟 test_speech_heard.gd 同一種做法：在 test_run 沒有活場景樹的 @tool 環境
## 用裸實例——thinking_indicator／bubble 這兩個 @onready 在場景外不會解析，
## 直接塞 ThinkingIndicator.new()／最小替身進去，只驗證收點本身的行為
## （visible 的收斂）。出現位置與動畫的實際觀感仍要實機確認。
##
## say() 的 broadcast=true 路徑會走 _broadcast_speech() →
## get_tree().get_nodes_in_group(...)，場景外測不到（見 note/技術/自動化測試.md
## 跟 test_speech_heard.gd 的說明），這裡只測 broadcast=false 的系統反應分支：
## 決策等待中不收指示器、非決策等待期照舊收（R1 review minor 的兩個方向）。

func suite_name() -> String:
	return "thinking_indicator"


# bubble 在 character.gd 裡型別是 Node2D、say() 對它走動態呼叫——用最小替身
# 撐住介面讓 say() 能走到指示收點（真 Bubble 需要 Label 子節點，裸實例做不出來）
class FakeBubble extends Node2D:
	func say(_message: String) -> void:
		pass


# 裸實例沒有場景樹，@onready 不會跑，收點的 null guard 會直接跳過——
# 手動塞節點，模擬場景掛好 ThinkingIndicator 的狀態
func _attach_indicator(character: Character) -> ThinkingIndicator:
	var indicator := track(ThinkingIndicator.new()) as ThinkingIndicator
	character.thinking_indicator = indicator
	character.bubble = FakeBubble.new()
	return indicator


func test_exit_conversation_hides_indicator() -> void:
	var character := track(Character.new()) as Character
	var indicator := _attach_indicator(character)
	indicator.show_indicator()
	assert_true(indicator.visible, "show_indicator() 之後指示應該是可見的")

	character.exit_conversation()

	assert_false(indicator.visible, "exit_conversation() 要收掉指示（對話任何原因結束的唯一收斂點）")


func test_force_interrupt_hides_indicator() -> void:
	var character := track(Character.new()) as Character
	var indicator := _attach_indicator(character)
	indicator.show_indicator()

	character.force_interrupt()

	assert_false(indicator.visible, "force_interrupt()（死亡／入眠／被攻擊）要立刻收掉指示，不等安全上限")


func test_system_reaction_keeps_indicator_while_decision_in_flight() -> void:
	var agent := track(Agent.new()) as Agent
	var indicator := _attach_indicator(agent)
	agent._awaiting_decision = true
	indicator.show_indicator()

	agent.say(L10n.t("DLG_SURPRISE"), false, false)

	assert_true(indicator.visible, "決策等待中的系統反應泡泡不該收掉指示——LLM 決策還在飛")


func test_system_reaction_hides_indicator_when_not_awaiting_decision() -> void:
	var agent := track(Agent.new()) as Agent
	var indicator := _attach_indicator(agent)
	indicator.show_indicator()

	agent.say(L10n.t("DLG_NOISE_ALERT"), false, false)

	assert_false(indicator.visible, "非決策等待期的系統反應泡泡照舊收掉指示（行為不變）")


func test_base_character_is_never_awaiting_decision() -> void:
	var character := track(Character.new()) as Character
	var agent := track(Agent.new()) as Agent

	assert_false(character._is_awaiting_decision(), "基底沒有決策迴圈，恆 false")
	assert_false(agent._is_awaiting_decision(), "Agent 沒有在飛的決策時是 false")

	agent._awaiting_decision = true
	assert_true(agent._is_awaiting_decision(), "Agent 有決策在飛時要回報 true（say() 的收點靠它擋系統反應泡泡）")
