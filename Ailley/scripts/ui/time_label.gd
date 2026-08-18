extends Label

## 畫面上的遊戲時鐘。
##
## 從舊的 scenes/TimeLabel.gd 移植，邏輯沒有變 —— 只是搬離 scenes/：
## 那個資料夾裝的是 .tscn，腳本放在裡面會讓「場景」與「程式」的界線消失。
##
## 訂閱 GameClock 而不是每幀讀它：時間一遊戲分鐘才跳一次，
## 每幀重設同一個字串是白費的

func _ready() -> void:
	GameClock.time_changed.connect(_on_time_changed)
	_on_time_changed(GameClock.hour, GameClock.minute)

func _on_time_changed(hour: int, minute: int) -> void:
	## GameClock 保證跨日時先發 day_changed 再發 time_changed（見 GameClock.gd:29），
	## 所以這裡直接讀 GameClock.day 就是當下那天，不用另外訂閱 day_changed 自己存一份。
	text = "第 %d 天 %02d:%02d" % [GameClock.day, hour, minute]
