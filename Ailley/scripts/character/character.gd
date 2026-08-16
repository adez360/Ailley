class_name Character
extends CharacterBody2D

## Player 與 Agent 的共用基底。
## 移動一律走 NavGrid 的 A* 路徑；動畫是 front / back / right 三向素材，
## 往左沒有專屬素材，用 flip_h 翻轉 right 代替。
## 子類別只負責決定「往哪走」：Player 讀輸入，Agent 讀行程表。

signal move_finished(reached: bool)
signal noise_heard(source: Character)		# 收到的那一方會發，見 make_noise()
signal spoke(line: String)			# 講出任何一句話都會發，日後寫逐字稿/記憶系統的接點

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

const WORK_RANGE := 32.0		# 跟 TALK_RANGE 一樣的距離門檻，2 格

## work_at() 的失敗原因碼，形狀比照 TALK_*——計畫 §5.3 要求每個動作都要能講出
## 為什麼失敗，AI 才有辦法重排行程
const WORK_OK := ""
const WORK_TARGET_NOT_FOUND := "TARGET_NOT_FOUND"
const WORK_TOO_FAR := "TOO_FAR"
const WORK_OCCUPIED := "OCCUPIED"	# 工作站已經有別人在用
const WORK_BUSY := "BUSY"		# 自己已經在對話，或已經在工作

## 工作要花的遊戲分鐘數。GameClock 一遊戲分鐘 = 1 現實秒（見 GameClock.gd 的
## seconds_per_game_minute），所以這裡不直接寫「等 5 秒」，改數
## GameClock.time_changed 發了幾次——遊戲時間流速哪天調快調慢，這裡不用跟著改
const WORK_DURATION_MINUTES := 5

## 做完一次工作固定拿多少錢。#62 明講先不做成功率或產出計價，
## 職業系統留到《99 待規劃項目清單》P-02 拍板之後再做
const WORK_PAYMENT := 50

const BUY_RANGE := 32.0		# 跟 TALK_RANGE／WORK_RANGE 一樣的距離門檻，2 格

## buy_from() 的失敗原因碼，形狀比照 TALK_*／WORK_*。除了這五個，buy_from()
## 還會**原樣轉傳** Inventory 自己的原因碼（`NOT_ENOUGH`、`NO_SPACE`），
## 不在這裡重新取名——沒有必要跟 Inventory 的字典再對一次照
const BUY_OK := ""
const BUY_TARGET_NOT_FOUND := "TARGET_NOT_FOUND"
const BUY_TOO_FAR := "TOO_FAR"
const BUY_ITEM_NOT_FOUND := "ITEM_NOT_FOUND"		# 販賣機沒有賣這個 item_id
const BUY_NO_INVENTORY := "NO_INVENTORY"		# 沒有背包的角色沒辦法買東西

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
@onready var work_progress: WorkProgress = get_node_or_null("WorkProgress")
@onready var money_popup: MoneyPopup = get_node_or_null("MoneyPopup")
@onready var memory: Memory = get_node_or_null("Memory")

# 最後一次的面向：front / back / right，停下時用來挑 idle 動畫
var facing := "front"

# 把 facing／sprite.flip_h 重建成單位向量，給互動優先序這類「候選是不是在我
# 正對著的方向上」的判斷用（見 player.gd 的 _is_facing()）。跟
# update_animation()／face_towards() 寫入這兩個欄位時用的方向對稱：
# front=下、back=上、right 依 flip_h 分左右
func get_facing_direction() -> Vector2:
	match facing:
		"back":
			return Vector2.UP
		"right":
			return Vector2.LEFT if sprite.flip_h else Vector2.RIGHT
		_:
			return Vector2.DOWN

var _path := PackedVector2Array()
var _path_index := 0
var _stuck_timer := 0.0
var _conversation: Node = null

