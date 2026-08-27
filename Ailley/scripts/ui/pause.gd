class_name Pause
extends CanvasLayer

## ESC 暫停。
##
## process_mode 必須是 ALWAYS：暫停之後這個節點自己也停掉的話，
## 輸入不會再送進來，按下去就再也醒不過來。
##
## 必須是 hud.tscn 裡 PersistentUI 的第一個子節點。_unhandled_input 依場景樹
## 反序傳遞（最後一個子節點先收到），排在最前面才是最後一個收到 ——
## 面板開著時 ESC 該關面板，不是暫停。chat_input 走 _input，順序無關
## （且真的比對 ui_cancel action）；debug_console 也走 _input，但直接比對
## KEY_ESCAPE，不是 ui_cancel action；其餘會攔 Esc 的面板
## （status_panel、inventory_panel、character_create、character_library……）
## 都走 _unhandled_input，且比對 ui_cancel action——這裡只要它們是 PersistentUI
## 底下排在 Pause 之後的子節點、且自己 set_input_as_handled()，就會比 Pause 先
## 收到，不需要另外做面板堆疊管理。這個「Pause 排最前面」的前提曾經因為
## #312 把 UI 拆進 hud.tscn 時弄丟過（#326），之後新增/搬動 PersistentUI
## 的子節點時要留意別把 Pause 擠到後面。

func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("ui_cancel"):
		return

	set_paused(not get_tree().paused)
	get_viewport().set_input_as_handled()


func set_paused(paused: bool) -> void:
	get_tree().paused = paused
	visible = paused
