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
	UNSUPPORTED_HOST,	# provider host 不支援自拉（非 127.0.0.1／localhost，見 _maybe_launch 防呆）
}

const STARTUP_TIMEOUT_SEC := 30.0
const POLL_INTERVAL_SEC := 1.0
# 子進程叫起後的「還沒被系統回收就先斷氣」觀察窗——用來分辨「這是真的啟動中
# 還在載模型」還是「根本起不來，立刻自己結束」（例如埠被佔用時 llama-server
# 通常會馬上因為 bind 失敗而退出）
const CRASH_CHECK_SEC := 2.0

# 《04》§1 已定案的數值。--parallel 不寫死在這裡——它要對齊 AIService.POOL_SIZE
# （HTTP 請求池大小），組 args 時引用 autoload 的同一份常數，兩邊只寫一份，
# 不會出現「改了池大小忘記改啟動參數」的脫鉤
const SIDECAR_ARGS_TAIL := ["-c", "16000"]

var status: Status = Status.NOT_ATTEMPTED
var status_reason := ""
var _pid := -1


func _ready() -> void:
	_maybe_launch()


# GameManager 收到 WM_CLOSE_REQUEST 負責存檔與 get_tree().quit()，await 期間
# 控制權交回樹上，可能長達數十秒（等的是還在飛的睡眠反思請求，見
# game_manager.gd::_wait_for_sleep_reflections_to_settle()）——autoload 順序
# GameManager 第一、本節點最後，這裡若在同一個通知就同步 OS.kill(_pid)，會把
# GameManager 還在等的服務提前殺掉。改成引擎真的拆樹（EXIT_TREE，存檔完成
# 之後）才收，兩邊不用互相等待的分工不變
#
# 編輯器 Play 模式按 Stop 鍵是強制砍掉整個編輯器子行程，不會走拆樹路徑，
# 子進程因此可能變成孤兒——跟本機遠端 GPU 隧道「機器關機／重開會中止」是
# 同一種已知的開發期限制，沒有更好的解法，留給開發者自己用工作管理員清理
func _exit_tree() -> void:
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
	# sidecar 自拉只支援 IPv4 loopback：--host 與探針 URL 都寫死 127.0.0.1，
	# provider 填了其他 host（例如 [::1]）就算 port 解析對了也連不上——不
	# 靜默錯連，明確標記 UNSUPPORTED_HOST 讓人知道這次不自動啟動；手動開著
	# 的服務不受影響（AIService 照常連它）
	var host := _host_from_url(provider.base_url)
	if host != "127.0.0.1" and host != "localhost":
		status = Status.UNSUPPORTED_HOST
		status_reason = L10n.tf("SIDECAR_UNSUPPORTED_HOST", {"host": host})
		push_warning("[LlamaSidecar] " + status_reason)
		return
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

	# --parallel 對齊 AIService.POOL_SIZE（見 SIDECAR_ARGS_TAIL 的說明）
	var args := PackedStringArray([
		"-m", model_path,
		"--host", "127.0.0.1", "--port", str(port),
		"--parallel", str(AIService.POOL_SIZE),
	])
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

	# 比照 game_manager.gd 的 deadline 寫法（_wait_for_sleep_reflections_to_settle()）：
	# 用 ticks 起點算差值，不用常數累加——一圈實際是 _probe_port() 的 2 秒
	# timeout＋1 秒 sleep，常數累加會讓 STARTUP_TIMEOUT_SEC 名不符實（最壞近
	# 90 秒才放棄）。比照它的 while 條件，每圈開頭重新檢查
	var deadline_msec := Time.get_ticks_msec() + int(STARTUP_TIMEOUT_SEC * 1000.0)
	while Time.get_ticks_msec() < deadline_msec:
		if await _probe_port(port):
			status = Status.READY
			status_reason = L10n.tf("SIDECAR_READY", {"pid": _pid})
			# 補一次就緒套用讓場上 Agent 跟上——AIService 開機那一批探測多半打在
			# sidecar 都還沒起來的時間點，場上 Agent 已被 main_scene.gd::
			# _apply_startup_ai_state() 鎖在排程模式（它只在開機套用一次），
			# activate_llm_decision_if_ready() 又只在存檔還原／debug spawn 呼叫——
			# 沒有人在這個時機重新套用的話，這一局不會有 LLM 決策，正式建置又
			# 停用 debug 主控台，玩家沒有任何救回路徑
			await AIService.reload_config_and_wait()
			_apply_ready_to_agents()
			return
		if not OS.is_process_running(_pid):
			status = Status.CRASHED
			status_reason = L10n.tf("SIDECAR_CRASHED", {"port": port})
			push_warning("[LlamaSidecar] " + status_reason)
			return
		await get_tree().create_timer(POLL_INTERVAL_SEC).timeout

	status = Status.START_TIMEOUT
	status_reason = L10n.tf("SIDECAR_START_TIMEOUT", {"sec": STARTUP_TIMEOUT_SEC})
	push_warning("[LlamaSidecar] " + status_reason)


