class_name Character
extends CharacterBody2D

## Player 與 Agent 的共用基底。
## 移動一律走 NavGrid 的 A* 路徑；動畫是 front / back / right 三向素材，
## 往左沒有專屬素材，用 flip_h 翻轉 right 代替。
## 子類別只負責決定「往哪走」：Player 讀輸入，Agent 讀行程表。

signal move_finished(reached: bool)

const SPEED = 80.0
const ARRIVE_DISTANCE = 2.0		# 距離 waypoint 多近算抵達
const STUCK_TIME = 1.0			# 卡住多久就放棄目前路徑

const TALK_RANGE := 32.0		# 搭話距離上限，2 格

## talk 的失敗原因碼。計畫 §5.3 要求每個動作都要有 ——
## AI 要能知道「為什麼失敗」才有辦法重排行程。
##
## 對話「正常講完」不算失敗，那是 conversation.gd 的 REASON_*。
## 兩者不可混用，否則 AI 會把講完的對話當成錯誤而反覆重試
const TALK_OK := ""
const TALK_TARGET_NOT_FOUND := "TARGET_NOT_FOUND"
const TALK_TARGET_IS_SELF := "TARGET_IS_SELF"
const TALK_TOO_FAR := "TOO_FAR"
const TALK_TARGET_BUSY := "TARGET_BUSY"
const TALK_TARGET_UNINTERRUPTIBLE := "TARGET_UNINTERRUPTIBLE"

## 角色的身分，全遊戲唯一且不隨改名而變：存檔、記憶連結、交誼區都靠它指人。
## 是內部識別字，不拿來顯示。留空就用節點名的小寫當預設
##
## 現階段是手動指定 + 開場偵測重複。等存檔做起來（見計畫 §10）才會改成
## 建立角色時生成一次並持久化，那時跨玩家的唯一性也要一併處理
@export var character_id := ""

## 玩家給角色取的名字，是拿來顯示與被指令指名的那一個，可以改、可以撞名。
## 留空就沿用 character_id
@export var character_name := ""

@onready var sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var collider: CollisionShape2D = $CollisionShape2D
@onready var stats: Stats = get_node_or_null("Stats")
@onready var relationships: Relationships = get_node_or_null("Relationships")
@onready var bubble: Node2D = get_node_or_null("Bubble")
@onready var vision: Vision = get_node_or_null("Vision")

# 最後一次的面向：front / back / right，停下時用來挑 idle 動畫
var facing := "front"

var _path := PackedVector2Array()
var _path_index := 0
var _stuck_timer := 0.0
var _conversation: Node = null


func _ready() -> void:
	if character_id.is_empty():
		character_id = name.to_lower()

	if character_name.is_empty():
		character_name = character_id

	# 要在自己進 group 之前檢查，否則一定會掃到自己
	_warn_if_id_taken()
	add_to_group("characters")

	sprite.play("idle_" + facing)

# id 重複不會讓任何東西報錯，只會讓依 id 查角色的地方靜靜指到同一隻，
# 所以寧可開場就吵
func _warn_if_id_taken() -> void:
	for other in get_tree().get_nodes_in_group("characters"):
		if other.character_id == character_id:
			push_error("Character id 重複：%s 已經被 %s 用掉了" % [character_id, other.name])
			return


# ---- 移動 ----

# 走 A* 路徑到指定的世界座標；找不到路徑回傳 false
func move_to(target: Vector2) -> bool:
	var nav = get_tree().get_first_node_in_group("nav_grid")
	if nav == null:
		push_error("Character.move_to: 場景裡沒有 NavGrid")
		return false

	var path: PackedVector2Array = nav.find_path(get_body_position(), target)
	if path.size() < 2:
		stop_moving()
		return false

	_path = path
	_path_index = 1		# 第 0 點是目前所在格
	_stuck_timer = 0.0
	return true

func stop_moving() -> void:
	_path = PackedVector2Array()
	_path_index = 0
	_stuck_timer = 0.0
	velocity = Vector2.ZERO

func is_moving() -> bool:
	return _path_index < _path.size()

func get_path_points() -> PackedVector2Array:
	return _path

# 碰撞圓心的世界座標。CollisionShape2D 有 y 偏移，尋徑要用實體位置而不是 global_position，
# 否則路徑點會把碰撞體塞進牆裡
func get_body_position() -> Vector2:
	return to_global(collider.position)


# ---- 對話 ----

func is_in_conversation() -> bool:
	return _conversation != null

# 目前在做的事可不可以被打斷。基底一律可以，Agent 依行程覆寫
func is_interruptible() -> bool:
	return true

