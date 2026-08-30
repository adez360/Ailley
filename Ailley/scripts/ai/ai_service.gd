extends Node

## 全專案**唯一**碰網路的地方（autoload 名稱 `AIService`）。
##
## 為什麼要是 autoload 而不是每個 Agent 自己帶一個 HTTPRequest：
## 一個 HTTPRequest 節點同時只能跑一個請求。散在各處等於每隻 Agent 自己
## 重寫一次佇列、逾時、重試與速率限制，而且沒有人能統計「這一局總共打了幾次」。
## 集中成一個服務之後，成本上限、金鑰處理、防注入入口都只有一個地方要顧。
##
## 對外只有一個函式，呼叫端一律 await：
##     var result := await AIService.request(envelope, requester_id)                     # 行程重排，預設 provider
##     var result := await AIService.request(envelope, requester_id, Policy.CONVERSATION) # 對話輪次
##     var result := await AIService.request(envelope, requester_id, Policy.SCHEDULED, "local")  # 指定 provider
##     # result = {"ok": bool, "data": Dictionary, "error": String}
##
## provider 是哪個角色打去哪個 LLM 服務的名字（見 AIConfig.Provider），
## 空字串就用設定檔的 default_provider。速率限制／每日配額算在 requester_id
## 上，不分 provider——同一隻角色不管打本地還雲端，額度算的是同一份，
## 這是角色的成本控管，跟打去哪個服務無關
##
## 為什麼要有 Policy 而不是所有呼叫一視同仁：速率限制的兩個數字是為
## **行程重排**訂的（同一隻 Agent 最短 30 秒、每遊戲日 20 次），而對話是逐輪產生、
## 輪與輪之間只隔幾秒。同一組限制套到對話上，第二輪起就會全部回 rate_limited。
##
## 豁免的是**限制**，不是**帳**：對話輪次照樣計數（走 _dialogue_calls_today），
## get_usage() 也照樣報出來。這是刻意的 —— 決策裡「LLM 成本上限」還沒有防護，
## 在訂出上限之前，至少要看得見花了多少。
##
## envelope 的欄位（Step 1 的 prompt_builder.gd 負責組出來）：
##     system          String      系統提示。人格、規則、輸出 schema、動作白名單
##     payload         Dictionary  設計文件那份 JSON 信封，會被字串化成 user 訊息
##     model           String      選填，覆寫設定檔的 model
##     response_format Dictionary  選填，OpenAI 的 json_schema。各模型支援度不一，
##                                 所以預設不帶，由呼叫端自己決定要不要賭
##
## system 與 payload 切成兩塊不是美觀問題，是成本問題：system 幾乎不變，
## 吃得到 provider 的 prompt cache；payload 每次都變。
##
## 金鑰只在 _send() 組 Authorization header 時碰得到。任何要進 log 或
## 回傳給呼叫端的字串都先過 _scrub()。

const POOL_SIZE := 3

## 這次呼叫屬於哪一種，決定要不要吃速率限制。
##
## SCHEDULED   —— 行程重排等由系統自己發動的呼叫。吃冷卻與每日配額
## CONVERSATION —— 對話輪次。玩家等在螢幕前面，而且輪次是秒級間隔，
##                 依 2026-08-05 的決定豁免冷卻與配額（可在設定檔關掉）
## CREATION     —— 建角當下的一次性生成（例如 words_to_creator）。結構上
##                 每個角色一輩子只會打這一次（呼叫端自己用 is_empty()
##                 擋重複觸發），沒有 CONVERSATION 那種「可能被無限次觸發」
##                 的濫用風險，所以直接無條件豁免冷卻與配額，不像
##                 CONVERSATION 需要 dialogue_exempt 開關。成本保護不敞開：
##                 豁免之後另有可設定的每日上限 max_creation_calls_per_game_day
##                 頂著（0＝不限）。不跟 SCHEDULED 共用同一個 requester_id
##                 冷卻池，是因為這通會在行程重排之前搶先打一次，佔掉冷卻
##                 會讓緊接著的第一次行程決策被 ERROR_RATE_LIMITED 同步擋下
##                 （issue #682）
enum Policy { SCHEDULED, CONVERSATION, CREATION, LISTENER }

# 速率限制的數字（同 requester_id 的最短真實間隔、每遊戲日上限，加上對話／
# 建角豁免後各自的每日上限）住在 AIConfig，不在這裡：它們是「花多少錢」的
# 旋鈕，玩家改得到。
#
# 用真實秒不用遊戲時間，因為要擋的是 API 帳單與 provider 的 rate limit，
# 那兩者都活在真實時間裡；掛 requester_id 不掛全域，因為多人版的帳單
# 是逐個 Agent 擁有者分開算的

