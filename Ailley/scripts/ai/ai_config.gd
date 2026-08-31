class_name AIConfig
extends RefCounted

## LLM provider 的連線設定。真檔放 `user://ai_config_<hash>.json`（hash 依
## checkout 隔離，見 CONFIG_PATH），範本在 `res://data/ai_config.example.json`。
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

## user:// 只依 project.godot 的 project name 解析，不分 worktree/checkout，
## 跟 DatabaseManager.DATABASE_PATH（issue #334）同一個病根：用這個 checkout
## 的 res:// 絕對路徑算完整 sha256 接在檔名後，讓不同 checkout 落地成不同
## 實體檔案，不會互相覆寫（issue #769）。被 static func（load_from_user()／
## _write_default_config()）讀取，只能用 static var，不能用 const 呼叫函式
static var CONFIG_PATH := _compute_config_path()
const EXAMPLE_PATH := "res://data/ai_config.example.json"


static func _compute_config_path() -> String:
	var checkout_hash := ProjectSettings.globalize_path("res://").sha256_text()
	return "user://ai_config_%s.json" % checkout_hash

# 開發期預設 OpenRouter；換本機 llama-server 只要在設定檔另開一個 provider，
# 不用改這裡的預設值——這兩個常數只在 provider 沒填某欄位時當退回值
const DEFAULT_BASE_URL := "https://openrouter.ai/api/v1"
const DEFAULT_MODEL := "openai/gpt-4o-mini"

# 是 HTTPRequest.timeout 的值，不是自寫的計時器 —— 引擎原生支援逾時。
# 這是逐 provider 設定不到時的退回值，不是唯一生效的全域值：_parse_provider()
# 把設定檔裡沒填、或填了非正值（0／負值，HTTPRequest 會解讀成「不逾時」）的
# provider.timeout 一律退回這個值；填了正值的話 provider.timeout 蓋過它，
# ai_service.gd::_send()／_probe_models() 每次發送前都把節點的
# HTTPRequest.timeout 設成當次呼叫的 provider.timeout，同一個節點池跨請求
# 換著用不同 provider 時逐次生效，不是建立節點當下定死的一次性初值
#
# #852：原本 10 秒，實測本機 llama-server（Qwen2.5-7B-Instruct-Q4_K_M）偶爾
# 會撞到——單人測試 127 次真實決策呼叫裡撞到 1 次安靜逾時，角色因此完全沒被
# 問到那一輪，跟 prompt 措辭或 need_bonus 加權無關，是請求本身沒能在時限內
# 拿到回應。20 秒／30 秒各自跑了 40 次以上、0 次逾時，但這個樣本量沒辦法
# 精確定出「最佳」數字（伺服器延遲是叢集性的，小樣本容易漏抓），20 秒是
# 「有實測資料撐腰的最小候選值」，不是理論上限。沒有調更高（例如一度討論
# 過的 60 秒）：AIService.POOL_SIZE 只有 3 個 HTTP 節點，timeout 拉更長會在
# 多角色場景下放大排隊風險，這次是單人測試量不到，留給之後的多角色測試
# 決定要不要再往上調
const DEFAULT_TIMEOUT := 20.0

## 速率限制的預設值。放在設定檔而不是寫死在 ai_service.gd，是因為這兩個數字
## 是「花多少錢」的旋鈕，屬於玩家的決定，不是程式的常數（決策裡它們也標著「暫定」）。
## 同樣是全域的，不分 provider——這是角色的成本控管（同一個 requester_id
## 不管打哪個 provider，額度算的是同一份），跟打去哪個服務無關
const DEFAULT_MIN_INTERVAL_SEC := 30.0
const DEFAULT_MAX_CALLS_PER_GAME_DAY := 20

## 對話輪次自己的每日呼叫上限，只在 dialogue_exempt=true 時才有意義——
## dialogue_exempt=true 讓 CONVERSATION 完全豁免上面兩條限制，沒有這個旋鈕
## 的話一場對話可以無限輪講下去，成本無上限。0＝不限，跟前兩者同一套慣例。
## 目前預設值是 150；起始值 30 的推算方法論與「8～9 場」的換算更正見
## 《LLM 串接與 AI 服務層》「每日對話呼叫上限提案」一節。dialogue_exempt=false
## 時這個旋鈕形同虛設——那種設定下對話呼叫已經走一般 max_calls_per_game_day
## 路徑，不需要疊加第二層限制
const DEFAULT_MAX_DIALOGUE_CALLS_PER_GAME_DAY := 150

