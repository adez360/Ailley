class_name AIConfig
extends RefCounted

## LLM provider 的連線設定。真檔放 `user://ai_config.json`，範本在
## `res://data/ai_config.example.json`。
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
## 主控台輸出一律走 masked_key()，不要直接碰 api_key。

const CONFIG_PATH := "user://ai_config.json"
const EXAMPLE_PATH := "res://data/ai_config.example.json"

# 開發期預設 OpenRouter；換 Ollama 只要在設定檔改 base_url，程式不用動
const DEFAULT_BASE_URL := "https://openrouter.ai/api/v1"
const DEFAULT_MODEL := "openai/gpt-4o-mini"

# 10 秒是 HTTPRequest.timeout 的值，不是自寫的計時器 —— 引擎原生支援逾時
const DEFAULT_TIMEOUT := 10.0

## 速率限制的預設值。放在設定檔而不是寫死在 ai_service.gd，是因為這兩個數字
## 是「花多少錢」的旋鈕，屬於玩家的決定，不是程式的常數（決策裡它們也標著「暫定」）
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

var enabled := false
var base_url := DEFAULT_BASE_URL
var model := DEFAULT_MODEL
var timeout := DEFAULT_TIMEOUT
var status_reason := L10n.t("AI_STATUS_NOT_LOADED")

var min_interval_sec := DEFAULT_MIN_INTERVAL_SEC
var max_calls_per_game_day := DEFAULT_MAX_CALLS_PER_GAME_DAY
var dialogue_exempt := DEFAULT_DIALOGUE_EXEMPT

# 不給預設值以外的任何存取糖衣：想印它的人只能拿到 masked_key()
var api_key := ""


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
	base_url = str(data.get("base_url", DEFAULT_BASE_URL)).strip_edges().rstrip("/")
	model = str(data.get("model", DEFAULT_MODEL)).strip_edges()
	timeout = float(data.get("timeout", DEFAULT_TIMEOUT))
	api_key = str(data.get("api_key", "")).strip_edges()

	# 速率限制在 enabled 的判斷之前就先讀，不然「設定檔在、但 enabled = false」
	# 的路徑會提早 return，留下一組沒套用過的預設值。負數視為 0（不限）
	min_interval_sec = maxf(0.0, float(data.get("min_interval_sec", DEFAULT_MIN_INTERVAL_SEC)))
	max_calls_per_game_day = maxi(0, int(data.get("max_calls_per_game_day", DEFAULT_MAX_CALLS_PER_GAME_DAY)))
	dialogue_exempt = bool(data.get("dialogue_exempt", DEFAULT_DIALOGUE_EXEMPT))

	# enabled 是「算出來的結果」不是「照抄設定檔」：設定檔寫 true 但沒填金鑰時
	# 仍然要 false，否則每次呼叫都會撞 401，錯誤訊息還離真正的原因很遠
	var wants_enabled := bool(data.get("enabled", false))
	if not wants_enabled:
		enabled = false
		status_reason = L10n.tf("AI_STATUS_DISABLED", {"path": CONFIG_PATH})
		return

	if api_key.is_empty():
		enabled = false
		status_reason = L10n.tf("AI_STATUS_NO_KEY", {"path": CONFIG_PATH})
		return

	if base_url.is_empty() or model.is_empty():
		enabled = false
		status_reason = L10n.tf("AI_STATUS_NO_ENDPOINT", {"path": CONFIG_PATH})
		return

	enabled = true
	status_reason = L10n.t("AI_STATUS_ENABLED")


# 唯一准許把金鑰帶進輸出的路徑。頭尾各留 MASK_KEEP 碼，中間一律省略
func masked_key() -> String:
	if api_key.is_empty():
		return L10n.t("AI_KEY_UNSET")
	if api_key.length() < MASK_KEEP * 2:
		return "*".repeat(api_key.length())
	return "%s…%s" % [api_key.substr(0, MASK_KEEP), api_key.substr(api_key.length() - MASK_KEEP)]


# 完整端點。base_url 已在 _apply 去過尾斜線，這裡不會生出雙斜線
func completions_url() -> String:
	return base_url + "/chat/completions"


# 印出去給人看的一行摘要。刻意覆寫 _to_string，讓「不小心 print(config)」
# 也印不出金鑰 —— 靠自律不夠，要靠這條路本身就是安全的
func _to_string() -> String:
	# 小數位數在這裡先格式化成字串再交給 format()：format() 沒有格式規格，
	# 而把 %.1f 留在翻譯字串裡等於要譯者處理格式碼
	return L10n.tf("AI_CONFIG_SUMMARY", {
		"enabled": enabled,
		"base_url": base_url,
		"model": model,
		"timeout": "%.1f" % timeout,
		"key": masked_key(),
		"cooldown": "%.0f" % min_interval_sec,
		"daily": max_calls_per_game_day,
		"exempt": dialogue_exempt,
	})
