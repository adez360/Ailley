class_name DecisionProvider
extends RefCounted

## 決策來源。agent.gd 只認得這個介面，不知道也不在乎背後是本機模型還是雲端模型
## （《12》§3、§5.1）。HumanInput／RemotePlayer 留給之後的 issue。

## 實際要傳給 AIService.request() 的 provider 名字。LocalLLMProvider／
## RemoteLLMProvider 都只是「決定這個字串是什麼」，其餘邏輯共用（#213），
## 所以搬進基底類別統一持有，子類別的 _init() 負責設定它
var _provider_name: String = ""

## envelope 是 PromptBuilder.build_dialogue_envelope()/build_plan_envelope() 組好的信封
## （system/payload/選填的 response_format）。requester_id 是 character_id，policy 決定
## 走不走速率限制——語意跟 AIService.request() 完全一致，這裡只是換一個呼叫對象。
## context 帶的 is_retry 原樣轉給 AIService.request()（見 DecisionContext 的說明）。
## 回傳形狀對齊 AIService.request()：{"ok": bool, "data": Dictionary, "error": String}
##
## LocalLLMProvider／RemoteLLMProvider 目前不覆寫這個方法，直接吃這份共用實作；
## 之後 HumanInput／RemotePlayer 如果需要不一樣的行為，照舊可以覆寫
func decide(envelope: Dictionary, requester_id: String, policy: AIService.Policy, context: DecisionContext = DecisionContext.new()) -> Dictionary:
	return await AIService.request(envelope, requester_id, policy, _provider_name, context.is_retry)


## 內容驗證失敗時，同一次決策請求內最多重試幾次（不含首次嘗試）。《12》§3.4：雲端 2 次，
## 本地無重試語意——本地靠 GBNF 在文法層就保證格式，出錯代表更根本的問題，重試沒有意義。
## 呼叫端（agent.gd._decide_with_retry()）用這個值決定要試幾次，不用自己判斷「這是哪種來源」
func max_validation_retries() -> int:
	return 0


## 這個 provider 實際會用哪個 AIConfig.Provider 名字打請求（#357）。開場要決定
## 「這隻角色的 provider 就緒了沒」時，問的是這個，不是 AIConfig.default_provider——
## 那是設定檔的預設值，跟這隻角色 decision_source／model_name 解析出來的實際
## provider 完全可能是兩個不同的東西
func provider_name() -> String:
	return _provider_name