# 對某人搭話。成功回傳 TALK_OK（空字串），否則回傳失敗原因碼
func talk_to(other: Character) -> String:
	if other == null:
		return TALK_TARGET_NOT_FOUND
	if other == self:
		return TALK_TARGET_IS_SELF
	if is_in_conversation() or other.is_in_conversation():
		return TALK_TARGET_BUSY
	if get_body_position().distance_to(other.get_body_position()) > TALK_RANGE:
		return TALK_TOO_FAR
	if not other.is_interruptible():
		return TALK_TARGET_UNINTERRUPTIBLE

	# 用 load 而不是 preload：conversation.gd 反過來也要 Character 型別，
	# preload 會變成靜態循環相依
	var conversation = load("res://scripts/dialogue/conversation.gd").new()
	conversation.initiator = self
	conversation.target = other
	conversation.name = "Conversation_%s_%s" % [character_id, other.character_id]
	get_tree().current_scene.add_child(conversation)
	return TALK_OK

# 找最近的可搭話對象。按鍵搭話用得到；指令是直接指名，不走這裡
func find_nearest_character() -> Character:
	var nearest: Character = null
	var shortest := TALK_RANGE

	for node in get_tree().get_nodes_in_group("characters"):
		if node == self:
			continue

		var distance := get_body_position().distance_to(node.get_body_position())
		if distance <= shortest:
			shortest = distance
			nearest = node

	return nearest

func enter_conversation(conversation: Node) -> void:
	_conversation = conversation
	stop_moving()

func exit_conversation() -> void:
	_conversation = null

# 自己主動離開對話
func leave_conversation() -> void:
	if _conversation != null:
		_conversation.interrupt()

func say(line: String) -> void:
	if bubble != null:
		bubble.say(line)

# 這句話大概會佔多久，讓對話狀態機知道什麼時候換人講
func speech_duration(line: String) -> float:
	if bubble == null:
		return 1.5
	return clampf(line.length() * bubble.SECONDS_PER_CHAR, bubble.MIN_DURATION, bubble.MAX_DURATION)

# 講話時轉向對方，否則兩個人會背對背對話
func face_towards(other: Character) -> void:
	var offset := other.get_body_position() - get_body_position()

	if absf(offset.y) > absf(offset.x):
		facing = "back" if offset.y < 0 else "front"
	else:
		facing = "right"
		sprite.flip_h = offset.x < 0

	sprite.play("idle_" + facing)


# ---- 每幀 ----

# 依移動方向切換 walk / idle；沒有 left 素材，往左用 flip_h 翻轉 right
func update_animation() -> void:
	var dir := velocity.normalized()

	if dir == Vector2.ZERO:
		sprite.play("idle_" + facing)
		return

	# 垂直位移比水平大就用背面／正面，否則用側面
	if abs(dir.y) > abs(dir.x):
		facing = "back" if dir.y < 0 else "front"
	else:
		facing = "right"
		sprite.flip_h = dir.x < 0

	sprite.play("walk_" + facing)

# 這一幀要用的速度。基底只跟隨 A* 路徑，子類別覆寫來加上自己的驅動來源。
# 對話中不自動移動 —— 但 Player 的輸入會蓋過這裡，走遠了由距離判定自然散場
func _decide_velocity() -> Vector2:
	if is_in_conversation():
		return Vector2.ZERO

	if is_moving():
		return _follow_path()

	return Vector2.ZERO

# 朝目前 waypoint 前進，走完路徑就發出 move_finished
func _follow_path() -> Vector2:
	var body_position := get_body_position()

	while is_moving() and body_position.distance_to(_path[_path_index]) < ARRIVE_DISTANCE:
		_path_index += 1

	if not is_moving():
		stop_moving()
		move_finished.emit(true)
		return Vector2.ZERO

	return body_position.direction_to(_path[_path_index]) * SPEED

# 該走卻幾乎沒位移（被地形頂住）就放棄，避免無限原地打轉
func _check_stuck(delta: float) -> void:
	if get_real_velocity().length() > SPEED * 0.1:
		_stuck_timer = 0.0
		return

	_stuck_timer += delta
	if _stuck_timer >= STUCK_TIME:
		push_warning("%s: 路徑走不動，於 %s 中止" % [character_id, global_position])
		stop_moving()
		move_finished.emit(false)

func _physics_process(delta: float) -> void:
	velocity = _decide_velocity()
	move_and_slide()
	update_animation()

	if is_moving():
		_check_stuck(delta)
