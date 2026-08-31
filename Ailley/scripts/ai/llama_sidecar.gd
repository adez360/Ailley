extends Node

## 開機自動拉起隨遊戲附帶的 llama-server sidecar（issue #772，《16 打包與發布
## 規格書》§2.2）。autoload，跟 AIService 分開——這裡只負責「把子進程叫起來、
## 盯著它有沒有活著」，真正的 HTTP 就緒探測仍然是 AIService._probe_models()
## 那一套，不重寫第二份（scripts/ai/ 是全專案唯一碰網路的地方，但同一件事
## 只該有一個實作）。
##
## 只在至少一個已設定的 provider 指向本機 loopback 位址時才嘗試拉起——玩家
## 只用雲端 provider 時不需要，也不該平白多開一個背景進程（見
## AIConfig.has_local_provider()）。
##
## 失敗要有動靜、不能悄悄卡住（《16》§2.2 驗收底線）：執行檔或模型檔遺失、
## 連接埠已被佔用、啟動逾時，三種情況都 push_warning 到 log 並記進
## status/status_reason，不擋主執行緒、不讓遊戲卡死或無提示閃退——找不到
## 就跳過自動拉起，玩家原本就可以自己手動啟動 llama-server 再用 debug 主控台
## 的 `ai` 指令重新連線，跟現行「AI 設定不完整就退回排程模式」的既有容錯
## 行為一致，這裡不另外發明一套彈窗通知機制（正式版的玩家可見 AI 狀態
## UI 是 #356 的範圍，不是這裡）。
##
## 目錄慣例（issue #772 開工時拍板，尚未有實體檔案進版控——執行檔／模型檔
## 由開發者自己放進來測試，見 note/技術/LLM Sidecar 啟動.md）：
##   res://sidecar/<platform>/llama-server[.exe]　　（platform: windows/macos/linux）
##   res://sidecar/models/<model 檔名>　　（檔名取 provider.model，跟 ai_config.json 對齊）
## 之後真的要切 Steam depot（《16》B4）時，整個 sidecar/ 目錄就是預定的
## depot content root，這裡先不用为了那一步改路徑。

enum Status {
	NOT_ATTEMPTED,		# 沒有本機 provider，這次開機不需要 sidecar
	LAUNCHING,		# 子進程已叫起、還在等它應答
	READY,			# 子進程活著且撐過起跳的觀察窗（真正能不能對話仍看 AIService 探測）
	ALREADY_RUNNING,	# 開叫之前就偵測到目標埠已有服務在跑，沿用不重複啟動
	MISSING_BINARY,
	MISSING_MODEL,
	LAUNCH_FAILED,		# OS.create_process() 本身失敗（回傳 -1）
	CRASHED,		# 叫起來了，但撐不過起跳觀察窗就自己結束
	START_TIMEOUT,		# 撐過起跳觀察窗、活著，但 STARTUP_TIMEOUT_SEC 內探測不到回應
}

const STARTUP_TIMEOUT_SEC := 30.0
const POLL_INTERVAL_SEC := 1.0
# 子進程叫起後的「還沒被系統回收就先斷氣」觀察窗——用來分辨「這是真的啟動中
# 還在載模型」還是「根本起不來，立刻自己結束」（例如埠被佔用時 llama-server
# 通常會馬上因為 bind 失敗而退出）
const CRASH_CHECK_SEC := 2.0

const SIDECAR_ARGS_TAIL := ["--parallel", "3", "-c", "16000"]	# 《04》§1 已定案的數值

var status: Status = Status.NOT_ATTEMPTED
var status_reason := ""
var _pid := -1


func _ready() -> void:
	_maybe_launch()


func _notification(what: int) -> void:
	# 跟 game_manager.gd 同一個通知，各自獨立處理——那邊負責存檔跟呼叫
	# get_tree().quit()，這裡只負責在引擎真的要關之前先收掉子進程，不用互相
	# 等待。編輯器 Play 模式按 Stop 鍵是強制砍掉整個編輯器子行程，不會走
	# 這條通知，子進程因此可能變成孤兒——跟本機遠端 GPU 隧道「機器關機／
	# 重開會中止」是同一種已知的開發期限制，沒有更好的解法，留給開發者自己
	# 用工作管理員清理
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_shutdown()


func _shutdown() -> void:
	if _pid != -1 and OS.is_process_running(_pid):
		OS.kill(_pid)


