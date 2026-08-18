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
##     Scrim（ColorRect，全螢幕半透明，預設隱藏；點空白處關閉銘謝子畫面，
##            做法跟 status_panel.gd／各面板的「點空白處或按 Esc 關閉」一致）
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


func _unhandled_input(event: InputEvent) -> void:
	if scrim.visible and event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		_close_credits()
		get_viewport().set_input_as_handled()


func _on_start_pressed() -> void:
	get_tree().change_scene_to_file(MAIN_SCENE)


func _on_credits_pressed() -> void:
	scrim.show()


# Scrim 蓋滿全螢幕，CreditsPanel 疊在它上面。CreditsPanel（以及它底下的
# TitleBg/TitleLabel/VBox 的 Label 群）mouse_filter 都是預設值 STOP，
# 點面板內部的事件會被那些節點自己吃掉、不會傳到這裡——收到代表點在面板外。
func _on_scrim_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		_close_credits()


func _close_credits() -> void:
	scrim.hide()
