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

	# 先看附近有沒有可互動物件（目前只有工作站），沒有才退回搭話——
	# 兩者都靜默失敗：玩家沒有回饋 UI，主控台的對應指令才會印原因碼
	var workstation := find_nearest_workstation()
	if workstation != null:
		work_at(workstation)
		return

	talk_to(find_nearest_character())

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
