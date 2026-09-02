class_name HumanDecisionPanel
extends CanvasLayer

## issue #156：《12》§3.4 HumanInput 的決策面板。純程式建樹、不掛 .tscn——
## 跟 model_download_overlay.gd／onboarding_hint.gd 同一個理由（簡單置中面板
## 用程式碼生成比另開場景檔划算，不需要走 godot-ai MCP 場景操作流程）。
## layer 20＝全專案「小型彈出選單」慣例（見 model_download_overlay.gd 的
## CanvasLayer 慣例說明）。
##
## 表單欄位對齊 AISchema.validate_tasks() 的必填契約（issue #156 驗收：
## 面板輸出走 LLM 來源同一條驗證路徑，不另開特例）：
## - reasoning 必填非空 → LineEdit 預填「真人代打」，可改
## - emotion 必填 {type, intensity} → 8 型下拉 + 0-100 滑桿
## - tasks[] 每筆必填 {action, priority, duration} → 動作下拉 + 兩個 SpinBox，
##   範圍帶 AISchema 的 MIN/MAX 常數，不寫死
## - talk/attack/bury/follow/persuade 需要 target → 下拉只列白名單內的值
##   （在場角色；attack 額外給 god_stone、bury 給遺體），真人物理上選不到
##   非法值（《12》§3.4「表單欄位由 schema 自動生成」）
## - persuade 另需 reason（_validate_persuade_params() 必填非空）→ 選
##   persuade 才顯示的必填欄
##
## 不提供的動作：give 的 item_id/count 面板收不了（需要背包 UI），端出來的
## 任務必在 give_to() 失敗——不邀請真人選一個保證失敗的動作，直接從清單
## 拿掉（issue 說的「當下情境可用的子集」）。
##
## 逾時（數值權威見《99》P-22 #2，秒數引用 HumanInputProvider 常數不重述）：
## 短逾時到 → 催促文案；中逾時到 → 自己收掉，HumanInputProvider 輪詢到
## settled 後回 no_response，由 agent.gd 的既有失敗分支走 §4.5 入眠流程。

## 需要 target 的動作，跟 AISchema._validate_task_shape() 的逐欄位檢查名單
## 同一組（give 在上面被拿掉，不進面板清單）
const TARGET_ACTIONS := ["talk", "attack", "bury", "follow", "persuade"]

const PANEL_WIDTH := 320
const COLOR_TEXT := Color("#2F2522")	# Bark，見 note/技術/UI 版面與素材規格.md 調色盤
const COLOR_REMIND := Color("#A33B2E")
const COLOR_OK := Color("#3D6B35")

## 多個真人來源角色同時等決策時面板往下錯開，不疊在同一個位置
static var _open_count := 0

## 給 HumanInputProvider 輪詢讀的收尾狀態
var settled := false
var decided_ok := false
var decision_data := {}

var _character_name: String
var _actions: Array
var _visible_names: PackedStringArray
var _corpse_names: PackedStringArray

var _elapsed := 0.0
var _reminded := false

var _countdown_label: Label
var _hint_label: Label
var _action_option: OptionButton
var _target_row: HBoxContainer
var _target_option: OptionButton
var _reason_row: HBoxContainer
var _reason_edit: LineEdit
var _reasoning_edit: LineEdit
var _emotion_option: OptionButton
var _intensity_slider: HSlider
var _intensity_value: Label
var _duration_spin: SpinBox
var _priority_spin: SpinBox


func _init(character_name: String, actions: Array, visible_names: PackedStringArray, corpse_names: PackedStringArray) -> void:
	_character_name = character_name
	_actions = actions
	_visible_names = visible_names
	_corpse_names = corpse_names


func _ready() -> void:
	layer = 20
	# 逾時倒數與 agent.gd 決策看門狗同一個真實時鐘（get_tree().paused 時照
	# 走）：看門狗吃 Time.get_ticks_msec()（暫停不停錶），面板若跟著樹一起
	# 凍結，暫停逾 135 秒會被看門狗先殺掉決策、遲到的真人輸入被安靜丟棄。
	# 掛 ALWAYS 讓 _process 在暫停期間照常收到真實 delta、_elapsed 照累加，
	# 也讓暫停中等決策的真人照常操作面板（輸入處理不暫停）
	process_mode = Node.PROCESS_MODE_ALWAYS
	_open_count += 1
	_build_ui()


