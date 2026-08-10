extends CanvasLayer

## ESC 暫停。
##
## process_mode 必須是 ALWAYS：暫停之後這個節點自己也停掉的話，
## 輸入不會再送進來，按下去就再也醒不過來。
##
## 掛在 main.tscn 的第一個子節點。_unhandled_input 依場景樹反序傳遞
## （最後一個子節點先收到），排在最前面才是最後一個收到 ——
## 面板開著時 ESC 該關面板，不是暫停。debug_console 走 _input、
## chat_input 與 character_create 走 _unhandled_input，
## 三個都會 set_input_as_handled()，所以不必再做面板堆疊管理。

func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("ui_cancel"):
		return

	set_paused(not get_tree().paused)
	get_viewport().set_input_as_handled()


func set_paused(paused: bool) -> void:
	get_tree().paused = paused
	visible = paused
