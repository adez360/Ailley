class_name AIConfig
extends RefCounted

## LLM provider 的連線設定。真檔放 `user://ai_config.json`，範本在
## `res://data/ai_config.example.json`。
##
## 支援多個具名 provider 同時存在（例如 `"local"` 打本機 `llama-server`、
## `"openrouter"` 打雲端），可以同時併用。這個檔案只回答「provider 叫這個
## 名字時，連線資訊是什麼」，**不管「誰該用哪個」**——那是呼叫端的事，
## 由 `AIService.request()` 的 `provider_name` 參數帶進來。目前唯一會指名的
## 呼叫端是 debug 主控台的 `ai @<provider>`。
##
## 之所以放 user:// 而不是 res://：Linux 下 user:// 是
## ~/.local/share/godot/app_userdata/<專案名>/，本來就在 repo 之外，
## 金鑰天然不進版控，連 .gitignore 都不用寫。
##
## 「檔案不存在」是預設狀態，不是錯誤 —— 玩家還沒填金鑰時整個 AI 層走 fallback，
## 遊戲照常跑。所以這條路徑一律不 push_error，只把 enabled 留在 false 並記下
## status_reason 讓 debug 主控台印得出人話。會 push_error 的只有「檔案在、
## 但內容是壞的」這種玩家自己改壞、需要被告知的情況。
##
## api_key 只准出現在送出的 Authorization header 裡。任何 log、錯誤訊息、
## 主控台輸出一律走 Provider.masked_key()，不要直接碰 api_key。

const CONFIG_PATH := "user://ai_config.json"
const EXAMPLE_PATH := "res://data/ai_config.example.json"

# 開發期預設 OpenRouter；換本機 llama-server 只要在設定檔另開一個 provider，
# 不用改這裡的預設值——這兩個常數只在 provider 沒填某欄位時當退回值
const DEFAULT_BASE_URL := "https://openrouter.ai/api/v1"
const DEFAULT_MODEL := "openai/gpt-4o-mini"

# 10 秒是 HTTPRequest.timeout 的值，不是自寫的計時器 —— 引擎原生支援逾時。
# 這個維持全域一個值，不做成逐 provider——HTTPRequest 節點池是共用的
# （見 ai_service.gd），節點的 timeout 是節點屬性不是逐請求參數，做成逐
# provider 反而沒有實際效果，只會製造「設定了卻沒生效」的錯覺
const DEFAULT_TIMEOUT := 10.0

## 速率限制的預設值。放在設定檔而不是寫死在 ai_service.gd，是因為這兩個數字
## 是「花多少錢」的旋鈕，屬於玩家的決定，不是程式的常數（決策裡它們也標著「暫定」）。
## 同樣是全域的，不分 provider——這是角色的成本控管（同一個 requester_id
## 不管打哪個 provider，額度算的是同一份），跟打去哪個服務無關
const DEFAULT_MIN_INTERVAL_SEC := 30.0
const DEFAULT_MAX_CALLS_PER_GAME_DAY := 20

## 對話輪次要不要豁免上面兩條限制。預設豁免 ——
## MIN_INTERVAL_SEC 是為「行程重排」訂的，而對話輪次是秒級間隔，
## 套上去會從第二輪起全部回 rate_limited，等於對話根本接不起來。
##
## 留成開關而不是寫死，是因為代價是真的：豁免之後對話成本沒有上限。
## 想先保住帳單的人可以把它關掉，代價是 LLM 對話大多會退回模板句
const DEFAULT_DIALOGUE_EXEMPT := true

# 遮蔽後保留的頭尾碼數。金鑰短於這個長度的兩倍就整條蓋掉，
# 免得「遮蔽」反而把一條短金鑰幾乎完整印出來
const MASK_KEEP := 4


