extends Node

var occupancy := {}

func _ready():

	for place_name in GameManager.places.keys():
		occupancy[place_name] = []

# NPC進入場所
func enter_place(place_name:String, npc_id:String):
	if !occupancy.has(place_name):
		return false
	var data = GameManager.get_place_data(place_name)
	if occupancy[place_name].size() >= data["capacity"]:
		return false
	occupancy[place_name].append(npc_id)
	return true

# NPC離開場所
func leave_place(place_name:String, npc_id:String):
	if !occupancy.has(place_name):
		return
	occupancy[place_name].erase(npc_id)

# 查詢場所是否已滿
func is_full(place_name:String):
	var data = GameManager.get_place_data(place_name)
	return occupancy[place_name].size() >= data["capacity"]

# 查詢有哪些人
func get_people(place_name:String):
	return occupancy[place_name]
