@tool
class_name TestConversationEndFact
extends McpTestSuite

## issue #950：對話因玩家走遠／被打斷而中斷時，exit_conversation() 記給 AI 的
## 事實句不能一律套「你跟 X 講完話了」——玩家按 E 搭話後、在對方還沒開口
## （turn 0 等 LLM）時就走開，一句話都沒交換過，記「講完話了」是假事實。
##
## 直接驗 Agent._conversation_end_fact() 這個純函式——選對措辭是 #950 的核心。
## 其餘 exit_conversation() 的場景樹／autoload 操作在 test_run 這個沒有活場景樹
## 的環境測不到（見 test_speech_heard.gd 同一種取捨）。

func suite_name() -> String:
	return "conversation_end_fact"


func test_normal_end_still_says_finished_talking() -> void:
	var fact := Agent._conversation_end_fact(Conversation.REASON_ENDED_BY_SPEAKER, "阿吉", true, false)
	assert_eq(fact, "你跟 阿吉 講完話了", "正常講完仍記『講完話了』")


func test_listener_end_still_says_finished_talking() -> void:
	var fact := Agent._conversation_end_fact(Conversation.REASON_ENDED_BY_LISTENER, "阿吉", true, false)
	assert_eq(fact, "你跟 阿吉 講完話了", "聽者主動收尾也算講完話")


func test_too_far_before_any_line_is_not_finished_talking() -> void:
	var fact := Agent._conversation_end_fact(Conversation.REASON_TOO_FAR, "阿吉", false, true)
	assert_eq(fact, "你和 阿吉 的對話還沒開始就中斷了",
		"turn 0 對方就走開、一句話都沒交換，不能記成講完話")


func test_too_far_mid_conversation() -> void:
	var fact := Agent._conversation_end_fact(Conversation.REASON_TOO_FAR, "阿吉", true, true)
	assert_eq(fact, "你和 阿吉 的對話中途中斷了", "聊到一半走遠記『中途中斷』")


func test_interrupted_before_any_line() -> void:
	var fact := Agent._conversation_end_fact(Conversation.REASON_INTERRUPTED, "阿吉", false, false)
	assert_eq(fact, "你和 阿吉 的對話還沒開始就中斷了", "被打斷且未交談，記『還沒開始就中斷』")


func test_ignored_initiator_sees_no_response() -> void:
	var fact := Agent._conversation_end_fact(Conversation.REASON_IGNORED, "阿吉", false, true)
	assert_eq(fact, "阿吉 不理你的搭話，沒有回應", "發起搭話的一方看到對方沒回應")


func test_ignored_target_sees_own_choice() -> void:
	var fact := Agent._conversation_end_fact(Conversation.REASON_IGNORED, "阿吉", false, false)
	assert_eq(fact, "你不理會 阿吉 的搭話", "被搭話的一方看到自己選擇不理會")