# 只重試一次。網路抖動一次就好，抖到第二次代表對面真的壞了，
# 這時候讓 Agent 走 fallback 比讓玩家多等一輪好
const RETRY_LIMIT := 1

# provider 的錯誤訊息只留這麼長。留一點有助於 debug（例如「模型名稱不存在」），
# 留太多會把整包 HTML 錯誤頁倒進 log
const MAX_ERROR_CHARS := 200

const ERROR_DISABLED := "disabled"
const ERROR_NO_REQUESTER := "no_requester_id"
const ERROR_NO_PROVIDER := "no_provider"
const ERROR_RATE_LIMITED := "rate_limited"
const ERROR_DAILY_QUOTA := "daily_quota"
const ERROR_TIMEOUT := "timeout"
const ERROR_NETWORK := "network"
const ERROR_HTTP := "http"
const ERROR_BAD_JSON := "bad_json"

# 就緒檢查（issue #345）失敗後，隔幾秒重試一次的等待時間。只救「開場那一刻
# 剛好卡一下」的瞬斷，不是背景輪詢——兩次都失敗就定型成未就緒，之後要
# 重測得靠 reload_config()（debug 主控台的 ai 指令會叫它），不會自己一直重試
const READINESS_RETRY_DELAY_SEC := 3.0

var config: AIConfig

var _pool: Array[HTTPRequest] = []
var _busy := {}					# HTTPRequest -> _Job，沒有 key 就代表這個節點閒著
var _queue: Array = []			# 等節點的 _Job，出隊順序見 _next_job_index()

var _last_call_msec := {}			# requester_id -> Time.get_ticks_msec()，只記受限的呼叫
var _calls_today := {}				# requester_id -> 今天已用的「受限」次數，吃配額
var _dialogue_calls_today := {}		# requester_id -> 今天的對話輪次，只計帳不設限
var _creation_calls_today := {}		# requester_id -> 今天的建角一次性生成次數，只計帳不設限

var _readiness := {}				# provider 名字 -> {"ready": bool, "reason": String}

# 每呼叫一次 _check_readiness_all() 就 +1。reload_config() 可能在上一批探測
# 還在飛的時候又觸發一批新的——舊那批探測回來得比新那批晚時，不能覆蓋新結果，
# 所以每個 _check_provider_readiness() 記住自己出生時的世代，寫回 _readiness
# 前先比對世代還新不新（跟 agent.gd 的決策世代編號同一個防呆手法）
var _readiness_generation := 0

# 這個世代還有幾個 provider 的探測沒回來。世代 -> 剩餘數量，全部回來後
# 那個 key 會被移除並 emit readiness_batch_finished——給需要「探測全部做完
# 才印結果」的呼叫端（debug 主控台 ai 指令）await 用，見 reload_config_and_wait()
var _pending_readiness_count := {}

## _check_readiness_all() 啟動的那一批探測全部有了結果（不管每個 provider
## 本身是就緒還是失敗）時 emit，帶那一批的世代編號。呼叫端 await 這個訊號
## 時要自己比對世代——舊世代可能在等待期間被新一輪 reload_config() 蓋過，
## 見 reload_config_and_wait() 的迴圈
signal readiness_batch_finished(generation: int)


func _ready() -> void:
	reload_config()

	for i in POOL_SIZE:
		var http := HTTPRequest.new()
		http.name = "Request%d" % i
		# 逐 provider 的逾時在 _send() 送出前才設定（不同 provider 可能給
		# 不同的 timeout），這裡先給一個預設值，純粹是建立節點需要填一個初值
		http.timeout = AIConfig.DEFAULT_TIMEOUT
		# 不開執行緒的話 TLS 握手會卡在主執行緒上掉幀
		http.use_threads = true
		add_child(http)
		http.request_completed.connect(_on_request_completed.bind(http))
		_pool.append(http)

	GameClock.day_changed.connect(_on_day_changed)
	# 開新遊戲不是跨日，是整條時間軸歸零重來（#618，CodeRabbit review 抓到）——
	# GameClock.reset_to_new_game_start() 不會發 day_changed（day 可能還是 1，
	# 語意上沒有「跳了一天」），沒有這條的話上一局殘留的每日配額會直接延續
	# 到新的一局，讓新一局一開場就打到 daily_quota
	GameClock.new_game_started.connect(_on_day_changed.bind(0))

	# reload_config() 上面已經呼叫過，裡面自己會觸發 _check_readiness_all()
	# （見該函式），這裡不用再呼叫一次——CodeRabbit review 抓到：原本這裡
	# 多打一次，開機時會送出兩批重複的 /models 請求


 # 玩家寫好 user://ai_config_<hash>.json 之後不必重開遊戲，debug 主控台的 ai 指令會先叫這個。
 # 就緒表也一併重算——這是唯一的手動重測入口。除此之外，
 # game_manager.gd::activate_llm_decision_if_ready() 與
 # main_scene.gd::_apply_startup_ai_state() 在讀到過期的「沒 ready」快照時，
 # 也會事件觸發補打一次 reload_config_and_wait()（issue #728，見各自註解），
 # 同樣不是持續輪詢——「開場瞬斷之外」玩到一半的網路狀態變化（例如玩到
 # 一半才把 llama-server 開起來）仍要靠 debug 主控台 `ai` 指令救回來。
