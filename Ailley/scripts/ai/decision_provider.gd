class_name DecisionProvider
extends RefCounted

## 決策來源。agent.gd 只認得這個介面，不知道也不在乎背後是本機模型還是雲端模型
## （《12》§3、§5.1）。HumanInput／RemotePlayer 留給之後的 issue。

## envelope 是 PromptBuilder.build_dialogue_envelope()/build_plan_envelope() 組好的信封
## （system/payload/選填的 response_format）。requester_id 是 character_id，policy 決定
## 走不走速率限制——語意跟 AIService.request() 完全一致，這裡只是換一個呼叫對象。
## is_retry 原樣轉給 AIService.request()：同一次決策內的內容驗證失敗重試要跳過冷卻
## 檢查，不然重試永遠會被自己剛送出的上一次呼叫的冷卻擋下（見 agent.gd._decide_with_retry()）。
## 回傳形狀對齊 AIService.request()：{"ok": bool, "data": Dictionary, "error": String}
func decide(_envelope: Dictionary, _requester_id: String, _policy: AIService.Policy, _is_retry: bool = false) -> Dictionary:
	push_error("DecisionProvider.decide() 未實作")
	return {"ok": false, "data": {}, "error": "not_implemented"}


## 內容驗證失敗時，同一次決策請求內最多重試幾次（不含首次嘗試）。《12》§3.4：雲端 2 次，
## 本地無重試語意——本地靠 GBNF 在文法層就保證格式，出錯代表更根本的問題，重試沒有意義。
## 呼叫端（agent.gd._decide_with_retry()）用這個值決定要試幾次，不用自己判斷「這是哪種來源」
func max_validation_retries() -> int:
	return 0
