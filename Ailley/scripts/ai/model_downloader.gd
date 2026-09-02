class_name ModelDownloader
extends Node

## 首次啟動主動下載本機 AI 執行檔／模型（issue #989）。推翻《16 打包與發布
## 規格書》§1 B3——原決策是「全部塞進安裝包，不做首次啟動另外下載」，理由是
## 走 Steam depot；B7（Steamworks 帳號）短期不可行，2026-09-02 拍板改成遊戲
## 本體自己偵測＋下載。
##
## 不是 autoload——玩家按下「下載本機 AI 模型」才由呼叫端 `ModelDownloader.new()`
## 生一個、`add_child()`、接上 `progress_updated`／`finished` 訊號、呼叫
## `start()`。下載目標路徑沿用 `LlamaSidecar` 已經在用的慣例（`get_sidecar_dir()`
## 等公開介面，這裡不重寫一套路徑邏輯，見 llama_sidecar.gd）。
##
## 下載完成後呼叫 LlamaSidecar.retry_launch()，不用重開遊戲就能接上。
##
## ⚠️ 目前只支援 Windows 自動下載執行檔——llama.cpp release 的 macOS／Linux
## 組建是 .tar.gz，Godot 沒有原生 tar/gzip 解壓能力（ZIPReader 只認 .zip）。
## macOS／Linux 這次先不做自動解壓，is_platform_supported() 會回 false，UI
## 端要顯示「請手動下載安裝」之類的引導，不是這裡的責任。

signal progress_updated(stage: Stage, bytes_downloaded: int, bytes_total: int)
signal finished(ok: bool, reason: String)

enum Stage {
	CHECKING_SPACE,
	DOWNLOADING_BINARY,
	EXTRACTING_BINARY,
	DOWNLOADING_MODEL,
}

# llama.cpp 官方 release（MIT），2026-09-02 查證存在、Windows CPU x64 有對應
# asset。之後升版只需要改這個 tag，不用動下載/解壓邏輯
const LLAMA_CPP_RELEASE_TAG := "b10752"
# GDScript 的 const 只接受編譯期常數表達式，字串 % 格式化（即使兩個運算元
# 都是 const）不算——跟 AIConfig.CONFIG_PATH 用 static var 接 _compute_
# config_path() 同一個理由，這裡也改用 static var 接一個小函式
static var _WINDOWS_BINARY_URL := _compute_windows_binary_url()


static func _compute_windows_binary_url() -> String:
	return (
		"https://github.com/ggml-org/llama.cpp/releases/download/%s/llama-%s-bin-win-cpu-x64.zip"
		% [LLAMA_CPP_RELEASE_TAG, LLAMA_CPP_RELEASE_TAG]
	)

# Qwen2.5-7B-Instruct-GGUF（HuggingFace，Apache-2.0）。2026-09-02 查證：
# Q4_K_M 以上量化版全部是分割檔（-00001-of-0000N.gguf），目前 bundle 的
# llama-server 版本支不支援分割檔直讀還沒測過（見 issue #989）；q3_k_m 是
# 單一檔案，避開這個不確定性，先用它當 v1 的自動下載預設值。之後真的驗證過
# 分割檔可用、且想換更高量化版時，只需要改這裡跟 AIConfig._DEFAULT_LOCAL_MODEL
# 兩個常數，其餘邏輯不用動
const MODEL_FILENAME := "qwen2.5-7b-instruct-q3_k_m.gguf"
static var _MODEL_URL := _compute_model_url()  # 同上，% 格式化不算 const 表達式


static func _compute_model_url() -> String:
	return (
		"https://huggingface.co/Qwen/Qwen2.5-7B-Instruct-GGUF/resolve/main/%s?download=true"
		% MODEL_FILENAME
	)

# 下載失敗（大小對不上／request 失敗）重試上限，比照 AIService.RETRY_LIMIT
# 的既有慣例，不是新發明一套數字
const RETRY_LIMIT := 1

# 主下載請求沒有設 timeout——位元組數連續這麼久沒有進展就視同失敗，
# 由 _process() 的停滯偵測判定
const STALL_TIMEOUT_SEC := 30.0


var _http: HTTPRequest
var _cancelled := false
# _download_to_file() 進場時填上，_process() 靠它們在下載期間每幀回報進度；
# _download_dest 另外讓 cancel() 刪得到寫到一半的檔案
var _progress_stage: Stage = Stage.CHECKING_SPACE
var _expected_size := 0
var _download_dest := ""
# 進度停滯偵測（_process()）用的狀態：上一次看到的位元組數與停滯累計秒數
var _stall_elapsed := 0.0
var _last_bytes := -1