## 一個 provider 的連線資訊跟它自己是否有效。刻意不對外開放建構子帶參數——
## 欄位驗證跟「valid 算不算得出來」是 AIConfig._apply() 的責任，
## 不該讓呼叫端自己組一個 Provider 就繞過驗證
class Provider extends RefCounted:
	var name := ""
	var base_url := AIConfig.DEFAULT_BASE_URL
	var model := AIConfig.DEFAULT_MODEL
	var api_key := ""
	var timeout := AIConfig.DEFAULT_TIMEOUT
	var valid := false
	var status_reason := ""

	## 這個 provider 送 response_format 的 json_schema 有沒有意義。預設 true——
	## 已知本機 llama-server 支援 OpenAI 相容的 response_format，並在內部自己把
	## schema 轉成 grammar 約束（決策迴圈實測 2.5-4 秒延遲主要就花在這步），
	## 雲端主流 provider 也支援。只有極少數不支援 json_schema 的 provider
	## 需要在設定檔把這個關掉，關掉後三層保證退到 layer 2（prompt 裡明寫
	## schema）跟 layer 3（AISchema 硬驗證），不送 response_format 欄位
	var supports_json_schema := true

	## 這個 provider 的輸出格式是不是真的被文法層（GBNF）約束住，不只是「有 json_schema
	## 支援」而已（#212）。預設 **false**——跟 supports_json_schema 的預設方向相反：
	## 格式保證是少數本機 provider 才有的特性，不能假設大多數 provider 都有；沒宣告的
	## provider 一律當作「可能需要重試」，最壞情況只是多重試幾次，不是正確性問題。
	## LocalLLMProvider.max_validation_retries() 讀這個欄位決定要不要給重試次數，
	## 不再用「provider 名字是不是字面值 "local"」判斷
	var format_guaranteed := false

	# 唯一准許把金鑰帶進輸出的路徑。頭尾各留 MASK_KEEP 碼，中間一律省略
	func masked_key() -> String:
		if api_key.is_empty():
			return L10n.t("AI_KEY_UNSET")
		if api_key.length() < AIConfig.MASK_KEEP * 2:
			return "*".repeat(api_key.length())
		return "%s…%s" % [
			api_key.substr(0, AIConfig.MASK_KEEP),
			api_key.substr(api_key.length() - AIConfig.MASK_KEEP),
		]

	# 完整端點。base_url 已在 AIConfig._parse_provider() 去過尾斜線，
	# 這裡不會生出雙斜線
	func completions_url() -> String:
		return base_url + "/chat/completions"

	# 就緒檢查用（issue #345）。刻意不用《04》§4-1 想像的 `/health`——那是
	# 假設一個自架後端才成立的端點，本機 llama-server 有但雲端 OpenRouter
	# 沒有。`/models` 是 OpenAI 相容 API 的標準端點，跟 completions_url() 一樣
	# 每個 provider 走同一條路徑，不用為本機/雲端分岔，還能順便驗證金鑰有效
	func models_url() -> String:
		return base_url + "/models"

	# 給 debug 主控台印一行摘要。冷卻／每日配額／對話豁免是全域設定，不屬於
	# 這個 provider 自己，由呼叫端（AIConfig）傳進來，不是這個類別自己存的——
	# 這樣同一份全域設定印在每個 provider 底下時保證一致，不會各自維護一份
	func summary(cooldown_sec: float, daily: int, dialogue_exempt: bool) -> String:
		return L10n.tf("AI_CONFIG_SUMMARY", {
			"enabled": valid,
			"base_url": base_url,
			"model": model,
			"timeout": "%.1f" % timeout,
			"key": masked_key(),
			"cooldown": "%.0f" % cooldown_sec,
			"daily": daily,
			"exempt": dialogue_exempt,
		})


var enabled := false
var status_reason := L10n.t("AI_STATUS_NOT_LOADED")
var default_provider := ""
var providers := {}					# 名字 -> Provider

var min_interval_sec := DEFAULT_MIN_INTERVAL_SEC
var max_calls_per_game_day := DEFAULT_MAX_CALLS_PER_GAME_DAY
var dialogue_exempt := DEFAULT_DIALOGUE_EXEMPT


