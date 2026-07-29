extends Node


# 飢餓值 0~100
var hunger = 0.0


# 每秒增加多少飢餓
@export var hunger_rate = 2.0



func _process(delta):

	hunger += hunger_rate * delta

	hunger = clamp(hunger, 0, 100)


	if hunger >= 80:

		print("村民感到飢餓，目前:", hunger)
