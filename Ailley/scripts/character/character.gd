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
const TALK_TARGET_NOT_VISIBLE := "TARGET_NOT_VISIBLE"

## 搭話的視線遮蔽判定用哪個 physics layer 擋。跟 vision.gd 的 blocker_mask
## 同一個值（1 = terrain）——搭話比照視覺判定，人不是牆，不會互相擋視線
const TALK_BLOCKER_MASK := 1

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

## 力竭恢復門檻（#364）。stamina ≤ 0 觸發 exhausted，stamina > 此值時自動解除。
## 待 #361 調校 ACTION_RECOVERY 的實際值後重新調整
const EXHAUSTION_RECOVERY_THRESHOLD := 50.0

## buy_from() 的失敗原因碼，形狀比照 TALK_*／WORK_*。除了這五個，buy_from()
## 還會**原樣轉傳** Inventory 自己的原因碼（`NOT_ENOUGH`、`NO_SPACE`），
## 不在這裡重新取名——沒有必要跟 Inventory 的字典再對一次照
const BUY_OK := ""
const BUY_TARGET_NOT_FOUND := "TARGET_NOT_FOUND"
const BUY_TOO_FAR := "TOO_FAR"
const BUY_ITEM_NOT_FOUND := "ITEM_NOT_FOUND"		# 販賣機沒有賣這個 item_id
const BUY_NO_INVENTORY := "NO_INVENTORY"		# 沒有背包的角色沒辦法買東西

## eat() 的失敗原因碼，形狀比照 TALK_*／WORK_*／BUY_*
const EAT_OK := ""
const EAT_NO_INVENTORY := "NO_INVENTORY"	# 沒有背包的角色沒辦法吃東西
const EAT_NO_FOOD := "NO_FOOD"			# 背包裡沒有 ItemDatabase 分類為 food 的物品
const EAT_NO_STATS := "NO_STATS"		# 沒有 Stats 的角色沒地方回復 satiety，不能先扣食物

## drink() 的失敗原因碼，形狀比照 EAT_*（#163）
const DRINK_OK := ""
const DRINK_NO_INVENTORY := "NO_INVENTORY"	# 沒有背包的角色沒辦法喝東西
const DRINK_NO_DRINK := "NO_DRINK"		# 背包裡沒有 ItemDatabase 分類為 drink 的物品
const DRINK_NO_STATS := "NO_STATS"		# 沒有 Stats 的角色沒地方回復 hydration，不能先扣飲品

const GIVE_RANGE := 32.0		# 跟 TALK_RANGE／WORK_RANGE／BUY_RANGE 一樣的距離門檻，2 格

## give_to() 的失敗原因碼，形狀比照 TALK_*／BUY_*。除了這四個，give_to()
## 還會**原樣轉傳** Inventory 自己的原因碼（`NOT_FOUND`、`INVALID_COUNT`、
## `NO_SPACE`），不在這裡重新取名——理由跟 buy_from() 一樣
const GIVE_OK := ""
const GIVE_TARGET_NOT_FOUND := "TARGET_NOT_FOUND"
const GIVE_TARGET_IS_SELF := "TARGET_IS_SELF"
const GIVE_TOO_FAR := "TOO_FAR"
const GIVE_NO_INVENTORY := "NO_INVENTORY"

const HAUL_RANGE := 32.0		# 跟 TALK_RANGE／GIVE_RANGE 一樣的距離門檻，2 格
const HAUL_SPEED_MULTIPLIER := 0.5		# 搬運時速度倍率（《99》P-27 #3-1）
const HAUL_STAMINA_DRAIN := 3.0			# 搬運者每現實秒額外扣的體力（《99》P-27 #3-2）

const HAUL_OK := ""
const HAUL_TARGET_NOT_FOUND := "TARGET_NOT_FOUND"
const HAUL_TARGET_IS_SELF := "TARGET_IS_SELF"
const HAUL_TOO_FAR := "TOO_FAR"

const ATTACK_RANGE := 32.0		# 跟 TALK_RANGE／WORK_RANGE／BUY_RANGE／GIVE_RANGE 一樣的距離門檻，2 格

## attack() 的失敗原因碼，形狀比照 GIVE_*
const ATTACK_OK := ""
const ATTACK_TARGET_NOT_FOUND := "TARGET_NOT_FOUND"
const ATTACK_TARGET_IS_SELF := "TARGET_IS_SELF"
const ATTACK_TOO_FAR := "TOO_FAR"

## 命中的數值效果（《99》P-28 已定案）：必中，MVP 不做閃避／格擋，
## 不像 steal／persuade 等動作走 agent.gd 的 SUCCESS_PARAMS 擲骰
const ATTACK_HEALTH_DELTA := -15.0
const ATTACK_INJURY_DELTA := 20.0

## 失敗原因碼 → L10n key（issue #180）。上面 TALK_*／WORK_*／BUY_*／EAT_*／
## DRINK_*／GIVE_*／HAUL_*／ATTACK_* 與 inventory.gd 的 ADD_*／REMOVE_*／
## USE_*／MONEY_* 本來就是共用同一組扁平字串詞彙（TOO_FAR、TARGET_NOT_FOUND、
## NO_SPACE…橫跨全部行為，不是各行為各自一組獨立代碼），一張表就夠、不用
## 按行為分開維護——give／persuade／shout／eat／drink 之後要顯示失敗原因，
## 直接呼叫 report_action_failure() 就有，不用回來加這張表
const FAILURE_MESSAGE_KEYS := {
	"TARGET_NOT_FOUND": "FAIL_TARGET_NOT_FOUND",
	"TARGET_IS_SELF": "FAIL_TARGET_IS_SELF",
	"TOO_FAR": "FAIL_TOO_FAR",
	"TARGET_BUSY": "FAIL_TARGET_BUSY",
	"TARGET_UNINTERRUPTIBLE": "FAIL_TARGET_UNINTERRUPTIBLE",
	"TARGET_NOT_VISIBLE": "FAIL_TARGET_NOT_VISIBLE",
	"OCCUPIED": "FAIL_OCCUPIED",
	"BUSY": "FAIL_BUSY",
	"ITEM_NOT_FOUND": "FAIL_ITEM_NOT_FOUND",
	"NO_INVENTORY": "FAIL_NO_INVENTORY",
	"NO_FOOD": "FAIL_NO_FOOD",
	"NO_DRINK": "FAIL_NO_DRINK",
	"NO_STATS": "FAIL_NO_STATS",
	"NOT_FOUND": "FAIL_NOT_FOUND",
	"INVALID_COUNT": "FAIL_INVALID_COUNT",
	"NOT_CONSUMABLE": "FAIL_NOT_CONSUMABLE",
	"INVALID_STATS": "FAIL_INVALID_STATS",
	"INVALID_EFFECT": "FAIL_INVALID_EFFECT",
	"REMOVE_FAILED": "FAIL_REMOVE_FAILED",
	"NOT_ENOUGH": "FAIL_NOT_ENOUGH",
	"INVALID_AMOUNT": "FAIL_INVALID_AMOUNT",
	"NO_SPACE": "FAIL_NO_SPACE",
}

## 滑鼠指到時套在 sprite 上的描邊
const OUTLINE_SHADER := preload("res://assets/shaders/character_outline.gdshader")

## 8 種定案情緒 enum（《02》§1-1，12 種草案已作廢）。neutral 是「沒有特別感受」
## 的必要預設值，不是湊數的第 8 種
const EMOTION_TYPES := [
	"joy", "anger", "sadness", "fear", "surprise", "disgust", "anticipation", "neutral",
]
const EMOTION_NEGATIVE := ["anger", "sadness", "fear", "disgust"]	# 見《02》§1-4 人格係數公式

const EMOTION_BASE_DURATION := 12	# tick，2 遊戲小時（《02》§1-4）
const EMOTION_DURATION_MIN := 1
const EMOTION_DURATION_MAX := 144	# 一遊戲日上限

## 8 種生理衍生 condition，全部「門檻自動」套路（《02》§2-2）
const CONDITION_INJURED := "injured"
const CONDITION_BLEEDING := "bleeding"
const CONDITION_DRUNK := "drunk"
const CONDITION_STARVING := "starving"
const CONDITION_DEHYDRATED := "dehydrated"
const CONDITION_EXHAUSTED := "exhausted"
const CONDITION_SLEEPY := "sleepy"
const CONDITION_FILTHY := "filthy"

## MVP 新機制：昏迷狀態（#160，《99》P-27）
const CONDITION_INCAPACITATED := "incapacitated"

## 死亡後的石化狀態（#379，《規格書09》§1）。跟其餘 8 種生理衍生 condition
## 不同，不是「門檻自動」——只在 _die() 寫入一次，之後不會被 _update_conditions()
## 移除（死亡是終局狀態，沒有恢復路徑）
const CONDITION_PETRIFIED := "petrified"

## 角色的身分，全遊戲唯一且不隨改名而變：存檔、記憶連結、交誼區都靠它指人。
## 是內部識別字，不拿來顯示，也**不要去解析它** —— 格式只有 generate_id() 說了算。
##
## 留空就生成一個，這是正常路徑；`@export` 只留給場景裡手擺的測試角色。
## 場景裡固定的 NPC 靠 identities 表跨場次穩定，Player 靠 _resolve_generated_id()
## 的覆寫額外持久化；動態生成、沒有這兩者的角色才會每次開遊戲重新生成
@export var character_id := ""

## 玩家給角色取的名字，是拿來顯示與被指令指名的那一個，可以改、可以撞名。
## 留空就沿用節點名 —— 不能退回 character_id，那是一串沒人讀得懂的 UUID
@export var character_name := ""

## 最近一次 LLM 決策的動作被 resolve() 判定的結果，中文自然語言，成功是空字串
## （#120，《01-2》§1 流程圖的「④ 寫回 last_action_result」）。目前只有 Agent
## 會寫這個欄位，Player 沒有 LLM 決策，留在 Character 是給 UI/debug 共用的掛點
var last_action_result := ""

## 給 LLM 讀的常駐人格段（#117，《01-1》§5、《01-3》§1 的 System 級）：
## 行為準則 ＋ `character` 自述 ＋ 外觀文字，組一次之後逐字元不變——那是
## llama-server 每個 slot 命中 KV cache 的前提。沒有人格資料的角色拿到的是
## 只有開場白與結尾句的最小版本，不是空字串（模型看到空欄位會自行編造）
var system_prompt := ""