# 讀不到就回一個 enabled = false 的設定物件，呼叫端不必自己判斷檔案在不在
static func load_from_user() -> AIConfig:
	var config := AIConfig.new()

	if not FileAccess.file_exists(CONFIG_PATH):
		config.status_reason = L10n.tf("AI_STATUS_NO_FILE", {"path": CONFIG_PATH, "example": EXAMPLE_PATH})
		return config

	var file := FileAccess.open(CONFIG_PATH, FileAccess.READ)
	if file == null:
		# 檔案在卻開不起來是權限之類的真問題，值得吵一下 —— 但訊息裡只有路徑沒有內容
		push_error("AIConfig: 開不了 %s（錯誤碼 %d）" % [CONFIG_PATH, FileAccess.get_open_error()])
		config.status_reason = L10n.tf("AI_STATUS_CANNOT_OPEN", {"path": CONFIG_PATH})
		return config

	var text := file.get_as_text()
	file.close()

	# 用 JSON 實例解析，因為 JSON.parse_string() 失敗時會把**出錯位置附近的原文**
	# 帶進引擎的錯誤訊息裡 —— 設定檔的原文就是金鑰。下面自己 push 一則不含內容的
	var json := JSON.new()
	if json.parse(text) != OK or not json.data is Dictionary:
		push_error("AIConfig: %s 不是合法的 JSON 物件" % CONFIG_PATH)
		config.status_reason = L10n.tf("AI_STATUS_BAD_JSON", {"path": CONFIG_PATH, "example": EXAMPLE_PATH})
		return config

	config._apply(json.data as Dictionary)
	return config


# 分開成一個方法是為了讓測試與未來的「設定 UI」能餵 Dictionary 進來，不必落地成檔案
func _apply(data: Dictionary) -> void:
	# 速率限制在 enabled 的判斷之前就先讀，不然「設定檔在、但 enabled = false」
	# 的路徑會提早 return，留下一組沒套用過的預設值。負數視為 0（不限）
	min_interval_sec = maxf(0.0, float(data.get("min_interval_sec", DEFAULT_MIN_INTERVAL_SEC)))
	max_calls_per_game_day = maxi(0, int(data.get("max_calls_per_game_day", DEFAULT_MAX_CALLS_PER_GAME_DAY)))
	dialogue_exempt = bool(data.get("dialogue_exempt", DEFAULT_DIALOGUE_EXEMPT))

	default_provider = str(data.get("default_provider", "")).strip_edges()

	providers.clear()
	var raw_providers: Variant = data.get("providers", {})
	if raw_providers is Dictionary:
		for provider_name in (raw_providers as Dictionary).keys():
			var raw_provider: Variant = (raw_providers as Dictionary)[provider_name]
			if raw_provider is Dictionary:
				providers[str(provider_name)] = _parse_provider(str(provider_name), raw_provider as Dictionary)

	# enabled 是「算出來的結果」不是「照抄設定檔」：設定檔寫 true 但沒填金鑰時
	# 仍然要 false，否則每次呼叫都會撞 401，錯誤訊息還離真正的原因很遠
	var wants_enabled := bool(data.get("enabled", false))
	if not wants_enabled:
		enabled = false
		status_reason = L10n.tf("AI_STATUS_DISABLED", {"path": CONFIG_PATH})
		return

	if providers.is_empty():
		enabled = false
		status_reason = L10n.tf("AI_STATUS_NO_PROVIDERS", {"path": CONFIG_PATH, "example": EXAMPLE_PATH})
		return

	# enabled 只回答「這份設定檔結構完整、至少有一個 provider」，**不管
	# default_provider 好不好**——不管是「沒填」「拼錯名字」還是「存在但缺金鑰」，
	# 都只該影響「沒指名 provider 的那些呼叫」，不該連累明確指名、而且填好的
	# provider。擋在這裡的話，default 一個字打錯就讓整個多 provider 系統當機，
	# 違背這次要做「各自獨立」的初衷。
	#
	# 沒指名而 default 又不可用的呼叫，request() 會用 get_provider() 回 null／
	# Provider.valid 為 false 擋成 ERROR_NO_PROVIDER——那是比 ERROR_DISABLED
	# 精確得多的錯誤碼
	enabled = true

	# default 壞掉不擋 enabled，但要講出來——不然「明明 enabled 卻每次都
	# ERROR_NO_PROVIDER」查不出原因。訊息講的是 default_provider 本身，
	# 不借用 AI_STATUS_NO_ENDPOINT（那句在講 base_url／model 空白，是別的毛病）
	var default_ok: bool = not default_provider.is_empty() and providers.has(default_provider)
	status_reason = L10n.t("AI_STATUS_ENABLED") if default_ok \
		else L10n.tf("AI_STATUS_BAD_DEFAULT", {"path": CONFIG_PATH})


