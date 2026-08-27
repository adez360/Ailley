extends Control

## 每日時鐘 HUD：指針一天轉一整圈（不是傳統 12 小時鐘），
## 對應 GameClock 的 24 小時制與 TimeLabel 顯示的整天進度

func _ready() -> void:
	GameClock.time_changed.connect(_on_time_changed)
	_on_time_changed(GameClock.hour, GameClock.minute)

func _on_time_changed(hour: int, minute: int) -> void:
	var day_fraction := (hour * 60 + minute) / 1440.0
	$Hand.rotation = day_fraction * TAU
