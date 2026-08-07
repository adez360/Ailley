extends Node

## 全專案**唯一**碰網路的地方（autoload 名稱 `AIService`）。
##
## 為什麼要是 autoload 而不是每個 Agent 自己帶一個 HTTPRequest：
## 一個 HTTPRequest 節點同時只能跑一個請求。散在各處等於每隻 Agent 自己
## 重寫一次佇列、逾時、重試與速率限制，而且沒有人能統計「這一局總共打了幾次」。
## 集中成一個服務之後，成本上限、金鑰處理、防注入入口都只有一個地方要顧。
##
## 對外只有一個函式，呼叫端一律 await：
##     var result := await AIService.request(envelope, requester_id)
##     # result = {"ok": bool, "data": Dictionary, "error": String}
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

# 同一個 requester_id 兩次呼叫的最短真實間隔。用真實秒不用遊戲時間，
# 因為要擋的是 API 帳單與 provider 的 rate limit，那兩者都活在真實時間裡
const MIN_INTERVAL_SEC := 30.0

# 每個 requester_id 每遊戲日的上限。掛在 requester 而不是全域，
# 是因為多人版的帳單是逐個 Agent 擁有者分開算的
const MAX_CALLS_PER_GAME_DAY := 20

# 只重試一次。網路抖動一次就好，抖到第二次代表對面真的壞了，
# 這時候讓 Agent 走 fallback 比讓玩家多等一輪好
const RETRY_LIMIT := 1

# provider 的錯誤訊息只留這麼長。留一點有助於 debug（例如「模型名稱不存在」），
# 留太多會把整包 HTML 錯誤頁倒進 log
const MAX_ERROR_CHARS := 200

const ERROR_DISABLED := "disabled"
const ERROR_NO_REQUESTER := "no_requester_id"
const ERROR_RATE_LIMITED := "rate_limited"
const ERROR_DAILY_QUOTA := "daily_quota"
const ERROR_TIMEOUT := "timeout"
const ERROR_NETWORK := "network"
const ERROR_HTTP := "http"
const ERROR_BAD_JSON := "bad_json"

var config: AIConfig

var _pool: Array[HTTPRequest] = []
var _busy := {}					# HTTPRequest -> _Job，沒有 key 就代表這個節點閒著
var _queue: Array = []			# 等節點的 _Job，先進先出

var _last_call_msec := {}		# requester_id -> Time.get_ticks_msec()
var _calls_today := {}			# requester_id -> 今天已用次數
var _game_day := 0
var _last_hour := 0


func _ready() -> void:
	reload_config()

	for i in POOL_SIZE:
		var http := HTTPRequest.new()
		http.name = "Request%d" % i
		# 引擎原生逾時，不必自寫計時器
		http.timeout = config.timeout
		# 不開執行緒的話 TLS 握手會卡在主執行緒上掉幀
		http.use_threads = true
		add_child(http)
		http.request_completed.connect(_on_request_completed.bind(http))
		_pool.append(http)

	_last_hour = GameClock.hour
	GameClock.time_changed.connect(_on_time_changed)


# 玩家寫好 user://ai_config.json 之後不必重開遊戲，debug 主控台的 ai 指令會先叫這個
func reload_config() -> void:
	config = AIConfig.load_from_user()
	# 已經在飛的請求沿用舊逾時，下一次才套新值 —— 中途改 timeout 會讓
	# HTTPRequest 的內部計時失去意義
	for http in _pool:
		http.timeout = config.timeout


# 唯一的對外入口。呼叫端：var result := await AIService.request(envelope, "agent")
func request(envelope: Dictionary, requester_id: String) -> Dictionary:
	if not config.enabled:
		# 沒設定金鑰是預設狀態不是錯誤，所以安靜地回，不 push_error
		return _fail(ERROR_DISABLED)

	if requester_id.is_empty():
		# 沒有 requester_id 就做不了速率限制。這是呼叫端寫錯，不能默默放行
		push_error("AIService: request() 的 requester_id 不可為空")
		return _fail(ERROR_NO_REQUESTER)

	var limit_error := _check_rate_limit(requester_id)
	if not limit_error.is_empty():
		return _fail(limit_error)

	# 配額在「接受」時就扣，不是送出成功才扣。否則同一幀連呼叫 20 次會在
	# 任何一次回來之前全部通過檢查，限制形同虛設
	_note_call(requester_id)

	var job := _Job.new()
	job.envelope = envelope
	job.requester_id = requester_id
	_queue.append(job)
	_pump()

	var result: Dictionary = await job.finished
	return result


# 給 debug 主控台看用量。回傳值刻意都是原始數字，格式化交給呼叫端
func get_usage(requester_id: String) -> Dictionary:
	var elapsed := Time.get_ticks_msec() - int(_last_call_msec.get(requester_id, -999999))
	return {
		"game_day": _game_day,
		"calls_today": int(_calls_today.get(requester_id, 0)),
		"max_calls": MAX_CALLS_PER_GAME_DAY,
		"cooldown_left": maxf(0.0, MIN_INTERVAL_SEC - elapsed / 1000.0),
		"queued": _queue.size(),
		"in_flight": _busy.size(),
	}


func _check_rate_limit(requester_id: String) -> String:
	if _last_call_msec.has(requester_id):
		var elapsed := Time.get_ticks_msec() - int(_last_call_msec[requester_id])
		if elapsed < int(MIN_INTERVAL_SEC * 1000.0):
			return ERROR_RATE_LIMITED

	if int(_calls_today.get(requester_id, 0)) >= MAX_CALLS_PER_GAME_DAY:
		return ERROR_DAILY_QUOTA

	return ""


func _note_call(requester_id: String) -> void:
	_last_call_msec[requester_id] = Time.get_ticks_msec()
	_calls_today[requester_id] = int(_calls_today.get(requester_id, 0)) + 1


# GameClock 只有 hour/minute，沒有日計數。hour 只會遞增或從 23 繞回 0，
# 所以「hour 變小」就是跨日。在這裡自己數而不是去 GameClock 加一個 day，
# 是因為 Step 0 的規則是不改變任何既有遊戲行為
func _on_time_changed(hour: int, _minute: int) -> void:
	if hour < _last_hour:
		_game_day += 1
		_calls_today.clear()
	_last_hour = hour


# 有閒節點就派工。每次有節點空出來都要再叫一次，佇列才不會卡住
func _pump() -> void:
	while not _queue.is_empty():
		var http := _take_idle_node()
		if http == null:
			return
		var job: _Job = _queue.pop_front()
		_send(http, job)


func _take_idle_node() -> HTTPRequest:
	for http in _pool:
		if not _busy.has(http):
			return http
	return null


func _send(http: HTTPRequest, job: _Job) -> void:
	_busy[http] = job
	job.attempts += 1

	var headers := PackedStringArray([
		"Content-Type: application/json",
		"Authorization: Bearer %s" % config.api_key,
	])
	var body := JSON.stringify(_build_body(job.envelope))

	var err := http.request(config.completions_url(), headers, HTTPClient.METHOD_POST, body)
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


func _build_body(envelope: Dictionary) -> Dictionary:
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
		"model": str(envelope.get("model", config.model)),
		"messages": messages,
	}

	# 三層保證的第一層。各模型支援度不一，所以只有呼叫端明確要求才帶上
	if envelope.has("response_format"):
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
		# 重試不再扣配額：它是同一次邏輯呼叫，扣兩次會讓玩家的每日額度憑空少掉
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


func _scrub(text: String) -> String:
	if config == null or config.api_key.is_empty():
		return text
	return text.replace(config.api_key, "<redacted>")


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
	var attempts := 0