# 滑鼠 hover（selection.gd）跟 E 鍵目前的互動目標（player.gd）是兩個獨立的
# 高亮來源，任一個成立就該顯示描邊。分開存，不是合用一個布林值——CodeRabbit
# review 抓到的問題：合用的話，一邊把它關掉（例如滑鼠移開）會連帶關掉另一邊
# 還想要的描邊（例如玩家還面向著這個人），而且兩邊都是「目標沒變就不重呼叫」
# 的 edge-triggered 寫法，被對方關掉之後不會自己補回來
var _mouse_highlighted := false
var _interact_highlighted := false
var _highlighted := false
var _outline: ShaderMaterial = null


func _ready() -> void:
	# 場景裡固定的 NPC，身分是設計時決定好的資料——先用節點名查 npc_schedule.json 的
	# identities（跟 agent.gd::_load_schedule() 查 assignments 同一個模式）。查到就用，
	# 讓 character_id 跨場次穩定（relationships 拿它當 key，每次重開都變等於認識的人全歸零）。
	# @export 手擺的值優先（測試角色）；兩者都空才落回生成 UUID／節點名，這條保留給
	# Player 與動態生成的角色
	var identity := GameManager.get_npc_identity(name)

	if character_id.is_empty():
		character_id = str(identity.get("character_id", ""))
	if character_id.is_empty():
		character_id = generate_id()

	if character_name.is_empty():
		character_name = str(identity.get("character_name", ""))
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

# 這次 move_to() 的目標世界座標。move_to() 的呼叫端不只一個（仲裁器、
# debug 主控台的 goto 類指令都會直接呼叫），
# 但 move_finished 訊號是同一個，收到訊號的一方得自己有辦法分辨「這是不是
# 我剛才發出的那個請求」——靠比對這個欄位跟自己期待的目標位置
var last_move_target := Vector2.ZERO

# 走 A* 路徑到指定的世界座標；找不到路徑回傳 false
func move_to(target: Vector2) -> bool:
	var nav = get_tree().get_first_node_in_group("nav_grid")
	if nav == null:
		push_error("Character.move_to: 場景裡沒有 NavGrid")
		return false

	last_move_target = target

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

# 能不能被搭話打斷。工作中一律不行——work_at() 擋掉「對話中的人去工作」，
# 這裡是對稱的另一半：擋掉「把工作中的人拉進對話」。只做單邊的話，角色會同時冒
# 氣泡跟進度條，而且工作照樣走完、錢照領。Agent 再依行程加上自己的條件。
#
# 只管「搭話」。仲裁器搶占目前任務是另一個不相干的問題（見 Agent 的
# _is_preemptible()）——這兩個問題曾經共用同一個 is_interruptible()，
# 是意外共用不是設計決定，issue #113 把它們拆開成各自獨立的判斷
func is_talk_interruptible() -> bool:
	return not _working

# 對某人搭話。成功回傳 TALK_OK（空字串），否則回傳失敗原因碼
func talk_to(other: Character) -> String:
	if other == null:
		return TALK_TARGET_NOT_FOUND
	if other == self:
		return TALK_TARGET_IS_SELF
	# 自己在工作中也算忙。少了這條，E 鍵在 work_at() 回 WORK_BUSY 之後退回搭話，
	# 工作中的角色就開得起對話——正好繞過上面 is_talk_interruptible() 要擋的那件事
	if is_in_conversation() or _working or other.is_in_conversation():
		return TALK_TARGET_BUSY
	if get_body_position().distance_to(other.get_body_position()) > TALK_RANGE:
		return TALK_TOO_FAR
	if not other.is_talk_interruptible():
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

## interrupt=true 立刻蓋掉正在顯示/排隊中的內容（LLM 回應等待中的「…」要被
## 真正的台詞立刻換掉，不能排在它後面等它自己的顯示時間跑完）。
## 預設 false 維持原本「不打斷正在講的話」的排隊語意，其餘呼叫端不用改
func say(line: String, interrupt: bool = false) -> void:
	if bubble == null:
		return
	if interrupt:
		bubble.clear()
	bubble.say(line)
	spoke.emit(line)

