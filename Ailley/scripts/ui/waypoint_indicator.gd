class_name WaypointIndicator
extends Node2D

## 玩家頭上的方向指標，指向 show_waypoint() 給的世界座標。
##
## 跟 bubble.gd／money_popup.gd 同一種「掛在角色身上」的頭上 UI 模式——
## 箭頭原點就是玩家自己的位置，方向永遠算得出來，不受目標在不在畫面內
## 影響，不需要另外處理螢幕邊緣裁切那套 off-screen indicator 的邏輯。
##
## 只服務一個 waypoint，不做多目標佇列——目前唯一的呼叫端（#305）一次
## 只會有一個進行中的說服請求，需要佇列的時候再加。

## 距離連續變遠這麼久，判定玩家放棄，指標自動收掉
const ABANDON_WINDOW_SEC := 4.0

## 多久量一次距離變化的趨勢。太頻繁的話玩家原地小幅度晃動（例如被卡住、
## 或只是微調站位）就會被誤判成「變遠」，拉長取樣間隔可以把這種雜訊平滑掉
const CHECK_INTERVAL_SEC := 0.5

## 兩次距離量測的容許誤差。浮點與物理解算會有次像素級的抖動，玩家站著不動
## 時距離不會剛好逐位元相等——沒有這個容差，原地不動也會被判定成「變遠」
const DISTANCE_TOLERANCE := 0.5

## 抵達／放棄判定要用角色的碰撞中心，不能用這個節點自己的 global_position——
## 這個節點掛在角色頭上方（見場景裡的 position 偏移），拿它自己的位置算距離，
## 目標在角色上方時會提早判定抵達、目標在下方時會延後，兩邊都不準。
## 方向指標的旋轉角度不受影響，那個仍然要用這個節點自己的位置（見 _process()）
@onready var _character: Character = get_parent()

var _target_position := Vector2.ZERO
var _on_arrived := Callable()
var _on_abandoned := Callable()
var _active := false
var _worse_streak_sec := 0.0
var _last_distance := 0.0
var _check_timer := 0.0


func _ready() -> void:
	visible = false
	set_process(false)


## 開始引導：畫面上出現指標，指向 world_position。抵達或判定放棄時
## 分別呼叫對應的 callback（可以是空 Callable，等同不關心那個結果），
## 呼叫完就自動收掉指標，呼叫端不用自己記得清
func show_waypoint(world_position: Vector2, on_arrived: Callable, on_abandoned: Callable) -> void:
	_target_position = world_position
	_on_arrived = on_arrived
	_on_abandoned = on_abandoned
	_active = true
	_worse_streak_sec = 0.0
	_last_distance = _character.get_body_position().distance_to(_target_position)
	_check_timer = 0.0
	visible = true
	set_process(true)


## 呼叫端主動取消（例如彈窗被別的事件打斷）。不觸發任何 callback——
## 那兩個是「指標自己判定的結果」，主動取消是呼叫端自己已經知道原因了
func clear_waypoint() -> void:
	_active = false
	_on_arrived = Callable()
	_on_abandoned = Callable()
	visible = false
	set_process(false)


func is_active() -> bool:
	return _active


func _process(delta: float) -> void:
	if not _active:
		return

	var body_position := _character.get_body_position()
	var distance := body_position.distance_to(_target_position)

	# 沿用 Character.TALK_RANGE，不自己另訂一個同樣是 32.0 的常數——「引導玩家
	# 去某個地點」跟「走到能對話的距離」在語意上是同一種「到了」，兩個常數各自
	# 維護遲早會漂移（CodeRabbit review 抓到）
	if distance <= Character.TALK_RANGE:
		_finish(_on_arrived)
		return

	# 指標本身不隨父節點（角色）縮放翻轉——facing 只動 sprite.flip_h，
	# 不動角色根節點的 scale/rotation（見 character.gd），所以這裡設的
	# rotation 就是箭頭真正指向的方向，不會被翻轉打亂。這裡刻意用自己的
	# global_position（不是 body_position）算方向——箭頭畫在自己的位置上，
	# 方向要跟畫的地方對齊，抵達／放棄判定才是身體位置的事
	rotation = (_target_position - global_position).angle()

	_check_timer += delta
	if _check_timer < CHECK_INTERVAL_SEC:
		return
	# 用實際累積的取樣間隔，不是固定的 CHECK_INTERVAL_SEC——掉幀讓單幀 delta
	# 超過檢查間隔時（例如一幀就經過 1.5 秒），_check_timer 這次真正涵蓋的是
	# 那 1.5 秒，只算 0.5 秒會低估放棄計時的累積速度，讓玩家能拖過 4 秒門檻
	# 還不觸發 _on_abandoned（CodeRabbit review 抓到）
	var elapsed_since_check := _check_timer
	_check_timer = 0.0

	# 容差內視為「沒有變遠」，不然玩家站著不動也會被物理解算的次像素抖動
	# 判定成持續遠離
	if distance > _last_distance + DISTANCE_TOLERANCE:
		_worse_streak_sec += elapsed_since_check
		if _worse_streak_sec >= ABANDON_WINDOW_SEC:
			_finish(_on_abandoned)
			return
	else:
		_worse_streak_sec = 0.0

	_last_distance = distance


func _finish(callback: Callable) -> void:
	clear_waypoint()
	if callback.is_valid():
		callback.call()
