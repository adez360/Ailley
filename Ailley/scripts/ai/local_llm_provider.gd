class_name LocalLLMProvider
extends DecisionProvider

## 打 AIConfig 裡名叫 "local" 的 provider（llama-server，見
## note/技術/LLM 串接與 AI 服務層.md 的設定慣例）。
const PROVIDER_NAME := "local"

## #288：model_name 是建角面板 local 分頁下拉選單選的型號字串（《06》，跟
## RemoteLLMProvider 吃 cloud model_name 同一套欄位），不是 providers 字典的
## key。查表方式也跟 cloud 一致：用 AIConfig.get_provider_by_model() 拿型號
## 反查，而不是把型號字串當 key 直接索引——同一個原因，key 只是玩家自己在
## 設定檔取的代號，規格書故意不讓它進 model_name。
##
## model_name 是空字串時（MVP 5 個排程 NPC 沒走建角面板，這個欄位維持預設
## 空值；未來若真的沒選到型號也會是空字串）退回原本「打字面值 PROVIDER_NAME」
## 的既有行為，不改變沒有 model_name 的角色原本的樣子。
##
## 玩家的 ai_config.json 不保證真的有一個可用的 "local" provider（可能只設了
## default_provider、取了別的名字，或有這個項目但 base_url/model 沒填齊）。直接把
## PROVIDER_NAME 硬傳給 AIService.request() 的話，這些情況一律是 ERROR_NO_PROVIDER，
## 決策整個啞掉。這裡在建立時解析一次：不可用就退回空字串並 push_warning——
## 跟 agent.gd::_make_provider() 對 decision_source 異常值的處理是同一種
## 「安靜降級＋警告」慣例。解析放在 _init() 不放 decide()，是因為設定在一場遊戲
## 內不會變，放 decide() 的話設定真的缺 "local" 時每次決策都印一次警告洗版
func _init(model_name: String = "") -> void:
	if not model_name.is_empty():
		var by_model := AIService.config.get_provider_by_model(model_name)
		if by_model != null and by_model.valid:
			_provider_name = by_model.name
			return
		push_warning("LocalLLMProvider: model_name \"%s\" 沒有對應的可用 AIConfig provider，退回字面值 \"%s\"" % [model_name, PROVIDER_NAME])

	if AIService.config.has_valid_provider(PROVIDER_NAME):
		_provider_name = PROVIDER_NAME
		return
	push_warning("LocalLLMProvider: AIConfig 沒有可用的 \"%s\" provider，退回 default_provider" % PROVIDER_NAME)
	_provider_name = ""


## 《12》§3.4 說本地無重試語意，理由是本地靠 GBNF 在文法層保證格式，重試沒有意義。
## 但退回 default_provider 之後打到的多半不是那個 GBNF 端點，那個理由就不成立了。
## #212：改問 AIConfig.Provider.format_guaranteed 這個宣告出來的能力，不再用
## 「provider 名字是不是字面值 "local"」判斷——名字只是我們自己取的識別字，
## 真正決定「有沒有格式保證」的是設定檔那筆 provider 自己的屬性
func max_validation_retries() -> int:
	var provider := AIService.config.get_provider(_provider_name)
	return 0 if provider != null and provider.format_guaranteed else 2
