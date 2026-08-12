class_name Character
extends CharacterBody2D

## Player 與 Agent 的共用基底。
## 移動一律走 NavGrid 的 A* 路徑；動畫是 front / back / right 三向素材，
## 往左沒有專屬素材，用 flip_h 翻轉 right 代替。
## 子類別只負責決定「往哪走」：Player 讀輸入，Agent 讀行程表。

signal move_finished(reached: bool)
signal noise_heard(source: Character)		# 收到的那一方會發，見 make_noise()

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

## 滑鼠指到時套在 sprite 上的描邊
const OUTLINE_SHADER := preload("res://assets/shaders/character_outline.gdshader")

## 角色的身分，全遊戲唯一且不隨改名而變：存檔、記憶連結、交誼區都靠它指人。
## 是內部識別字，不拿來顯示，也**不要去解析它** —— 格式只有 generate_id() 說了算。
##
## 留空就生成一個，這是正常路徑；`@export` 只留給場景裡手擺的測試角色。
## 目前每次開遊戲都重新生成，要跨場次接續得等存檔把它寫下來
@export var character_id := ""

## 玩家給角色取的名字，是拿來顯示與被指令指名的那一個，可以改、可以撞名。
## 留空就沿用節點名 —— 不能退回 character_id，那是一串沒人讀得懂的 UUID
@export var character_name := ""

@onready var sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var collider: CollisionShape2D = $CollisionShape2D
@onready var stats: Stats = get_node_or_null("Stats")
@onready var relationships: Relationships = get_node_or_null("Relationships")
@onready var bubble: Node2D = get_node_or_null("Bubble")
@onready var vision: Vision = get_node_or_null("Vision")
@onready var inventory: Inventory = get_node_or_null("Inventory")

# 最後一次的面向：front / back / right，停下時用來挑 idle 動畫
var facing := "front"

var _path := PackedVector2Array()
var _path_index := 0
var _stuck_timer := 0.0
var _conversation: Node = null
var _highlighted := false
var _outline: ShaderMaterial = null


func _ready() -> void:
	if character_id.is_empty():
		character_id = generate_id()

	if character_name.is_empty():
		character_name = name.to_lower()

	_ensure_unique_id()
	add_to_group("characters")

	sprite.play("idle_" + facing)

# 隨機的 UUID v4。刻意不帶任何語意 —— 擁有者、名字、行程都不編進去，
# 那些各自是欄位。把 owner 寫進 id 的話，帳號系統一改就得替所有存檔寫遷移
static func generate_id() -> String:
	var bytes := Crypto.new().generate_random_bytes(16)
	bytes[6] = (bytes[6] & 0x0F) | 0x40		# version 4
	bytes[8] = (bytes[8] & 0x3F) | 0x80		# variant 10
	var hex := bytes.hex_encode()
	return "%s-%s-%s-%s-%s" % [
		hex.substr(0, 8), hex.substr(8, 4), hex.substr(12, 4),
		hex.substr(16, 4), hex.substr(20, 12),
	]

# 撞 id 的兩隻會共用同一份關係與記憶（relationships.gd 拿 id 當 key），
# 所以這裡換掉一個，而不是印完錯誤照樣讓兩隻共用。
# 生成的 id 不會撞，會走到這裡的是場景裡手寫重複，或日後讀進壞掉的存檔
func _ensure_unique_id() -> void:
	var holder := _find_id_holder(character_id)
	while holder != null:
		var taken := character_id
		character_id = generate_id()
		push_error("Character id 重複：%s 已被 %s 用掉，%s 改用 %s" % [
			taken, holder.name, name, character_id
		])
		holder = _find_id_holder(character_id)

# 佔用這個 id 的節點，沒人用回 null。回節點而不是 bool 是為了讓訊息講得出
# 「被誰佔走」—— 撞到的是手寫 id，得知道去改哪一隻才有意義。
#
# 一定要排除自己：讀存檔會在自己進 group 之後才修 id，掃得到自己的話，
# 換幾次新 id 都還是掃得到自己，上面那個 while 就永遠停不下來
func _find_id_holder(id: String) -> Character:
	for other in get_tree().get_nodes_in_group("characters"):
		if other != self and other.character_id == id:
			return other as Character
	return null


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


# ---- 聲音 ----

## 廣播半徑（像素），8 格。跟 Vision 刻意不同：聲音不判定視線遮蔽，穿牆照樣聽得到
const NOISE_RADIUS := 128.0

## 對外廣播「這裡發出聲音」。範圍內每個角色都會收到 noise_heard 訊號，
## 要不要有反應（例如冒出 !?）由收到的那一方決定——跟 Vision 的
## spotted/反應分離是同一種分工，這裡只負責喊，不管誰在乎
func make_noise(radius: float = NOISE_RADIUS) -> void:
	for other in get_tree().get_nodes_in_group("characters"):
		if other == self:
			continue
		if get_body_position().distance_to(other.get_body_position()) <= radius:
			other.noise_heard.emit(self)


