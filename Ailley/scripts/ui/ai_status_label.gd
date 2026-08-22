extends Label

## 開場 AI 決策狀態的常駐指示（#357）：純排程的村莊跟真的在跑決策的村莊
## 從畫面上很像（都會走路、都會在涼亭碰面），沒有這個指示的話要盯很久
## 才會發現兩者其實不一樣。main_scene.gd::_apply_startup_ai_state() 開場
## 套用結果後呼叫 set_status() 寫一次，之後不會再變（provider 就緒狀態
## 只在開場探測一次，不做背景輪詢，見 AIService.get_readiness() 的說明）。
##
## 這是開發期介面，正式版收起交給 #356 統一處理，這裡不自己另立
## 一套建置判斷。

const COLOR_READY := Color(0.4, 1.0, 0.4)
const COLOR_PARTIAL := Color(1.0, 0.55, 0.2)
const COLOR_SCHEDULE := Color(1.0, 0.8, 0.3)


## ready_count／total_count 是這輪開場探測後，場上總共有幾隻 Agent、其中幾隻
## provider 就緒。三種狀態：全部就緒、部分就緒（混合場面，例如某隻角色的
## model_name 指到一個壞掉的 provider）、全部排程——混合場面不能只用
## true/false 表示，不然玩家會看到「排程模式」卻有幾隻角色其實在跑真的決策，
## 或反過來看到「AI 決策中」卻有幾隻其實是排程 fallback（CodeRabbit review
## 抓到，PR #467）。reason 只在有角色沒就緒時才有意義，全部就緒時忽略
func set_status(ready_count: int, total_count: int, reason: String) -> void:
	if ready_count == total_count:
		text = "AI 決策中"
		modulate = COLOR_READY
	elif ready_count == 0:
		text = "排程模式（原因：%s）" % reason
		modulate = COLOR_SCHEDULE
	else:
		text = "AI 決策中（%d／%d，其餘排程模式，原因：%s）" % [ready_count, total_count, reason]
		modulate = COLOR_PARTIAL