func _exit_tree() -> void:
	_open_count -= 1


func _process(delta: float) -> void:
	if settled:
		return
	_elapsed += delta
	var left := maxi(0, int(HumanInputProvider.MID_TIMEOUT_SEC) - int(_elapsed))
	_countdown_label.text = L10n.tf("UI_HUMAN_DECISION_COUNTDOWN", {"sec": left})
	if not _reminded and _elapsed >= HumanInputProvider.SHORT_TIMEOUT_SEC:
		_reminded = true
		_hint_label.text = L10n.t("UI_HUMAN_DECISION_REMIND")
		_hint_label.add_theme_color_override("font_color", COLOR_REMIND)
	if _elapsed >= HumanInputProvider.MID_TIMEOUT_SEC:
		_settle(false, {})


## 真人放棄／角色死亡時由 HumanInputProvider 呼叫：標記收尾、不帶決策。
## queue_free() 由呼叫端統一做，這裡只負責狀態
func cancel() -> void:
	_settle(false, {})


func _settle(ok: bool, data: Dictionary) -> void:
	if settled:
		return
	settled = true
	decided_ok = ok
	decision_data = data


func _build_ui() -> void:
	var scrim := ColorRect.new()
	scrim.color = Color(0, 0, 0, 0.45)
	scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	scrim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(scrim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	# 多面板同時開時整個置中容器往下錯開，不疊死在同一個位置——CenterContainer
	# 會覆寫子節點的 position，位移要打在容器自己的 offset 上才不會被 layout 蓋掉
	var shift := 40.0 * _open_count
	center.offset_top = shift
	center.offset_bottom = shift
	scrim.add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(PANEL_WIDTH, 0)
	var style := StyleBoxFlat.new()
	style.bg_color = Color("#FAF3E8")	# Cream，同上調色盤
	style.border_color = COLOR_TEXT
	style.set_border_width_all(2)
	style.set_content_margin_all(10)
	panel.add_theme_stylebox_override("panel", style)
	center.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	panel.add_child(vbox)

	var title := Label.new()
	title.text = L10n.tf("UI_HUMAN_DECISION_PROMPT", {"name": _character_name})
	title.add_theme_color_override("font_color", COLOR_TEXT)
	title.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(title)

	_countdown_label = Label.new()
	_countdown_label.add_theme_color_override("font_color", COLOR_TEXT)
	vbox.add_child(_countdown_label)

	_hint_label = Label.new()
	_hint_label.add_theme_color_override("font_color", COLOR_TEXT)
	_hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(_hint_label)

	_reasoning_edit = _add_labeled_line(vbox, L10n.t("UI_HUMAN_DECISION_REASONING"), L10n.t("UI_HUMAN_DECISION_REASONING_DEFAULT"))

	var action_row := _add_label(vbox, L10n.t("UI_HUMAN_DECISION_ACTION"))
	_action_option = OptionButton.new()
	for action in _actions:
		if action == "give":
			continue	# item_id/count 面板收不了，見檔頭說明
		_action_option.add_item(action)
	_action_option.item_selected.connect(_on_action_selected)
	action_row.add_child(_action_option)

	_target_row = _add_label(vbox, L10n.t("UI_HUMAN_DECISION_TARGET"))
	_target_option = OptionButton.new()
	_target_row.add_child(_target_option)

	_reason_row = _add_label(vbox, L10n.t("UI_HUMAN_DECISION_REASON"))
	_reason_edit = LineEdit.new()
	_reason_edit.expand_to_text_length = true
	_reason_row.add_child(_reason_edit)

	var emotion_row := _add_label(vbox, L10n.t("UI_HUMAN_DECISION_EMOTION"))
	_emotion_option = OptionButton.new()
	for emotion_type in Character.EMOTION_TYPES:
		_emotion_option.add_item(emotion_type)
	_emotion_option.select(Character.EMOTION_TYPES.size() - 1)	# neutral 在清單尾
	emotion_row.add_child(_emotion_option)

	var intensity_row := _add_label(vbox, L10n.t("UI_HUMAN_DECISION_INTENSITY"))
	_intensity_slider = HSlider.new()
	_intensity_slider.min_value = 0
	_intensity_slider.max_value = 100
	_intensity_slider.value = 50
	_intensity_slider.custom_minimum_size = Vector2(120, 0)
	_intensity_slider.value_changed.connect(_on_intensity_changed)
	intensity_row.add_child(_intensity_slider)
	_intensity_value = Label.new()
	_intensity_value.text = "50"
	_intensity_value.add_theme_color_override("font_color", COLOR_TEXT)
	intensity_row.add_child(_intensity_value)

	_duration_spin = _add_spin(vbox, L10n.t("UI_HUMAN_DECISION_DURATION"),
		1, int(AISchema.MAX_TASK_DURATION), 30)
	_priority_spin = _add_spin(vbox, L10n.t("UI_HUMAN_DECISION_PRIORITY"),
		int(AISchema.MIN_TASK_PRIORITY), int(AISchema.MAX_TASK_PRIORITY), 10)

	var submit := Button.new()
	submit.text = L10n.t("UI_HUMAN_DECISION_SUBMIT")
	submit.pressed.connect(_on_submit)
	vbox.add_child(submit)

	_on_action_selected(_action_option.selected)


func _add_label(vbox: VBoxContainer, text: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", COLOR_TEXT)
	row.add_child(label)
	vbox.add_child(row)
	return row


func _add_labeled_line(vbox: VBoxContainer, text: String, default_value: String) -> LineEdit:
	var row := _add_label(vbox, text)
	var edit := LineEdit.new()
	edit.text = default_value
	edit.expand_to_text_length = true
	row.add_child(edit)
	return edit


func _add_spin(vbox: VBoxContainer, text: String, min_value: int, max_value: int, value: int) -> SpinBox:
	var row := _add_label(vbox, text)
	var spin := SpinBox.new()
	spin.min_value = min_value
	spin.max_value = max_value
	spin.step = 1
	spin.value = value
	row.add_child(spin)
	return spin


func _on_intensity_changed(value: float) -> void:
	_intensity_value.text = str(int(value))


## 換動作時重算 target 下拉名單與 persuade reason 欄的可見性——target 名單
## 依 AISchema._is_valid_target() 的白名單語意：bury 比對遺體、attack 額外
## 接受 god_stone 保留字、其餘比對在場角色
func _on_action_selected(_index: int) -> void:
	var action := _selected_action()
	var needs_target := TARGET_ACTIONS.has(action)
	_target_row.visible = needs_target
	_reason_row.visible = action == "persuade"
	if not needs_target:
		return
	_target_option.clear()
	if action == "bury":
		for corpse_name in _corpse_names:
			_target_option.add_item(corpse_name)
	elif action == "attack":
		for visible_name in _visible_names:
			_target_option.add_item(visible_name)
		_target_option.add_item("god_stone")
	else:
		for visible_name in _visible_names:
			_target_option.add_item(visible_name)


func _selected_action() -> String:
	if _action_option.item_count == 0 or _action_option.selected < 0:
		return ""
	return _action_option.get_item_text(_action_option.selected)


func _on_submit() -> void:
	var action := _selected_action()
	if action.is_empty():
		_hint_label.text = L10n.t("UI_HUMAN_DECISION_ERR_ACTION")
		return

	var reasoning := _reasoning_edit.text.strip_edges()
	if reasoning.is_empty():
		_hint_label.text = L10n.t("UI_HUMAN_DECISION_ERR_REASONING")
		return

	var task := {
		"action": action,
		"priority": int(_priority_spin.value),
		"duration": int(_duration_spin.value),
	}
	if TARGET_ACTIONS.has(action):
		if _target_option.item_count == 0 or _target_option.selected < 0:
			_hint_label.text = L10n.t("UI_HUMAN_DECISION_ERR_TARGET")
			return
		task["params"] = {"target": _target_option.get_item_text(_target_option.selected)}
	if action == "persuade":
		var reason := _reason_edit.text.strip_edges()
		if reason.is_empty():
			_hint_label.text = L10n.t("UI_HUMAN_DECISION_ERR_PERSUADE")
			return
		(task["params"] as Dictionary)["reason"] = reason

	# 形狀對齊 plan_response_schema()：reasoning／emotion 必填，tasks 至少一筆。
	# 其餘欄位（inner_monologue／update_plan／appointment……）面板不收，缺席
	# 走 validate_tasks() 的既有「選填／條件式」語意，跟 LLM 來源同一套規則
	_settle(true, {
		"reasoning": reasoning,
		"emotion": {
			"type": _emotion_option.get_item_text(_emotion_option.selected),
			"intensity": int(_intensity_slider.value),
		},
		"tasks": [task],
	})
