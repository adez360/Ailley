class_name Animal
extends CharacterBody2D

## 森林動物（issue #573）。刻意不走 Character／Agent 那套 LLM 決策架構——
## 動物沒有意圖、不需要打 AI API，出沒行為只是給森林添點動態的裝飾，真正的
## 互動判定（獵不獵得到）交給 Character.hunt() 與《01-2》SUCCESS_PARAMS 的擲骰。
##
## 移動只是 Timer 驅動的隨機遊走：在自己出生點附近隨機挑一個點走過去，到了
## 再挑下一個，不用 NavGrid／A*，也不維護 Character 那套 path/stuck 偵測。

const SPEED := 30.0
const WANDER_RADIUS := 96.0
const WANDER_INTERVAL_MIN := 2.0
const WANDER_INTERVAL_MAX := 5.0
const ARRIVE_THRESHOLD := 4.0

## `_on_wander_timer_timeout()` 在 `_wandering` 為 true 時直接 return（見下方），
## 挑新目標只能靠抵達（`ARRIVE_THRESHOLD`）或這個逾時來清掉 `_wandering`。
## 沒有這個逾時的話，障礙物擋住 `move_and_slide()` 時動物會永遠卡在遊走狀態，
## 永遠選不到下一個目標（CodeRabbit review, PR #621）。抓走到 WANDER_RADIUS
## 邊緣的最長時間（96 / 30 = 3.2 秒）留一倍安全邊界
const WANDER_TIMEOUT := 6.0

## 對應《08》已定案的 item_id（"small_game" 或 "large_game"）——Character.hunt()
## 直接拿這個值當 add_item() 的 item_id，兩者刻意共用同一組字串，不要各自維護
@export var game_type: String = "small_game"

var _home_position := Vector2.ZERO
var _wander_target := Vector2.ZERO
var _wandering := false
var _wander_elapsed := 0.0

@onready var _wander_timer: Timer = $WanderTimer


func _ready() -> void:
	add_to_group("animals")
	_home_position = global_position
	_wander_timer.wait_time = randf_range(WANDER_INTERVAL_MIN, WANDER_INTERVAL_MAX)
	_wander_timer.timeout.connect(_on_wander_timer_timeout)
	_wander_timer.start()


func _physics_process(delta: float) -> void:
	if _wandering:
		velocity = global_position.direction_to(_wander_target) * SPEED
		_wander_elapsed += delta
		if global_position.distance_to(_wander_target) < ARRIVE_THRESHOLD or _wander_elapsed >= WANDER_TIMEOUT:
			_wandering = false
			velocity = Vector2.ZERO
	else:
		velocity = Vector2.ZERO
	move_and_slide()


func _on_wander_timer_timeout() -> void:
	if _wandering:
		return
	_wander_timer.wait_time = randf_range(WANDER_INTERVAL_MIN, WANDER_INTERVAL_MAX)
	var offset := Vector2(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0))
	_wander_target = _home_position + offset.normalized() * randf_range(0.0, WANDER_RADIUS)
	_wandering = true
	_wander_elapsed = 0.0


## 被獵殺後從場景移除。呼叫端（Character.hunt()）已經在呼叫這個之前把戰利品
## 加進獵人背包，這裡只管動物本身的收尾，不做重生／regen——地點資料結構裡的
## `regen` 欄位是森林資源庫存的抽象值，MVP 這則 issue 不做庫存追蹤（見
## note/規格書/07_地點/森林.md），動物死了就是不見了
func remove_from_world() -> void:
	queue_free()