static func is_platform_supported() -> bool:
	# 只有 Windows 的 release asset 是 .zip；macOS／Linux 是 .tar.gz，Godot
	# 的 ZIPReader 解不開，見檔頭說明
	return OS.get_name() == "Windows"


func start() -> void:
	_cancelled = false

	if not is_platform_supported():
		finished.emit(false, "此平台目前不支援自動下載，需要手動安裝")
		return

	progress_updated.emit(Stage.CHECKING_SPACE, 0, 0)
	if not _has_enough_free_space():
		# 這個檢查實際上是「試寫 probe 檔確認 sidecar 目錄寫得進去」，不是
		# 精確的剩餘容量查詢（Godot 沒有跨平台 API），錯誤訊息要跟檢查本身相符
		finished.emit(false, "無法寫入 sidecar 目錄，請檢查權限與磁碟空間")
		return

	var binary_ok := await _download_binary()
	if _cancelled:
		return
	if not binary_ok:
		return  # _download_binary() 已經自己 emit 過 finished

	var model_ok := await _download_model()
	if _cancelled:
		return
	if not model_ok:
		return  # _download_model() 已經自己 emit 過 finished

	_write_model_into_config()
	LlamaSidecar.retry_launch()
	finished.emit(true, "")


func cancel() -> void:
	_cancelled = true
	# 取消就是結束：不管當下在下載什麼（甚至還沒開始），統一在這裡發
	# finished，呼叫端收到就能把 UI 收掉，不用另外監聽別的狀態
	_abort_request("已取消下載")


## 釋放當下這顆 _http、刪掉寫到一半的檔案，並發 finished(false, reason)。
## cancel() 與 _process() 的進度停滯判定共用同一套收尾：cancel_request()
## 之後 request_completed 不保證會發，_download_to_file 裡的 await 不能
## 指望自己醒來善後——直接釋放節點，協程留在掛起狀態（跟既有 cancel
## 行為同一套）
func _abort_request(reason: String) -> void:
	if _http != null and is_instance_valid(_http):
		_http.cancel_request()
		_http.queue_free()
		_http = null
		if not _download_dest.is_empty():
			DirAccess.remove_absolute(_download_dest)
	finished.emit(false, reason)


func _process(delta: float) -> void:
	# 進度輪詢放在這裡而不是下載協程裡：request() 之後主流程就停在
	# await request_completed 上；狀態輪詢迴圈會在 DISCONNECTED 時跳出、
	# 之後才 await 訊號，跟訊號發送時序相衝。_process 每幀照常跑，_http
	# 還活著就回報當下位元組數，順便做停滯偵測——主下載請求沒有設
	# timeout，位元組數持續沒進展就視同失敗，收尾走 _abort_request()
	# （懸掛的 await 跟 cancel() 一樣留著不醒）
	if _http != null:
		var bytes := _http.get_downloaded_bytes()
		progress_updated.emit(_progress_stage, bytes, _expected_size)
		if bytes != _last_bytes:
			_last_bytes = bytes
			_stall_elapsed = 0.0
		else:
			_stall_elapsed += delta
			if _stall_elapsed >= STALL_TIMEOUT_SEC:
				_abort_request("下載停滯（超過 %d 秒沒有任何進展）" % int(STALL_TIMEOUT_SEC))


func _has_enough_free_space() -> bool:
	# Godot 沒有跨平台的「查剩餘磁碟空間」原生 API（DirAccess 只能查檔案
	# 存不存在、目錄底下有什麼，查不到容量）。這裡用「試寫一個小檔案，寫得
	# 進去就當作空間夠」這種保守判斷，不是精確的容量檢查——真的要精確查，
	# Windows 得走 OS.execute() 呼叫 `wmic`/`fsutil` 之類的外部指令，
	# 跨平台一致性差，這次先不做，留給之後真的有人反映「明明有空間卻擋下」
	# 或「空間不夠卻沒擋」再處理
	var sidecar_dir := LlamaSidecar.get_sidecar_dir()
	DirAccess.make_dir_recursive_absolute(sidecar_dir)
	var probe_path := sidecar_dir.path_join(".space_probe")
	var probe := FileAccess.open(probe_path, FileAccess.WRITE)
	if probe == null:
		return false
	# store_string() 回 false 一樣是寫不進去（磁碟滿等），跟 open 失敗
	# 同樣視為空間不足，不能默默吞掉
	var write_ok := probe.store_string("probe")
	probe.close()
	DirAccess.remove_absolute(probe_path)
	return write_ok == OK


