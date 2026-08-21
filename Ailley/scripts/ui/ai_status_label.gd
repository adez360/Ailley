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
const COLOR_SCHEDULE := Color(1.0, 0.8, 0.3)


func set_status(ai_ready: bool, reason: String) -> void:
	if ai_ready:
		text = "AI 決策中"
		modulate = COLOR_READY
	else:
		text = "排程模式（原因：%s）" % reason
		modulate = COLOR_SCHEDULE
