extends Node

signal time_changed(hour: int, minute: int)
## 跨日時發出。需要「第幾天」的系統訂閱這個，不要各自比對 hour 有沒有變小 ——
## 私有的日計數重開遊戲就歸零，靠它擋的東西（例如每日配額）等於沒擋
signal day_changed(day: int)

## 生理 tick 週期：Stats 漂移與 conditions 檢查的時間單位（遊戲分鐘）
const GAME_MINUTES_PER_TICK := 10

@export var seconds_per_game_minute := 1.0

## 跟著 get_world_save_data()／apply_world_save_data() 一起存讀，可以跨場次
## 接續（#19，hour／minute 見 #517）
var hour := 8
var minute := 0
## 第幾個遊戲日，從 1 起算
var day := 1
var _timer := 0.0

## 開始新遊戲時呼叫（#606）。_process() 沒有暫停開關，開機後只要引擎在跑
## 就一直累加，停在主選單也不例外——「繼續遊戲」不受影響，因為讀檔會把
## day/hour/minute 整個覆蓋回存檔值（見 apply_world_save_data()），但「開始
## 新遊戲」原本沒有對應的重置，玩家在主選單多待一段時間才按開始，一進場
## 時間就已經被選單掛機的時間推走。單一真相來源集中在這裡，不要讓
## main_menu.gd 自己去戳三個變數
func reset_to_new_game_start() -> void:
	day = 1
	hour = 8
	minute = 0
	_timer = 0.0


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
