class_name LocalLLMProvider
extends DecisionProvider

## 固定打 AIConfig 裡名叫 "local" 的 provider（llama-server，見
## note/技術/LLM 串接與 AI 服務層.md 的設定慣例）。純包裝，不改變 AIService 現有行為。
## max_validation_retries() 沿用基底的 0——不覆寫。
const PROVIDER_NAME := "local"

func decide(envelope: Dictionary, requester_id: String, policy: AIService.Policy) -> Dictionary:
	return await AIService.request(envelope, requester_id, policy, PROVIDER_NAME)