#
# 刻意不 await 這批探測——_ready() 開機時呼叫這個，遊戲啟動不該被網路
# 探測卡住。想等探測全部做完才拿結果的呼叫端（debug 主控台 ai 指令）
# 用 reload_config_and_wait()
func reload_config() -> void:
	config = AIConfig.load_from_user()
	_check_readiness_all()


# reload_config() 的等待版——探測全部做完（不管每個 provider 本身就緒或
# 失敗）才回來，讓呼叫端這時候讀 get_readiness() 才不會撈到上一批舊結果或
# AI_READY_NOT_CHECKED（CodeRabbit review 抓到：debug 主控台的 ai 指令原本
# 呼叫 reload_config() 後立刻印 get_readiness()，探測都還沒回來就先印了）
func reload_config_and_wait() -> void:
	reload_config()

	# 每次迴圈重新讀 _readiness_generation，不要在第一輪就把世代號碼定住——
	# 定住的話，等待期間如果又有一輪 reload_config()（例如玩家很快連下兩次
	# `ai` 指令）把世代蓋過去，這裡等到的會是「舊世代做完了」，回去讀
	# get_readiness() 時新世代可能還在飛，撈到新舊混雜、不一致的結果
	# （CodeRabbit review 抓到）。動態重讀的話，等待期間世代被蓋過時，
	# 下一輪迴圈會自動改成等最新那一批，回傳時保證讀到的是同一批的結果
	while _pending_readiness_count.has(_readiness_generation):
		await readiness_batch_finished


## _ready() 已經在飛的那一批探測做完就回來，不像 reload_config_and_wait()
## 那樣重新觸發一整批新的 /models 請求（#357：main_scene.gd 開場只需要等
## 一次「_ready() 那批」的結果，不需要為了等待就多打一輪重複的網路請求）。
## 沒有任何一批在飛（探測已經做完，或 config 沒啟用因而從沒開始過）時
## 立刻回，不會卡住
func await_readiness_settled() -> void:
	while _pending_readiness_count.has(_readiness_generation):
		await readiness_batch_finished


# 給 #357／debug 主控台查某個 provider 就不就緒。**只有空字串會退回
# default_provider**，跟 AIConfig.get_provider() 同一個規則——名字打錯要讓
# 呼叫端看見「查無此 provider」，不是靜默給錯的狀態
func get_readiness(provider_name: String = "") -> Dictionary:
	var resolved := provider_name if not provider_name.is_empty() else config.default_provider

	# 查無此 provider（拼字錯）跟「這個 provider 存在、只是還沒檢查過」是
	# 兩種不同的錯——前者退到 AI_READY_NOT_CHECKED 的話，打錯字會被誤報成
	# 「還沒檢查」，讓人以為等一下就會有結果，實際上永遠不會有（CodeRabbit
	# review 抓到）
	if not config.providers.has(resolved):
		return {"ready": false, "reason": L10n.tf("AI_READY_PROVIDER_NOT_FOUND", {"name": resolved})}

	return _readiness.get(resolved, {"ready": false, "reason": L10n.t("AI_READY_NOT_CHECKED")})


func _check_readiness_all() -> void:
	_readiness_generation += 1
	var generation := _readiness_generation
	_readiness.clear()

	# config 沒啟用就不用打網路——AIConfig.status_reason 已經講清楚原因，
	# 打了也只會全部落在「設定層失敗」，多一輪網路等待沒有意義。這批探測
	# 等於零個 provider，直接視為「已完成」，不然等這批的呼叫端會永遠等不到
	if not config.enabled:
		readiness_batch_finished.emit(generation)
		return

	var provider_names := config.providers.keys()
	if provider_names.is_empty():
		readiness_batch_finished.emit(generation)
		return

	_pending_readiness_count[generation] = provider_names.size()
	for provider_name in provider_names:
		_check_provider_readiness(provider_name, generation)