## 引擎用的 10 項人格數值（《01》§2，由 Personality.hexaco_to_personality() 產出）。
## **不注入 prompt**——那是給成功率公式（agent.gd 的 _roll_success()）與記憶
## 衰減率讀的，模型讀的是上面那段文字。本地模型看到 `curiosity: 60` 沒有基準，
## 不知道 60 是高是低，也分不出 60 跟 55（《01》§2-1）。
## 沒有人格資料的角色是空字典，讀的人一律用 .get(key, 0.0)
var personality := {}

## AI 唯一可自行宣告的內在狀態（《02》§1）。引擎不計算情緒，只負責倒數 duration_left，
## 見 set_emotion() 與 _tick_emotion()
var emotion := {
	"type": "neutral",
	"intensity": 0,
	"cause_event_id": "",
	"duration_left": 0,
}

## 特殊狀態陣列，元素形狀 {type, turns_left}（《02》§2-1）。全部由引擎寫入，
## LLM 不可宣告；目前只實作 8 種生理衍生 condition，見 _update_conditions()
var conditions: Array[Dictionary] = []

## AI 自由填寫、自己更新的短期目標（《06》，≤40 字）。跟 today_plan 不同層級：
## today_plan 是一串今天想做的事，current_goal 是模型自己選的「現在最想達成
## 的那一件」，沒有更細的結構。引擎只負責存跟注入，不驗證內容合不合理、
## 不強制跟 today_plan 對齊（#352）
var current_goal := ""

## 搬運相關狀態（#161，《99》P-27）
var _hauling_target: Character = null		# 目前正在搬運誰
var _hauled_by: Array[Character] = []		# 目前正被誰搬運
var _speed_multiplier := 1.0				# 速度倍率（搬運時為 50%）

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
# 只有 Player 掛這個節點——NPC 不需要被引導去任何地方。get_node_or_null()
# 在沒有這個節點的 Agent 實例上安靜回 null，呼叫端（#305）自己判斷要不要用
@onready var waypoint_indicator: WaypointIndicator = get_node_or_null("WaypointIndicator")

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

## 昏迷相關狀態（《99》P-27）
var _incapacitation_start_minute := -1		# 昏迷開始的遊戲分鐘，-1 表示未昏迷
var _is_being_carried := false				# 標記正在被搬運（#161 會設置此項）
var _treatment_start_minute := -1			# 藥草鋪治療開始的遊戲分鐘，-1 表示未治療
var _treatment_location := ""				# 治療地點（暫定「藥草鋪」）
var _herb_shop_lookup_error_reported := false	# 找不到 herb_shop 時只記一次錯誤，避免昏迷期間每遊戲分鐘洗版

## 死亡相關狀態（#379，《規格書09》§1／§2）。is_dead 是死亡狀態的唯一事實
## 來源，其餘欄位只在 is_dead=true 時有意義，一旦寫入不會再變回未死亡
## （死亡是終局狀態）。這批 issue 只做「health≤0→昏迷→逾時未獲救治→死亡」
## 這條觸發路徑，見 _die() 說明與 issue #379 範圍界線
var is_dead := false
var death_tick := -1			# 見 _current_tick()，跨天累積的全域 tick 計數
var death_day := -1
var death_at := ""				# UTC ISO 8601 時間戳，見 §8 復活窗口判斷依據
var death_cause := ""			# 中文自然語言，引擎彙整，不讓 LLM 潤飾
var death_location_id := ""	# 死亡當下的地點，查不到具名地點時是空字串（在地點之間）
var last_words: Variant = null	# String 或 null（來不及開口）；只有 Agent 會真的問 LLM，見 _request_last_words()
var corpse_decay := 0.0		# 0–100，_update_corpse_decay() 每 tick +0.7；達 100 之後交給 #387 判斷是否自動立無名碑
var is_buried := false			# 安葬流程見 #380，這裡只保留欄位供其寫入
var grave_id: Variant = null	# 同上，String 或 null
var buried_by: Variant = null	# 誰安葬了你，String（character_id）或 null（無名碑等非人為安葬留給 #387）
var buried_tick := -1			# 安葬當下的全域 tick，同 death_tick 換算方式，見 bury()

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
		character_id = _resolve_generated_id()

	if character_name.is_empty():
		character_name = str(identity.get("character_name", ""))
	if character_name.is_empty():
		character_name = name.to_lower()

	_ensure_unique_id()
	add_to_group("characters")

	# 人格要在 _ensure_unique_id() 之後才組：種子用的是最終的 character_id。
	# 種子而不是真的隨機——《01-1》§4 每個極端維度有 3 種語氣變體，真隨機的話
	# 同一隻角色每次開遊戲的人格文案都不一樣，而 system_prompt 的設計前提是
	# 「組好之後逐字元不變」。存檔接上之後（#21）改讀存下來的那份，
	# Personality 那邊不用改
	var persona := Personality.from_identity(identity, character_id)
	personality = persona["personality"]
	system_prompt = persona["system_prompt"]

	sprite.play("idle_" + facing)
	# load_save_data() 若在進場景樹前就被呼叫（見該函式開頭註解），is_dead=true
	# 時會因為 sprite 還不存在而跳過灰階——sprite 現在已就緒，補套一次
	# （CodeRabbit review 抓到）
	_apply_death_tint(is_dead)

	# emotion.duration_left／conditions[].turns_left 都是離散單位，用 GameClock 既有的
	# 「每遊戲分鐘」訊號驅動比自己在 _process(delta) 裡做累加器精簡（agent.gd 也是這樣接的），
	# 且會跟著 GameClock 的時間流速走，不會像 stats.gd 的連續 drift 那樣綁死真實秒數
	GameClock.time_changed.connect(_on_game_minute)

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

# 走到第三層（沒有 @export 手擺值、npc_schedule.json 也查不到）時要用哪個 id，
# 預設就是普通生成，即用即棄。Player 覆寫這個函式讓生成的 id 額外持久化，
# 下次開遊戲沿用同一組——動態生成的角色（spawn_character()）不需要這件事：
# 它們要嘛已經帶著角色庫存好的 character_id（不會走到這裡），要嘛本來就是
# 一次性測試用途，沒有「跨場次是同一隻」的需求
func _resolve_generated_id() -> String:
	return generate_id()

# character_id 被 _ensure_unique_id() 換掉時呼叫，預設 no-op。Player 覆寫這個
# hook 把新 id 同步寫回 _resolve_generated_id() 額外持久化的檔案，不然下次
# _resolve_generated_id() 還是讀到那組已經被撞掉、不再代表這個 Player 的
# 舊 id（issue #438）——沒有額外持久化的子類別（Agent／動態生成角色）沒有
# 檔案要同步，撞號換掉就換掉
func _on_id_changed(_new_id: String) -> void:
	pass

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
		_on_id_changed(character_id)
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


# ---- 情緒與狀態 ----

## 1 tick = 10 遊戲分鐘（《02》§1-4：12 tick = 2 遊戲小時 ＝ GameClock.GAME_MINUTES_PER_TICK）。
## GameClock.time_changed 每遊戲分鐘觸發一次，用 `_minute % GAME_MINUTES_PER_TICK == 0`
## 判斷是否落在 tick 邊界上，不是每次都跑，也不是本地累加器——跟 Stats 漂移共用
## 同一個全域邊界，兩者永遠同步觸發。拿規格書自己的算例反查：joy intensity=60、
## stability=90、grudge=75 應該是 9 tick ≈ 1.5 小時（90 遊戲分鐘），不是 9 遊戲分鐘

func _on_game_minute(_hour: int, _minute: int) -> void:
	# 昏迷與治療檢查每遊戲分鐘執行（與 GameClock.time_changed 同步）
	_update_incapacitation()
	_update_treatment()
	_update_exhausted_condition()

	# 情緒與其他 condition 在全局分鐘邊界執行（tick 機制，與 Stats 漂移同步）
	if _minute % GameClock.GAME_MINUTES_PER_TICK == 0:
		_tick_emotion()
		_update_conditions()
		_update_corpse_decay()

## AI 宣告新情緒。type 必須是 EMOTION_TYPES 之一，intensity 0–100。
## stability／grudge 是《02》§1-4 持續時間公式的人格係數，人格資料還沒接上
## Character（#117），呼叫端拿不到真實值時用 50.0（中性值）當預設——
## 比照 memory.gd::decay_all() 對 grudge 的既有做法
func set_emotion(type: String, intensity: int, cause_event_id: String = "",
		stability: float = 50.0, grudge: float = 50.0) -> void:
	if not EMOTION_TYPES.has(type):
		push_error("Character.set_emotion: 不是定案的情緒 enum：%s" % type)
		return

	intensity = clampi(intensity, 0, 100)
	emotion = {
		"type": type,
		"intensity": intensity,
		"cause_event_id": cause_event_id,
		"duration_left": _calc_emotion_duration(type, intensity, stability, grudge),
	}

## 《02》§1-4：duration = 基礎時長 × (intensity/50) × 人格係數，夾制 1~144 tick
func _calc_emotion_duration(type: String, intensity: int, stability: float, grudge: float) -> int:
	if type == "neutral":
		return 0

	var personality_factor := 1.0 + (50.0 - stability) / 100.0
	if EMOTION_NEGATIVE.has(type):
		personality_factor += (grudge - 50.0) / 100.0

	var duration := EMOTION_BASE_DURATION * (intensity / 50.0) * personality_factor
	return clampi(roundi(duration), EMOTION_DURATION_MIN, EMOTION_DURATION_MAX)

## 每遊戲分鐘倒數一次；歸零轉回 neutral（《02》§1-3 規則 4）
func _tick_emotion() -> void:
	if emotion["type"] == "neutral":
		return

	emotion["duration_left"] -= 1
	if emotion["duration_left"] <= 0:
		emotion = {"type": "neutral", "intensity": 0, "cause_event_id": "", "duration_left": 0}

func has_condition(type: String) -> bool:
	for c in conditions:
		if c["type"] == type:
			return true
	return false

func _get_condition_display_name(type: String) -> String:
	match type:
		CONDITION_INJURED:
			return "受傷"
		CONDITION_BLEEDING:
			return "流血"
		CONDITION_DRUNK:
			return "醉酒"
		CONDITION_STARVING:
			return "饑餓"
		CONDITION_DEHYDRATED:
			return "缺水"
		CONDITION_EXHAUSTED:
			return "疲勞"
		CONDITION_SLEEPY:
			return "困倦"
		CONDITION_FILTHY:
			return "骯髒"
		CONDITION_INCAPACITATED:
			return "昏迷"
		CONDITION_PETRIFIED:
			return "石化"
		_:
			return type