## 建角一次性生成（words_to_creator）的每日呼叫上限。CREATION policy 無條件
## 豁免冷卻與配額（見 ai_service.gd Policy 的說明），沒有這個旋鈕的話成本
## 保護完全敞開——雖然結構上每個角色一輩子只打一次，但生成失敗時每次開局／
## 投放都會重打，累積請求數沒有上限。0＝不限（預設，維持「結構上只打一次」
## 的既有行為），跟對話上限同一套慣例；想保住帳單的人可以設一個數字兜底
const DEFAULT_MAX_CREATION_CALLS_PER_GAME_DAY := 0

## L3 語意檢索的 embedding 端點設定（issue #571，《03》§7）。刻意放在頂層、
## 不塞進 providers 字典——providers 代表玩家自己選的聊天 provider（Local／
## Cloud 二選一），而 embedding 永遠打本機的 embedding-only llama-server，
## 跟玩家選了哪個聊天 provider 無關，兩者是獨立的設定面。預設值指向專案內
## 已驗證可用的本機 embedding server（bge-small-zh-v1.5-q8_0.gguf，
## `llama-server --embedding --pooling cls`），沒填這個區塊時就套用這組預設值，
## 不是留白——EmbeddingService 本來就是軟失敗設計（連不上就回空結果，不擋
## 遊戲），沒必要在設定層再擋一次
const DEFAULT_EMBEDDING_BASE_URL := "http://127.0.0.1:8081/v1"
const DEFAULT_EMBEDDING_MODEL := "bge-small-zh-v1.5-q8_0.gguf"
const DEFAULT_EMBEDDING_TIMEOUT := 10.0

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
	func summary(cooldown_sec: float, daily: int, dialogue_exempt: bool, max_dialogue: int) -> String:
		return L10n.tf("AI_CONFIG_SUMMARY", {
			"enabled": valid,
			"base_url": base_url,
			"model": model,
			"timeout": "%.1f" % timeout,
			"key": masked_key(),
			"cooldown": "%.0f" % cooldown_sec,
			"daily": daily,
			"exempt": dialogue_exempt,
			"max_dialogue": max_dialogue,
		})


var enabled := false
var status_reason := L10n.t("AI_STATUS_NOT_LOADED")
var default_provider := ""
var providers := {}					# 名字 -> Provider

var min_interval_sec := DEFAULT_MIN_INTERVAL_SEC
var max_calls_per_game_day := DEFAULT_MAX_CALLS_PER_GAME_DAY
var dialogue_exempt := DEFAULT_DIALOGUE_EXEMPT
var max_creation_calls_per_game_day := DEFAULT_MAX_CREATION_CALLS_PER_GAME_DAY
var max_dialogue_calls_per_game_day := DEFAULT_MAX_DIALOGUE_CALLS_PER_GAME_DAY

var embedding_base_url := DEFAULT_EMBEDDING_BASE_URL
var embedding_model := DEFAULT_EMBEDDING_MODEL
var embedding_timeout := DEFAULT_EMBEDDING_TIMEOUT


# 內建 sidecar 的本機連線預設值（《16》§2.2 決定隨安裝包附上的 llama-server，
# 固定跑在這個位址與埠號）。寫死在這裡，不讀 ai_config.example.json——範本檔
# 同時示範 openrouter 這個玩家要自己填金鑰的 provider，不能整包照抄當預設值，
# 這裡只需要「local」那一段
const _DEFAULT_LOCAL_BASE_URL := "http://127.0.0.1:8080/v1"
const _DEFAULT_LOCAL_MODEL := "Qwen2.5-7B-Instruct-Q4_K_M.gguf"