# 逐 provider 各自跑，互不等待——local 連不上不該拖累 openrouter 的檢查結果
func _check_provider_readiness(provider_name: String, generation: int) -> void:
	var provider: AIConfig.Provider = config.providers[provider_name]

	if not provider.valid:
		# 設定層失敗（base_url／model 空白）不用打網路就知道，也不用重試——
		# 重試網路請求救不了一個本來就沒填齊的設定
		_apply_readiness(provider_name, generation, _readiness_result(
			false, L10n.tf("AI_READY_CONFIG_INVALID", {"reason": provider.status_reason})
		))
		return

	var outcome := await _probe_models(provider)
	if not outcome["ready"] and outcome.get("retryable", false):
		# 只重試值得重試的失敗——4xx（金鑰錯／模型名打錯）跟逾時再打一次
		# 也不會變好，白等一次 provider.timeout。跟 _interpret() 判斷
		# retryable 的邏輯同一套標準，不要各自一套
		await get_tree().create_timer(READINESS_RETRY_DELAY_SEC).timeout

		# 等待期間可能有新一輪 reload_config() 把這批檢查整批作廢——世代
		# 對不上就不用再打第二次網路請求了，反正 _apply_readiness() 最後也會
		# 丟棄結果，不浪費一次已知會被丟掉的探測。但**不能直接 return**：
		# 這個 provider 對它自己出生時的舊世代而言還是要算「有了結果」，
		# 不然那個舊世代在 _pending_readiness_count 裡的計數永遠不會歸零，
		# 任何還在 await reload_config_and_wait() 那個舊世代的呼叫端會永遠
		# 卡住等不到 readiness_batch_finished（CodeRabbit review 抓到，
		# 原本的 early return 連 _apply_readiness()／_note_readiness_done()
		# 都跳過了）
		if generation == _readiness_generation:
			outcome = await _probe_models(provider)

	_apply_readiness(provider_name, generation, outcome)


# 舊世代的探測結果比新一輪 reload_config() 晚回來時直接丟棄，不寫入
# _readiness——不然「玩到一半重新整理設定」會被更早、已經過期的探測結果蓋回去
func _apply_readiness(provider_name: String, generation: int, outcome: Dictionary) -> void:
	if generation == _readiness_generation:
		_readiness[provider_name] = {"ready": outcome["ready"], "reason": outcome["reason"]}

	# 一定要在真正寫完 _readiness 之後才呼叫——signal 的 emit() 是同步的，
	# await 這個訊號的呼叫端（reload_config_and_wait()）會在 emit() 呼叫的
	# 當下就恢復執行，寫在它前面的話，呼叫端讀到 get_readiness() 時這個
	# provider 的結果根本還沒寫進去，撈到的還是 AI_READY_NOT_CHECKED
	# （這裡曾經寫反過，用 game_eval 實測抓到：signal 正確帶對的世代觸發，
	# 但緊接著讀 get_readiness() 卻是空的）
	_note_readiness_done(generation)


# 一個 provider 的探測有了結果（不管就緒還失敗）就呼叫一次。同一世代的
# provider 全部呼叫過後，這裡才 emit readiness_batch_finished——
# reload_config_and_wait() 靠這個訊號知道「這批全部做完了」
func _note_readiness_done(generation: int) -> void:
	if not _pending_readiness_count.has(generation):
		return
	_pending_readiness_count[generation] -= 1
	if _pending_readiness_count[generation] <= 0:
		_pending_readiness_count.erase(generation)
		readiness_batch_finished.emit(generation)


# 連線層探針：打 GET {base_url}/models。不用《04》§4-1 想像的 /health——
# 那是假設一個自架後端才有的端點，OpenRouter 這類雲端 provider 根本沒有；
# /models 是 OpenAI 相容 API 的標準端點，本機／雲端同一條路徑，還能順便
# 驗證金鑰有效（/health 不驗證 Authorization）
func _probe_models(provider: AIConfig.Provider) -> Dictionary:
	var http := HTTPRequest.new()
	http.timeout = provider.timeout
	http.use_threads = true
	add_child(http)

	var headers := PackedStringArray()
	if not provider.api_key.is_empty():
		headers.append("Authorization: Bearer %s" % provider.api_key)

	var err := http.request(provider.models_url(), headers, HTTPClient.METHOD_GET)
	if err != OK:
		http.queue_free()
		# 「連送都送不出去」（URL 格式錯、節點忙）不是網路往返失敗，跟
		# _send() 的判斷一致：重試同樣送不出去，不值得重試
		return _readiness_result(
			false, L10n.tf("AI_READY_NETWORK", {"url": provider.models_url(), "detail": "request()=%d" % err})
		)

	# HTTPRequest.request_completed 是引擎自己在真正的網路 I/O 完成後才發，
	# 不會在 request() 呼叫的當下同步觸發，所以這裡可以直接 await，不需要
	# _Job.finished 那種 call_deferred 的防呆——那個防呆解的是另一個問題
	# （我們自己手動 emit 的訊號有可能在呼叫端 await 之前就先發生）
	var response: Array = await http.request_completed
	http.queue_free()

	var result: int = response[0]
	var response_code: int = response[1]

	if result == HTTPRequest.RESULT_TIMEOUT:
		# 跟 _interpret() 同一個理由：已經燒掉整個 timeout，重試只是再等一次
		return _readiness_result(false, L10n.tf("AI_READY_TIMEOUT", {"url": provider.models_url()}))
	if result != HTTPRequest.RESULT_SUCCESS:
		# 連不上／握手失敗這種立刻就知道結果的錯，值得重試一次
		return _readiness_result(
			false, L10n.tf("AI_READY_NETWORK", {"url": provider.models_url(), "detail": "result=%d" % result}), true
		)
	if response_code >= 500:
		# 對面自己壞了，重試一次有機會落到健康的機器上
		return _readiness_result(
			false, L10n.tf("AI_READY_HTTP", {"url": provider.models_url(), "code": response_code}), true
		)
	# 只有 2xx 才算就緒——HTTPRequest.RESULT_SUCCESS 只代表網路請求本身
	# 有始有終，不代表 HTTP 狀態碼是成功的。原本只擋 4xx／5xx，1xx（少見但
	# 合法）跟 3xx（重導向，通常代表 base_url 設錯或該服務把 /models
	# 導去別的地方）會落進最後的 return true，被誤報成「就緒」
	# （CodeRabbit review 抓到）。跟 4xx 同一個理由：這種回應重試不會變好
	if response_code < 200 or response_code >= 300:
		return _readiness_result(false, L10n.tf("AI_READY_HTTP", {"url": provider.models_url(), "code": response_code}))

	return _readiness_result(true, L10n.t("AI_READY_OK"))


