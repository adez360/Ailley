extends CharacterBody2D


const SPEED = 50.0

var direction = Vector2.ZERO

@onready var sprite = $AnimatedSprite2D
@onready var state_machine = $StateMachine
@onready var needs = $Needs

func _ready():
	sprite.play("idle_down")
	state_machine.state_changed.connect(_on_state_changed)
#	needs.hungry.connet(_on_hungry)

func update_animation():

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


func _physics_process(delta):

	if state_machine.current_state == state_machine.State.WANDER:

		velocity = direction * SPEED

	else:

		velocity = Vector2.ZERO


	move_and_slide()
	update_animation()
	
	position.x = clamp(position.x, 16, 1280)
	position.y = clamp(position.y, 16, 720)



func choose_direction():

	direction = Vector2(
		randf_range(-1, 1),
		randf_range(-1, 1)
	).normalized()



func _on_state_changed():

	if state_machine.current_state == state_machine.State.WANDER:

		choose_direction()

		print("新的移動方向:", direction)


func _on_village_state_changed() -> void:
	pass # Replace with function body.