func _parse_provider(provider_name: String, data: Dictionary) -> Provider:
	var provider := Provider.new()
	provider.name = provider_name
	provider.base_url = str(data.get("base_url", DEFAULT_BASE_URL)).strip_edges().rstrip("/")
	provider.model = str(data.get("model", DEFAULT_MODEL)).strip_edges()
	provider.timeout = float(data.get("timeout", DEFAULT_TIMEOUT))
	provider.api_key = str(data.get("api_key", "")).strip_edges()
	provider.supports_json_schema = bool(data.get("supports_json_schema", true))
	provider.format_guaranteed = bool(data.get("format_guaranteed", false))

	# 空金鑰是合法的：本機 llama-server／ollama 這類服務根本不驗 Authorization，
	# 逼它填一把假金鑰只是在替一條不合身的規則寫解法。金鑰空的時候
	# AIService._send() 直接不送 Authorization 標頭。
	#
	# 這條規則本來是想擋「照抄範例檔但沒填金鑰」，但擋不到——範例檔給的是
	# `sk-or-v1-REPLACE_ME`，非空，本來就過得了這關然後撞 401。真正擋得住的
	# 是 base_url／model 空白
	if provider.base_url.is_empty() or provider.model.is_empty():
		provider.valid = false
		provider.status_reason = L10n.tf("AI_STATUS_NO_ENDPOINT", {"path": CONFIG_PATH})
	else:
		provider.valid = true
		provider.status_reason = L10n.t("AI_STATUS_ENABLED")

	return provider


## 依名字取 provider。**只有空字串會退回 default_provider**；名字打錯是回 null，
## 不會靜默導去別的服務——這個函式決定金鑰往哪送，猜錯的代價是把金鑰送去
## 使用者沒指名的端點。
##
## 呼叫端要自己檢查回傳是不是 null（含 default_provider 本身不存在的情況），
## AIService.request() 會把它擋成 ERROR_NO_PROVIDER
func get_provider(provider_name: String) -> Provider:
	var resolved := provider_name if not provider_name.is_empty() else default_provider
	return providers.get(resolved)


func has_provider(provider_name: String) -> bool:
	return get_provider(provider_name) != null


## 依「型號字串」反查 provider（#122）。角色存的 `model_name`（《06》）是
## 給玩家看的型號（如 `qwen2.5-7b-instruct`），不是 `providers` 字典的 key
## （如 `local`）——那個 key 只是玩家自己在設定檔取的代號，規格書故意不讓它
## 進 `model_name`，理由是「角色面板顯示『這隻由 local 驅動』沒有意義，玩家
## 想看的是型號」。查表方向因此要反過來：拿型號去掃所有 provider 找 `.model`
## 相符的那個，而不是照舊拿字串當 key 直接索引
func get_provider_by_model(model: String) -> Provider:
	for provider in providers.values():
		if (provider as Provider).model == model:
			return provider
	return null


## 「這個名字真的打得出去嗎」。has_provider() 只查設定項存不存在，但 AIService.request()
## 擋的條件是 `provider == null or not provider.valid`——只用 has_provider() 事前檢查的
## 呼叫端，會放行一個存在但 base_url/model 沒填齊的設定項，然後每次請求都安靜收到
## ERROR_NO_PROVIDER。要在建立階段判斷「能不能用這個 provider」一律用這個
func has_valid_provider(provider_name: String) -> bool:
	var provider := get_provider(provider_name)
	return provider != null and provider.valid


# 印出去給人看的整份摘要，每個 provider 各一行，名字在前面標出來
# （名字是識別字，不翻譯，跟主控台指令名同一個道理）。刻意不用單一
# _to_string()：provider 有好幾個，塞進一行字串反而更難讀
func _to_string() -> String:
	var lines: Array[String] = []
	for provider_name in providers.keys():
		var provider: Provider = providers[provider_name]
		var marker := " (default)" if provider_name == default_provider else ""
		lines.append("%s%s: %s" % [
			provider_name, marker, provider.summary(min_interval_sec, max_calls_per_game_day, dialogue_exempt)
		])

	if lines.is_empty():
		return L10n.t("AI_STATUS_NOT_LOADED") if providers.is_empty() and not enabled else ""

	return "\n".join(lines)