func _readiness_result(ready: bool, reason: String, retryable: bool = false) -> Dictionary:
	return {"ready": ready, "reason": reason, "retryable": retryable}


# 唯一的對外入口。呼叫端：var result := await AIService.request(envelope, "agent")
#
# policy 決定要不要吃速率限制，預設是「吃」—— 忘了指定的呼叫端會落在比較保守的
# 那一邊，而不是意外地拿到無限額度。provider 是哪個具名 LLM 服務，空字串
# 用設定檔的 default_provider
func request(
	envelope: Dictionary,
	requester_id: String,
	policy: Policy = Policy.SCHEDULED,
	provider_name: String = "",
	is_retry: bool = false,
) -> Dictionary:
	if not config.enabled:
		# 沒設定金鑰是預設狀態不是錯誤，所以安靜地回，不 push_error
		return _fail(ERROR_DISABLED)

	if requester_id.is_empty():
		# 沒有 requester_id 就做不了速率限制。這是呼叫端寫錯，不能默默放行
		push_error("AIService: request() 的 requester_id 不可為空")
		return _fail(ERROR_NO_REQUESTER)

	var provider: AIConfig.Provider = config.get_provider(provider_name)
	if provider == null or not provider.valid:
		# 指定的 provider 不存在，或存在但沒填齊金鑰/端點——都不是呼叫端
		# 能自己判斷的事，交給 AIConfig 那層算好的 valid 旗標
		return _fail(ERROR_NO_PROVIDER)

	# is_retry 只跳過冷卻檢查，不跳過每日配額——同一次決策內的重試是同一份
	# 邏輯請求的延續，不該被自己造成的冷卻擋下（agent.gd::_decide_with_retry()
	# 重試間隔只有幾秒，遠低於預設 30 秒冷卻，SCHEDULED policy 沒有 CONVERSATION
	# 那種豁免，不加這個旗標的話《12》§3.4 要求的重試在 SCHEDULED 路徑上
	# 實際永遠只跑得到 1 次就被 ERROR_RATE_LIMITED 擋死，見 PR #176 review）；
	# 每日配額照樣算，因為重試仍然是真的網路請求，有真的成本
	var limit_error := _check_rate_limit(requester_id, policy, is_retry)
	if not limit_error.is_empty():
		return _fail(limit_error)

	# 配額在「接受」時就扣，不是送出成功才扣。否則同一幀連呼叫 20 次會在
	# 任何一次回來之前全部通過檢查，限制形同虛設
	_note_call(requester_id, policy)

	var job := _Job.new()
	job.envelope = envelope
	job.requester_id = requester_id
	job.provider = provider
	job.policy = policy
	_queue.append(job)
	_pump()

	var result: Dictionary = await job.finished
	return result


