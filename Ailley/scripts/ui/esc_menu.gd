class_name EscMenu
extends PanelContainer

## Esc 暫停選單。必須是 hud.tscn 裡 Pause（CanvasLayer，pause.gd）的子節點——
## Resume 靠這個結構直接把 get_parent() 轉型成 Pause 呼叫 set_paused()。
##
## Setting 目前沒有面板可接，按鈕在 esc_menu.tscn 裡設成 disabled，這裡不接訊號。

const MAIN_MENU_SCENE := "res://scenes/main_menu.tscn"

@onready var _pause: Pause = get_parent() as Pause
@onready var resume_button: Button = $MarginContainer/VBoxContainer/Resume
@onready var exit_button: Button = $MarginContainer/VBoxContainer/Exit


func _ready() -> void:
	resume_button.pressed.connect(_on_resume_pressed)
	exit_button.pressed.connect(_on_exit_pressed)


func _on_resume_pressed() -> void:
	_pause.set_paused(false)


# 回主選單跟關視窗一樣算「離開遊戲」，存檔邏輯共用 game_manager.gd 的
# save_before_leaving()。change_scene_to_file() 不會自動把 paused 重設回
# false——不先解除的話主選單場景會在暫停狀態下開場，按鈕收不到輸入。
func _on_exit_pressed() -> void:
	GameManager.save_before_leaving()
	get_tree().paused = false
	get_tree().change_scene_to_file(MAIN_MENU_SCENE)
