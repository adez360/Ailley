extends Node

var places = {}

func _ready():
	load_places()

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

	return Vector2(
		places[place_name]["x"],
		places[place_name]["y"]
	)
