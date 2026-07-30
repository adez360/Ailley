extends Panel

@onready var label = $ScrollContainer/DebugLabel

func _process(_delta):

	var text = ""

	for villager in get_tree().get_nodes_in_group("villagers"):

		text += villager.villager_id + "\n"
		text += "Hunger : %d\n" % round(villager.needs.hunger)
		text += "Energy : %d\n" % round(villager.needs.energy)
		text += "Social : %d\n" % round(villager.needs.social)
		text += "Fun    : %d\n" % round(villager.needs.fun)
		text += "\n"

	label.text = text
