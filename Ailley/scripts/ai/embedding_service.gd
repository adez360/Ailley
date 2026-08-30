extends Node

## L3 語意檢索的 embedding 用戶端（autoload 名稱 `EmbeddingService`，issue #571，
## 《03 事件評估與記憶》§7）。
##
## 跟 AIService 分開是刻意的：AIService 打的是玩家自己選的聊天 provider（Local／
## Cloud 二選一，見 AIConfig.providers），而這裡永遠打**本機**的 embedding-only
## `llama-server --embedding --pooling cls`，跟玩家選了哪個聊天 provider 無關——
## 把 NPC 記憶內容送出去做語意檢索這件事，不該因為玩家選了雲端聊天 provider
## 就跟著送去雲端。正式環境這支 embedding server 跟遊戲本體同機（localhost），
## 不是一次網路呼叫。
##
## 自己讀一份 AIConfig（見 _ready()/reload_config()），不借用 AIService.config——
## embedding 的設定面（AIConfig.embedding_base_url 等）本來就跟 providers 字典
## 平行、互相獨立，讀 AIService.config 只會製造兩個 autoload 之間不必要的
## 初始化順序依賴，對這裡完全沒有好處。
##
## 呼叫頻率遠低於 AIService（見《03》§7 觸發時機表：不是每 tick，只在角色遇到
## 新面孔／新地點／天神之石／睡眠反思這幾個情境變化點才打一次，外加 L3 候選
## 記憶產生時各打一次），所以不需要 AIService 那一整套節點池／佇列／速率限制——
## 每次呼叫各自建一個 HTTPRequest 節點，用完即丟。
##
## 對外只有一個函式：
##     var embedding := await EmbeddingService.request_embedding("<text>")
##     # 失敗（未設定／逾時／連不上／回應格式不對）一律回傳空的 PackedFloat32Array
##
## 軟失敗設計：這裡不 push_error、不丟例外。呼叫端（Memory.search_l3()／
## Memory._embed_l3_entry()）看到空陣列就當作「這次沒有語意檢索結果」，
## 退回《03》§7 的兜底句，不是讓整個決策迴圈掛掉——embedding server 沒開
## 是玩家還沒把它跑起來的正常狀態，不是程式錯誤，跟 AIConfig 對「設定檔不存在」
## 的態度一致。

var _config: AIConfig


func _ready() -> void:
	reload_config()


## 跟 AIService.reload_config() 同一個理由：玩家改了 user://ai_config_<hash>.json
## 的 embedding 區塊之後不必重開遊戲
func reload_config() -> void:
	_config = AIConfig.load_from_user()


## text 為空、或設定沒填齊時直接回空陣列，不送出一次注定失敗的請求
func request_embedding(text: String) -> PackedFloat32Array:
	if text.is_empty() or _config == null or _config.embedding_base_url.is_empty():
		return PackedFloat32Array()

	var http := HTTPRequest.new()
	http.timeout = _config.embedding_timeout
	http.use_threads = true
	# 停用重導向：_config.embedding_base_url 已經過 loopback 檢查，但沒擋住
	# loopback 伺服器自己回 301/302/303 把請求導去遠端網址——HTTPRequest 預設
	# max_redirects=8 會照走，等於繞過前面那層 loopback 驗證
	http.max_redirects = 0
	add_child(http)

	var headers := PackedStringArray(["Content-Type: application/json"])
	# model 要帶進請求（CodeRabbit review 抓到）：先前只送 input，設定檔裡的
	# embedding.model 存了卻沒用到，改 model 完全不會影響實際打的請求——
	# llama-server --embedding 單模型模式下忽略這個欄位也能正常運作，但一旦
	# 換成多模型的 embedding 服務，AIConfig.embedding_model 這個設定就是死的
	var body := JSON.stringify({"input": text, "model": _config.embedding_model})

	var err := http.request(_config.embedding_base_url + "/embeddings", headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		# 連送都送不出去（URL 格式錯、節點忙）—— 這裡沒有節點池要顧，
		# 直接釋放節點、回空結果即可
		http.queue_free()
		return PackedFloat32Array()

	var response: Array = await http.request_completed
	http.queue_free()

	var result: int = response[0]
	var response_code: int = response[1]
	var raw_body: PackedByteArray = response[3]

	if result != HTTPRequest.RESULT_SUCCESS or response_code < 200 or response_code >= 300:
		return PackedFloat32Array()

	var json := JSON.new()
	if json.parse(raw_body.get_string_from_utf8()) != OK or not json.data is Dictionary:
		return PackedFloat32Array()

	var data: Dictionary = json.data as Dictionary
	var items: Variant = data.get("data", [])
	if not (items is Array) or (items as Array).is_empty():
		return PackedFloat32Array()

	var first: Variant = (items as Array)[0]
	if not (first is Dictionary):
		return PackedFloat32Array()

	var raw_embedding: Variant = (first as Dictionary).get("embedding", [])
	if not (raw_embedding is Array):
		return PackedFloat32Array()

	# 逐項驗證型別，任何一項不是數字就整批視為格式錯誤——半吊子的 embedding
	# 參與 cosine 相似度計算沒有意義，寧可整批當失敗處理
	var embedding := PackedFloat32Array()
	for v in (raw_embedding as Array):
		if not (v is float or v is int):
			return PackedFloat32Array()
		embedding.append(float(v))

	return embedding