# ---- 狀態快照 ----

# 純資料的角色狀態，不含任何翻譯字串或 BBCode。debug_console.gd 的 status
# 指令只負責把這份 Dictionary 排版顯示，不重新蒐集一次；日後 LLM payload
# （見 note/技術/LLM 串接與 AI 服務層.md）要的也是同一批資料。
#
# key/value 一律是識別字，不可以是翻譯過的字 —— Stats.SPEC 的 label 存的是
# 翻譯 key，這裡照樣只放 key，翻譯留給顯示端做。stats/affinity 只有掛了對應
# 元件才會出現在回傳值裡，呼叫端用 has() 判斷。
#
# 子類別自己的欄位由子類別 override 這個方法補上（agent.gd 補 schedule），
# 基底不去猜誰是什麼
func get_state_snapshot() -> Dictionary:
	var snapshot := {
		"id": character_id,
		"name": character_name,
		"position": get_body_position(),
		"moving": is_moving(),
		"facing": facing,
		"animation": sprite.animation,
		"in_conversation": is_in_conversation(),
	}

	if stats != null:
		var values := {}
		for key in Stats.SPEC:
			values[key] = stats.get_value(key)
		snapshot["stats"] = values

	# 只放金錢，不放整份背包：Agent 查得到自己有多少錢是最低限度，
	# 而 slots 是 36 格的陣列，塞進每一次快照（含日後的 LLM payload）太貴。
	# 要看背包內容的呼叫端自己拿 inventory.get_summary()
	if inventory != null:
		snapshot["money"] = inventory.get_money()

	# 欄名跟 relationships.gd 的 record 一致（affinity / met_count），
	# 不要在這裡改名——同一個數值有兩個名字，讀過 relationships.gd 的人
	# 會在 snapshot 上找不到 affinity。用純量 accessor 不用 get_record()，
	# 後者每筆都 duplicate(true) 深拷一份只為了讀兩個數字
	if relationships != null:
		var known := relationships.known_ids()
		if not known.is_empty():
			var affinity := {}
			for other_id in known:
				affinity[other_id] = {
					"affinity": relationships.get_affinity(other_id),
					"met_count": relationships.get_met_count(other_id),
				}
			snapshot["affinity"] = affinity

	return snapshot


# ---- 滑鼠選取 ----

# 滑鼠點得到的範圍，世界座標。用目前影格的圖去量而不是碰撞形狀 ——
# 碰撞形狀只有腳下那一個小圓，照它算的話點頭部會點不到
func get_pick_rect() -> Rect2:
	var texture := _current_frame_texture()
	if texture == null:
		return Rect2(sprite.global_position, Vector2.ZERO)

	var size := Vector2(texture.get_size())
	var origin := sprite.global_position + sprite.offset
	if sprite.centered:
		origin -= size * 0.5

	return Rect2(origin, size)

func is_highlighted() -> bool:
	return _highlighted

# 描一圈邊表示滑鼠正指著這個角色。
# 材質是第一次要用才建，沒被指到過的角色不會多背一份
func set_highlighted(on: bool) -> void:
	if on == _highlighted:
		return

	_highlighted = on

	if not on:
		sprite.material = null
		sprite.frame_changed.disconnect(_sync_outline_frame)
		sprite.animation_changed.disconnect(_sync_outline_frame)
		return

	if _outline == null:
		_outline = ShaderMaterial.new()
		_outline.shader = OUTLINE_SHADER

	sprite.material = _outline
	# 換影格與換動畫都會換到圖集的另一塊，不同步的話描邊會停在上一格的輪廓
	sprite.frame_changed.connect(_sync_outline_frame)
	sprite.animation_changed.connect(_sync_outline_frame)
	_sync_outline_frame()

# 告訴描邊 shader 目前這一格在圖集裡佔哪個 UV 範圍，
# 它才不會取樣到緊鄰的下一格
func _sync_outline_frame() -> void:
	var atlas := _current_frame_texture() as AtlasTexture
	if atlas == null or atlas.atlas == null:
		_outline.set_shader_parameter("region", Vector4(0.0, 0.0, 1.0, 1.0))
		return

	var full := Vector2(atlas.atlas.get_size())
	var used := atlas.region
	_outline.set_shader_parameter("region", Vector4(
		used.position.x / full.x, used.position.y / full.y,
		used.end.x / full.x, used.end.y / full.y
	))

func _current_frame_texture() -> Texture2D:
	if sprite.sprite_frames == null:
		return null
	if not sprite.sprite_frames.has_animation(sprite.animation):
		return null

	return sprite.sprite_frames.get_frame_texture(sprite.animation, sprite.frame)


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
		push_warning("%s: 路徑走不動，於 %s 中止" % [character_name, global_position])
		stop_moving()
		move_finished.emit(false)

func _physics_process(delta: float) -> void:
	velocity = _decide_velocity()
	move_and_slide()
	update_animation()

	if is_moving():
		_check_stuck(delta)