# 給 debug 主控台看用量。回傳值刻意都是原始數字，格式化交給呼叫端
func get_usage(requester_id: String) -> Dictionary:
	var elapsed := Time.get_ticks_msec() - int(_last_call_msec.get(requester_id, -999999))
	var calls := int(_calls_today.get(requester_id, 0))
	var dialogue := int(_dialogue_calls_today.get(requester_id, 0))
	var creation := int(_creation_calls_today.get(requester_id, 0))
	return {
		"game_day": GameClock.day,
		"calls_today": calls,
		"max_calls": config.max_calls_per_game_day,
		# 對話輪次、建角一次性生成都不佔配額，但一樣是錢，所以分開報而不是不報
		"dialogue_today": dialogue,
		"max_dialogue": config.max_dialogue_calls_per_game_day,
		"creation_today": creation,
		"max_creation": config.max_creation_calls_per_game_day,
		"total_today": calls + dialogue + creation,
		"dialogue_exempt": config.dialogue_exempt,
		"cooldown_left": maxf(0.0, config.min_interval_sec - elapsed / 1000.0),
		"queued": _queue.size(),
		"in_flight": _busy.size(),
	}


# 豁免的實作點。豁免的是這裡的檢查，不是 _note_call() 的計數（LISTENER 例外，
# 見 _note_call() 說明）。CREATION 無條件豁免（見 Policy 的說明），CONVERSATION
# 依設定檔的 dialogue_exempt 開關。LISTENER（issue #691，聽者的繼續/退出判斷）
# 無條件豁免且完全不計帳——這是對話輪次本身的一部分，不是額外多打一次電話，
# 2026-08-30 拍板「不佔用配額」
func _is_exempt(policy: Policy) -> bool:
	match policy:
		Policy.CONVERSATION:
			return config.dialogue_exempt
		Policy.CREATION, Policy.LISTENER:
			return true
		_:
			return false


func _check_rate_limit(requester_id: String, policy: Policy, skip_cooldown: bool = false) -> String:
	if _is_exempt(policy):
		# CONVERSATION 豁免的是冷卻與「行程重排」那份配額，不是完全不設
		# 上限——對話輪次沒有這條護欄的話，一場對話可以無限輪講下去，成本
		# 無上限（#395 提案，#434 落地）。0 代表不限，跟 max_calls_per_game_day
		# 同一套慣例；用 >= 不用 >，跟下面對 max_calls_per_game_day 的判斷式
		# 一致
		if policy == Policy.CONVERSATION and config.max_dialogue_calls_per_game_day > 0 \
				and int(_dialogue_calls_today.get(requester_id, 0)) >= config.max_dialogue_calls_per_game_day:
			return ERROR_DAILY_QUOTA
		# CREATION 同理：豁免不等於完全不設限。結構上每個角色一輩子只打一次，
		# 但生成失敗時每次開局／投放都會重打（agent.gd／game_manager.gd 的
		# _generate_words_to_creator() 都是 fire-and-forget、不重試也不擋流程），
		# 累積請求數還是要有個能設定的兜底（#434 同一套慣例，0＝不限）
		if policy == Policy.CREATION and config.max_creation_calls_per_game_day > 0 \
				and int(_creation_calls_today.get(requester_id, 0)) >= config.max_creation_calls_per_game_day:
			return ERROR_DAILY_QUOTA
		return ""

	# 0 代表不限。設定檔可以把兩條限制各自關掉
	if not skip_cooldown and config.min_interval_sec > 0.0 and _last_call_msec.has(requester_id):
		var elapsed := Time.get_ticks_msec() - int(_last_call_msec[requester_id])
		if elapsed < int(config.min_interval_sec * 1000.0):
			return ERROR_RATE_LIMITED

	if config.max_calls_per_game_day > 0:
		if int(_calls_today.get(requester_id, 0)) >= config.max_calls_per_game_day:
			return ERROR_DAILY_QUOTA

	return ""


# 豁免的呼叫只計數，不動 _last_call_msec 也不動 _calls_today ——
# 動了的話一輪對話就會把行程重排的冷卻往後推 30 秒或把它的每日配額吃光，
# 建角生成也一樣不該佔用行程重排的冷卻池（issue #682）。「豁免」要是雙向的：
# 不受限，也不佔別人的額度。LISTENER 連計帳都不用——它豁免的不是「限制」，
# 是整個配額概念本身（見 _is_exempt() 說明），沒有對應的每日上限可計
func _note_call(requester_id: String, policy: Policy) -> void:
	if _is_exempt(policy):
		if policy == Policy.CONVERSATION:
			_dialogue_calls_today[requester_id] = int(_dialogue_calls_today.get(requester_id, 0)) + 1
		elif policy == Policy.CREATION:
			_creation_calls_today[requester_id] = int(_creation_calls_today.get(requester_id, 0)) + 1
		return

	_last_call_msec[requester_id] = Time.get_ticks_msec()
	_calls_today[requester_id] = int(_calls_today.get(requester_id, 0)) + 1


# 跨日、或開新遊戲（#618）就把三本帳清掉。日計數在 GameClock，這裡不自己數 ——
# 私有計數重開遊戲會歸零，每日配額就能靠重開遊戲繞過
func _on_day_changed(_day: int) -> void:
	_calls_today.clear()
	_dialogue_calls_today.clear()
	_creation_calls_today.clear()


