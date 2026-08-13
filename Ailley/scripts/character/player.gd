extends Character

## 玩家操作的角色。輸入優先於 A* 自動移動：一按方向鍵就中斷現有路徑。
## 對話中依然吃得到方向鍵 —— 走遠了由 conversation.gd 的距離判定自然散場，
## 不需要另外做「離開對話」的操作。

## chat_input.gd 在玩家對話中打字送出時發這個訊號，next_line() 等它。
## 不直接讓 chat_input.gd 呼叫 conversation 物件——玩家不知道、也不該知道
## 自己現在是不是在跟一場 Conversation 物件對話，只知道「我打字、我的角色講話」，
## 這個訊號是 Character 介面本來就有的東西（spoke 訊號同一種精神）
signal line_submitted(text: String)


func _ready() -> void:
	super()
	add_to_group("player")

# 用 _unhandled_input 而不是 _input：debug 主控台的輸入框拿到焦點時
# 打字不該觸發搭話
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("make_noise"):
		get_viewport().set_input_as_handled()
		make_noise()
		return

	if not event.is_action_pressed("interact"):
		return

	# 販賣機選單開著時，這個 E 是要給選單用來關閉／已經在選單裡點過商品了，
	# 不該在這裡又被當成「開始一個新的互動」——不 set_input_as_handled()，
	# 讓事件繼續往下傳給 vending_menu.gd 自己的 _unhandled_input 處理
	var vending_menu := get_tree().get_first_node_in_group("vending_menu")
	if vending_menu != null and vending_menu.is_open():
		return

	get_viewport().set_input_as_handled()

	if is_in_conversation():
		leave_conversation()
		return

	# 附近的可互動物件（工作站、販賣機）與可搭話的人，三邊都先找出來。
	# 全部對玩家都是靜默失敗，沒有回饋 UI；但失敗原因會印成 warning
	# （跟 character.gd 的 _check_stuck() 同一種寫法），方便開發時對著
	# 編輯器 Output/Debugger 面板看，不用另外開主控台查
	var workstation := find_nearest_workstation()
	var machine := find_nearest_vending_machine()
	var other := find_nearest_character()

	# 誰近誰先試。**不能無條件讓世界物件優先**——桌子與販賣機都是擺在世界裡的
	# 固定物件，很容易落在某個地點錨點的互動半徑內（`square` 那張距錨點
	# 23px < WORK_RANGE 32），而 agent 的行程正好把大家帶去那些錨點。
	# 物件永遠優先的話，那個點上的搭話等於死掉。不在範圍內的候選距離是 INF，
	# 直接輸掉比較，不用另外再寫一層 null 判斷
	var pos := get_body_position()
	var to_work: float = pos.distance_to(workstation.global_position) if workstation != null else INF
	var to_machine: float = pos.distance_to(machine.global_position) if machine != null else INF
	var to_other: float = pos.distance_to(other.get_body_position()) if other != null else INF

	# 失敗要往下掉到搭話，不是直接 return。工作站被別人佔用（WORK_OCCUPIED）
	# 或自己正在工作（WORK_BUSY）時直接 return 的話，E 整個沒反應 ——
	# 玩家連站在眼前那個正在工作的人都搭不了話
	if workstation != null and to_work <= to_machine and to_work <= to_other:
		var work_reason := work_at(workstation)
		if work_reason == WORK_OK:
			return
		push_warning("%s: work_at 失敗（%s）" % [character_name, work_reason])
	# 販賣機不是立刻執行動作，是開商品選單——真正的購買發生在
	# vending_menu.gd 裡點下某一項的時候。vending_menu 理論上一定找得到
	# （場景裡固定掛著），這裡多防一手是避免場景漏掛的話直接炸掉
	elif machine != null and to_machine <= to_other and vending_menu != null:
		vending_menu.open(machine, self)
		return

	var talk_reason := talk_to(other)
	if talk_reason != TALK_OK:
		push_warning("%s: talk_to 失敗（%s）" % [character_name, talk_reason])

# 讀取 WASD 輸入，回傳正規化後的方向（斜向不會加速）
func get_input_direction() -> Vector2:
	# 有 UI 拿到焦點時（例如 debug 輸入框）不吃移動鍵，
	# 因為 Input.get_axis() 讀的是全域輸入狀態，不會被 LineEdit 攔下來
	if get_viewport().gui_get_focus_owner() != null:
		return Vector2.ZERO

	return Vector2(
		Input.get_axis("move_left", "move_right"),
		Input.get_axis("move_up", "move_down")
	).normalized()

func _decide_velocity() -> Vector2:
	var input_dir := get_input_direction()

	# 手動操作優先，直接中斷自動移動
	if input_dir != Vector2.ZERO:
		if is_moving():
			stop_moving()
		return input_dir * SPEED

	return super()

# 玩家的下一句話就是玩家打的字，等 chat_input.gd 送出 line_submitted。
# 沒有 end 這個概念——玩家不是靠一個結構化欄位收尾，是靠實際走開或
# leave_conversation()（_unhandled_input 的 interact 分支），所以這裡固定 false
func next_line(_listener: Character, _turns: Array[Dictionary], _max_turns: int) -> Dictionary:
	var text: String = await line_submitted
	return {"ok": true, "line": text, "end": false}
