class_name LocalLLMProvider
extends DecisionProvider

## 打 AIConfig 裡名叫 "local" 的 provider（llama-server，見
## note/技術/LLM 串接與 AI 服務層.md 的設定慣例）。
const PROVIDER_NAME := "local"

## 實際要傳給 AIService.request() 的名字：PROVIDER_NAME，或退回 "" (＝ default_provider)
var _provider_name: String

## 玩家的 ai_config.json 不保證真的有一個可用的 "local" provider（可能只設了
## default_provider、取了別的名字，或有這個項目但 base_url/model 沒填齊）。直接把
## PROVIDER_NAME 硬傳給 AIService.request() 的話，這些情況一律是 ERROR_NO_PROVIDER，
## 決策整個啞掉。這裡在建立時解析一次：不可用就退回空字串並 push_warning——
## 跟 agent.gd::_make_provider() 對 decision_source 異常值的處理是同一種
## 「安靜降級＋警告」慣例。解析放在 _init() 不放 decide()，是因為設定在一場遊戲
## 內不會變，放 decide() 的話設定真的缺 "local" 時每次決策都印一次警告洗版
func _init() -> void:
	if AIService.config.has_valid_provider(PROVIDER_NAME):
		_provider_name = PROVIDER_NAME
		return
	push_warning("LocalLLMProvider: AIConfig 沒有可用的 \"%s\" provider，退回 default_provider" % PROVIDER_NAME)
	_provider_name = ""


func decide(envelope: Dictionary, requester_id: String, policy: AIService.Policy, is_retry: bool = false) -> Dictionary:
	return await AIService.request(envelope, requester_id, policy, _provider_name, is_retry)


## 《12》§3.4 說本地無重試語意，理由是本地靠 GBNF 在文法層保證格式，重試沒有意義。
## 但退回 default_provider 之後打到的多半不是那個 GBNF 端點，那個理由就不成立了，
## 此時比照 RemoteLLMProvider 給 2 次——不然同一個雲端模型，decision_source="cloud"
## 有 2 次重試、走 local fallback 進來卻是驗證失敗就直接掛掉
func max_validation_retries() -> int:
	return 0 if _provider_name == PROVIDER_NAME else 2
