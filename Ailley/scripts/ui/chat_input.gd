extends CanvasLayer

## 玩家的說話輸入框。Enter 開啟／送出，Esc 取消。
##
## 跟 debug_console 是兩件事：那個是打指令給遊戲，這個是讓角色說話。
## 兩者都吃 Enter，所以開啟前會先確認沒有別的 UI 拿著焦點
## （主控台的輸入框有焦點時，Enter 是要送出指令的）。

const MAX_LENGTH := 40		# 太長的句子會撐出一個蓋住畫面的氣泡

@onready var root: Control = $Root
@onready var input: LineEdit = $Root/Input


func _ready() -> void:
	input.max_length = MAX_LENGTH
	input.text_submitted.connect(_on_submitted)
	_set_open(false)

# 用 _unhandled_input：輸入框自己有焦點時，Enter 會先被 LineEdit 吃掉走
# text_submitted，不會再跑到這裡開第二次
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("chat"):
		if not root.visible and _ui_is_busy():
			return
		_set_open(not root.visible)
		get_viewport().set_input_as_handled()
		return

	if event.is_action_pressed("ui_cancel") and root.visible:
		_set_open(false)
		get_viewport().set_input_as_handled()

# 別的 UI（例如 debug 主控台）正在收鍵盤時不要跳出來搶
func _ui_is_busy() -> bool:
	return get_viewport().gui_get_focus_owner() != null

func _set_open(open: bool) -> void:
	root.visible = open

	if open:
		input.clear()
		input.grab_focus()
	else:
		input.release_focus()

func _on_submitted(text: String) -> void:
	var line := text.strip_edges()
	input.clear()
	_set_open(false)

	if line.is_empty():
		return

	var player := get_tree().get_first_node_in_group("player")
	if player == null:
		push_error("ChatInput: 場景裡找不到 player group 的節點")
		return

	player.say(line)