func _set_condition(type: String, present: bool, record_event: bool = true) -> void:
	var had := has_condition(type)
	if present and not had:
		conditions.append({"type": type, "turns_left": -1})
		# 记录进入新状态的事件
		if record_event and is_in_group("agents"):
			var condition_name := _get_condition_display_name(type)
			(self as Agent)._push_daily_event("你開始%s。" % condition_name)
	elif not present and had:
		conditions = conditions.filter(func(c): return c["type"] != type)

## 依生理值重新檢查 8 種生理衍生 condition，全部「門檻自動」——條件不成立
## 下次檢查就自動移除（《02》§2-2／§2-3 規則 4）。只做偵測與新增/移除；
## 行為成功率／說真心話機率留給 #120，exhausted「強制昏睡」是行動佔用邏輯，
## 留給該動作自己處理，filthy 效果待《99》P-35 重新設計，這裡都不做
##
## 昏迷狀態檢查（《99》P-27）：health ≤ 0 即進入昏迷。注意昏迷不是「門檻自動」，
## 只要曾經觸發就必須明確結束（被搬走或完成治療），不會因為 health 變正就自動消失
##
## 死亡後整個函式直接跳過（#379）：死亡的 conditions 只留 petrified（見 _die()），
## 不然這裡任何一項「門檻自動」condition 只要生理數值仍符合門檻，下次檢查就會
## 被重新加回死屍身上；health 仍 ≤0 也會撞到下面的昏迷觸發，把死屍重新打回昏迷
func _update_conditions() -> void:
	if stats == null or is_dead:
		return

	var injury := stats.get_value("injury")
	var health := stats.get_value("health")

	_set_condition(CONDITION_INJURED, injury > 0.0)
	_set_condition(CONDITION_BLEEDING, injury >= 20.0)
	_set_condition(CONDITION_DRUNK, stats.get_value("alcohol") > 30.0)
	_set_condition(CONDITION_STARVING, stats.get_value("satiety") < 10.0)
	_set_condition(CONDITION_DEHYDRATED, stats.get_value("hydration") < 10.0)
	_set_condition(CONDITION_SLEEPY, stats.get_value("wakefulness") < 15.0)
	_set_condition(CONDITION_FILTHY, stats.get_value("hygiene") < 20.0)

	## 昏迷狀態觸發（health ≤ 0）——不是門檻自動，一旦進入必須明確結束
	if health <= 0.0 and not has_condition(CONDITION_INCAPACITATED):
		_start_incapacitation()

	# bleeding／starving／dehydrated 的直接數值效果（《02》§2-2 效果欄），
	# 跟成功率無關所以不算 #120 的範圍。injury 自然衰減暫停是唯一的例外規則
	if has_condition(CONDITION_BLEEDING):
		stats.add("health", -1.5)
	if has_condition(CONDITION_STARVING):
		stats.add("health", -0.5)
	if has_condition(CONDITION_DEHYDRATED):
		stats.add("health", -1.0)
	stats.injury_decay_paused = has_condition(CONDITION_BLEEDING)

## exhausted 的觸發與解除邏輯（#364）。不同於其他生理衍生狀態的簡單門檻，
## exhausted 需要一個恢復門檻（stamina <= 0 時觸發，stamina > 門檻時解除）。
## 門檻值待 #361 調校後調整
##
## 死亡後跳過（#379），理由同 _update_conditions()：死屍 conditions 只留 petrified
func _update_exhausted_condition() -> void:
	if stats == null or is_dead:
		return
	var stamina := stats.get_value("stamina")

	# 觸發：stamina 歸零且尚未 exhausted
	if stamina <= 0.0 and not has_condition(CONDITION_EXHAUSTED):
		_set_condition(CONDITION_EXHAUSTED, true)
	# 解除：stamina 恢復到門檻且已經 exhausted
	elif stamina > EXHAUSTION_RECOVERY_THRESHOLD and has_condition(CONDITION_EXHAUSTED):
		_set_condition(CONDITION_EXHAUSTED, false)

## 開始昏迷（health ≤ 0 觸發）。記錄開始時間，30 分鐘內若無人搬走則自動傳送藥草鋪
## （《99》P-27，搬走邏輯依賴 #161 haul/struggle）
func _start_incapacitation() -> void:
	_set_condition(CONDITION_INCAPACITATED, true)
	_incapacitation_start_minute = GameClock.hour * 60 + GameClock.minute
	_is_being_carried = false
	stop_moving()  # 立即停止移動
	print_debug("Character %s 進入昏迷，計時器已啟動" % character_name)

## 死亡／昏迷／治療中都不能動：死亡是終局的石化，昏迷是暫時的石化，治療是
## 「住院中」，三者共用同一個移動鎖（《99》P-27／藥草鋪筆記／《規格書09》§1），
## 供 move_to() 與 _decide_velocity()（含 Player 覆寫）共用
func _is_movement_locked() -> bool:
	return is_dead or has_condition(CONDITION_INCAPACITATED) or _treatment_start_minute != -1

## 每遊戲分鐘檢查昏迷狀態：
## 1. 若被搬走（#161 設置 _is_being_carried），立即結束昏迷
## 2. 若昏迷 30 分鐘無人搬走，轉入真正死亡流程（#379，依 #368 拍板結果取代
##    原本「自動傳送藥草鋪治療」這個結局分支——見《規格書09》文首拍板 note）。
##    「天神主動介入送醫」與昏迷倒數改依傷勢動態計算，都留給後續實作 issue，
##    不在 #379 範圍內；_send_to_herb_shop_for_treatment() 保留給那個 issue用
func _update_incapacitation() -> void:
	if not has_condition(CONDITION_INCAPACITATED):
		return

	# 檢查是否被搬走（#161 會設置此標誌）
	if _is_being_carried:
		_end_incapacitation()
		return

	# 計算昏迷時長（單位：遊戲分鐘）
	var current_minute := GameClock.hour * 60 + GameClock.minute
	var elapsed_minutes := (current_minute - _incapacitation_start_minute) % (24 * 60)

	# 30 分鐘無人搬走時轉入死亡流程
	if elapsed_minutes >= 30:
		_die("傷重昏迷，始終無人相救")

## 結束昏迷（被搬走時觸發，#161 負責調用）
func _end_incapacitation() -> void:
	_set_condition(CONDITION_INCAPACITATED, false)
	_incapacitation_start_minute = -1
	_is_being_carried = false

	# 恢復少量 health 避免立即重新進入昏迷（被搬走表示獲得基礎救助）
	if stats != null:
		stats.set_value("health", 10.0)

	print_debug("Character %s 昏迷已結束（被搬走）" % character_name)

## 由搬運動作（#161 haul）調用，標記此角色正在被搬運。
## 若該角色昏迷，搬運會立即結束昏迷計時器（《99》P-27）
func set_being_carried(is_carried: bool) -> void:
	if is_carried and has_condition(CONDITION_INCAPACITATED):
		_is_being_carried = true
	elif not is_carried:
		_is_being_carried = false

## 傳送到藥草鋪並開始治療。#379 之前是昏迷逾時的自動結局，現在改成死亡流程
## 接手那個結局分支（見 _update_incapacitation()），這個函式暫時沒有呼叫端——
## 保留給後續「天神主動介入送醫」的實作 issue（《規格書09》文首拍板 note）用，
## 不是死代碼
func _send_to_herb_shop_for_treatment() -> void:
	# 治療已開始時不重複設置（避免重置計時器）
	if _treatment_start_minute != -1:
		return

	print_debug("Character %s 昏迷 30 分鐘無人搬走，自動傳送藥草鋪治療" % character_name)

	# 直接瞬移，不做「NPC 走過來救」的移動演出——《99》P-27 明講 MVP 簡化做法。
	# 用 places.gd 的 PlaceAnchors 當單一事實來源，跟 _pursue_current_task() 解析
	# 地點座標同一條路（見 places.gd 開頭註解：不要另開第二份寫死座標）。
	# 這一刻 stop_moving() 沒有必要——_is_movement_locked() 已經把
	# CONDITION_INCAPACITATED 期間鎖死，不會有殘留路徑在同一 tick 跟瞬移搶位置
	var anchors := get_tree().get_first_node_in_group("place_anchors")
	if anchors == null or not anchors.has("herb_shop"):
		if not _herb_shop_lookup_error_reported:
			push_error("Character %s: 找不到 herb_shop 地點，無法傳送治療" % character_name)
			_herb_shop_lookup_error_reported = true
		return
	_herb_shop_lookup_error_reported = false

	global_position = anchors.resolve("herb_shop")

	# 記錄治療開始時間，_update_treatment() 會處理倒計時
	_treatment_start_minute = GameClock.hour * 60 + GameClock.minute
	_treatment_location = "herb_shop"

	# 進入治療時移除昏迷狀態（治療與昏迷互斥）
	_set_condition(CONDITION_INCAPACITATED, false)
	_incapacitation_start_minute = -1

## 每遊戲分鐘檢查治療進度。60 分鐘治療完成後解除所有異常狀態
func _update_treatment() -> void:
	if _treatment_start_minute == -1:
		return

	var current_minute := GameClock.hour * 60 + GameClock.minute
	var elapsed_minutes := (current_minute - _treatment_start_minute) % (24 * 60)

	# 治療完成：60 分鐘後解除所有異常狀態並結束昏迷
	if elapsed_minutes >= 60:
		_complete_treatment()

## 治療完成：解除所有異常狀態、恢復 health 和 injury、結束昏迷
func _complete_treatment() -> void:
	print_debug("Character %s 藥草鋪治療完成" % character_name)

	# 恢復 health 和 injury（《99》P-27、P-28）
	if stats != null:
		stats.set_value("health", 50.0)		# 設定一個中等恢復量
		stats.set_value("injury", 0.0)

		# 恢復其他生理數值到安全水平，避免治療完立即重新觸發 condition
		stats.set_value("alcohol", 0.0)		# 清除酒精
		stats.set_value("satiety", 50.0)	# 恢復飽食度
		stats.set_value("hydration", 50.0)	# 恢復水分
		stats.set_value("stamina", EXHAUSTION_RECOVERY_THRESHOLD + 1.0)	# 恢復體力，超過力竭恢復門檻
		stats.set_value("wakefulness", 50.0)	# 恢復清醒度
		stats.set_value("hygiene", 50.0)	# 恢復衛生

	# 清除所有異常狀態
	conditions.clear()
	_incapacitation_start_minute = -1
	_treatment_start_minute = -1
	_treatment_location = ""

	print_debug("Character %s 已恢復可行動" % character_name)


# ---- 死亡 ----