# 首次啟動、`user://` 還沒有設定檔時自動寫一份指向內建 sidecar 的預設值
# （《16 打包與發布規格書》§2.3），玩家不用手動抄 ai_config.example.json。
# 雲端 provider（OpenRouter token）不在自動產生範圍內——那需要玩家自己的金鑰，
# 沒有預設值可以填。回傳寫入是否成功；呼叫端失敗時退回原本「檔案不存在」的
# disabled 狀態，不當硬錯誤
static func _write_default_config() -> bool:
	var default_data := {
		"enabled": true,
		"default_provider": "local",
		"providers": {
			"local": {
				"base_url": _DEFAULT_LOCAL_BASE_URL,
				"api_key": "",
				"model": _DEFAULT_LOCAL_MODEL,
				"timeout": DEFAULT_TIMEOUT,
				"supports_json_schema": true,
				"format_guaranteed": true
			}
		},
		"min_interval_sec": DEFAULT_MIN_INTERVAL_SEC,
		"max_calls_per_game_day": DEFAULT_MAX_CALLS_PER_GAME_DAY,
		"dialogue_exempt": DEFAULT_DIALOGUE_EXEMPT
	}

	var file := FileAccess.open(CONFIG_PATH, FileAccess.WRITE)
	if file == null:
		push_error("AIConfig: 無法建立預設設定檔 %s（錯誤碼 %d）" % [CONFIG_PATH, FileAccess.get_open_error()])
		return false

	# store_string() 回傳 bool，忽略它的話寫入失敗（例如磁碟滿）時仍會回傳
	# true，留下一份寫壞的 CONFIG_PATH——下次 load_from_user() 檢查
	# file_exists() 會判定「有檔案」，改去解析出 AI_STATUS_BAD_JSON，而不是
	# 停在原本「檔案不存在」該有的 disabled 狀態（CodeRabbit review 抓到）
	var write_ok := file.store_string(JSON.stringify(default_data, "\t"))
	file.close()
	if not write_ok:
		push_error("AIConfig: 寫入預設設定檔 %s 失敗" % CONFIG_PATH)
		# remove_absolute() 回傳 Error，忽略它的話清理也失敗時（例如檔案被
		# 其他行程鎖住）會留下寫壞的部分內容，下次啟動 file_exists() 判定
		# 「有檔案」，改去解析出 AI_STATUS_BAD_JSON，而不是停在「檔案不存在」
		# 該有的 disabled 狀態——記下來至少能在 log 裡看到清理本身也失敗了
		# （CodeRabbit review 抓到）
		var remove_err := DirAccess.remove_absolute(CONFIG_PATH)
		if remove_err != OK:
			push_error(
				"AIConfig: 清理寫壞的 %s 失敗（錯誤碼 %d），下次啟動可能誤判成 AI_STATUS_BAD_JSON"
				% [CONFIG_PATH, remove_err]
			)
		return false
	return true


