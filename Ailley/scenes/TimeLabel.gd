extends Label

func _ready():
	GameClock.time_changed.connect(update_time)
	update_time(GameClock.hour, GameClock.minute)

func update_time(hour: int, minute: int):
	text = "%02d:%02d" % [hour, minute]
