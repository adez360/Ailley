class_name LocalLLMProvider
extends DecisionProvider

## 打 AIConfig 裡名叫 "local" 的 provider（llama-server，見
## note/技術/LLM 串接與 AI 服務層.md 的設定慣例）。max_validation_retries()
## 沿用基底的 0——不覆寫。
const PROVIDER_NAME := "local"

## 玩家的 ai_config.json 不保證真的有一個叫 "local" 的 provider（可能只設了
## default_provider，或取了別的名字）——PR #176 review 抓到：如果直接把
## PROVIDER_NAME 硬傳給 AIService.request()，找不到就是 ERROR_NO_PROVIDER，
## 決策整個啞掉，比重構前「傳空字串讓 AIConfig.default_provider 自己解析」
## 更差。這裡先確認 "local" 真的存在，不存在就退回空字串（＝退回
## default_provider），並 push_warning 講清楚原因——跟 agent.gd::_make_provider()
## 對 decision_source 異常值的處理是同一種「安靜降級＋警告」慣例
func decide(envelope: Dictionary, requester_id: String, policy: AIService.Policy, is_retry: bool = false) -> Dictionary:
	var provider_name := PROVIDER_NAME
	if not AIService.config.has_provider(PROVIDER_NAME):
		push_warning("LocalLLMProvider: AIConfig 沒有名叫 \"%s\" 的 provider，退回 default_provider" % PROVIDER_NAME)
		provider_name = ""
	return await AIService.request(envelope, requester_id, policy, provider_name, is_retry)