## 死亡地點反查半徑，跟 agent.gd::ACTUAL_PLACE_RADIUS（事實句的即時位置反查）
## 取同一個值——都是「站在哪個地點錨點附近算數」的同一種判斷，沒有理由不同
const DEATH_LOCATION_RADIUS := 32.0

## 死亡流程（#379，《規格書09》§1／§2）。這批 issue 只處理
## 「health≤0→昏迷→逾時未獲救治→死亡」這一條觸發路徑；餓死／渴死／老化／
## 瞬間死亡 Flag 等其餘觸發源留給後續 issue，各自準備好 death_cause 文案後
## 呼叫這裡收尾即可，不需要重做狀態機本身。墓園／安葬（#380）與 corpse_decay
## 達 100 自動立無名碑（#387）都是後續 issue，這裡只負責觸發與石化
func _die(cause: String) -> void:
	if is_dead:
		return

	is_dead = true
	death_tick = _current_tick()
	death_day = GameClock.day
	death_at = Time.get_datetime_string_from_system(true, false) + "Z"
	death_cause = cause
	death_location_id = _resolve_death_location()

	# ①②③：conditions 清空只留 petrified（《規格書09》§1 死亡流程圖）
	conditions.clear()
	conditions.append({"type": CONDITION_PETRIFIED, "turns_left": -1})

	# 昏迷正式被死亡取代，清掉哨兵值——不然存檔會同時記著一段「未結束的昏迷」，
	# load_save_data() 讀回來會誤判成「昏迷中但還沒送醫」，把 CONDITION_INCAPACITATED
	# 重新加回死屍身上
	_incapacitation_start_minute = -1

	# 治療同理要清掉（CodeRabbit review 抓到）：_update_treatment() 沒有 is_dead
	# 判斷，_treatment_start_minute 若殘留，60 分鐘後 _complete_treatment() 會
	# 把 conditions 清空（連 petrified 一起沒了）並恢復 health／injury，等於
	# 讓死屍活過來
	_treatment_start_minute = -1
	_treatment_location = ""

	corpse_decay = 0.0
	# 搬運中的角色（自己是搬運者）要先放手，不然目標的 _hauled_by 卡在死掉的
	# 搬運者身上、_follow_hauler() 讓目標永遠走不動（CodeRabbit review 抓到）。
	# 只解除「自己搬運別人」這一端，被別人搬運（_hauled_by）的關係不動——
	# 死屍本來就該繼續能被搬運去墓園
	if is_hauling():
		stop_haul()
	# force_interrupt() 已含 stop_moving()／leave_conversation()／_end_work()——
	# 昏迷倒數的 30 分鐘內角色仍可能開始新的工作或被搭話（is_dead 這時還是
	# false，_on_time_changed() 照常仲裁，work_at() 也不擋 _is_movement_locked()），
	# 死亡當下要一次收尾，不能只清路徑，否則死屍會繼續佔用工作站領工資、
	# 或被 conversation.gd 繼續要台詞（CodeRabbit review 抓到）。Agent 覆寫的
	# _on_action_interrupted() 已加上 is_dead 判斷，這裡不會反過來觸發新決策
	force_interrupt()
	_apply_death_tint(true)		# 本體變灰色（《規格書09》§1）

	print_debug("Character %s 死亡：%s" % [character_name, cause])

	# 不 await——last_words 是死亡當下才問 LLM，回應要等數百毫秒到數十秒，
	# 死亡狀態機（is_dead、石化、decay 開始累積）不該卡在那份請求後面才生效
	_request_last_words(cause)

## 死亡本體變灰／存活還原正常顏色。獨立成函式是因為 load_save_data() 明確
## 允許在節點還沒進場景樹時呼叫（見該函式開頭註解）——這時 @onready var sprite
## 還沒初始化，直接寫 sprite.modulate 會炸掉，這裡統一擋 null（CodeRabbit
## review 抓到）。_ready() 會在 sprite 就緒後補呼叫一次，把 load_save_data()
## 在 sprite 還不存在時被跳過的那次補回來
func _apply_death_tint(dead: bool) -> void:
	if sprite == null:
		return
	sprite.modulate = Color(0.5, 0.5, 0.5) if dead else Color(1, 1, 1)

## 臨終遺言請求的掛點，基底 no-op：Player 沒有 LLM 決策，last_words 維持 null
## （來不及開口，跟《規格書09》§2 表格「無機會留遺言」的語意不同，是單純沒有
## 生成管道）。Agent 覆寫這個 hook 真正送出 LLM 請求，見 agent.gd
func _request_last_words(_cause: String) -> void:
	pass

## 死亡時刻換算成全域遞增的 tick 計數（《規格書09》§2 death_tick 範例
## 8642：跨天累積，不是當天的相對 tick）。GameClock 本身沒有這個計數器，
## 只有 hour/minute/day，用既有的 GAME_MINUTES_PER_TICK 週期换算
func _current_tick() -> int:
	var ticks_per_day := (24 * 60) / GameClock.GAME_MINUTES_PER_TICK
	var minute_of_day := GameClock.hour * 60 + GameClock.minute
	return (GameClock.day - 1) * ticks_per_day + int(minute_of_day / GameClock.GAME_MINUTES_PER_TICK)

## 死亡地點反查，跟 agent.gd::_resolve_actual_place() 同一種做法（不能沿用
## current_place——那個欄位只有 Agent 有意義，Player 沒有）。查不到具名地點
## （例如死在地點之間的路上）就回傳空字串，是合法值
func _resolve_death_location() -> String:
	var anchors := get_tree().get_first_node_in_group("place_anchors")
	if anchors == null:
		return ""
	return anchors.resolve_from_position(get_body_position(), DEATH_LOCATION_RADIUS)

## 屍體腐壞（《規格書09》§3-4）：死亡後每 tick +0.7，clamp 在 [0,100]——
## 100/0.7 除不盡，不 clamp 會在某個 tick 算出 100.1，讓存檔的 CHECK 約束
## 寫入失敗（規格書原文引用 issue #451 CodeRabbit review 踩過的坑）。達到
## 100 之後交給 #387（自動立無名碑）判斷，這裡只負責累加，不做立碑
func _update_corpse_decay() -> void:
	if not is_dead:
		return
	# 死亡當下那個 tick 不算：_die() 觸發時若剛好落在 tick 邊界上，_on_game_minute()
	# 會在同一次呼叫裡先跑 _die()（corpse_decay 歸零）再跑這裡，沒有這個判斷
	# 剛死的屍體會立刻變成 0.7，等於白白少算一個完整 tick 的「新鮮」時間
	# （CodeRabbit review 抓到）
	if death_tick == _current_tick():
		return
	corpse_decay = clampf(corpse_decay + 0.7, 0.0, 100.0)


# ---- 安葬（#380，《規格書09》§3-2／§6） ----

## 搬運／安葬距離門檻，跟 HAUL_RANGE／GIVE_RANGE 同一種「2 格內」判斷，
## 沒有理由對屍體另訂一套距離
const BURY_RANGE := 32.0

## PlaceAnchors 底下這個錨點的節點名稱（見 note/技術/村莊地圖.md）。
## 《規格書09》§6 寫的 `loc_cemetery` 是 LocationSchema／規格文件那一層的
## 正式 location_id（帶 `loc_` 前綴），跟這裡不是同一份字串——PlaceAnchors
## 錨點名稱／`current_place`／`npc_schedule.json` 的 `place` 欄位全部是不帶
## 前綴的短名（`home`／`herb_shop`…，見《村莊地圖》），跟其餘地點一致才能讓
## `move_to()`／`resolve_from_position()` 認得
const CEMETERY_PLACE_NAME := "cemetery"

## 墓碑格數上限（《規格書09》§6，issue #368 拍板值）。滿格時 bury() 直接拒絕，
## 屍體留在原地繼續佔一般 capacity，符合§6「Phase 2：拒絕」——動態擴張是
## Phase 3（《99》P-57），不在這則範圍內
const CEMETERY_GRAVE_CAPACITY := 6

const BURY_OK := ""
const BURY_TARGET_NOT_FOUND := "TARGET_NOT_FOUND"
const BURY_TARGET_NOT_DEAD := "TARGET_NOT_DEAD"
const BURY_ALREADY_BURIED := "ALREADY_BURIED"
const BURY_TOO_FAR := "TOO_FAR"
const BURY_NOT_AT_CEMETERY := "NOT_AT_CEMETERY"
const BURY_CEMETERY_FULL := "CEMETERY_FULL"

## 安葬。self 是動手安葬的人，corpse 是屍體本體（死亡後角色不會被移除，
## 石化留在原地／被搬運，見 _die()）。跟 attack()／give_to() 同一種寫法：
## 一路檢查、任何一關不過就回失敗碼，全過才真的寫入狀態。
##
## 沒有檢查 self 是不是也在墓園——安葬者跟屍體只要彼此在 BURY_RANGE 內、
## 屍體本身位於墓園錨點範圍內即可，跟 give_to() 只檢查雙方距離、不檢查
## 「送禮者站在哪」同一個道理
func bury(corpse: Character) -> String:
	if corpse == null or not is_instance_valid(corpse):
		return BURY_TARGET_NOT_FOUND
	if not corpse.is_dead:
		return BURY_TARGET_NOT_DEAD
	if corpse.is_buried:
		return BURY_ALREADY_BURIED
	if get_body_position().distance_to(corpse.get_body_position()) > BURY_RANGE:
		return BURY_TOO_FAR
	if not _is_at_cemetery(corpse.get_body_position()):
		return BURY_NOT_AT_CEMETERY
	if _cemetery_grave_count() >= CEMETERY_GRAVE_CAPACITY:
		return BURY_CEMETERY_FULL

	corpse.is_buried = true
	corpse.grave_id = "grave_%s" % corpse.character_id
	corpse.buried_by = character_id
	corpse.buried_tick = _current_tick()

	print_debug("Character %s 安葬了 %s" % [character_name, corpse.character_name])
	return BURY_OK

## 位置是否落在墓園錨點範圍內。跟 _resolve_death_location() 同一種
## place_anchors 查詢模式，但這裡只需要布林值，不需要地點名稱本身
func _is_at_cemetery(position: Vector2) -> bool:
	var anchors := get_tree().get_first_node_in_group("place_anchors")
	if anchors == null:
		return false
	return anchors.resolve_from_position(position, DEATH_LOCATION_RADIUS) == CEMETERY_PLACE_NAME

