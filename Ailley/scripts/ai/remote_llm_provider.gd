class_name RemoteLLMProvider
extends DecisionProvider

## 打哪個 AIConfig provider，建構時就決定（對應《06》model_name 欄位——建角面板下拉
## 選的是 AIConfig 裡已設定好的 provider 名字）。跟 LocalLLMProvider 不同的是這個名字
## 不是常數，是每個角色自己的選擇，投放後不可改（跟《06》規則一致）。
var _provider_name: String

func _init(provider_name: String) -> void:
	_provider_name = provider_name

func decide(envelope: Dictionary, requester_id: String, policy: AIService.Policy, is_retry: bool = false) -> Dictionary:
	return await AIService.request(envelope, requester_id, policy, _provider_name, is_retry)


## 《12》§3.4：「RemoteLLM 必須實作驗證失敗重試」，上限 2 次（P-22 #3 已拍板，見 #152）
func max_validation_retries() -> int:
	return 2
