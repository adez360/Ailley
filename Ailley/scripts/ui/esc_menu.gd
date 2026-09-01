class_name EscMenu
extends PanelContainer

## Esc 暫停選單。必須是 hud.tscn 裡 Pause（CanvasLayer，pause.gd）的子節點——
## Resume 靠這個結構直接把 get_parent() 轉型成 Pause 呼叫 set_paused()。
##
## Setting 目前沒有面板可接，這裡先不接訊號——按鈕保持 enabled 只是點了沒反應，
## 沒有設成 disabled：這個主題的 disabled 樣式沒定義專屬字色，字會沉到底色裡看不見。

const MAIN_MENU_SCENE := "res://scenes/main_menu.tscn"
const DISPLAY_SETTINGS := preload("res://scripts/core/display_settings.gd")

@onready var _pause: Pause = get_parent() as Pause
@onready var resume_button: Button = $MarginContainer/VBoxContainer/Resume
@onready var setting_button: Button = $MarginContainer/VBoxContainer/Setting
@onready var exit_button: Button = $MarginContainer/VBoxContainer/Exit
@onready var ai_recheck_button: Button = $MarginContainer/VBoxContainer/AiRecheck
@onready var ai_recheck_status_label: Label = $MarginContainer/VBoxContainer/AiRecheckStatus


var _fps_option: OptionButton
var _settings_dialog: AcceptDialog


func _ready() -> void:
	resume_button.pressed.connect(_on_resume_pressed)
	setting_button.pressed.connect(_on_setting_pressed)
	exit_button.pressed.connect(_on_exit_pressed)
	ai_recheck_button.pressed.connect(_on_ai_recheck_pressed)
	_pause.visibility_changed.connect(_on_pause_visibility_changed)
	ai_recheck_status_label.text = ""


func _on_setting_pressed() -> void:
	if _settings_dialog == null:
		_create_settings_dialog()
	_fps_option.select(DISPLAY_SETTINGS.get_fps_options().find(DISPLAY_SETTINGS.load_fps()))
	_settings_dialog.popup_centered()


func _create_settings_dialog() -> void:
	_settings_dialog = AcceptDialog.new()
	_settings_dialog.title = "畫面設定"
	_settings_dialog.process_mode = Node.PROCESS_MODE_ALWAYS
	_pause.add_child(_settings_dialog)

	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 8)
	_settings_dialog.add_child(content)

	var fps_label := Label.new()
	fps_label.text = "畫面更新率"
	content.add_child(fps_label)

	_fps_option = OptionButton.new()
	for fps in DISPLAY_SETTINGS.get_fps_options():
		_fps_option.add_item("%d FPS" % fps, fps)
	_fps_option.item_selected.connect(_on_fps_selected)
	content.add_child(_fps_option)

	_settings_dialog.get_ok_button().text = "關閉"


func _on_fps_selected(index: int) -> void:
	DISPLAY_SETTINGS.save_fps(_fps_option.get_item_id(index))


func _on_resume_pressed() -> void:
	_pause.set_paused(false)


# 選單顯示時把焦點放到 Resume——不設的話玩家一開啟選單就得先用滑鼠點一下
# 某顆按鈕，方向鍵／搖桿 D-pad 才有辦法開始導覽（CodeRabbit review on #587 抓到）
func _on_pause_visibility_changed() -> void:
	if _pause.visible:
		resume_button.grab_focus()


# 回主選單跟關視窗一樣算「離開遊戲」，存檔邏輯共用 game_manager.gd 的
# save_before_leaving()。存檔失敗就留在原地不切場景——不然會在玩家不知情的
# 情況下弄丟進度（CodeRabbit review on #587 抓到）。change_scene_to_file()
# 不會自動把 paused 重設回 false——不先解除的話主選單場景會在暫停狀態下
# 開場，按鈕收不到輸入。
#
# Pause 的 process_mode=3（見 hud.tscn），暫停期間按鈕仍會處理輸入——
# await 存檔期間連續按 Exit 會疊出多個存檔流程，各自結束後都呼叫
# change_scene_to_file()（CodeRabbit review on #587 抓到）。用旗標＋停用
# 按鈕擋掉重入，存檔失敗要復原成可以再按一次
var _exit_in_flight := false


func _on_exit_pressed() -> void:
	if _exit_in_flight:
		return
	_exit_in_flight = true
	exit_button.disabled = true
	if not await GameManager.save_before_leaving():
		_exit_in_flight = false
		exit_button.disabled = false
		return
	get_tree().paused = false
	get_tree().change_scene_to_file(MAIN_MENU_SCENE)


## 手動重新探測 AI 連線（issue #824「建議」的第一個選項）：正式版玩家除了
## 每遊戲日一次的低頻背景重試（見 game_manager.gd::recheck_ai_readiness()），
## 也能主動觸發。跟 _on_exit_pressed() 同一種旗標＋停用按鈕擋重入寫法——
## await 期間連點會疊出多個探測流程
var _ai_recheck_in_flight := false


func _on_ai_recheck_pressed() -> void:
	if _ai_recheck_in_flight:
		return
	_ai_recheck_in_flight = true
	ai_recheck_button.disabled = true
	ai_recheck_status_label.text = L10n.t("UI_AI_RECHECK_CHECKING")

	var result: Dictionary = await GameManager.recheck_ai_readiness()

	# await 期間玩家可能已經關閉選單／離開場景（跟 _apply_startup_ai_state()
	# 的 is_inside_tree() 防呆同一個理由）
	if not is_inside_tree():
		return
	_ai_recheck_in_flight = false
	ai_recheck_button.disabled = false

	var checked: int = result.get("checked", 0)
	var result_text := ""
	if checked == 0:
		result_text = L10n.t("UI_AI_RECHECK_NONE")
	else:
		var recovered: int = result.get("recovered", 0)
		if recovered == checked:
			result_text = L10n.tf("UI_AI_RECHECK_RECOVERED", {"recovered": recovered, "checked": checked})
		elif recovered > 0:
			result_text = L10n.tf("UI_AI_RECHECK_PARTIAL", {"recovered": recovered, "checked": checked})
		else:
			result_text = L10n.t("UI_AI_RECHECK_FAILED")
	ai_recheck_status_label.text = "%s\n\n%s" % [result_text, _connection_summary()]


func _connection_summary() -> String:
	if AIService == null or AIService.config == null:
		return "AI 連線：尚未載入設定"
	var info: Dictionary = AIService.config.connection_info()
	if info.get("kind", "unavailable") == "unavailable":
		return "AI 連線：未設定 provider"
	var kind_text: String = str({
		"localhost": "本機 localhost",
		"lan": "區域網路",
		"cloud": "雲端",
	}.get(str(info.get("kind", "cloud")), "未知"))
	return "連線：%s\n位址：%s\nProvider：%s\n模型：%s" % [
		kind_text,
		str(info.get("base_url", "")),
		str(info.get("provider", "")),
		str(info.get("model", "")),
	]