## 目前已佔用的墓碑格數：場上所有已安葬角色的數量。不另外維護一個計數器——
## 死亡角色不會被移除節點（見 _die()），直接數 is_buried 的人數就是即時正確
## 答案，跟 hauler_count() 數 _hauled_by 而不是另存一個計數欄位同一種作法
func _cemetery_grave_count() -> int:
	var count := 0
	for node in get_tree().get_nodes_in_group("characters"):
		if node is Character and (node as Character).is_buried:
			count += 1
	return count


# ---- 移動 ----

# 這次 move_to() 的目標世界座標。move_to() 的呼叫端不只一個（仲裁器、
# debug 主控台的 goto 類指令都會直接呼叫），
# 但 move_finished 訊號是同一個，收到訊號的一方得自己有辦法分辨「這是不是
# 我剛才發出的那個請求」——靠比對這個欄位跟自己期待的目標位置
var last_move_target := Vector2.ZERO

# 走 A* 路徑到指定的世界座標；找不到路徑回傳 false
func move_to(target: Vector2) -> bool:
	# 昏迷或治療中無法移動
	if _is_movement_locked():
		return false

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
	# is_dead 排除（CodeRabbit review 抓到）：force_interrupt() 只收尾死亡當下
	# 已經存在的對話，沒擋之後別人再對死屍發起新對話——死屍不該再被搭話
	return not _working and not is_dead

# 對某人搭話。成功回傳 TALK_OK（空字串），否則回傳失敗原因碼
func talk_to(other: Character) -> String:
	if other == null:
		return TALK_TARGET_NOT_FOUND
	if other == self:
		return TALK_TARGET_IS_SELF
	# 自己在工作中也算忙。少了這條，E 鍵在 work_at() 回 WORK_BUSY 之後退回搭話，
	# 工作中的角色就開得起對話——正好繞過上面 is_talk_interruptible() 要擋的那件事。
	# is_dead 同理擋自己是死屍發起搭話（CodeRabbit review 抓到）——target 那側已經
	# 靠 is_talk_interruptible() 擋掉，initiator 這側沒有對稱檢查會漏掉
	if is_in_conversation() or _working or is_dead or other.is_in_conversation():
		return TALK_TARGET_BUSY
	if get_body_position().distance_to(other.get_body_position()) > TALK_RANGE:
		return TALK_TOO_FAR
	if not _has_line_of_sight(other):
		return TALK_TARGET_NOT_VISIBLE
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

# 兩點之間有沒有牆擋住。跟 vision.gd 的 _has_line_of_sight() 同一個演算法
# （direct_space_state 查 blocker_mask），但不透過 Vision 元件——talk_to() 可能
# 被明確指名對象呼叫（debug 主控台、agent.gd 的 LLM 決策），這時候對象不一定
# 在呼叫端 Vision 目前的可見集合裡（例如剛好卡在 0.2 秒的重新整理間隔之間），
# 這裡要的是「現在這一刻真的擋不擋」，不是快取
func _has_line_of_sight(other: Character) -> bool:
	var params := PhysicsRayQueryParameters2D.create(
		get_body_position(), other.get_body_position(), TALK_BLOCKER_MASK
	)
	return get_world_2d().direct_space_state.intersect_ray(params).is_empty()

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

## 行為失敗時統一的回報方式（issue #180），取代原本三個呼叫點（player.gd
## 的 work_at／talk_to、vending_menu.gd 的 buy_from）各自手寫的
## push_warning——格式收進這裡一次，之後 give／persuade／shout／eat／drink
## 等動作要回報失敗，呼叫這個就有，不用各自重寫一份。reason 是 OK（空字串）
## 不該傳進來，呼叫端本來就要先判斷過
##
## FAILURE_MESSAGE_KEYS 查不到就直接顯示原始碼——寧可暴露一個沒翻過的
## 識別字，也不要吞掉錯誤讓玩家完全看不到任何反應，跟在地化系統本身
## 「key 不存在就顯示 KEY 本身」同一種「看得出來哪裡漏了」的設計
## （見 note/技術/在地化.md）
func report_action_failure(action_label: String, reason: String) -> void:
	push_warning("%s: %s 失敗（%s）" % [character_name, action_label, reason])

	var key: String = FAILURE_MESSAGE_KEYS.get(reason, "")
	say(L10n.t(key) if not key.is_empty() else reason)

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

## _end_work() 需要的 workstation 參照，讓 force_interrupt() 可以在不依賴
## _run_work() 協程本地變數的情況下，自己也呼叫得到 _end_work()
var _current_workstation: Workstation = null

## 每次 _end_work() 遞增，_run_work() 協程在建立時記住當下的號碼。
## force_interrupt()（見《02》§3「被攻擊立即中斷，含 work 中」）當下就直接
## 呼叫 _end_work() 立即釋放工作站、收掉進度條——不能拖到 _run_work() 下一次
## GameClock.time_changed 才收尾（CodeRabbit review 抓到）：那段空窗期
## 工作站仍算「有人在用」，其他角色會被 WORK_OCCUPIED 擋下來，明明沒有人真的
## 在那裡工作。協程醒來後比對號碼：跟目前的號碼對不上，代表這個 session
## 已經被 force_interrupt() 提早收尾過，單純 return，不能重複呼叫
## _end_work()——這時 workstation 可能已經被下一個佔用者用掉
var _work_session_id := 0


func is_working() -> bool:
	return _working

# 開始在某個工作站工作。成功回傳 WORK_OK（空字串）不代表錢已經到手——
# 這裡只負責卡位、開始計時，真正撥款在 _run_work()，時間到了才給，
# 跟 talk_to() 開對話一樣是 fire-and-forget
func work_at(workstation: Workstation) -> String:
	if workstation == null:
		return WORK_TARGET_NOT_FOUND
	# 昏迷／治療／死亡期間不能開始新工作（CodeRabbit review 抓到）：
	# _is_movement_locked() 只擋得住 _decide_velocity() 的移動輸出，原本沒擋
	# work_at()——角色昏迷時若剛好站在工作站範圍內，仲裁器照樣能選中 work
	# 任務並成功卡位，昏迷或死亡期間憑空多出一段不該存在的工作
	if is_in_conversation() or _working or _is_movement_locked():
		return WORK_BUSY
	if get_body_position().distance_to(workstation.global_position) > WORK_RANGE:
		return WORK_TOO_FAR
	if not workstation.try_occupy(self):
		return WORK_OCCUPIED

	_working = true
	_current_workstation = workstation
	stop_moving()
	if work_progress != null:
		work_progress.show_progress(0.0)
	_run_work(workstation, _work_session_id)
	return WORK_OK

# 數 GameClock.time_changed 發了幾次來算「過了幾個遊戲分鐘」，不是掛
# get_tree().create_timer()——後者是現實時間，跟 GameClock 的時間刻度脫鉤，
# 遊戲時間變速的話兩邊就會對不上。進度條每過一個遊戲分鐘更新一次，
# 不是照 _process() 的 delta 平滑跑——工作本身就是離散地一分鐘一分鐘算，
# 進度條應該老實反映這件事，不用假裝連續
func _run_work(workstation: Workstation, session_id: int) -> void:
	for i in WORK_DURATION_MINUTES:
		await GameClock.time_changed

		# 這個協程橫跨 5 個遊戲分鐘，中間什麼都可能發生。三件事要在每次醒來時重驗：
		#
		# 一、這個 session 可能已經被 force_interrupt() 收尾過（見它的註解，
		#     還可能已經被下一次 work_at() 蓋掉）——不是自己的號碼了就直接
		#     return，不能對這時可能已經被別人用掉的 workstation 再收尾一次。
		# 二、工作站可能已經被移除。await 之後直接 workstation.release() 會炸
		#     「call function on a previously freed instance」。
		# 三、角色可能自己走開了——Player 一按方向鍵就蓋掉 work_at() 的 stop_moving()，
		#     `_working` 攔不住移動。不重驗距離的話，按下 E 之後跑到地圖另一頭，
		#     時間到照樣入帳，而且這 5 分鐘工作站一直被卡著、現場卻沒人。
		#
		# 後兩種都是「沒有做完」，所以收尾但不撥款：錢是站在這裡做滿的報酬，
		# 不是按下 E 的報酬
		if session_id != _work_session_id:
			return
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
	_current_workstation = null
	# 遞增號碼：如果這次收尾是 force_interrupt() 提早觸發的，_run_work() 的
	# 協程還在等下一次 GameClock.time_changed，讓它醒來後比對號碼發現對不上，
	# 知道 session 已經收尾過，不用再收一次
	_work_session_id += 1
	if work_progress != null:
		work_progress.hide_progress()
	_on_work_finished()

# 工作結束後的鉤子。基底不做事；Agent 覆寫它重算行程——工作是 5 遊戲分鐘的
# 阻塞動作，期間可能已經跨過行程的整點，跟 exit_conversation() 是同一個理由。
# 用覆寫而不是在基底嗅探 is_in_group("agents")：子類別的事由子類別自己做
func _on_work_finished() -> void:
	pass


# ---- 購買 ----

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


# ---- 人格 ----

## 依 delta_dict（{欄位: 差值}）調整人格特質，統一夾在 0~100。跟睡眠反思套用
## personality_delta 是同一件事（同一份人格數值被誰改）,agent.gd 的反思流程
## 也改呼叫這裡,不要兩份 clampf 公式各自長歪。物品效果（見 eat()/drink()）
## 跟反思共用同一個 personality_delta 欄位名稱與語意，只是觸發來源不同——
## 反思那邊的數字在 ai_schema.gd 已經先夾過 ±MAX_PERSONALITY_DELTA（LLM
## 宣告的內容需要防它自己講過頭），物品這邊的數字是開發者寫在 items.json
## 裡的靜態資料，不是執行期才收到的不信任輸入，不需要再套一次同樣的驗證，
## 只要作者自己在資料裡填小一點的數字即可
func apply_personality_delta(delta_dict: Dictionary) -> void:
	for dim in delta_dict.keys():
		# 只認 _PERSONALITY_FIELDS 內的 10 個維度——不認得的 key（items.json
		# 手打錯欄位名之類）略過不寫。personality 存檔載入靠 _is_valid_
		# personality_data() 卡「剛好 10 項欄位」，這裡如果照單全收把第 11 個
		# 陌生 key 寫進 personality，下次存讀就會整包 personality 被判定不合法
		# 而拒絕套用，連本來合法的 10 項都遭殃（CodeRabbit review 抓到）
		if not _PERSONALITY_FIELDS.has(dim):
			push_warning("Character %s: 未知的人格欄位 %s，略過" % [character_name, dim])
			continue
		var current: float = float(personality.get(dim, 50.0))
		personality[dim] = clampf(current + float(delta_dict[dim]), 0.0, 100.0)


# ---- 進食 ----

