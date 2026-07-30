extends CharacterBody2D


const SPEED = 50.0

var direction = Vector2.ZERO
var target_position = Vector2.ZERO
var has_target = false
var schedule = []
var current_place = ""

@export var villager_id = "npc001"

@onready var sprite = $AnimatedSprite2D
@onready var state_machine = $StateMachine
@onready var needs = $Needs
@onready var navigation = $NavigationAgent2D
@onready var bubble = $Bubble

func on_time_changed(hour:int, minute:int):
	var current_time = "%02d:%02d" % [hour, minute]
	for item in schedule:
		if item["time"] == current_time:
			print(villager_id, "現在前往", item["place"])
			go_to(item["place"])
			break

# 讀取行程資料
func load_schedule():
	var npc = GameManager.get_npc(villager_id)
	if npc == null:
		print("找不到：", villager_id)
		return
	schedule = npc["schedule"]
#	var file = FileAccess.open(
#		"res://data/npc_schedule.json",
#		FileAccess.READ
#	)
#	if file == null:
#		print("找不到 JSON")
#		return
#	var json_text = file.get_as_text()
#	file.close()
#	var data = JSON.parse_string(json_text)
#	for npc in data["villagers"]:
#		if npc["id"] == villager_id:
#			print(villager_id, " 找到自己的資料")
#			go_to(npc["target"])
#			schedule = npc["schedule"]
#			break

func _ready():
#	print("我是", villager_id)
	sprite.play("idle_down")
#	state_machine.state_changed.connect(_on_state_changed)
#	needs.hungry.connet(_on_hungry)
	load_schedule()
	GameClock.time_changed.connect(on_time_changed)
	on_time_changed(GameClock.hour, GameClock.minute)
	add_to_group("villagers")
	bubble.say("你好！")

func update_animation():	# 控制移動時動畫的function
	# 沒有移動
	if velocity.length() < 1:
		if sprite.animation.begins_with("walk"):
			sprite.play(sprite.animation.replace("walk", "idle"))
		return

	var dir = velocity.normalized()
	sprite.flip_h = false

	# ↓
	if dir.y > 0.7:
		sprite.play("walk_down")
	# ↑
	elif dir.y < -0.7:
		sprite.play("walk_up")
	# →
	elif dir.x > 0.7:
		sprite.play("walk_right")
	# ←
	elif dir.x < -0.7:
		sprite.play("walk_right")
		sprite.flip_h = true
	# ↘
	elif dir.x > 0 and dir.y > 0:
		sprite.play("walk_down_right")
	# ↙
	elif dir.x < 0 and dir.y > 0:
		sprite.play("walk_down_right")
		sprite.flip_h = true
	# ↗
	elif dir.x > 0 and dir.y < 0:
		sprite.play("walk_up_right")
	# ↖
	else:
		sprite.play("walk_up_right")
		sprite.flip_h = true

func move_to_target():
	if !has_target:
		velocity = Vector2.ZERO
		return

	if navigation.is_navigation_finished():
		print(villager_id, "已抵達目的地")
		velocity = Vector2.ZERO
		has_target = false
		return

	var next_point = navigation.get_next_path_position()
	var dir = next_point - global_position
	velocity = dir.normalized() * SPEED

func go_to(place_name:String):
	current_place = place_name
	target_position = GameManager.get_place(place_name)
	navigation.target_position = target_position
	has_target = true

func _physics_process(delta):
	move_to_target()
	move_and_slide()
	update_animation()
	if needs.needs_attention():
		print(villager_id, "需要處理：", needs.get_lowest_need())
#	position.x = clamp(position.x, 16, 1280)
#	position.y = clamp(position.y, 16, 720)

func choose_direction():
	direction = Vector2(
		randf_range(-1, 1),
		randf_range(-1, 1)
	).normalized()

func _on_state_changed():
# 已經有導航目的地，就不理會狀態機
	if has_target:
		return

	if state_machine.current_state == state_machine.State.WANDER:
		choose_direction()
		print("新的移動方向:", direction)

func _on_village_state_changed() -> void:
	pass # Replace with function body.

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
