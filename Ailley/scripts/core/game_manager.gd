extends Node

var places = {}
var npc_data = {}

func _ready():
	load_places()
	load_npc_data()

func load_places():
	var file = FileAccess.open(
		"res://data/places.json",
		FileAccess.READ
	)
	if file == null:
		print("找不到 places.json")
		return

	var data = JSON.parse_string(file.get_as_text())
	file.close()
	places = data["places"]

func get_place(place_name:String)->Vector2:
	if !places.has(place_name):
		return Vector2.ZERO
		
	var p = places[place_name]

	return Vector2(
		p["x"],
		p["y"]
	)

# 讀取NPC行程
func load_npc_data():
	var file = FileAccess.open(
		"res://data/npc_schedule.json",
		FileAccess.READ
	)
	if file == null:
		push_error("找不到 npc_schedule.json")
		return
		
	var data = JSON.parse_string(file.get_as_text())
	file.close()
	npc_data.clear()
	for npc in data["villagers"]:
		npc_data[npc["id"]] = npc

# 查詢NPC行程
func get_npc(id:String):
	return npc_data.get(id, null)

func get_place_data(place_name:String):
	if !places.has(place_name):
		return null
	return places[place_name]