## 這個角色對話中的下一句話由誰產生、內容是什麼。基底不知道答案——
## 本機玩家要等打字（見 player.gd），本機 Agent 要打 AIService（見 agent.gd），
## 兩者由子類別覆寫。conversation.gd 只問「輪到你了，下一句是什麼」，不問
## 「你是誰」，之後要接遠端角色（伺服器轉發）也只是再多一個覆寫，會話層不用改。
##
## 回傳 {"ok": bool, "line": String, "end": bool}：ok=false 代表這一輪要不到
## 台詞（LLM 停用/逾時/驗證失敗），呼叫端（conversation.gd）要轉去 fallback，
## 不是把空字串當成正常台詞講出去
func next_line(_listener: Character, _turns: Array[Dictionary], _max_turns: int) -> Dictionary:
	push_error("%s: next_line() 沒有被子類別覆寫" % character_name)
	return {"ok": false}

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


# ---- 工作 ----

var _working := false


func is_working() -> bool:
	return _working

# 世界物件版的「找最近的」：量的是 global_position，因為工作站、販賣機這些
# StaticBody2D 的原點就是它們的位置。find_nearest_character() 不走這條——
# 它要跳過自己，而且量的是 get_body_position()（角色的碰撞體相對節點有偏移）
func _find_nearest_in_group(group: String, max_distance: float) -> Node2D:
	var nearest: Node2D = null
	var shortest := max_distance

	for node in get_tree().get_nodes_in_group(group):
		var distance := get_body_position().distance_to(node.global_position)
		if distance <= shortest:
			shortest = distance
			nearest = node

	return nearest

# 找最近的可工作地點。E 鍵在工作站、販賣機與人之間比距離挑最近的（見 player.gd）
func find_nearest_workstation() -> Workstation:
	return _find_nearest_in_group("workstations", WORK_RANGE) as Workstation

# 開始在某個工作站工作。成功回傳 WORK_OK（空字串）不代表錢已經到手——
# 這裡只負責卡位、開始計時，真正撥款在 _run_work()，時間到了才給，
# 跟 talk_to() 開對話一樣是 fire-and-forget
func work_at(workstation: Workstation) -> String:
	if workstation == null:
		return WORK_TARGET_NOT_FOUND
	if is_in_conversation() or _working:
		return WORK_BUSY
	if get_body_position().distance_to(workstation.global_position) > WORK_RANGE:
		return WORK_TOO_FAR
	if not workstation.try_occupy(self):
		return WORK_OCCUPIED

	_working = true
	stop_moving()
	if work_progress != null:
		work_progress.show_progress(0.0)
	_run_work(workstation)
	return WORK_OK

# 數 GameClock.time_changed 發了幾次來算「過了幾個遊戲分鐘」，不是掛
# get_tree().create_timer()——後者是現實時間，跟 GameClock 的時間刻度脫鉤，
# 遊戲時間變速的話兩邊就會對不上。進度條每過一個遊戲分鐘更新一次，
# 不是照 _process() 的 delta 平滑跑——工作本身就是離散地一分鐘一分鐘算，
# 進度條應該老實反映這件事，不用假裝連續
func _run_work(workstation: Workstation) -> void:
	for i in WORK_DURATION_MINUTES:
		await GameClock.time_changed

		# 這個協程橫跨 5 個遊戲分鐘，中間什麼都可能發生。兩件事要在每次醒來時重驗：
		#
		# 一、工作站可能已經被移除。await 之後直接 workstation.release() 會炸
		#     「call function on a previously freed instance」。
		# 二、角色可能自己走開了——Player 一按方向鍵就蓋掉 work_at() 的 stop_moving()，
		#     `_working` 攔不住移動。不重驗距離的話，按下 E 之後跑到地圖另一頭，
		#     時間到照樣入帳，而且這 5 分鐘工作站一直被卡著、現場卻沒人。
		#
		# 兩種都是「沒有做完」，所以收尾但不撥款：錢是站在這裡做滿的報酬，
		# 不是按下 E 的報酬
		if not is_instance_valid(workstation) \
				or get_body_position().distance_to(workstation.global_position) > WORK_RANGE:
			_end_work(workstation)
			return

		if work_progress != null:
			work_progress.show_progress(float(i + 1) / float(WORK_DURATION_MINUTES))

	_end_work(workstation)
	if inventory != null:
		inventory.add_money(WORK_PAYMENT)

