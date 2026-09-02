class_name OnboardingHint
extends CanvasLayer

## issue #585：新手引導。範圍界定（2026-08-24 拍板，見
## 《17_產品範圍與完整度地圖》「新手引導」）：開場簡短文字/UI 提示，
## 不做互動式教學關卡——不阻擋玩家立刻開始遊戲，關掉之後不會再出現。
##
## 純程式建樹、不掛任何 .tscn：godot-ai MCP 連不上時場景操作沒辦法走
## 規定流程（見 Ailley/CLAUDE.md），這裡全部節點在 _ready() 用程式碼生成，
## 屬於「純 GDScript 邏輯」可以直接 Edit 的範圍。
##
## Esc 關閉走 _input()、不是 _unhandled_input()：pause.gd 的關閉順序
## 是靠 PersistentUI 底下的子節點順序（反序送達）保證的，這個節點是
## main_scene.gd 動態掛上去的，不在那個子節點序列裡，順序沒有保證
## ——比照 chat_input.gd／debug_console.gd 的既有解法，走 _input() 能
## 保證一定比 Pause 的 _unhandled_input() 先看到這次按鍵（見
## note/技術/滑鼠選取與鏡頭.md「兩個 _unhandled_input 搶同一個事件」）。

const PANEL_WIDTH := 260

const HINT_KEYS := [
	"UI_ONBOARDING_MOVE",
	"UI_ONBOARDING_INTERACT",
	"UI_ONBOARDING_TALK",
	"UI_ONBOARDING_SELECT",
	"UI_ONBOARDING_ATTACK",
	"UI_ONBOARDING_GIVE",
	"UI_ONBOARDING_INVENTORY",
]


func _ready() -> void:
	layer = 50
	_build_ui()


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		queue_free()


func _build_ui() -> void:
	var scrim := ColorRect.new()
	scrim.color = Color(0, 0, 0, 0.55)
	scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	scrim.mouse_filter = Control.MOUSE_FILTER_STOP
	scrim.gui_input.connect(_on_scrim_gui_input)
	add_child(scrim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	scrim.add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(PANEL_WIDTH, 0)
	var style := StyleBoxFlat.new()
	style.bg_color = Color("#FAF3E8") # Cream，見 note/技術/UI 版面與素材規格.md 調色盤
	style.border_color = Color("#2F2522") # Bark
	style.set_border_width_all(2)
	style.set_content_margin_all(10)
	panel.add_theme_stylebox_override("panel", style)
	center.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	panel.add_child(vbox)

	# Control.text 直接填翻譯 key 會被自動翻譯（auto_translate_mode 預設
	# INHERIT），不必經過 L10n——那是給拿不到 self 的 static 場合用的，
	# 見 note/技術/在地化.md「兩條路徑」與 god_stone_input.gd 的既有寫法
	var title := Label.new()
	title.text = "UI_ONBOARDING_TITLE"
	title.add_theme_color_override("font_color", Color("#2F2522"))
	vbox.add_child(title)

	for key in HINT_KEYS:
		var line := Label.new()
		line.text = key
		line.add_theme_color_override("font_color", Color("#2F2522"))
		line.autowrap_mode = TextServer.AUTOWRAP_WORD
		vbox.add_child(line)

	vbox.add_child(HSeparator.new())

	var close_hint := Label.new()
	close_hint.text = "UI_STATUS_CLOSE_HINT"
	close_hint.add_theme_color_override("font_color", Color("#5D4A38")) # Loam，次要文字
	vbox.add_child(close_hint)


# Scrim 蓋滿全螢幕、mouse_filter=STOP；panel 疊在它上面同樣預設 STOP，會把點在
# panel 本體上的事件吃掉。CenterContainer 跟 vbox/Label 群都沒覆寫 mouse_filter，
# 走各自預設值（Container=PASS、Label=IGNORE），點在 panel 以外的地方事件會一路
# 冒泡回到這裡的 scrim，代表點在面板外——跟 main_menu.gd 的 Scrim/CreditsPanel
# 走同一套判定，只認滑鼠左鍵，滾輪/右鍵/中鍵不誤觸關閉
func _on_scrim_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		queue_free()