# 找背包裡第一筆食物類物品的摘要（get_summary() 那份，含 item_id/count/slot），
# 找不到回空字典。食物判斷走 ItemDatabase 的 category == "food"（#84 已落地），
# 不是硬編碼白名單——#114 原本的建議是「先硬編碼、等 #84 落地後再改查表」，
# #84 已經在這之前完成，沒有必要走回頭路
func _find_food_slot() -> Dictionary:
	for entry in inventory.get_summary():
		var item_id: String = entry["item_id"]
		if ItemDatabase.get_item(item_id).get("category", "") == "food":
			return entry
	return {}

# 吃掉背包裡一份食物：扣一個、套用該物品在 items.json 定義的 effect_*／
# personality_delta。沒有背包的角色（EAT_NO_INVENTORY）或背包裡沒有食物
# （EAT_NO_FOOD）都要有明確原因碼，跟 TALK_*／WORK_*／BUY_* 同一套「每個
# 動作都要能講出為什麼失敗」的規則。效果套用交給 inventory.use_item()——
# 它才是「先套效果、確認成功才扣格子」那個順序的唯一實作，這裡不重複
# 一次 remove_item() 的判斷
func eat() -> String:
	if inventory == null:
		return EAT_NO_INVENTORY

	var food := _find_food_slot()
	if food.is_empty():
		return EAT_NO_FOOD
	if stats == null:
		return EAT_NO_STATS

	var item_id: String = food["item_id"]
	var item := ItemDatabase.get_item(item_id)
	var use_reason := inventory.use_item(item_id, stats, item)
	if use_reason != Inventory.USE_OK:
		return EAT_NO_FOOD

	apply_personality_delta(item.get("personality_delta", {}))
	return EAT_OK


# ---- 飲用 ----

# 找背包裡第一筆飲品類物品的摘要，找不到回空字典。跟 _find_food_slot() 同一招，
# 走 ItemDatabase 的 category == "drink"，不是硬編碼白名單（#163）
func _find_drink_slot() -> Dictionary:
	for entry in inventory.get_summary():
		var item_id: String = entry["item_id"]
		if ItemDatabase.get_item(item_id).get("category", "") == "drink":
			return entry
	return {}

# 喝掉背包裡一份飲品：跟 eat() 同一套「每個動作都要能講出為什麼失敗」規則，
# 效果套用同樣交給 inventory.use_item()（原本 DRINK_HYDRATION_RECOVERY／
# DRINK_ALCOHOL_RECOVERY 已刪除，資料搬進 data/items.json——含酒精飲品的
# alcohol／wakefulness 效果都在裡面一起讀出來，不用分兩行各自 add）
func drink() -> String:
	if inventory == null:
		return DRINK_NO_INVENTORY

	var slot := _find_drink_slot()
	if slot.is_empty():
		return DRINK_NO_DRINK
	if stats == null:
		return DRINK_NO_STATS

	var item_id: String = slot["item_id"]
	var item := ItemDatabase.get_item(item_id)
	var use_reason := inventory.use_item(item_id, stats, item)
	if use_reason != Inventory.USE_OK:
		return DRINK_NO_DRINK

	apply_personality_delta(item.get("personality_delta", {}))
	return DRINK_OK


# ---- 送禮 ----

# 把物品從自己的背包轉移到對方背包。跟 buy_from() 一樣是「兩件事要一起成功」，
# 但這裡不能照抄 buy_from() 的「先做、失敗再補償」寫法：一筆 give 可能橫跨好幾個
# 腐壞程度不同的格子（remove_item_detailed() 照原樣拆開），若其中一筆送到一半
# 才發現對方背包滿了，前面幾筆已經真的進了對方背包——不撤回就不是「兩件事一起
# 成功」，撤回又得從對方背包裡精確挑出剛剛那幾筆（跟對方原有的同物品混在一起，
# 挑錯格的風險不小）。
#
# 解法是先在對方背包的副本上，用真正的 add_item() 邏輯模擬全部加一遍——不是
# 自己另外設計一套「空間夠不夠」的公式來猜（那正是 buy_from() 註解裡刻意避開的
# 「猜錯要再重算一次堆疊規則」問題），模擬跑的就是等一下真的會執行的那個函式，
# 兩者不可能對不上。全部模擬通過才正式套用到對方背包，任何一筆會失敗就整批
# 作廢，沒有半成功的中間狀態（CodeRabbit review 抓到，#158）。
#
# 用 remove_item_detailed() 而不是 remove_item()：後者只回一個原因碼，逐筆的
# decay／durability 資訊會直接消失，送到對方那邊等於變成一批全新狀態（腐壞
# 程度歸零、耐久類物品甚至會被誤標成不追蹤耐久）。
#
# 不改動 relations 任何欄位——送禮的真實意圖交給雙方後續行為自己演，
# 不是引擎蓋章（見《99》決策紀錄、CLAUDE.md「遊戲機制規格：AI 自主性自檢」）
func give_to(other: Character, item_id: String, count: int = 1) -> String:
	if other == null:
		return GIVE_TARGET_NOT_FOUND
	if other == self:
		return GIVE_TARGET_IS_SELF
	if inventory == null or other.inventory == null:
		return GIVE_NO_INVENTORY
	if get_body_position().distance_to(other.get_body_position()) > GIVE_RANGE:
		return GIVE_TOO_FAR

	# 送出失敗時要原封不動退回——remove 前先留一份快照。不能靠事後逐筆
	# add_item() 補回去：那會照它的堆疊規則重新分組，跟原本各筆分開的格子、
	# 各自的 decay 不一定對得上（CodeRabbit review 抓到）
	var snapshot := inventory.slots.duplicate(true)

	# notify=false：這筆移除還沒確定算數，可能整批回滾——發了 changed 的話，
	# 訂閱者會在轉移成不成功還沒有結論前，看到來源背包暫時少了東西
	# （CodeRabbit review 抓到）。確定結果後這個函式自己決定要不要發
	var removal: Dictionary = inventory.remove_item_detailed(item_id, count, false)
	if removal["reason"] != Inventory.REMOVE_OK:
		return removal["reason"]

	var chunks: Array = removal["removed"]

	# 模擬：副本上的格子跟對方現在的背包一模一樣，跑一遍會不會塞不下
	var sim := Inventory.new()
	sim.slots = other.inventory.slots.duplicate(true)
	var blocked_reason := ""
	for chunk in chunks:
		var sim_reason: String = sim.add_item(item_id, chunk["count"], chunk["decay"], chunk["durability"])
		if sim_reason != Inventory.ADD_OK:
			blocked_reason = sim_reason
			break
	sim.free()

	if blocked_reason != "":
		# 模擬就擋下來了，對方背包從頭到尾沒被動過——用快照原封不動還原自己的
		# 背包，不能逐筆 add_item() 補回去，那會照它的堆疊規則重新分組。
		# 上面的移除故意沒發 changed，這裡還原後也不發：淨變化是 0，不該讓
		# 外部訂閱者看到一次「來源背包變了」的暫態事件
		inventory.slots = snapshot
		return blocked_reason

	# 模擬全部通過，正式套用到對方背包——不會再失敗，因為套用的規則、對方背包
	# 當下的狀態，跟模擬時完全一樣（中間沒有任何 await，不會有別的呼叫端插進來改動）。
	# notify=false：逐筆發 changed 的話，訂閱者會在轉移途中看到對方背包只收到
	# 一部分物品的暫態，而且訂閱者若在收到事件當下改動對方背包，會讓後面幾筆
	# 跟模擬時的假設對不上（CodeRabbit review 抓到）——靜音到全部套用完再發一次，
	# 迴圈中途連訊號都不發，這個假設就不會被打破
	for chunk in chunks:
		var add_reason: String = other.inventory.add_item(
			item_id, chunk["count"], chunk["decay"], chunk["durability"], false
		)
		if add_reason != Inventory.ADD_OK:
			# 理論上不會發生（模擬已經驗過），真的發生代表上面那個「不會被
			# 打斷」的假設被打破了——這裡不試著回滾（已經進去的 chunk 混進
			# 對方背包，退不乾淨），只留一個明確的錯誤讓它可被追查
			push_error("Character.give_to(): 模擬通過但正式套用失敗（%s）——%s 的背包可能在轉移途中被改動" % [add_reason, other.character_name])

	# 上面的移除跟正式套用都故意沒發 changed，整筆轉移確定成功才在這裡對兩邊
	# 背包各發一次——跟失敗時完全不發是對稱的：一次真的發生的變化只對應一次事件
	inventory.changed.emit()
	other.inventory.changed.emit()

	return GIVE_OK


# ---- 攻擊 ----

## 攻擊命中必中——跟 steal／persuade 等動作不同，不依《01-2》§2 通用成功率
## 公式擲骰，P-28 已拍板 MVP 不做閃避／格擋。硬規則只檢查目標是否存在、
## 距離夠不夠近；命中後直接套用數值、強制中斷對方目前行動
func attack(other: Character) -> String:
	if other == null:
		return ATTACK_TARGET_NOT_FOUND
	if other == self:
		return ATTACK_TARGET_IS_SELF
	if get_body_position().distance_to(other.get_body_position()) > ATTACK_RANGE:
		return ATTACK_TOO_FAR

	if other.stats != null:
		other.stats.add("health", ATTACK_HEALTH_DELTA)
		other.stats.add("injury", ATTACK_INJURY_DELTA)
		# 立即同步 bleeding／injury 衰減暫停，不等 _update_conditions() 的 10 分鐘
		# 一次 tick——命中瞬間 injury 可能已經跨過 20 的門檻，晚同步的話這段空窗期
		# injury 會繼續被 Stats 的自然衰減（GameClock 驅動）蓋掉這次造成的傷害。
		# is_dead 時跳過：死屍的 conditions 只留 petrified（#379），這裡不能
		# 直接呼叫 _set_condition() 把 BLEEDING 疊加回去，蓋掉那個不變量
		if not other.is_dead:
			other._set_condition(CONDITION_BLEEDING, other.stats.get_value("injury") >= 20.0)
			other.stats.injury_decay_paused = other.has_condition(CONDITION_BLEEDING)
	other.force_interrupt()
	other._on_attacked(self)
	return ATTACK_OK

## 被攻擊的收尾鉤子。基底只是掛點——Player 沒有記憶系統可寫，只有 Agent
## 需要把這件事記成事實句給下次決策／反思用（見 agent.gd 覆寫）
func _on_attacked(_attacker: Character) -> void:
	pass

