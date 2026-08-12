class_name VillageSimClient
extends RefCounted

## poc_village_sim/server.py 的最小 HTTP 客戶端——transport 層第一步驗證用。
##
## 只做一件事：送一個角色的「當下情境」，拿回 server.py 的 /decide 決策 JSON。
## 不做世界狀態管理、不做速率限制、不走 AIService。
##
## 為什麼不走 AIService：AIService 是為 OpenRouter 這類雲端付費呼叫設計的
## envelope（system/payload/model）+ 節流（冷卻、每日配額）機制，這支打的是
## 地端免費服務（server.py 內部再轉呼叫 llama-server），呼叫模式跟成本結構
## 完全不同，套用同一套節流沒有意義。要不要走獨立 Python 後端這個架構問題
## 還沒定案，見 note/40-規劃與路線圖/討論草稿 - AI決策要不要走獨立後端.md，
## 這支只負責「送出去、收回來」，不預設任何架構立場。
##
## server.py 的 /decide 目前綁死 POC 固定的 5 人名單（character_id 只接受
## alan/zhou/mei/tie/aji），不是 Godot 端真正的 UUID character_id——用這支
## 測試連線可以，還不能拿真的 Godot NPC 直接餵進去。
##
## 用法：
##     var client := VillageSimClient.new()
##     var result := await client.decide(base_url, payload)
##     # result = {"ok": bool, "data": Dictionary, "error": String}

const DEFAULT_TIMEOUT := 30.0

const ERROR_REQUEST_FAILED := "request_failed"
const ERROR_NETWORK := "network"
const ERROR_HTTP := "http"
const ERROR_BAD_JSON := "bad_json"


## payload 的形狀對照 poc_village_sim/server.py 的 DecideRequest：
##     character_id     String（必填，見上方限制）
##     current_time      String（必填，例如「第 3 天 19:40（夜晚）」）
##     location          String（必填，須在 /locations 回傳的清單內）
##     visible           Array[{"id": String, "activity": String}]（選填，預設空陣列）
##     recent_event      String（選填）
##     last_emotion      String（選填，預設 "neutral"）
##     current_goal      String（選填，上一輪的目標，沒有就空字串）
##     last_action_result String（選填）
##     recent_memory     String（選填）
func decide(base_url: String, payload: Dictionary, timeout: float = DEFAULT_TIMEOUT) -> Dictionary:
	var tree := Engine.get_main_loop() as SceneTree
	var http := HTTPRequest.new()
	http.timeout = timeout
	http.use_threads = true
	tree.root.add_child(http)

	var headers := PackedStringArray(["Content-Type: application/json"])
	var body := JSON.stringify(payload)
	var url := base_url.rstrip("/") + "/decide"

	var err := http.request(url, headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		# 送都送不出去（URL 格式錯、逾時設定不合法），不是網路往返失敗
		http.queue_free()
		return _fail("%s(%d)" % [ERROR_REQUEST_FAILED, err])

	var response: Array = await http.request_completed
	http.queue_free()

	var result: int = response[0]
	var response_code: int = response[1]
	var response_body: PackedByteArray = response[3]

	if result != HTTPRequest.RESULT_SUCCESS:
		return _fail("%s(result=%d)" % [ERROR_NETWORK, result])

	var text := response_body.get_string_from_utf8()

	if response_code >= 400:
		# server.py 用 HTTPException 回傳 4xx 時，detail 欄位是實際錯誤原因
		# （例如「未知的 location」），裁短避免整包 log 太長
		return _fail("%s_%d %s" % [ERROR_HTTP, response_code, text.substr(0, 300)])

	var json := JSON.new()
	if json.parse(text) != OK or not json.data is Dictionary:
		return _fail(ERROR_BAD_JSON)

	return {"ok": true, "data": json.data as Dictionary, "error": ""}


func _fail(error: String) -> Dictionary:
	return {"ok": false, "data": {}, "error": error}
