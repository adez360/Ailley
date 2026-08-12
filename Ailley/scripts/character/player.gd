extends Character

## 玩家操作的角色。輸入優先於 A* 自動移動：一按方向鍵就中斷現有路徑。
## 對話中依然吃得到方向鍵 —— 走遠了由 conversation.gd 的距離判定自然散場，
## 不需要另外做「離開對話」的操作。


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

	get_viewport().set_input_as_handled()

	if is_in_conversation():
		leave_conversation()
		return

	# 附近的可互動物件（目前只有工作站）與可搭話的人，兩邊都先找出來。
	# 兩者對玩家都是靜默失敗，沒有回饋 UI；但失敗原因會印成 warning
	# （跟 character.gd 的 _check_stuck() 同一種寫法），方便開發時對著
	# 編輯器 Output/Debugger 面板看，不用另外開主控台查
	var workstation := find_nearest_workstation()
	var other := find_nearest_character()

	# 兩個都在範圍內就比距離，近的先試。**不能無條件讓工作站優先**——
	# 桌子是擺在世界裡的固定物件，很容易落在某個地點錨點的互動半徑內
	# （`square` 那張距錨點 23px < WORK_RANGE 32），而 agent 的行程正好
	# 把大家帶去那些錨點。工作站永遠優先的話，那個點上的搭話等於死掉
	var work_first := workstation != null
	if work_first and other != null:
		var to_work := get_body_position().distance_to(workstation.global_position)
		var to_other := get_body_position().distance_to(other.get_body_position())
		work_first = to_work <= to_other

	# 失敗要往下掉到搭話，不是直接 return。工作站被別人佔用（WORK_OCCUPIED）
	# 或自己正在工作（WORK_BUSY）時直接 return 的話，E 整個沒反應 ——
	# 玩家連站在眼前那個正在工作的人都搭不了話
	if work_first:
		var work_reason := work_at(workstation)
		if work_reason == WORK_OK:
			return
		push_warning("%s: work_at 失敗（%s）" % [character_name, work_reason])

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