## 強制中斷目前行動，不徵詢 interruptible／能不能被搭話打斷——跟仲裁器的
## 「搶占」判斷是兩回事，這裡是外部事件硬性發生（被攻擊等，《02》§3「立即
## 中斷，含 work 中」）。工作中要立即呼叫 _end_work()：工作站的釋放與進度條
## 收尾不能拖到 _run_work() 下一次 GameClock.time_changed 才做（CodeRabbit
## review 抓到）——拖著的話那段空窗期工作站仍算「有人在用」，擋掉其他角色，
## 而工作進度 UI 也還開著，跟角色已經不在工作的實際狀態對不上
func force_interrupt() -> void:
	stop_moving()
	if is_in_conversation():
		leave_conversation()
	if _working:
		_end_work(_current_workstation)
	_on_action_interrupted()

## 中斷後的收尾鉤子，讓子類別決定要不要重新規劃行程。基底不用管——
## Player 沒有行程可言，只有 Agent 需要清目前任務並重新問決策
func _on_action_interrupted() -> void:
	pass


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
		"last_action_result": last_action_result,
		# 深拷貝：Dictionary／Array 是傳參照，直接放進 snapshot 的話呼叫端改了
		# 快照會連帶改到 Character 內部狀態，繞過 set_emotion() 的驗證
		"emotion": emotion.duplicate(true),
		"conditions": conditions.duplicate(true),
		"current_goal": current_goal,
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

# 給 SaveService 存的角色資料：身分、數值、關係、記憶（L2/L4）。跟 get_state_snapshot() 是
# 兩份不同的東西，不要互相包裝——snapshot 要描述現況給 LLM 看（含 facing、
# 動畫這類衍生狀態），這裡要能還原（座標屬於世界存檔，見 #21，不在這裡）
func get_save_data() -> Dictionary:
	var data := {
		"character_id": character_id,
		"character_name": character_name,
		"incapacitation_start_minute": _incapacitation_start_minute,
		"is_being_carried": _is_being_carried,
		"treatment_start_minute": _treatment_start_minute,
		"treatment_location": _treatment_location,
		# 睡前反思（#349）會用 personality_delta 累積調整這 10 項，跨天累積的
		# 性格漂移不該因為重開就被重置回建角當下的原始值——跟 today_plan「跨天
		# 承諾不該憑空消失」同一個道理（見 note/技術/存檔.md）
		"personality": personality.duplicate(true),
		"is_exhausted": has_condition(CONDITION_EXHAUSTED),
		"is_dead": is_dead,
		"death_tick": death_tick,
		"death_day": death_day,
		"death_at": death_at,
		"death_cause": death_cause,
		"death_location_id": death_location_id,
		"last_words": last_words,
		"corpse_decay": corpse_decay,
		"is_buried": is_buried,
		"grave_id": grave_id,
		"buried_by": buried_by,
		"buried_tick": buried_tick,
	}

	if stats != null:
		data["stats"] = stats.get_save_data()
	if relationships != null:
		data["relationships"] = relationships.get_save_data()
	if memory != null:
		data["memory"] = memory.get_save_data()

	return data

# 已經在 characters 群組裡（_ready() 跑過）才重驗 id 唯一性——存檔的 character_id
# 可能撞到另一隻已經在場上的角色，覆寫後兩隻共用同一個 id 就會共用關係與記憶
# （_ensure_unique_id() 註解講的那個坑）。還沒進 tree 就不用管，接下來的 _ready()
# 本來就會做這件事，這裡搶著做反而會在 get_tree() 是 null 時炸掉
func load_save_data(data: Dictionary) -> void:
	# 每個欄位都先取出來檢查型別再指定，不直接 data.get(key, 現有值)——
	# 這幾個都是型別化屬性（String/int/bool），壞掉的存檔把值存成別的型別
	# 時直接指定會是執行期型別錯誤；型別不對就沿用現有值，跟 stats／
	# relationships 那兩處是同一個理由（CodeRabbit review 抓到）
	var loaded_id: Variant = data.get("character_id", character_id)
	character_id = loaded_id if loaded_id is String else character_id
	if character_id.is_empty():
		character_id = _resolve_generated_id()
	if is_inside_tree():
		_ensure_unique_id()
	# 空字串不是合法的存檔值——_ready() 一定會把空名稱解析成節點名再存進
	# get_save_data()，能存出空字串的只有損毀存檔，接受它會讓主控台指令／
	# UI 找不到或顯示空白名稱，跟型別不對一樣沿用現有值
	var loaded_name: Variant = data.get("character_name", character_name)
	character_name = loaded_name if loaded_name is String and not loaded_name.is_empty() else character_name

	# 還原昏迷與治療狀態（用 -1 作為哨兵值表示未進入該狀態，其餘合法值是
	# GameClock.hour*60+GameClock.minute 那個 [0, 1439] 範圍——只驗證 is int
	# 不夠，-2 這種值會通過型別檢查、又不等於 -1，被當成合法的昏迷/治療
	# 時間點還原，角色可能被錯誤鎖定或直接進入治療流程）
	var loaded_incap: Variant = data.get("incapacitation_start_minute", _incapacitation_start_minute)
	_incapacitation_start_minute = loaded_incap if loaded_incap is int and (loaded_incap == -1 or (loaded_incap >= 0 and loaded_incap < 1440)) else _incapacitation_start_minute
	var loaded_carried: Variant = data.get("is_being_carried", _is_being_carried)
	_is_being_carried = loaded_carried if loaded_carried is bool else _is_being_carried
	var loaded_treat_start: Variant = data.get("treatment_start_minute", _treatment_start_minute)
	_treatment_start_minute = loaded_treat_start if loaded_treat_start is int and (loaded_treat_start == -1 or (loaded_treat_start >= 0 and loaded_treat_start < 1440)) else _treatment_start_minute
	var loaded_treat_loc: Variant = data.get("treatment_location", _treatment_location)
	_treatment_location = loaded_treat_loc if loaded_treat_loc is String else _treatment_location

	# 還原死亡狀態（#379）。is_dead 一旦是 true 就是終局，其餘欄位照搬存檔值即可
	# ——不像昏迷/治療那樣需要用哨兵值判斷「進行到一半」，死亡沒有進行到一半這回事。
	# 缺席預設 false，不是沿用目前值（CodeRabbit review 抓到）：is_dead 是這個 PR
	# 新增的欄位，所有既有存檔都沒有這個 key——若沿用目前值，先載入一份死亡存檔、
	# 再對同一個節點載入一份沒有 is_dead 的舊存檔時，死亡狀態會黏著甩不掉，下面
	# else 分支的清理永遠執行不到
	var loaded_dead: Variant = data.get("is_dead", false)
	is_dead = loaded_dead if loaded_dead is bool else false
	if is_dead:
		var loaded_tick: Variant = data.get("death_tick", death_tick)
		death_tick = loaded_tick if loaded_tick is int else death_tick
		var loaded_day: Variant = data.get("death_day", death_day)
		death_day = loaded_day if loaded_day is int else death_day
		var loaded_at: Variant = data.get("death_at", death_at)
		death_at = loaded_at if loaded_at is String else death_at
		var loaded_cause: Variant = data.get("death_cause", death_cause)
		death_cause = loaded_cause if loaded_cause is String else death_cause
		var loaded_loc: Variant = data.get("death_location_id", death_location_id)
		death_location_id = loaded_loc if loaded_loc is String else death_location_id
		var loaded_words: Variant = data.get("last_words", last_words)
		last_words = loaded_words if (loaded_words == null or loaded_words is String) else last_words
		var loaded_decay: Variant = data.get("corpse_decay", corpse_decay)
		corpse_decay = clampf(loaded_decay, 0.0, 100.0) if (loaded_decay is float or loaded_decay is int) else corpse_decay
		var loaded_buried: Variant = data.get("is_buried", is_buried)
		is_buried = loaded_buried if loaded_buried is bool else is_buried
		var loaded_grave: Variant = data.get("grave_id", grave_id)
		grave_id = loaded_grave if (loaded_grave == null or loaded_grave is String) else grave_id
		# 缺席預設 null／-1，不是沿用目前值，跟 is_dead 同一個理由（CodeRabbit
		# review 抓到）：buried_by／buried_tick 是這個 PR 新增的欄位，同一節點
		# 若先載入一份已安葬存檔、再載入一份沒有這兩個 key 的舊死亡存檔，
		# 沿用目前值會讓安葬歸屬與時間點黏著甩不掉
		var loaded_buried_by: Variant = data.get("buried_by", null)
		buried_by = loaded_buried_by if (loaded_buried_by == null or (loaded_buried_by is String and not loaded_buried_by.is_empty())) else null
		var loaded_buried_tick: Variant = data.get("buried_tick", -1)
		buried_tick = loaded_buried_tick if (loaded_buried_tick is int and (loaded_buried_tick == -1 or loaded_buried_tick >= 0)) else -1

		# 治療欄位跟 _die() 同一個理由清掉（CodeRabbit review 抓到）：上面幾行
		# 只還原死亡欄位本身，沒清掉治療欄位——若這份存檔或載入前的角色狀態剛好
		# 帶著沒清乾淨的 treatment_start_minute，_update_treatment() 沒有 is_dead
		# 判斷，60 分鐘後 _complete_treatment() 會把 petrified 一起清掉、救活死屍
		_treatment_start_minute = -1
		_treatment_location = ""

		conditions.clear()
		conditions.append({"type": CONDITION_PETRIFIED, "turns_left": -1})
		_apply_death_tint(true)
		# 跟 _die() 同一個理由（CodeRabbit review 抓到）：還原死亡存檔時若既有
		# _hauling_target 殘留，同樣要放手，不然目標卡在死掉的搬運者身上走不動
		if is_hauling():
			stop_haul()
		# 跟 _die() 同一個理由（CodeRabbit review 抓到）：場上正在工作／對話中的
		# 角色被載入一份死亡存檔時，這裡只設了狀態欄位，沒有真的收尾——不呼叫
		# force_interrupt() 的話 _run_work() 協程會在下個 GameClock.time_changed
		# 通過距離檢查照樣撥款給死屍。Agent 覆寫的 _on_action_interrupted() 已經
		# 擋了 is_dead，這裡呼叫不會反過來問出新決策
		force_interrupt()
	else:
		# 還原成活人存檔時清掉死亡殘留（CodeRabbit review 抓到）：同一個 Character
		# 節點先前若死過（例如 debug 重新載入另一份存活存檔），petrified 與灰階
		# 只在上面 is_dead 分支寫入，不會因為這次 is_dead=false 自動消失——不清的話
		# 會出現 is_dead=false 但外觀／conditions 仍是死屍的矛盾狀態
		conditions = conditions.filter(func(c): return c["type"] != CONDITION_PETRIFIED)
		_apply_death_tint(false)
		death_tick = -1
		death_day = -1
		death_at = ""
		death_cause = ""
		death_location_id = ""
		last_words = null
		corpse_decay = 0.0
		is_buried = false
		grave_id = null
		buried_by = null
		buried_tick = -1

	# 治療與昏迷互斥（見 _send_to_herb_shop_for_treatment()），治療中的存檔優先還原成治療狀態，
	# 不重建 CONDITION_INCAPACITATED；只有「昏迷中但還沒送醫」才需要重建。死亡是終局，
	# 優先於昏迷——_die() 已經把 _incapacitation_start_minute 清成 -1，這裡的 not is_dead
	# 只是雙重保險，防止未來別的路徑忘記清理時把 INCAPACITATED 疊加回死屍身上
	if not is_dead and _incapacitation_start_minute != -1 and _treatment_start_minute == -1:
		_set_condition(CONDITION_INCAPACITATED, true, false)

	# is Dictionary 而不是只看 has()——壞掉的存檔把 stats/relationships 存成
	# 別的型別時，直接把值傳給下面兩個型別化參數的函式會是執行期型別錯誤，
	# 不是「缺欄位」那種能被 has() 擋掉的情況（CodeRabbit review 抓到）
	if stats != null and data.get("stats", null) is Dictionary:
		stats.load_save_data(data["stats"])
	if relationships != null and data.get("relationships", null) is Dictionary:
		relationships.load_save_data(data["relationships"])

	# 獨立還原力竭狀態（不依賴 stats 存在，處理沒有 Stats 節點的角色，也處理
	# stamina = 1-50 這種邊界情況）。新存檔有 is_exhausted 欄位則直接還原，
	# 舊存檔沒有這個欄位、但有 stats 可用時才由 stamina 推斷。
	# 死亡分支已經把 conditions 清成只留 petrified（#379）——not is_dead 防止
	# 這裡把 EXHAUSTED 疊加回死屍身上，蓋掉那個清空
	if not is_dead:
		if data.has("is_exhausted"):
			_set_condition(CONDITION_EXHAUSTED, data["is_exhausted"])
		elif stats != null:
			_update_exhausted_condition()

	# 沒有存檔資料時維持 _ready() 已經由 Personality.from_identity() 組好的值，
	# 不清空——跟 stats／relationships 同一個理由，personality 不是每次都
	# 隨存檔走的東西（沒建過角的預設角色也要有值）。
	#
	# 覆寫前先驗證結構完整（10 項欄位都在、值是合法數字）才套用——之後
	# Agent._roll_success() 會把這幾項當 float 直接運算，缺欄位會被
	# .get(key, 0.0) 悄悄當成 0（角色性格整個跑掉但不報錯），型別錯誤則要
	# 到那裡才會炸開。壞掉的存檔資料寧可整包不套用、保留目前有效的人格，
	# 也不要讓半殘資料靜默生效（CodeRabbit review 抓到）
	if data.has("personality") and data["personality"] is Dictionary:
		var loaded_personality: Dictionary = data["personality"]
		if _is_valid_personality_data(loaded_personality):
			personality = loaded_personality.duplicate(true)
		else:
			push_error("Character %s: 存檔的 personality 資料結構不合法，保留目前人格" % character_name)

	# memory 一定呼叫，跟 stats／relationships 特意不同：這個角色可能是已經在
	# 場上跑過、累積了新記憶的既有節點（debug console `load` 就是這樣用），
	# 讀進來的存檔沒有 memory 欄位時要把記憶重設成空，而不是保留讀檔前的
	# 舊記憶——Memory.load_save_data() 本身也會處理欄位缺失/格式錯誤
	if memory != null:
		var memory_data: Variant = data.get("memory", {})
		memory.load_save_data(memory_data if memory_data is Dictionary else {})

