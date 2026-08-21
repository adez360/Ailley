extends Node

signal time_changed(hour: int, minute: int)
## 跨日時發出。需要「第幾天」的系統訂閱這個，不要各自比對 hour 有沒有變小 ——
## 私有的日計數重開遊戲就歸零，靠它擋的東西（例如每日配額）等於沒擋
signal day_changed(day: int)

## 生理 tick 週期：Stats 漂移與 conditions 檢查的時間單位（遊戲分鐘）
const GAME_MINUTES_PER_TICK := 10

@export var seconds_per_game_minute := 1.0

var hour := 8
var minute := 0
## 第幾個遊戲日，從 1 起算。跟著 get_world_save_data()／apply_world_save_data()
## 一起存讀，可以跨場次接續（#19）
var day := 1
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
			day += 1
			# 先發 day_changed：time_changed 的訂閱者讀到的 day 才是新的那天
			day_changed.emit(day)

		time_changed.emit(hour, minute)
