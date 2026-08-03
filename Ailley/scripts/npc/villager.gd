extends CharacterBody2D

# -----------------------------------------------------------------
# 基礎設定與變數
# -----------------------------------------------------------------
const SPEED = 50.0
# 單位轉換：1 格 = 16px (5格 = 80px)
const TILE_SIZE: float = 16.0  

var direction = Vector2.ZERO
var target_position = Vector2.ZERO
var has_target = false
var schedule = []
var current_place = ""

@export var villager_id = "npc001"

# 🎯 節點對接
@onready var sprite = $AnimatedSprite2D
@onready var state_machine = $StateMachine
@onready var needs = $Needs
@onready var navigation = $NavigationAgent2D
@onready var bubble = $Bubble
@onready var vision_area: Area2D = $VisionArea
@onready var vision_shape: CollisionShape2D = $VisionArea/CollisionShape2D
@onready var ray_cast: RayCast2D = $RayCast2D  # 🌟 視線探測射線

# 🎯 感知系統相關變數
var detected_targets: Array[Node2D] = []
var is_paused: bool = false
var debug_draw: bool = false

# 動態感知半徑（格數），預設為 5 格
var vision_radius_tiles: int = 5:
	set(value):
		vision_radius_tiles = clampi(value, 1, 20)
		_apply_radius()

# -----------------------------------------------------------------
# 初始化與輸入控制
# -----------------------------------------------------------------
func _ready():
	sprite.play("idle_down")
	load_schedule()
	GameClock.time_changed.connect(on_time_changed)
	on_time_changed(GameClock.hour, GameClock.minute)
	
	# 🌟 將自己加入 villagers 群組
	add_to_group("villagers")
	
	bubble.say("你好！")

	# 🌟 初始化 VisionArea
	if vision_shape.shape:
		vision_shape.shape = vision_shape.shape.duplicate()
	else:
		vision_shape.shape = CircleShape2D.new()
	
	_apply_radius()
	
	vision_area.area_entered.connect(_on_vision_area_entered)
	vision_area.area_exited.connect(_on_vision_area_exited)

# 快捷鍵監聽（按 D 開關圓圈，按 + / - 縮放半徑）
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_D:
			debug_draw = !debug_draw
			queue_redraw()
		elif event.keycode == KEY_EQUAL or event.keycode == KEY_KP_ADD:
			vision_radius_tiles += 1
		elif event.keycode == KEY_MINUS or event.keycode == KEY_KP_SUBTRACT:
			vision_radius_tiles -= 1

func _apply_radius() -> void:
	if not is_node_ready():
		await ready
	
	var circle := vision_shape.shape as CircleShape2D
	if circle:
		circle.radius = vision_radius_tiles * TILE_SIZE
	queue_redraw()

func _draw() -> void:
	if not debug_draw:
		return
	
	var current_radius := vision_radius_tiles * TILE_SIZE
	draw_circle(Vector2.ZERO, current_radius, Color(0.3, 0.7, 1.0, 0.15))
	draw_arc(Vector2.ZERO, current_radius, 0.0, TAU, 64, Color(0.3, 0.7, 1.0, 0.6), 2.0)

# -----------------------------------------------------------------
# 物理更新與視線動態檢查
# -----------------------------------------------------------------
func _physics_process(delta):
	if is_paused:
		velocity = Vector2.ZERO
		update_animation()
		return

	move_to_target()
	move_and_slide()
	update_animation()
	
	# 🌟 每幀動態檢查視線範圍內的村民是否被牆壁擋住
	_check_line_of_sight()

func move_to_target():
	if !has_target:
		velocity = Vector2.ZERO
		return

	if navigation.is_navigation_finished():
		velocity = Vector2.ZERO
		has_target = false
		return

	var next_point = navigation.get_next_path_position()
	var dir = next_point - global_position
	velocity = dir.normalized() * SPEED

# 🌟 視線檢查邏輯（含 null 安全防護）
func _check_line_of_sight() -> void:
	# 防護：確保 ray_cast 節點正常存在才執行
	if not is_instance_valid(ray_cast):
		return

	for target in detected_targets:
		if not is_instance_valid(target):
			continue
			
		# 設定 RayCast 方向指向目標村民
		ray_cast.global_position = global_position
		ray_cast.target_position = target.global_position - global_position
		ray_cast.force_raycast_update()
		
		# 如果射線第一個撞到的是對方村民（代表中間沒牆壁）
		if ray_cast.is_colliding():
			var collider = ray_cast.get_collider()
			if collider == target or collider.get_parent() == target:
				_trigger_detection()

# -----------------------------------------------------------------
# 感知與訊號觸發邏輯
# -----------------------------------------------------------------
func _on_vision_area_entered(other_area: Area2D) -> void:
	var other_villager := other_area.get_parent() as Node2D
	
	# 過濾：不是村民或撞到建築物就直接返回
	if not other_villager or other_villager == self or not other_villager.is_in_group("villagers"):
		return
	
	if not other_villager in detected_targets:
		detected_targets.append(other_villager)

func _on_vision_area_exited(other_area: Area2D) -> void:
	var other_villager := other_area.get_parent() as Node2D
	if other_villager in detected_targets:
		detected_targets.erase(other_villager)
	
	if detected_targets.is_empty():
		bubble.say("")

func _trigger_detection() -> void:
# 🌟 直接呼叫 bubble.say("！") 即可
	bubble.say("！")
	if not is_paused:
		_pause_movement(2.0)

func _pause_movement(duration: float) -> void:
	is_paused = true
	# 🌟 將 createTimer 改為 create_timer
	await get_tree().create_timer(duration).timeout
	is_paused = false

# -----------------------------------------------------------------
# 行程與動畫
# -----------------------------------------------------------------
func on_time_changed(hour:int, minute:int):
	var current_time = "%02d:%02d" % [hour, minute]
	for item in schedule:
		if item["time"] == current_time:
			go_to(item["place"])
			break

func load_schedule():
	var npc = GameManager.get_npc(villager_id)
	if npc == null:
		return
	schedule = npc["schedule"]

func go_to(place_name:String):
	current_place = place_name
	target_position = GameManager.get_place(place_name)
	navigation.target_position = target_position
	has_target = true

func update_animation():
	if velocity.length() < 1:
		if sprite.animation.begins_with("walk"):
			sprite.play(sprite.animation.replace("walk", "idle"))
		return

	var dir = velocity.normalized()
	sprite.flip_h = false

	if dir.y > 0.7:
		sprite.play("walk_down")
	elif dir.y < -0.7:
		sprite.play("walk_up")
	elif dir.x > 0.7:
		sprite.play("walk_right")
	elif dir.x < -0.7:
		sprite.play("walk_right")
		sprite.flip_h = true
	elif dir.x > 0 and dir.y > 0:
		sprite.play("walk_down_right")
	elif dir.x < 0 and dir.y > 0:
		sprite.play("walk_down_right")
		sprite.flip_h = true
	elif dir.x > 0 and dir.y < 0:
		sprite.play("walk_up_right")
	else:
		sprite.play("walk_up_right")
		sprite.flip_h = true

func choose_direction():
	direction = Vector2(
		randf_range(-1, 1),
		randf_range(-1, 1)
	).normalized()

func _on_state_changed():
	if has_target:
		return

	if state_machine.current_state == state_machine.State.WANDER:
		choose_direction()

func _on_village_state_changed() -> void:
	pass

func get_place_for_need(need:String) -> String:
	match need:
		"hunger":
			return "restaurant"
		"energy":
			return "home_001"
		"social":
			return "square"
		"fun":
			return "square"
		_:
			return ""
