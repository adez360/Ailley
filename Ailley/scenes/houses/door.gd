extends StaticBody2D


@onready var animated_sprite_2d: AnimatedSprite2D = $AnimatedSprite2D
@onready var collision_shape_2d: CollisionShape2D = $CollisionShape2D
@onready var interactable_component: InteractableComponent = $InteractableComponent

func _ready() -> void:
	interactable_component.interactable_activated.connect(on_interactable_activated)
	interactable_component.interactable_deactivated.connect(on_interactable_deactivated)

func on_interactable_activated() -> void:
	animated_sprite_2d.play("door-open")
	collision_shape_2d.set_deferred("disabled", true)

func on_interactable_deactivated() -> void:
	animated_sprite_2d.play("door-close")
	collision_shape_2d.set_deferred("disabled", false)