## 依序：查 Content-Length → 下載 zip → 解壓到 sidecar/<platform>/ → 刪暫存 zip。
## 回傳 false 時已經自己 emit 過 finished，呼叫端不用重複處理
func _download_binary() -> bool:
	var target_dir := LlamaSidecar.get_sidecar_dir().path_join(LlamaSidecar.get_platform_subdir())
	var zip_path := target_dir.path_join("_download.zip")
	DirAccess.make_dir_recursive_absolute(target_dir)

	var attempt := 0
	while attempt <= RETRY_LIMIT:
		attempt += 1
		var ok := await _download_to_file(
			_WINDOWS_BINARY_URL, zip_path, Stage.DOWNLOADING_BINARY
		)
		if _cancelled:
			return false
		if ok:
			break
		if attempt > RETRY_LIMIT:
			finished.emit(false, "下載 llama-server 執行檔失敗（已重試 %d 次）" % RETRY_LIMIT)
			return false

	progress_updated.emit(Stage.EXTRACTING_BINARY, 0, 0)
	var extract_ok := _extract_zip(zip_path, target_dir)
	DirAccess.remove_absolute(zip_path)
	if not extract_ok:
		finished.emit(false, "解壓 llama-server 執行檔失敗")
		return false

	if not FileAccess.file_exists(target_dir.path_join(LlamaSidecar.get_binary_name())):
		finished.emit(false, "解壓完成，但找不到 llama-server 執行檔本身")
		return false

	return true


func _download_model() -> bool:
	var model_dir := LlamaSidecar.get_sidecar_dir().path_join("models")
	var model_path := model_dir.path_join(MODEL_FILENAME)
	DirAccess.make_dir_recursive_absolute(model_dir)

	var attempt := 0
	while attempt <= RETRY_LIMIT:
		attempt += 1
		var ok := await _download_to_file(_MODEL_URL, model_path, Stage.DOWNLOADING_MODEL)
		if _cancelled:
			return false
		if ok:
			return true
		if attempt > RETRY_LIMIT:
			finished.emit(false, "下載模型檔失敗（已重試 %d 次）" % RETRY_LIMIT)
			return false
	return false


## 通用下載：先 HEAD 查 Content-Length（沒查到就跳過大小核對，不當硬錯誤），
## 再用 download_file 直接串流寫檔，_process() 期間輪詢位元組數發 progress_updated。
## 完成後比對實際檔案大小跟 Content-Length，對不上視為下載不完整
func _download_to_file(url: String, dest_path: String, stage: Stage) -> bool:
	# stage 與 expected size 存進成員變數，進度由 _process() 輪詢發出，
	# 這裡只負責送出請求後等結果
	_progress_stage = stage
	_download_dest = dest_path
	var expected_size := await _fetch_content_length(url)
	_expected_size = expected_size
	# cancel() 若在 HEAD 進行中打到，這個協程仍會被 HEAD 完成喚醒——
	# 醒來後不要再開主下載，直接比照取消路徑返回（_http 還沒建立、暫存
	# 檔還不存在，沒有東西要清；finished 由 cancel() 統一發）
	if _cancelled:
		return false

	_http = HTTPRequest.new()
	_http.use_threads = true
	_http.download_file = dest_path
	add_child(_http)
	# 每次請求重置停滯計時，不留上一次嘗試的殘值
	_last_bytes = -1
	_stall_elapsed = 0.0

	var err := _http.request(url)
	if err != OK:
		_http.queue_free()
		_http = null
		return false

	var response: Array = await _http.request_completed
	var result: int = response[0]
	var response_code: int = response[1]
	# cancel() 可能已經釋放節點並清掉 _http（訊號若在釋放前發出，這段
	# 協程仍會被喚醒），別對已釋放的節點再 queue_free 一次
	if _http != null and is_instance_valid(_http):
		_http.queue_free()
		_http = null

	if result != HTTPRequest.RESULT_SUCCESS or response_code < 200 or response_code >= 300:
		DirAccess.remove_absolute(dest_path)
		return false

	if expected_size > 0:
		# 只取長度不讀內容——get_file_as_bytes() 會把整份幾 GB 的模型
		# 讀進記憶體，數個大小不需要這樣
		var downloaded := FileAccess.open(dest_path, FileAccess.READ)
		if downloaded == null:
			# 檔案開不出來就無從確認下載完整，比照大小對不上處理
			DirAccess.remove_absolute(dest_path)
			return false
		var actual_size := downloaded.get_length()
		downloaded.close()
		if actual_size != expected_size:
			DirAccess.remove_absolute(dest_path)
			return false

	return true


