extends Node

signal need_changed

@export var hunger := 100.0
@export var energy := 100.0
@export var social := 100.0
@export var fun := 100.0
var debug_timer := 0.0

func _process(delta):
	hunger -= delta * 3
	energy -= delta * 1
	social -= delta * 0.5
	fun -= delta * 0.2
	
	# 更新數值計時器
	debug_timer += delta

	hunger = clamp(hunger, 0, 100)
	energy = clamp(energy, 0, 100)
	social = clamp(social, 0, 100)
	fun = clamp(fun, 0, 100)

	if debug_timer >= 5.0:	# 每幾秒更新
		debug_timer = 0.0
		print(
			"H:", int(hunger),
			" E:", int(energy),
			" S:", int(social),
			" F:", int(fun)
		)


func needs_attention() -> bool:
	return (
		hunger < 30
		or energy < 30
		or social < 30
		or fun < 30
	)

func get_lowest_need() -> String:
	var lowest = "hunger"
	var value = hunger

	if energy < value:
		value = energy
		lowest = "energy"

	if social < value:
		value = social
		lowest = "social"

	if fun < value:
		lowest = "fun"

	return lowest
