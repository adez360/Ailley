extends Node

signal time_changed(hour: int, minute: int)

@export var seconds_per_game_minute := 1.0

var hour := 8
var minute := 0
var _timer := 0.0

func _process(delta: float) -> void:
	_timer += delta
	if _timer >= seconds_per_game_minute:
		_timer -= seconds_per_game_minute
		minute += 1

		if minute >= 60:
			minute = 0
			hour += 1

		if hour >= 24:
			hour = 0

		time_changed.emit(hour, minute)