# 收尾：放掉工作站、清狀態與進度條。**撥款不在這裡**——做滿全程才給，
# 半途放棄走的是同一條收尾路徑但沒有那一行
func _end_work(workstation: Workstation) -> void:
	if is_instance_valid(workstation):
		workstation.release(self)
	_working = false
	if work_progress != null:
		work_progress.hide_progress()
	_on_work_finished()

# 工作結束後的鉤子。基底不做事；Agent 覆寫它重算行程——工作是 5 遊戲分鐘的
# 阻塞動作，期間可能已經跨過行程的整點，跟 exit_conversation() 是同一個理由。
# 用覆寫而不是在基底嗅探 is_in_group("agents")：子類別的事由子類別自己做
func _on_work_finished() -> void:
	pass


# ---- 購買 ----

func find_nearest_vending_machine() -> VendingMachine:
	return _find_nearest_in_group("vending_machines", BUY_RANGE) as VendingMachine

# 跟販賣機買一件東西。買一件東西是兩件事，要一起成功（#63 明講的坑）：
# spend() 扣款成功之後，add_item() 還是可能因為背包滿了回 ADD_NO_SPACE ——
# 那時候錢已經扣了，玩家等於白付錢。這裡用「扣款失敗就不買、加入失敗就退款」
# 的補償式寫法，而不是買之前先用 find_first_empty() 猜背包放不放得下——
# 猜的話還要重算一次 Inventory 內部的堆疊規則（同 item_id 可能疊進既有格，
# 不一定要空格），退款反而更簡單可靠
func buy_from(machine: VendingMachine, item_id: String) -> String:
	if machine == null:
		return BUY_TARGET_NOT_FOUND
	if get_body_position().distance_to(machine.global_position) > BUY_RANGE:
		return BUY_TOO_FAR
	if inventory == null:
		return BUY_NO_INVENTORY

	var price := machine.get_price(item_id)
	if price < 0:
		return BUY_ITEM_NOT_FOUND

	# 0 元商品不呼叫 spend()：Inventory.spend() 擋掉 amount <= 0（那是防呼叫端
	# 傳負數當加錢用的守衛），免費商品送進去會拿到 MONEY_INVALID_AMOUNT，
	# 變成「按鈕看得到、點下去永遠買不成」。免費就是不用扣錢，本來也沒事可做
	if price > 0:
		var spend_reason := inventory.spend(price)
		if spend_reason != Inventory.MONEY_OK:
			return spend_reason

	var add_reason := inventory.add_item(item_id)
	if add_reason != Inventory.ADD_OK:
		inventory.add_money(price)		# 退回剛剛扣的錢——買賣沒有真的發生
		return add_reason

	# 退款的路徑不會走到這裡——買賣真的成立、錢是真的扣了，才值得頭上飄一個
	# -N。中途失敗退款的話淨變動是 0，飄出來只會讓人以為扣了又加，很奇怪
	if money_popup != null:
		money_popup.show_change(-price)

	return BUY_OK


# ---- 狀態快照 ----

# 純資料的角色狀態，不含任何翻譯字串或 BBCode。debug_console.gd 的 status
# 指令只負責把這份 Dictionary 排版顯示，不重新蒐集一次；日後 LLM payload
# （見 note/技術/LLM 串接與 AI 服務層.md）要的也是同一批資料。
#
# key/value 一律是識別字，不可以是翻譯過的字 —— Stats.SPEC 的 label 存的是
# 翻譯 key，這裡照樣只放 key，翻譯留給顯示端做。stats/relations 只有掛了對應
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
		"working": is_working(),
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

	# 欄名跟 relationships.gd 的 record 一致（trust / met_count），
	# 不要在這裡改名——同一個數值有兩個名字，讀過 relationships.gd 的人
	# 會在 snapshot 上找不到 trust。用純量 accessor 不用 get_record()，
	# 後者每筆都 duplicate(true) 深拷一份只為了讀兩個數字
	if relationships != null:
		var known := relationships.known_ids()
		if not known.is_empty():
			var relations := {}
			for other_id in known:
				relations[other_id] = {
					"trust": relationships.get_trust(other_id),
					"met_count": relationships.get_met_count(other_id),
				}
			snapshot["relations"] = relations

	return snapshot