## 輕量 HEAD 請求查 Content-Length，查不到（逾時／伺服器不支援 HEAD）回 -1，
## 呼叫端當「不核對大小」處理，不當成下載失敗——核對是額外的保險，不是
## 下載能不能進行的必要條件
func _fetch_content_length(url: String) -> int:
	var head := HTTPRequest.new()
	head.use_threads = true
	head.timeout = 10.0
	add_child(head)

	var err := head.request(url, PackedStringArray(), HTTPClient.METHOD_HEAD)
	if err != OK:
		head.queue_free()
		return -1

	var response: Array = await head.request_completed
	head.queue_free()

	if int(response[0]) != HTTPRequest.RESULT_SUCCESS:
		return -1

	var headers: PackedStringArray = response[2]
	for header in headers:
		if header.to_lower().begins_with("content-length:"):
			var value := header.split(":", true, 1)[1].strip_edges()
			if value.is_valid_int():
				return int(value)
	return -1


## 把 zip 裡的每個檔案原樣放進 target_dir——llama.cpp release zip 目前是
## 檔案直接在根目錄、沒有多包一層資料夾（2026-09-02 對照本機一份手動下載的
## 同款 zip 內容確認過），這裡防呆一下：如果所有項目確實共用同一個最外層
## 資料夾名稱，先扒掉那層再落地，避免哪天上游改了打包方式就整層資料夾錯位
func _extract_zip(zip_path: String, target_dir: String) -> bool:
	var reader := ZIPReader.new()
	if reader.open(zip_path) != OK:
		return false

	var paths := reader.get_files()
	if paths.is_empty():
		reader.close()
		return false

	var common_prefix := _common_top_level_folder(paths)

	for path in paths:
		if path.ends_with("/"):
			continue  # 目錄項目，不用手動建立，下面用檔案路徑自動建立父層
		var relative := path.substr(common_prefix.length()) if not common_prefix.is_empty() else path
		if relative.is_empty():
			continue
		var out_path := target_dir.path_join(relative)
		# zip-slip 防呆：zip 內條目名可能夾帶「..」，不解驗就 path_join 會
		# 寫出 target_dir 之外。simplify_path() 後對照目標目錄前綴，越界整包拒解
		if not out_path.simplify_path().begins_with(target_dir.simplify_path().path_join("")):
			reader.close()
			return false
		DirAccess.make_dir_recursive_absolute(out_path.get_base_dir())
		var out_file := FileAccess.open(out_path, FileAccess.WRITE)
		if out_file == null:
			reader.close()
			return false
		out_file.store_buffer(reader.read_file(path))
		out_file.close()

	reader.close()
	return true


## 所有項目是不是都共用同一個最外層資料夾（例如 "llama-b10752/xxx.exe"）——
## 是的話回傳那個資料夾名稱＋"/"，之後解壓時扒掉；不是（檔案直接在根目錄）
## 就回傳空字串
func _common_top_level_folder(paths: PackedStringArray) -> String:
	if paths.is_empty():
		return ""
	var first_slash := paths[0].find("/")
	if first_slash == -1:
		return ""
	var candidate := paths[0].substr(0, first_slash + 1)
	for path in paths:
		if not path.begins_with(candidate):
			return ""
	return candidate


## 下載成功後，把 ai_config.json 的 local provider 指到剛落地的檔名——玩家
## 不用自己編輯 JSON。沿用 AIConfig 既有的讀寫介面，不直接戳 FileAccess
## 重寫一套
func _write_model_into_config() -> void:
	var config := AIConfig.load_from_user()
	var local_provider: AIConfig.Provider = config.get_local_provider()
	if local_provider == null:
		# 沒有本機 provider 可寫（例如玩家的 ai_config.json 被手動改壞、拿掉
		# 了 local 這個 key）——下載本身還是成功的，只是接不回設定檔，
		# push_warning 記下來，不當成整個下載流程失敗
		push_warning(
			"ModelDownloader: 下載成功，但 ai_config.json 裡沒有本機 provider 可以寫入，"
			+ "需要手動設定"
		)
		return
	if not AIConfig.update_provider_model(local_provider.name, MODEL_FILENAME):
		push_warning("ModelDownloader: 下載成功，但寫回 ai_config.json 失敗")
