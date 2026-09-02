class_name OnboardingHint
extends CanvasLayer

## 操作說明總覽（issue #585 起的新手引導，issue #1017 擴成完整快捷鍵表）。
##
## 一個面板兩種用途：
##   1. 新遊戲第一次開場自動彈一次（`auto_show` 由 main_scene.gd 設，且只在
##      沒看過時——`user://onboarding_seen` 標記檔）。
##   2. 遊戲中隨時按 F1 叫出來當快捷鍵速查表（`_toggle()`）。
## 讀檔（繼續遊戲）不自動彈，但節點照樣掛著，F1 一樣有效。
##
## 純程式建樹、不掛任何 .tscn：跟舊版同一個理由（godot-ai MCP 連不上時
## 場景操作沒辦法走規定流程），全部節點在 _build_ui() 用程式碼生成。
##
## 每一列的「按鍵」欄一律從 InputMap 現算（`_key_label()`），不寫死——
## 玩家日後重綁鍵位這張表會跟著變。列的「說明」是散文，走 locale key。
##
## Esc／F1／點面板外都關；F1 在面板關著時是開。輸入走 _input()、不是
## _unhandled_input()：這個節點是 main_scene.gd 動態掛的，不在 Pause 靠
## 子節點順序保證的關閉序列裡（同 chat_input.gd／debug_console.gd 的既有解法）。

const PANEL_WIDTH := 300
const SEEN_MARKER := "user://onboarding_seen"

const BARK := Color("2F2522")
const LOAM := Color("5D4A38")

## 每一列：`actions` 是 InputMap 動作名（多個 = 合併顯示，例如方向鍵），
## `desc` 是說明的 locale key，`keys` 有給就用它覆寫按鍵欄的顯示文字
## （hotbar_1..9 逐一列出來沒意義，直接寫「1–9」）。
const ROWS := [
	{"actions": ["move_up", "move_left", "move_down", "move_right"], "desc": "UI_KEYREF_MOVE"},
	{"actions": ["interact"], "desc": "UI_KEYREF_INTERACT"},
	{"actions": ["chat"], "desc": "UI_KEYREF_TALK"},
	{"actions": ["select"], "desc": "UI_KEYREF_SELECT"},
	{"actions": ["attack"], "desc": "UI_KEYREF_ATTACK"},
	{"actions": ["give"], "desc": "UI_KEYREF_GIVE"},
	{"actions": ["make_noise"], "desc": "UI_KEYREF_NOISE"},
	{"actions": ["use_item"], "desc": "UI_KEYREF_USE_ITEM"},
	{"actions": ["rest"], "desc": "UI_KEYREF_REST"},
	{"actions": ["inventory_toggle"], "desc": "UI_KEYREF_INVENTORY"},
	{"actions": ["hotbar_1"], "desc": "UI_KEYREF_HOTBAR", "keys": "1–9"},
	{"actions": ["ui_cancel"], "desc": "UI_KEYREF_CANCEL"},
]

## main_scene.gd 設：新遊戲開場 true，繼續遊戲 false。true 時 _ready() 若
## 玩家沒看過就自動顯示一次。
var auto_show := false

var _scrim: ColorRect


func _ready() -> void:
	layer = 50
	_build_ui()
	_scrim.hide()
	if auto_show and not FileAccess.file_exists(SEEN_MARKER):
		_show()
		_mark_seen()


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F1:
		get_viewport().set_input_as_handled()
		_toggle()
		return
	if _scrim.visible and event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		_scrim.hide()


func _toggle() -> void:
	_scrim.visible = not _scrim.visible


func _show() -> void:
	_scrim.show()


func _mark_seen() -> void:
	var f := FileAccess.open(SEEN_MARKER, FileAccess.WRITE)
	if f != null:
		f.store_line("1")


func _build_ui() -> void:
	_scrim = ColorRect.new()
	_scrim.color = Color(0, 0, 0, 0.55)
	_scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_scrim.mouse_filter = Control.MOUSE_FILTER_STOP
	_scrim.gui_input.connect(_on_scrim_gui_input)
	add_child(_scrim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_scrim.add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(PANEL_WIDTH, 0)
	var style := StyleBoxFlat.new()
	style.bg_color = Color("#FAF3E8") # Cream，見 note/技術/UI 版面與素材規格.md 調色盤
	style.border_color = BARK
	style.set_border_width_all(2)
	style.set_content_margin_all(10)
	panel.add_theme_stylebox_override("panel", style)
	center.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	panel.add_child(vbox)

	# Control.text 直接填翻譯 key 會被自動翻譯（auto_translate_mode 預設
	# INHERIT）；說明文字用 self 拿得到，直接填 key。按鍵欄是現算的字串、
	# 不是 key，照原樣填。
	var title := Label.new()
	title.text = "UI_KEYREF_TITLE"
	title.add_theme_color_override("font_color", BARK)
	vbox.add_child(title)
	vbox.add_child(HSeparator.new())

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 3)
	vbox.add_child(grid)

	for row in ROWS:
		var key_label := Label.new()
		key_label.text = row["keys"] if row.has("keys") else _keys_label(row["actions"])
		key_label.add_theme_color_override("font_color", BARK)
		grid.add_child(key_label)

		var desc_label := Label.new()
		desc_label.text = row["desc"]
		desc_label.add_theme_color_override("font_color", BARK)
		desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD
		grid.add_child(desc_label)

	vbox.add_child(HSeparator.new())

	var close_hint := Label.new()
	close_hint.text = "UI_KEYREF_REOPEN_HINT"
	close_hint.add_theme_color_override("font_color", LOAM) # Loam，次要文字
	vbox.add_child(close_hint)


## 一列可能綁多個動作（方向鍵）：各取第一個事件的按鍵字串，用空格接起來。
func _keys_label(actions: Array) -> String:
	var parts: Array[String] = []
	for action in actions:
		var s := _key_label(action)
		if not s.is_empty() and not parts.has(s):
			parts.append(s)
	return " ".join(parts) if not parts.is_empty() else "—"


## 從 InputMap 現算某個動作的第一個按鍵顯示字串。鍵盤取 keycode（沒有就取
## physical_keycode）；滑鼠鍵轉成中文。查不到綁定回空字串。
func _key_label(action: String) -> String:
	if not InputMap.has_action(action):
		return ""
	for event in InputMap.action_get_events(action):
		if event is InputEventKey:
			var code: int = event.keycode if event.keycode != 0 else event.physical_keycode
			if code != 0:
				return OS.get_keycode_string(code)
		elif event is InputEventMouseButton:
			match event.button_index:
				MOUSE_BUTTON_LEFT:
					return tr("UI_KEYREF_MOUSE_LEFT")
				MOUSE_BUTTON_RIGHT:
					return tr("UI_KEYREF_MOUSE_RIGHT")
				MOUSE_BUTTON_MIDDLE:
					return tr("UI_KEYREF_MOUSE_MIDDLE")
	return ""


# 只認滑鼠左鍵關閉（滾輪 tick 也是合成的 button pressed 事件，不過濾會誤觸）——
# 跟 main_menu.gd 的 Scrim/CreditsPanel 同一套判定。panel 疊在 scrim 上、
# 預設 mouse_filter=STOP 會吃掉點在面板本體上的點擊，冒泡回來代表點在面板外。
func _on_scrim_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_scrim.hide()
