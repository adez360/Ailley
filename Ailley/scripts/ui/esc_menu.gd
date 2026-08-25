class_name EscMenu
extends PanelContainer

## Esc 暫停選單。必須是 hud.tscn 裡 Pause（CanvasLayer，pause.gd）的子節點——
## Resume 靠這個結構直接把 get_parent() 轉型成 Pause 呼叫 set_paused()。
##
## Setting 目前沒有面板可接，這裡先不接訊號——按鈕保持 enabled 只是點了沒反應，
## 沒有設成 disabled：這個主題的 disabled 樣式沒定義專屬字色，字會沉到底色裡看不見。

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
# save_before_leaving()。存檔失敗就留在原地不切場景——不然會在玩家不知情的
# 情況下弄丟進度（CodeRabbit review on #587 抓到）。change_scene_to_file()
# 不會自動把 paused 重設回 false——不先解除的話主選單場景會在暫停狀態下
# 開場，按鈕收不到輸入。
func _on_exit_pressed() -> void:
	if not GameManager.save_before_leaving():
		return
	get_tree().paused = false
	get_tree().change_scene_to_file(MAIN_MENU_SCENE)
