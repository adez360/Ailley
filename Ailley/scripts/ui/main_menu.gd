class_name MainMenu
extends Control

## 遊戲開場的第一顆場景（issue #295：原本 run/main_scene 直接開進 main.tscn，
## 沒有任何前置流程）。目前只有兩個入口：開始遊戲、銘謝（第三方授權）。
## 具體文案、按鈕位置、排版留給前端組決定，這裡先把結構跟行為做出來。
##
## 場景結構是這份腳本的合約：
##   Control（本腳本）
##     Background（ColorRect，全螢幕）
##     TitleLabel（遊戲名稱，不走翻譯 key——專有名詞）
##     ButtonsBox（VBoxContainer，置中）
##       StartButton / CreditsButton
##     Scrim（ColorRect，全螢幕半透明，預設隱藏；點面板外關閉銘謝子畫面，
##            做法跟 status_panel.gd／各面板的「點面板外或按 Esc 關閉」一致）
##       CreditsPanel（Setting menu.png 九宮格，樣式沿用 status_panel.gd）
##         TitleBg / TitleLabel
##         VBox
##           QwenLabel / LlamaCppLabel（《16》§2.2 列名的兩項第三方授權）
##           HintLabel

const MAIN_SCENE := "res://scenes/main.tscn"

@onready var start_button: Button = $ButtonsBox/StartButton
@onready var credits_button: Button = $ButtonsBox/CreditsButton
@onready var scrim: ColorRect = $Scrim


func _ready() -> void:
	scrim.hide()
	start_button.pressed.connect(_on_start_pressed)
	credits_button.pressed.connect(_on_credits_pressed)
	scrim.gui_input.connect(_on_scrim_gui_input)
	start_button.grab_focus()


func _unhandled_input(event: InputEvent) -> void:
	if scrim.visible and event.is_action_pressed("ui_cancel"):
		_close_credits()
		get_viewport().set_input_as_handled()


func _on_start_pressed() -> void:
	get_tree().change_scene_to_file(MAIN_SCENE)


func _on_credits_pressed() -> void:
	scrim.show()


# Scrim 蓋滿全螢幕，CreditsPanel 疊在它上面。CreditsPanel 底下的 TitleBg 有
# 明確覆寫 mouse_filter=IGNORE 只是純裝飾；TitleLabel/VBox 的 Label 群沒覆寫，
# 走 Godot 4 的 Label/Container 預設值 IGNORE，點擊會穿過它們，落到 CreditsPanel
# 本體（Panel 預設 STOP）才被吃掉——不會傳到這裡，收到代表點在面板外。
# 只認滑鼠左鍵：event 也包含滾輪 tick（合成的 button pressed 事件）與右鍵/中鍵，
# 不過濾 button_index 的話滾一下滑鼠滾輪就會把面板關掉，跟 status_panel.gd
# 的 _input() 用同一個判斷式對齊。
func _on_scrim_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_close_credits()


func _close_credits() -> void:
	scrim.hide()
