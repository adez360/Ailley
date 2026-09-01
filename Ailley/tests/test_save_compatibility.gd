extends Node


func _ready() -> void:
	var character := Character.new()
	var old_player_save := {
		"character_id": "test-player",
		"character_name": "player",
		"personality": {},
		"emotion": {
			"type": "neutral",
			"intensity": 0.0,
			"cause_event_id": "",
			"duration_left": 0.0,
		},
	}
	character.load_save_data(old_player_save)
	assert(character.personality.is_empty())
	assert(character.emotion["intensity"] is int)
	assert(character.emotion["duration_left"] is int)
	character.free()
	print("Save compatibility verification passed")
	get_tree().quit(0)