# 讀不到就回一個 enabled = false 的設定物件，呼叫端不必自己判斷檔案在不在
static func load_from_user() -> AIConfig:
	var config := AIConfig.new()

	if not FileAccess.file_exists(CONFIG_PATH):
		# 首次啟動自動產生一份指向內建 sidecar（127.0.0.1 本機連線）的設定檔
		# （《16 打包與發布規格書》§2.3）——寫不出去（例如 user:// 沒有寫入權限）
		# 不當硬錯誤，退回原本「檔案不存在」的 disabled 狀態，遊戲照樣能跑，
		# 只是要玩家自己抄範本
		if not _write_default_config():
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
	max_dialogue_calls_per_game_day = maxi(0, int(
		data.get("max_dialogue_calls_per_game_day", DEFAULT_MAX_DIALOGUE_CALLS_PER_GAME_DAY)
	))
	max_creation_calls_per_game_day = maxi(0, int(
		data.get("max_creation_calls_per_game_day", DEFAULT_MAX_CREATION_CALLS_PER_GAME_DAY)
	))

	# embedding 區塊跟上面幾個速率限制欄位一樣，在 enabled 判斷之前就先讀——
	# 這個區塊管的是 L3 語意檢索，跟聊天 provider 的 enabled/disabled 狀態無關，
	# 玩家沒開聊天 AI 一樣可能想要記憶檢索照常運作（雖然沒有 LLM 決策迴圈會用到
	# 它，但 Memory.search_l3() 不該因為這裡提早 return 而讀到沒套用過的預設值）
	var raw_embedding: Variant = data.get("embedding", {})
	if raw_embedding is Dictionary:
		var embedding_data := raw_embedding as Dictionary
		var raw_embedding_base_url := str(embedding_data.get("base_url", DEFAULT_EMBEDDING_BASE_URL)).strip_edges().rstrip("/")
		# 只信任 loopback 位址（CodeRabbit review 抓到）：embedding 一律走本機
		# 是這個功能的核心承諾（見 note/技術/LLM 串接與 AI 服務層.md「Embedding」
		# 一節）——不是怕記憶內容外流的隱私問題（NPC 記憶是模擬事件，不是玩家
		# 真實個資），是怕設定檔手改或未來開放玩家自訂這個欄位時，不小心指到
		# 一個真的收費的雲端端點，讓玩家在不知情的狀況下，每筆記憶寫入／每次
		# 語意檢索觸發都默默產生 API 費用（觸發頻率比對話還高）。非 loopback
		# 位址一律拒絕、退回預設值，不嘗試「警告但照樣送出去」
		if _is_loopback_url(raw_embedding_base_url):
			embedding_base_url = raw_embedding_base_url
		else:
			# 不把 raw_embedding_base_url 整個印進錯誤訊息（CodeRabbit review
			# 抓到）：這個值來自玩家可寫入的設定檔，可能夾帶 URI userinfo 或
			# query string 裡的帳密／token，寫進 log 就是把這些資料留在使用者
			# 看得到、可能被分享出去除錯的地方——這裡只需要讓玩家知道「這個
			# 設定被拒絕了」，不需要把被拒絕的值本身複誦一次
			push_error(
				"[AIConfig] embedding.base_url 不是本機位址，拒絕使用、退回預設值——"
				+ "embedding 設計上一律走本機，避免玩家不知情下對雲端端點產生費用"
			)
			embedding_base_url = DEFAULT_EMBEDDING_BASE_URL
		# 跟下面 timeout 同一個理由：空字串／全空白不是合法的模型名稱，
		# 設定檔手滑填 "" 或 "   " 時退回預設值，不然 EmbeddingService
		# 會拿空字串當 model 送出請求（CodeRabbit review 抓到）
		var raw_embedding_model := str(embedding_data.get("model", DEFAULT_EMBEDDING_MODEL)).strip_edges()
		embedding_model = raw_embedding_model if not raw_embedding_model.is_empty() else DEFAULT_EMBEDDING_MODEL
		# 跟 _parse_provider() 的 timeout 處理同一個理由：<= 0 代表「不設逾時」，
		# 設定檔手滑填 0 或負值時退回預設值，不信任非正值
		var raw_embedding_timeout := float(embedding_data.get("timeout", DEFAULT_EMBEDDING_TIMEOUT))
		embedding_timeout = raw_embedding_timeout if raw_embedding_timeout > 0.0 else DEFAULT_EMBEDDING_TIMEOUT
	else:
		embedding_base_url = DEFAULT_EMBEDDING_BASE_URL
		embedding_model = DEFAULT_EMBEDDING_MODEL
		embedding_timeout = DEFAULT_EMBEDDING_TIMEOUT

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