# ---- 存檔 ----

# 給 SaveService 存的角色資料：身分、數值、關係。跟 get_state_snapshot() 是
# 兩份不同的東西，不要互相包裝——snapshot 要描述現況給 LLM 看（含 facing、
# 動畫這類衍生狀態），這裡要能還原（座標屬於世界存檔，見 #21，不在這裡）
func get_save_data() -> Dictionary:
	var data := {
		"character_id": character_id,
		"character_name": character_name,
	}

	if stats != null:
		data["stats"] = stats.get_save_data()
	if relationships != null:
		data["relationships"] = relationships.get_save_data()

	return data

# 已經在 characters 群組裡（_ready() 跑過）才重驗 id 唯一性——存檔的 character_id
# 可能撞到另一隻已經在場上的角色，覆寫後兩隻共用同一個 id 就會共用關係與記憶
# （_ensure_unique_id() 註解講的那個坑）。還沒進 tree 就不用管，接下來的 _ready()
# 本來就會做這件事，這裡搶著做反而會在 get_tree() 是 null 時炸掉
func load_save_data(data: Dictionary) -> void:
	character_id = data.get("character_id", character_id)
	if character_id.is_empty():
		character_id = generate_id()
	if is_inside_tree():
		_ensure_unique_id()
	character_name = data.get("character_name", character_name)

	if stats != null and data.has("stats"):
		stats.load_save_data(data["stats"])
	if relationships != null and data.has("relationships"):
		relationships.load_save_data(data["relationships"])


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

# 滑鼠指到時呼叫（selection.gd）
func set_highlighted(on: bool) -> void:
	_mouse_highlighted = on
	_apply_highlight()

# 目前是不是 E 鍵的互動目標時呼叫（player.gd）
func set_interact_highlighted(on: bool) -> void:
	_interact_highlighted = on
	_apply_highlight()

# 描一圈邊表示滑鼠指到、或是目前的互動目標，兩者任一成立即可。
# 材質是第一次要用才建，沒被指到過的角色不會多背一份
func _apply_highlight() -> void:
	var on := _mouse_highlighted or _interact_highlighted
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

# 依移動方向切換 walk / idle；沒有 left 素材，往左用 flip_h 翻轉 right。
#
# facing 讀 desired_velocity（move_and_slide() 解算前、_decide_velocity() 的原始輸出），
# 不是解算後的 velocity——貼平物件時想往物件方向走，move_and_slide() 會把那個分量
# 直接歸零，若 facing 也照 velocity 判斷就會卡在貼上去之前的方向，永遠轉不過來面對
# 眼前的東西（#108）。walk / idle 動畫另外照解算後的 velocity 判斷：貼平時人確實
# 沒有在動，播 idle 才對，只是 facing 要跟上輸入方向
func update_animation(desired_velocity: Vector2) -> void:
	var dir := desired_velocity.normalized()

	if dir != Vector2.ZERO:
		# 垂直位移比水平大就用背面／正面，否則用側面
		if abs(dir.y) > abs(dir.x):
			facing = "back" if dir.y < 0 else "front"
		else:
			facing = "right"
			sprite.flip_h = dir.x < 0

	sprite.play(("walk_" if velocity != Vector2.ZERO else "idle_") + facing)

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
	var desired_velocity := _decide_velocity()
	velocity = desired_velocity
	move_and_slide()
	update_animation(desired_velocity)

	if is_moving():
		_check_stuck(delta)
