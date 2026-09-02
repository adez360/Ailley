class_name Selection
extends Node2D

## 用滑鼠指人與選人。三件事：指到誰描邊、點到誰就讓鏡頭跟著他、點空地取消。
##
## class_name 是給 status_panel.gd 用的：它重用這裡的 character_at()
## 做點擊判定，兩邊要認同一顆角色不必各自猜一次「點中了誰」。
##
## 不走 Godot 內建的 physics object picking：角色的碰撞形狀只有腳下那個小圓，
## 點頭部會落空；而 Vision 那圈 Area2D 大到會把游標整個吃掉。
## 這裡直接拿目前影格的矩形去比 —— 點得到的範圍就是看得到的範圍。

const RIPPLE_DURATION := 0.35
const RIPPLE_START_RADIUS := 2.0
const RIPPLE_END_RADIUS := 12.0
const RIPPLE_COLOR := Color(1.0, 1.0, 1.0, 0.9)
const RIPPLE_SEGMENTS := 24

## 選取對象變了（select／deselect 都會發，deselect 傳 null）——給常駐 UI 用，
## 例如 StatusPanel2 狀態列的快照與名字要跟著當前選取目標走
signal selection_changed(character: Character)
var _hovered: Character = null
var _selected: Character = null
# 每筆 {position: Vector2, elapsed: float}，播完自己消失
var _ripples: Array[Dictionary] = []


func _ready() -> void:
	add_to_group("selection")

func _process(delta: float) -> void:
	_update_hover()
	_advance_ripples(delta)

# 用 _unhandled_input：主控台或聊天框蓋在上面時，那一下算在 UI 身上不算選人
func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("select"):
		return

	get_viewport().set_input_as_handled()

	var point := _world_point(event)
	_ripples.append({"position": point, "elapsed": 0.0})
	queue_redraw()

	var target := character_at(point)
	if target == null:
		deselect()
	else:
		select(target)

# 選取一個角色，鏡頭改跟著他
func select(character: Character) -> void:
	_selected = character
	_camera_follow(character)
	selection_changed.emit(character)

# 取消選取，鏡頭移回玩家身上
func deselect() -> void:
	_selected = null
	selection_changed.emit(null)

	var camera := _find_camera()
	if camera != null:
		camera.follow_player()

func get_selected() -> Character:
	return _selected

func get_hovered() -> Character:
	return _hovered

# 這個點底下的角色，沒有回 null。
# 兩個人站在一起時矩形會重疊，取中心離游標最近的那個
func character_at(point: Vector2) -> Character:
	var found: Character = null
	var shortest := INF

	for node in get_tree().get_nodes_in_group("characters"):
		var character := node as Character
		var rect := character.get_pick_rect()
		if not rect.has_point(point):
			continue

		var distance := rect.get_center().distance_to(point)
		if distance < shortest:
			shortest = distance
			found = character

	return found


# ---- 內部 ----

# 這一下點在世界的哪個位置。用事件自己的座標而不是當下的游標位置 ——
# 真人操作時兩者一樣，但事件是被餵進來的（測試、重播）時只有前者是對的
func _world_point(event: InputEvent) -> Vector2:
	var mouse := event as InputEventMouse
	if mouse == null:
		return get_global_mouse_position()

	return get_canvas_transform().affine_inverse() * mouse.position

func _update_hover() -> void:
	var under := character_at(get_global_mouse_position())
	if under == _hovered:
		return

	if is_instance_valid(_hovered):
		_hovered.set_highlighted(false)

	_hovered = under

	if _hovered != null:
		_hovered.set_highlighted(true)

func _camera_follow(character: Character) -> void:
	var camera := _find_camera()
	if camera != null:
		camera.follow(character)

func _find_camera() -> Camera2D:
	var camera := get_tree().get_first_node_in_group("follow_camera") as Camera2D
	if camera == null:
		push_error("Selection: 場景裡沒有 FollowCamera，選了人鏡頭不會跟")

	return camera

func _advance_ripples(delta: float) -> void:
	if _ripples.is_empty():
		return

	var alive: Array[Dictionary] = []
	for ripple in _ripples:
		ripple["elapsed"] += delta
		if ripple["elapsed"] < RIPPLE_DURATION:
			alive.append(ripple)

	_ripples = alive
	queue_redraw()

func _draw() -> void:
	for ripple in _ripples:
		var progress: float = ripple["elapsed"] / RIPPLE_DURATION
		var radius := lerpf(RIPPLE_START_RADIUS, RIPPLE_END_RADIUS, progress)

		var color := RIPPLE_COLOR
		color.a *= 1.0 - progress

		draw_arc(to_local(ripple["position"]), radius, 0.0, TAU, RIPPLE_SEGMENTS, color, 1.0)