## embedding.base_url 的 loopback 檢查（見 _apply() 的呼叫處說明）。只認
## host 是 127.0.0.1／localhost／[::1] 這三種寫法，不做真正的 DNS 解析——
## 設定檔裡填一個會解析到 loopback 的自訂 hostname 這種邊緣情況不在防範
## 範圍內，這裡只擋最直接、最可能因為設定檔手滑或誤用範例產生的情況
## （填了雲端 API 的網域）
static func _is_loopback_url(url: String) -> bool:
	var without_scheme := url
	var scheme_index := url.find("://")
	if scheme_index != -1:
		without_scheme = url.substr(scheme_index + 3)

	var host := without_scheme
	var slash_index := host.find("/")
	if slash_index != -1:
		host = host.substr(0, slash_index)

	# URI userinfo（"user:pass@host"，CodeRabbit review 抓到）：
	# "127.0.0.1:8081@evil.example" 這種寫法，@ 前面看起來是 loopback，但
	# Godot 的 HTTPRequest 實際連線時會把 @ 前面當成 userinfo 丟棄，真正連
	# 上的是 @ 後面的 evil.example——如果這裡只看 @ 前面就判定過關，等於
	# 讓一個指向任意遠端主機的 URL 偽裝成本機位址騙過驗證。embedding server
	# 不需要 URL 內嵌帳密，含 @ 的 authority 一律直接拒絕，不嘗試解析
	# 「@ 後面才是真正的 host」這種寫法本身要不要放行
	if host.find("@") != -1:
		return false

	# 括號包住的 IPv6 字面值（CodeRabbit review 抓到）：[::1] 或 [::1]:port，
	# port 只會出現在右括號之後——不能像下面非括號的情形直接找「最後一個
	# 冒號」去切，[::1] 本身內部就有冒號，會把左括號內容切壞（[::1] 被切成
	# 「[:」）。有括號時改成找右括號位置，port（如果有）保證在它後面
	if host.begins_with("["):
		var bracket_end := host.find("]")
		if bracket_end == -1:
			return false

		# 右括號後面的內容要嘛是空字串、要嘛是合法的 ":<port>"（CodeRabbit
		# review 抓到）："[::1]evil.example" 這種寫法，右括號後面直接接一個
		# 網域名稱，不是 port——先前這裡只保留 "[::1]" 那一段去比對，等於
		# 完全忽略了右括號後面還有東西，讓這種偽裝成 loopback 的字串通過
		# 驗證；但 _apply() 實際存起來、後續 EmbeddingService 真正拿去打的
		# 是原始未截斷的 raw_embedding_base_url，不是這裡截斷過的 host，兩者
		# 對不上
		var suffix := host.substr(bracket_end + 1)
		if not suffix.is_empty():
			if not suffix.begins_with(":") or not _is_valid_port(suffix.substr(1)):
				return false

		host = host.substr(0, bracket_end + 1)
	else:
		var colon_index := host.rfind(":")
		if colon_index != -1:
			# 冒號後面也要驗證是合法 port 才能截掉（CodeRabbit review 抓到
			# 的同一類問題，這裡原本完全沒驗證：is_valid_int() 連 ":-1" 這種
			# 負數、":65536" 這種超出 TCP port 範圍的值都會判定通過，兩者都
			# 不是真正能用的 port）——冒號後面不是合法 port 時，代表這整段
			# 不是「host:port」的寫法，不能只取冒號前半段去比對，直接判定
			# 不是 loopback
			if not _is_valid_port(host.substr(colon_index + 1)):
				return false
			host = host.substr(0, colon_index)

	return host == "127.0.0.1" or host == "localhost" or host == "[::1]" or host == "::1"


## TCP port 合法範圍是 1-65535（CodeRabbit review 抓到：is_valid_int() 只驗證
## 字串是不是整數格式，不驗證數值範圍，":-1"／":65536" 這種不合法的 port 會被
## 誤判通過）。is_valid_int() 允許前導 "+"／"-"，這裡額外用 int() 轉換後做
## 範圍檢查，一次擋掉格式與範圍兩種問題
static func _is_valid_port(port_str: String) -> bool:
	if not port_str.is_valid_int():
		return false
	var port := int(port_str)
	return port >= 1 and port <= 65535


func _parse_provider(provider_name: String, data: Dictionary) -> Provider:
	var provider := Provider.new()
	provider.name = provider_name
	provider.base_url = str(data.get("base_url", DEFAULT_BASE_URL)).strip_edges().rstrip("/")
	provider.model = str(data.get("model", DEFAULT_MODEL)).strip_edges()
	# HTTPRequest.timeout <= 0 在 Godot 裡代表「不設逾時」，不是「立刻逾時」——
	# 設定檔手滑填 0 或負值會讓 _send()／_probe_models() 的請求永遠不逾時，
	# 卡住的節點回不了池子。這裡退回 DEFAULT_TIMEOUT，不信任設定檔給的非正值
	# （CodeRabbit review 抓到）
	var raw_timeout := float(data.get("timeout", DEFAULT_TIMEOUT))
	provider.timeout = raw_timeout if raw_timeout > 0.0 else DEFAULT_TIMEOUT
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
			provider_name, marker, provider.summary(
				min_interval_sec, max_calls_per_game_day, dialogue_exempt, max_dialogue_calls_per_game_day
			)
		])

	if lines.is_empty():
		return L10n.t("AI_STATUS_NOT_LOADED") if providers.is_empty() and not enabled else ""

	return "\n".join(lines)
