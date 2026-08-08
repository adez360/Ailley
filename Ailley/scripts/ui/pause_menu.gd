extends CanvasLayer

## Esc 開關的暫停選單：存檔並回主選單，或返回遊戲。
##
## 跟 chat_input/debug_console 一樣用 _unhandled_input 吃 ui_cancel（Esc），
## 這樣主控台開著時（它在 _input 裡處理 Esc 並 set_input_as_handled）
## 這裡就收不到、不會搶著跳出來。

@onready var root: Control = $Root
@onready var save_and_exit: Button = $Root/SaveAndExit
@onready var resume: Button = $Root/Resume

const MENU_SCENE_PATH := "res://scenes/MainMenu.tscn"


func _ready() -> void:
	save_and_exit.pressed.connect(_on_save_and_exit_pressed)
	resume.pressed.connect(_on_resume_pressed)
	_set_open(false)

func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("ui_cancel"):
		return

	if root.visible:
		_set_open(false)
		get_viewport().set_input_as_handled()
	elif not _ui_is_busy():
		_set_open(true)
		get_viewport().set_input_as_handled()

# 別的 UI（debug 主控台、聊天輸入框）正在收鍵盤時不要跳出來搶
func _ui_is_busy() -> bool:
	return get_viewport().gui_get_focus_owner() != null

func _set_open(open: bool) -> void:
	root.visible = open

func _on_save_and_exit_pressed() -> void:
	Global.save_game()
	get_tree().change_scene_to_file(MENU_SCENE_PATH)

func _on_resume_pressed() -> void:
	_set_open(false)