# 有閒節點就派工。每次有節點空出來都要再叫一次，佇列才不會卡住
func _pump() -> void:
	while not _queue.is_empty():
		var http := _take_idle_node()
		if http == null:
			return
		var job: _Job = _queue.pop_at(_next_job_index())
		_send(http, job)


# 佇列是優先序的不是先進先出：CONVERSATION／LISTENER 先出隊，其餘照進來的
# 順序（#492；LISTENER 見 issue #691）。
#
# 排序只看呼叫端自己標的 Policy，引擎不另外判斷「誰的處境比較急」——那會變成
# 引擎替 AI 認定一個情境算不算一回事（《00》原則二），排序依據也會從「誰在等」
# 悄悄變成「誰重要」。這裡只有前者：CONVERSATION 是玩家停在對話框前面等字出來，
# LISTENER 卡在同一條對話輪次迴圈裡（conversation.gd::_run() 要它的結果才會
# 往下叫 speaker.next_line()），跟 CONVERSATION 同等急迫；SCHEDULED 是背景
# 角色重排行程，晚幾秒沒有人看得出來
#
# 線性掃描不換成優先佇列：長度等於同時在等的角色數，掃一遍比維護一個堆便宜，
# 而且「同優先權內維持進場順序」直接由掃描順序保證，不必另外記進場序號
func _next_job_index() -> int:
	for i in _queue.size():
		if _queue[i].policy == Policy.CONVERSATION or _queue[i].policy == Policy.LISTENER:
			return i
	return 0


func _take_idle_node() -> HTTPRequest:
	for http in _pool:
		if not _busy.has(http):
			return http
	return null


