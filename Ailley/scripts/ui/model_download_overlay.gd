class_name ModelDownloadOverlay
extends CanvasLayer

## issue #989：下載本機 AI 模型的進度畫面。純程式建樹、不掛 .tscn——跟
## onboarding_hint.gd 同一個理由，這種簡單的置中面板用程式碼生成比另開一份
## 場景檔划算，不需要走 godot-ai MCP 場景操作那套規定流程（見 Ailley/CLAUDE.md
## 「純 GDScript 邏輯可以直接 Edit」那條例外）。
##
## 呼叫端只需要 `add_child(ModelDownloadOverlay.new())`，其餘（建 UI、生
## ModelDownloader、接訊號、開始下載）都在 _ready() 自己完成，呼叫端不用
## 知道 ModelDownloader 的存在。

const PANEL_WIDTH := 280

var _downloader: ModelDownloader
var _stage_label: Label
var _progress_bar: ProgressBar
var _close_button: Button
var _cancel_button: Button


func _ready() -> void:
	# 全專案 CanvasLayer 慣例（2026-09-02 實機查證）：一般 UI=1、Pause=10、
	# 小型彈出選單（CorpseMenu/GiveMenu/PersuadeDialog/TipMenu）=20、
	# CharacterCreate=80（目前最高）。這個 overlay 是從 CharacterCreate
	# 面板觸發的，非得蓋在它上面才看得到，90 留出安全邊界給之後可能更高
	# 的彈窗，不是隨便挑的數字
	layer = 90
	_build_ui()

	if not ModelDownloader.is_platform_supported():
		_show_terminal_state(false, L10n.t("UI_MODEL_DOWNLOAD_UNSUPPORTED"))
		return

	_downloader = ModelDownloader.new()
	add_child(_downloader)
	_downloader.progress_updated.connect(_on_progress_updated)
	_downloader.finished.connect(_on_finished)
	_downloader.start()


func _build_ui() -> void:
	var scrim := ColorRect.new()
	scrim.color = Color(0, 0, 0, 0.55)
	scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	scrim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(scrim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	scrim.add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(PANEL_WIDTH, 0)
	var style := StyleBoxFlat.new()
	style.bg_color = Color("#FAF3E8")  # Cream，見 note/技術/UI 版面與素材規格.md 調色盤
	style.border_color = Color("#2F2522")  # Bark
	style.set_border_width_all(2)
	style.set_content_margin_all(10)
	panel.add_theme_stylebox_override("panel", style)
	center.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	panel.add_child(vbox)

	var title := Label.new()
	title.text = "UI_MODEL_DOWNLOAD_TITLE"
	title.add_theme_color_override("font_color", Color("#2F2522"))
	vbox.add_child(title)

	_stage_label = Label.new()
	_stage_label.text = ""
	_stage_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	_stage_label.add_theme_color_override("font_color", Color("#2F2522"))
	vbox.add_child(_stage_label)

	_progress_bar = ProgressBar.new()
	_progress_bar.min_value = 0
	_progress_bar.max_value = 1
	_progress_bar.value = 0
	_progress_bar.show_percentage = true
	vbox.add_child(_progress_bar)

	var button_row := HBoxContainer.new()
	vbox.add_child(button_row)

	_cancel_button = Button.new()
	_cancel_button.text = "UI_MODEL_DOWNLOAD_CANCEL"
	_cancel_button.pressed.connect(_on_cancel_pressed)
	button_row.add_child(_cancel_button)

	_close_button = Button.new()
	_close_button.text = "UI_MODEL_DOWNLOAD_CLOSE"
	_close_button.visible = false
	_close_button.pressed.connect(queue_free)
	button_row.add_child(_close_button)


func _on_progress_updated(stage: ModelDownloader.Stage, bytes_downloaded: int, bytes_total: int) -> void:
	_stage_label.text = _stage_text(stage)
	if bytes_total > 0:
		_progress_bar.max_value = bytes_total
		_progress_bar.value = bytes_downloaded
		_progress_bar.show_percentage = true
	else:
		# 查不到 Content-Length（例如 HEAD 被擋）或還在檢查磁碟空間這種
		# 沒有總量概念的階段——顯示跑滿但不給百分比，至少讓玩家知道有在動，
		# 不是卡死
		_progress_bar.max_value = 1
		_progress_bar.value = 1
		_progress_bar.show_percentage = false


func _stage_text(stage: ModelDownloader.Stage) -> String:
	match stage:
		ModelDownloader.Stage.CHECKING_SPACE:
			return L10n.t("UI_MODEL_DOWNLOAD_STAGE_SPACE")
		ModelDownloader.Stage.DOWNLOADING_BINARY:
			return L10n.t("UI_MODEL_DOWNLOAD_STAGE_BINARY")
		ModelDownloader.Stage.EXTRACTING_BINARY:
			return L10n.t("UI_MODEL_DOWNLOAD_STAGE_EXTRACT")
		ModelDownloader.Stage.DOWNLOADING_MODEL:
			return L10n.t("UI_MODEL_DOWNLOAD_STAGE_MODEL")
		_:
			return ""


func _on_finished(ok: bool, reason: String) -> void:
	if ok:
		_show_terminal_state(true, L10n.t("UI_MODEL_DOWNLOAD_SUCCESS"))
	else:
		_show_terminal_state(false, L10n.tf("UI_MODEL_DOWNLOAD_FAILED", {"reason": reason}))


func _show_terminal_state(ok: bool, message: String) -> void:
	_stage_label.text = message
	_stage_label.add_theme_color_override("font_color", Color("#3D6B35") if ok else Color("#A33B2E"))
	_progress_bar.visible = false
	_cancel_button.visible = false
	_close_button.visible = true


func _on_cancel_pressed() -> void:
	if _downloader != null and is_instance_valid(_downloader):
		_downloader.cancel()
	queue_free()