# personality 欄位清單跟 Personality.hexaco_to_personality() 實際產出的
# 10 項對齊，不引用 Personality 常數——這裡只是「存檔資料合不合法」的結構
# 檢查，跟 Personality 那邊「HEXACO 怎麼算出這 10 項」是不同層次的事
const _PERSONALITY_FIELDS := [
	"diligence", "courage", "sociability", "morality", "stability",
	"romanticism", "curiosity", "grudge", "greed", "honesty",
]

# 存檔的 personality 必須恰好是這 10 項欄位、每項都是合法有限數字，才准
# 覆寫目前人格——少欄位、多欄位、型別錯誤、NaN/Infinity 一律拒絕整包
func _is_valid_personality_data(loaded: Dictionary) -> bool:
	if loaded.size() != _PERSONALITY_FIELDS.size():
		return false
	for key in _PERSONALITY_FIELDS:
		if not loaded.has(key):
			return false
		var value: Variant = loaded[key]
		if not (value is int or value is float) or not is_finite(float(value)):
			return false
	return true

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
# 沒有在動，播 idle 才對，只是 facing 要跟上輸入方向。
# 判斷用容差而非精確比較 == Vector2.ZERO——沿角度貼著障礙物滑動時，
# move_and_slide() 可能把 velocity 解算成極小但非零的殘值，跟 _check_stuck()
# 同一個理由、用同一個門檻（SPEED * 0.1）
func update_animation(desired_velocity: Vector2) -> void:
	var dir := desired_velocity.normalized()

	if dir != Vector2.ZERO:
		# 垂直位移比水平大就用背面／正面，否則用側面
		if abs(dir.y) > abs(dir.x):
			facing = "back" if dir.y < 0 else "front"
		else:
			facing = "right"
			sprite.flip_h = dir.x < 0

	sprite.play(("walk_" if get_real_velocity().length() > SPEED * 0.1 else "idle_") + facing)

# 這一幀要用的速度。基底只跟隨 A* 路徑，子類別覆寫來加上自己的驅動來源。
# 對話中不自動移動 —— 但 Player 的輸入會蓋過這裡，走遠了由距離判定自然散場
func _decide_velocity() -> Vector2:
	# 被搬運時身體要跟著搬運者走，即使正昏迷或治療中（石化原地指的是不能「自己」
	# 移動，不是身體釘死不能被搬走）——這個判斷要排在昏迷/治療鎖定之前
	if is_being_hauled():
		return _follow_hauler()

	# 昏迷或治療中無法產生移動速度
	if _is_movement_locked():
		return Vector2.ZERO

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

	return body_position.direction_to(_path[_path_index]) * effective_speed()

# 被搬運中跟著搬運者移動
func _follow_hauler() -> Vector2:
	if _hauled_by.is_empty():
		return Vector2.ZERO

	var hauler: Character = _hauled_by[0]
	if not is_instance_valid(hauler):
		return Vector2.ZERO

	var body_position := get_body_position()
	if body_position.distance_to(hauler.get_body_position()) < ARRIVE_DISTANCE:
		return Vector2.ZERO

	return body_position.direction_to(hauler.get_body_position()) * hauler.effective_speed()

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

	# 搬運體力消耗（#161，《99》P-27 #3-2）
	if _hauling_target != null and stats != null:
		stats.add("stamina", -HAUL_STAMINA_DRAIN * delta)


# ---- 搬運邏輯（#161） ----

func is_being_hauled() -> bool:
	return not _hauled_by.is_empty()

func hauler_count() -> int:
	return _hauled_by.size()

func is_hauling() -> bool:
	return _hauling_target != null

func effective_speed() -> float:
	return SPEED * _speed_multiplier

func start_haul(target: Character) -> String:
	if target == null:
		return HAUL_TARGET_NOT_FOUND
	if target == self:
		return HAUL_TARGET_IS_SELF
	if get_body_position().distance_to(target.get_body_position()) > HAUL_RANGE:
		return HAUL_TOO_FAR

	# 換搬別的目標前，先放掉原本那個，避免舊目標的 _hauled_by 留著搬不掉的殘留參照
	if _hauling_target != null and _hauling_target != target:
		stop_haul()

	target._attach_haul(self)
	_hauling_target = target
	_speed_multiplier = HAUL_SPEED_MULTIPLIER
	target.set_being_carried(true)		# #271: 通知昏迷機制

	if is_in_group("agents"):
		(self as Agent)._push_daily_event("你搬運了%s。" % target.character_name, [target.character_id])
	if target.is_in_group("agents"):
		(target as Agent)._push_daily_event("你被%s搬運了。" % character_name, [character_id])

	return HAUL_OK

func stop_haul() -> void:
	if _hauling_target != null:
		var target := _hauling_target
		target._detach_haul(self)
		# 雙人搬運時（《99》P-27 #8），其中一人放手不該讓另一人還在搬的目標被標記成沒人搬
		if not target.is_being_hauled():
			target.set_being_carried(false)		# #271: 通知昏迷機制
			if is_in_group("agents"):
				(self as Agent)._push_daily_event("你放開了%s。" % target.character_name, [target.character_id])
			if target.is_in_group("agents"):
				(target as Agent)._push_daily_event("你掙脫了搬運。")
		_hauling_target = null
	_speed_multiplier = 1.0

func _attach_haul(hauler: Character) -> void:
	if not _hauled_by.has(hauler):
		_hauled_by.append(hauler)

func _detach_haul(hauler: Character) -> void:
	_hauled_by.erase(hauler)


# ---- 長動作檢查點的依附者（issue #336，《02》§3） ----

## 自己進行長動作、觸發固定間隔檢查點時，除了自己還要一併收到檢查點通知的
## 角色——目前唯一情形是被自己 haul 的目標。檢查點觸發時「搬運者選繼續搬
## 還是放棄放下、被搬運者選 struggle／shout／idle」是兩件不同的事（見
## Agent._reevaluate_once()／#337），這裡只負責列出「還有誰要一併通知」。
##
## 之後若有類似「一方長時間限制另一方行動」的機制（如 detained），比照這套
## 模式在這裡加一條，不要各自另兜一套通知管道（《02》§3 明訂）
func get_checkpoint_dependents() -> Array[Character]:
	var dependents: Array[Character] = []
	if _hauling_target != null:
		dependents.append(_hauling_target)
	return dependents

## 依附在別人的長動作上時收到的檢查點通知（例如被 haul 時，對方的 haul
## 檢查點觸發）。基底預設什麼都不做——要不要因此發起自己的決策請求、問什麼
## 選項，是各自機制的責任（被 haul 時要問 struggle／shout／idle，見 #337；
## Player 若之後也會被 haul，這裡會是接 UI 提示的地方，不是這裡的責任）
func on_dependent_checkpoint(_task: Dictionary) -> void:
	pass