func _send(http: HTTPRequest, job: _Job) -> void:
	_busy[http] = job
	job.attempts += 1

	# 逾時是節點屬性不是逐請求參數，每個 provider 可能給不同的值，
	# 所以送出前才設定，不是節點建立時就固定死
	http.timeout = job.provider.timeout

	# 金鑰空的時候整個標頭不送，不是送一個空的 Bearer：本機 llama-server／
	# ollama 不驗 Authorization，而 `Bearer ` 後面空白在某些伺服器會被當成
	# 「有帶但格式錯」而回 401，比不帶還糟
	var headers := PackedStringArray(["Content-Type: application/json"])
	if not job.provider.api_key.is_empty():
		headers.append("Authorization: Bearer %s" % job.provider.api_key)
	var body := JSON.stringify(_build_body(job.envelope, job.provider))

	var err := http.request(job.provider.completions_url(), headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		# 這是「連送都送不出去」（URL 格式錯、節點還在忙），不是網路往返失敗，
		# 重試同樣送不出去，直接結束這份工作。
		#
		# 一定要先 cancel_request()：request() 即使中途失敗，逾時計時器也已經起跑，
		# 不停掉的話 timeout 秒後會補送一個 request_completed 給一個早就沒工作的
		# 節點，_on_request_completed() 就會噴「收到沒有對應工作的回應」
		http.cancel_request()
		_busy.erase(http)
		_finish(job, _fail("%s(request=%d)" % [ERROR_NETWORK, err]))
		_pump()


func _build_body(envelope: Dictionary, provider: AIConfig.Provider) -> Dictionary:
	var messages := []

	var system := str(envelope.get("system", ""))
	if not system.is_empty():
		messages.append({"role": "system", "content": system})

	# payload 一律字串化成 user 訊息。它裡面可能含玩家打的字，
	# 所以它是資料不是指令 —— 規則寫在 system 那一則裡，兩者不混
	messages.append({
		"role": "user",
		"content": JSON.stringify(envelope.get("payload", {})),
	})

	var body := {
		"model": str(envelope.get("model", provider.model)),
		"messages": messages,
	}

	# 三層保證的第一層。各模型支援度不一，所以只有呼叫端明確要求、
	# 且這個 provider 自己也宣稱支援（AIConfig.Provider.supports_json_schema）
	# 才帶上——不支援的 provider 退到 layer 2（prompt 裡明寫 schema）跟
	# layer 3（AISchema 硬驗證），不送這個容易被直接拒收整包請求的欄位
	if envelope.has("response_format") and provider.supports_json_schema:
		body["response_format"] = envelope["response_format"]

	return body


func _on_request_completed(
	result: int,
	response_code: int,
	_headers: PackedStringArray,
	body: PackedByteArray,
	http: HTTPRequest
) -> void:
	var job: _Job = _busy.get(http)
	_busy.erase(http)

	if job == null:
		# 節點與工作對不起來代表派工邏輯壞了，要看得見，不能吞掉
		push_warning("AIService: 收到沒有對應工作的回應（節點 %s）" % http.name)
		_pump()
		return

	var outcome := _interpret(result, response_code, body)

	if not outcome["ok"] and outcome["retryable"] and job.attempts <= RETRY_LIMIT:
		# 重試不再扣配額：它是同一次邏輯呼叫，扣兩次會讓玩家的每日額度憑空少掉。
		# push_front 只讓它排在同優先權的最前面，不會讓 SCHEDULED 的重試搶到
		# 還在等的 CONVERSATION 前面——見 _next_job_index()
		_queue.push_front(job)
		_pump()
		return

	_finish(job, {"ok": outcome["ok"], "data": outcome["data"], "error": outcome["error"]})
	_pump()


# 把 HTTPRequest 的兩種失敗（傳輸層 result、應用層 response_code）攤平成一種結果，
# 順便決定值不值得重試。多回一個 retryable 欄位，呼叫端看不到
func _interpret(result: int, response_code: int, body: PackedByteArray) -> Dictionary:
	if result == HTTPRequest.RESULT_TIMEOUT:
		# 逾時**不重試**：已經燒掉 10 秒了，再來一次讓呼叫端等 20 秒，
		# 那時候 Agent 早該走 fallback 了。「網路錯誤重試一次」指的是
		# 連不上／握手失敗那種立刻就知道結果的錯
		return _outcome(ERROR_TIMEOUT, false)

	if result != HTTPRequest.RESULT_SUCCESS:
		return _outcome("%s(result=%d)" % [ERROR_NETWORK, result], true)

	var text := body.get_string_from_utf8()

	if response_code >= 500:
		# 對面自己壞了，重試一次有機會落到健康的機器上
		return _outcome("%s_%d %s" % [ERROR_HTTP, response_code, _brief(text)], true)

	if response_code >= 400:
		# 4xx 是請求本身錯了（金鑰無效、模型名打錯、餘額不足），重試只會再錯一次
		return _outcome("%s_%d %s" % [ERROR_HTTP, response_code, _brief(text)], false)

	# 同 AISchema.parse_object 的理由：用實例解析，失敗不讓引擎自己 push_error。
	# 呼叫端收得到 bad_json，該不該吵是它的決定
	var json := JSON.new()
	if json.parse(text) != OK or not json.data is Dictionary:
		# 200 卻不是 JSON 通常是代理伺服器插進來的頁面，重試沒有意義
		return _outcome(ERROR_BAD_JSON, false)

	return {"ok": true, "data": json.data as Dictionary, "error": "", "retryable": false}


# 用 call_deferred 而不是直接 emit。
#
# request() 的流程是「排進佇列 -> _pump() -> await job.finished」，而 _pump() 是
# 同步的：送不出去時（URL 格式錯之類）_send() 會一路同步走到這裡，也就是在呼叫端
# 跑到 await 之前就把訊號發掉，呼叫端接著 await 一個永遠不會再來的訊號而卡死。
#
# 延後到下一個 idle frame 發，就保證不管哪條路徑進來，呼叫端都已經在等了
func _finish(job: _Job, result: Dictionary) -> void:
	job.finished.emit.call_deferred(result)


# 把 provider 的錯誤訊息裁短並洗掉金鑰。金鑰理論上不會出現在回應裡，
# 但這條路徑的終點是 log，所以寧可多洗一次
func _brief(text: String) -> String:
	var scrubbed := _scrub(text).strip_edges()
	if scrubbed.length() > MAX_ERROR_CHARS:
		scrubbed = scrubbed.substr(0, MAX_ERROR_CHARS) + "…"
	return scrubbed


# 洗掉**所有**已知 provider 的金鑰，不是只洗這次呼叫用的那一個——
# 錯誤字串理論上不會含金鑰，但這條路徑的終點是 log，寧可每個都洗一次
func _scrub(text: String) -> String:
	if config == null:
		return text

	var scrubbed := text
	for provider in config.providers.values():
		var api_key: String = (provider as AIConfig.Provider).api_key
		if not api_key.is_empty():
			scrubbed = scrubbed.replace(api_key, "<redacted>")
	return scrubbed


func _outcome(error: String, retryable: bool) -> Dictionary:
	return {"ok": false, "data": {}, "error": error, "retryable": retryable}


# 形狀與 AISchema 的回傳一致，呼叫端只要學一套判斷方式
func _fail(error: String) -> Dictionary:
	return {"ok": false, "data": {}, "error": error}


# 一次呼叫的完整生命週期。用 RefCounted 帶一個 signal，是為了讓 request()
# 能單純地 await 自己那一份工作 —— 服務層共用一個 signal 的話，
# 三個併發請求會互相收到對方的結果
class _Job extends RefCounted:
	signal finished(result: Dictionary)

	var envelope := {}
	var requester_id := ""
	var provider: AIConfig.Provider
	var policy := Policy.SCHEDULED
	var attempts := 0
