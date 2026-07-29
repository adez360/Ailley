extends CharacterBody2D


const SPEED = 50.0

var direction = Vector2.ZERO


@onready var state_machine = $StateMachine


func _ready():

	state_machine.state_changed.connect(_on_state_changed)



func _physics_process(delta):

	if state_machine.current_state == state_machine.State.WANDER:

		velocity = direction * SPEED

	else:

		velocity = Vector2.ZERO


	move_and_slide()



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