func _maybe_launch() -> void:
	var config := AIConfig.load_from_user()
	if not config.has_local_provider():
		status = Status.NOT_ATTEMPTED
		status_reason = ""
		return

	var provider: AIConfig.Provider = config.get_local_provider()
	var port := _port_from_url(provider.base_url, 8080)
	var sidecar_dir := _sidecar_dir()
	var binary_path := sidecar_dir.path_join(_platform_subdir()).path_join(_binary_name())
	var model_path := sidecar_dir.path_join("models").path_join(provider.model)

	if await _probe_port(port):
		status = Status.ALREADY_RUNNING
		status_reason = L10n.tf("SIDECAR_ALREADY_RUNNING", {"port": port})
		return

	if not FileAccess.file_exists(binary_path):
		status = Status.MISSING_BINARY
		status_reason = L10n.tf("SIDECAR_MISSING_BINARY", {"path": binary_path})
		push_warning("[LlamaSidecar] " + status_reason)
		return

	if not FileAccess.file_exists(model_path):
		status = Status.MISSING_MODEL
		status_reason = L10n.tf("SIDECAR_MISSING_MODEL", {"path": model_path})
		push_warning("[LlamaSidecar] " + status_reason)
		return

	var args := PackedStringArray(["-m", model_path, "--host", "127.0.0.1", "--port", str(port)])
	args.append_array(PackedStringArray(SIDECAR_ARGS_TAIL))

	_pid = OS.create_process(binary_path, args, false)
	if _pid == -1:
		status = Status.LAUNCH_FAILED
		status_reason = L10n.tf("SIDECAR_LAUNCH_FAILED", {"path": binary_path})
		push_warning("[LlamaSidecar] " + status_reason)
		return

	status = Status.LAUNCHING
	_watch(port)


func _watch(port: int) -> void:
	await get_tree().create_timer(CRASH_CHECK_SEC).timeout
	if not OS.is_process_running(_pid):
		status = Status.CRASHED
		status_reason = L10n.tf("SIDECAR_CRASHED", {"port": port})
		push_warning("[LlamaSidecar] " + status_reason)
		return

	var elapsed := CRASH_CHECK_SEC
	while elapsed < STARTUP_TIMEOUT_SEC:
		if await _probe_port(port):
			status = Status.READY
			status_reason = L10n.tf("SIDECAR_READY", {"pid": _pid})
			# 補一次探測讓狀態列跟上——AIService 開機那一批探測多半打在 sidecar
			# 都還沒起來的時間點，靠這裡的成功時機重打一次，玩家不用自己
			# 到 debug 主控台打 `ai` 才看得到「AI 決策中」
			AIService.reload_config()
			return
		if not OS.is_process_running(_pid):
			status = Status.CRASHED
			status_reason = L10n.tf("SIDECAR_CRASHED", {"port": port})
			push_warning("[LlamaSidecar] " + status_reason)
			return
		await get_tree().create_timer(POLL_INTERVAL_SEC).timeout
		elapsed += POLL_INTERVAL_SEC

	status = Status.START_TIMEOUT
	status_reason = L10n.tf("SIDECAR_START_TIMEOUT", {"sec": STARTUP_TIMEOUT_SEC})
	push_warning("[LlamaSidecar] " + status_reason)


## 輕量 HTTP 探針：只看連不連得上，不驗證回應內容——AIService._probe_models()
## 才是「這個 provider 真的能用」的正式判定，這裡只回答「這個埠有沒有東西在聽」
func _probe_port(port: int) -> bool:
	var http := HTTPRequest.new()
	http.timeout = 2.0
	http.use_threads = true
	add_child(http)

	var err := http.request("http://127.0.0.1:%d/v1/models" % port, PackedStringArray(), HTTPClient.METHOD_GET)
	if err != OK:
		http.queue_free()
		return false

	var response: Array = await http.request_completed
	http.queue_free()
	var result: int = response[0]
	return result == HTTPRequest.RESULT_SUCCESS


func _sidecar_dir() -> String:
	# 編輯器 Play 模式：OS.get_executable_path() 指到 Godot 編輯器本體，不是
	# 這個專案，得改用專案目錄本身，才能讓開發者直接把測試用的執行檔／模型檔
	# 放進 res://sidecar/ 就地測試；匯出版才用「執行檔旁邊」這個慣例
	if OS.has_feature("editor"):
		return ProjectSettings.globalize_path("res://sidecar")
	return OS.get_executable_path().get_base_dir().path_join("sidecar")


func _platform_subdir() -> String:
	match OS.get_name():
		"Windows":
			return "windows"
		"macOS":
			return "macos"
		_:
			return "linux"


func _binary_name() -> String:
	return "llama-server.exe" if OS.get_name() == "Windows" else "llama-server"


static func _port_from_url(url: String, fallback: int) -> int:
	var scheme_index := url.find("://")
	var without_scheme := url.substr(scheme_index + 3) if scheme_index != -1 else url
	var host_port := without_scheme.split("/")[0]
	var parts := host_port.split(":")
	if parts.size() >= 2 and parts[1].is_valid_int():
		return int(parts[1])
	return fallback