## sidecar 就緒後的消費端補套用（見 _watch() 就緒分支的說明）：開機套用只在
## main_scene.gd::_apply_startup_ai_state() 跑一次，那時 sidecar 多半還沒起來，
## 場上 Agent 已被關在排程模式，沒有其他消費端會在這個時機重新套用。這裡整批
## 共用一次 reload_config_and_wait()（_watch() 裡已 await 完才進來，不是逐隻
## 各等一次），再對還沒打開 llm_decision_enabled 的 Agent 重跑就緒套用；已經
## 開著的不動——debug 主控台 ai_decision 手動設過的狀態不被這裡蓋掉。
## activate_llm_decision_if_ready() 內部自帶 is_instance_valid 防呆與 readiness
## 判定，這裡不重抄
func _apply_ready_to_agents() -> void:
	var tree := get_tree()
	if tree == null:
		return
	for node in tree.get_nodes_in_group("agents"):
		var agent := node as Agent
		# agents group 只收 Agent（agent.gd::_ready() add_to_group），as 轉型
		# 判空是型別安全慣例（見 debug_console.gd 同款註解）
		if agent == null or agent.llm_decision_enabled:
			continue
		GameManager.activate_llm_decision_if_ready(agent)


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


## 從 provider.base_url 取 host 字面值（不解析 DNS）：[::1] 連括號一起回，
## 一般 host 去掉 :port。_maybe_launch 的防呆用——sidecar 自拉只支援
## 127.0.0.1／localhost 兩種寫法，跟 AIConfig._is_loopback_url() 的字面比對
## 同一套哲學（不做 DNS 解析，只擋最直接的手滑）
static func _host_from_url(url: String) -> String:
	var scheme_index := url.find("://")
	var without_scheme := url.substr(scheme_index + 3) if scheme_index != -1 else url
	var host_port := without_scheme.split("/")[0]
	if host_port.begins_with("["):
		var bracket_index := host_port.find("]")
		return host_port.substr(0, bracket_index + 1) if bracket_index != -1 else host_port
	var colon_index := host_port.rfind(":")
	return host_port.substr(0, colon_index) if colon_index != -1 else host_port


static func _port_from_url(url: String, fallback: int) -> int:
	var scheme_index := url.find("://")
	var without_scheme := url.substr(scheme_index + 3) if scheme_index != -1 else url
	var host_port := without_scheme.split("/")[0]
	# bracket-aware：[::1] 內部的冒號不是 port 分隔——rfind(":") 的位置要比
	# rfind("]") 靠後才可能是 port；無 port 的 URL（http://localhost/v1）沒有
	# 冒號，同樣退回 fallback
	var colon_index := host_port.rfind(":")
	var bracket_index := host_port.rfind("]")
	if colon_index == -1 or (bracket_index != -1 and colon_index < bracket_index):
		return fallback
	var port_text := host_port.substr(colon_index + 1)
	if port_text.is_valid_int():
		return int(port_text)
	return fallback
