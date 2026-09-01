class_name Character
extends CharacterBody2D

## Player 與 Agent 的共用基底。
## 移動一律走 NavGrid 的 A* 路徑；動畫是 front / back / right 三向素材，
## 往左沒有專屬素材，用 flip_h 翻轉 right 代替。
## 子類別只負責決定「往哪走」：Player 讀輸入，Agent 讀行程表。

signal move_finished(reached: bool)
signal noise_heard(source: Character)		# 收到的那一方會發，見 make_noise()
signal spoke(line: String)			# 講出任何一句話都會發，日後寫逐字稿/記憶系統的接點
signal speech_heard(source: Character, line: String)	# 收到的那一方會發，見 say() 的廣播（issue #669）

const SPEED = 60.0		# 2026-08-24 從 80 調降，原速 5 格/秒（16px/格）偏快
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

## perform() 的失敗原因碼，形狀比照 EAT_*／DRINK_*（#575）。跟 work_at() 一樣
## 是多分鐘的長動作，多了一個 BUSY——已經在表演、工作或對話中不能再開始一次
const PERFORM_OK := ""
const PERFORM_NO_INVENTORY := "NO_INVENTORY"	# 沒有背包的角色沒有樂器可用
const PERFORM_NO_INSTRUMENT := "NO_INSTRUMENT"	# 背包裡沒有 instrument（#575 拍板：任意地點皆可，只認物品，不認地點）
const PERFORM_NO_STATS := "NO_STATS"			# 沒有 Stats 的角色沒地方扣 hygiene
const PERFORM_BUSY := "BUSY"					# 已經在表演、工作、對話中，或移動被鎖定

## 表演持續的遊戲分鐘數。跟 WORK_DURATION_MINUTES 同一種「固定分鐘數」寫法，
## 值取相同量級——太短的話，範圍內的路人 Vision 偵測＋LLM 決策一輪跑不完，
## 表演已經結束了，永遠等不到任何人打賞
const PERFORM_DURATION_MINUTES := 10

## gather() 的失敗原因碼，形狀比照 BUY_*：除了 NO_INVENTORY，背包滿了直接
## 原樣轉傳 Inventory 的 ADD_NO_SPACE，不重新取名（#574）
const GATHER_OK := ""
const GATHER_NO_INVENTORY := "NO_INVENTORY"	# 沒有背包的角色沒辦法採集
const GATHER_NO_STATS := "NO_STATS"	# 沒有 Stats 的角色沒地方扣 hygiene（跟 PERFORM_NO_STATS 同一個理由）

## use_selected_item() 的失敗原因碼，形狀比照 EAT_*／DRINK_*（#611）。除了這四個，
## use_selected_item() 還會**原樣轉傳** Inventory.use_item() 自己的原因碼
## （`NOT_CONSUMABLE`、`INVALID_EFFECT`、`REMOVE_FAILED`……），跟 buy_from() 轉傳
## `NOT_ENOUGH`／`NO_SPACE` 同一個理由，不重新取名
const USE_ITEM_OK := ""
const USE_ITEM_NO_INVENTORY := "NO_INVENTORY"	# 沒有背包的角色沒辦法使用道具
const USE_ITEM_NO_SELECTION := "NO_SELECTION"	# 快捷欄沒選格，或選到的是空格
const USE_ITEM_NO_STATS := "NO_STATS"		# 沒有 Stats 的角色沒地方回復數值
const USE_ITEM_IS_DEAD := "IS_DEAD"		# 死屍不能使用道具（CodeRabbit review 抓到，PR #615）——
						# 跟 talk_to() 擋自己是死屍發起搭話同一種漏洞：is_dead
						# 之後沒有任何地方會停用玩家的 _unhandled_input()，
						# 死屍照樣能吃/喝

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
const HAUL_TARGET_ALREADY_BURIED := "TARGET_ALREADY_BURIED"
const HAUL_TOO_FAR := "TOO_FAR"

const ATTACK_RANGE := 32.0		# 跟 TALK_RANGE／WORK_RANGE／BUY_RANGE／GIVE_RANGE 一樣的距離門檻，2 格

## 天神之石互動手勢（吐口水／攻擊／膜拜／讚美，issue #752）共用的距離門檻，
## 跟其他小互動同一種「2 格內」標準，沒理由對這裡另訂一套
const GOD_STONE_GESTURE_RANGE := 32.0

## attack() 的失敗原因碼，形狀比照 GIVE_*。IS_DEAD 是「攻擊者是死屍」
## （CodeRabbit review 抓到，PR #763）——死屍不能發起攻擊，跟 talk_to()／
## use_selected_item() 擋自己這側同一種漏洞、同一種修法：is_dead 之後沒有
## 任何地方會停用玩家的 _unhandled_input()，死屍照樣能右鍵開打。
## 注意只擋攻擊者這一側：攻擊死屍（other.is_dead）的既有行為不變
const ATTACK_OK := ""
const ATTACK_TARGET_NOT_FOUND := "TARGET_NOT_FOUND"
const ATTACK_TARGET_IS_SELF := "TARGET_IS_SELF"
const ATTACK_TOO_FAR := "TOO_FAR"
const ATTACK_IS_DEAD := "IS_DEAD"		# 失敗原因碼沿用共用詞彙表，FAILURE_MESSAGE_KEYS 已有 IS_DEAD 對應

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
	"NO_INSTRUMENT": "FAIL_NO_INSTRUMENT",
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
	"NO_SELECTION": "FAIL_NO_SELECTION",
	"IS_DEAD": "FAIL_IS_DEAD",
	"TARGET_NOT_DEAD": "FAIL_TARGET_NOT_DEAD",
	"TARGET_ALREADY_BURIED": "FAIL_TARGET_ALREADY_BURIED",
	"CEMETERY_FULL": "FAIL_CEMETERY_FULL",
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

## 這個角色專屬的家，指向 location 表的其中一筆 loc_home_0N（《規格書01》§1-1，
## issue #391）。玩家不選，建角時由 CharacterStatePersistence._resolve_home_location()
## round-robin 自動分配並寫回這裡；留空是正常初始狀態，代表還沒建過 npc 記錄
var home_location_id := ""

## 建角面板滑桿設定的年齡（《規格書01》§1-1，16–70，預設 30），issue #837。
## -1 是「未知」的哨兵值——只有走過角色庫投放（`GameManager.deploy_from_library()`／
## `spawn_character()`）或存檔還原的角色才會被寫入真正的數值；固定寫在場景裡的
## NPC（`npc_schedule.json` 的 `identities` 表）沒有年齡資料，維持 -1，
## `status_panel.gd` 顯示佔位符，不是假造一個看起來合理的預設數字
var age := -1

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
## 這次昏迷事件裡已經觸發過 _on_rescued() 的搬運者名單，避免第一位搬運者
## 救到人、_end_incapacitation() 已經跑過後，稍後才加入的第二位搬運者被
## set_being_carried() 的 has_condition(CONDITION_INCAPACITATED) 判斷擋掉、
## 漏記救助事實句（CodeRabbit review 抓到）。新一輪昏迷開始時歸零
var _rescued_haulers: Array[Character] = []

@onready var sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var collider: CollisionShape2D = $CollisionShape2D
@onready var stats: Stats = get_node_or_null("State/Stats")
@onready var relationships: Relationships = get_node_or_null("State/Relationships")
@onready var bubble: Node2D = get_node_or_null("UI/Bubble")
@onready var vision: Vision = get_node_or_null("Sensing/Vision")
@onready var inventory: Inventory = get_node_or_null("State/Inventory")
@onready var work_progress: WorkProgress = get_node_or_null("UI/WorkProgress")
@onready var money_popup: MoneyPopup = get_node_or_null("UI/MoneyPopup")
@onready var memory: Memory = get_node_or_null("State/Memory")
# 只有 Player 掛這個節點——NPC 不需要被引導去任何地方。get_node_or_null()
# 在沒有這個節點的 Agent 實例上安靜回 null，呼叫端（#305）自己判斷要不要用
@onready var waypoint_indicator: WaypointIndicator = get_node_or_null("UI/WaypointIndicator")

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
var corpse_decay := 0.0		# 0–100，_update_corpse_decay() 每 tick +0.7；達 100 觸發 _erect_unmarked_grave()
var is_buried := false			# 人為安葬見 bury()（#380），自動立無名碑見 _erect_unmarked_grave()（#387）
var grave_id: Variant = null	# 同上，String 或 null
var grave_slot_index := -1		# 安葬在墓園時分配到的墓位索引（0~CEMETERY_GRAVE_CAPACITY-1），
								# -1 代表未分配（尚未安葬，或立碑當下不在墓園範圍內，見 _assign_cemetery_grave_slot()）
var buried_by: Variant = null	# 誰安葬了你，String（character_id）或 null（無名碑等非人為安葬，見 _erect_unmarked_grave()）
var buried_tick := -1			# 安葬當下的全域 tick，同 death_tick 換算方式，見 bury()
var is_anonymous := false		# 無名碑（《規格書09》§3-4／§4-3）：_erect_unmarked_grave() 自動立碑時設 true；
								# bury() 人為安葬不改這個值，只有《規格書09》§4-4 擦拭墓碑（未實作）能清成 false
var _grave_marker: Node2D = null	# 安葬後取代石化本體的墓碑造型，見 _apply_grave_visual()（issue #832）

## 入眠相關狀態（issue #827，《10》§4.5「玩家離線處置」／§6.4「模型失效
## 處理」）。is_offline_asleep 是狀態的唯一事實來源，跟 is_dead 同一種寫法。
## §4.5（真人離線）與§6.4（模型下架／額度用盡／格式錯誤）在規格書上是兩種
## 情境，但對「角色現在該怎麼表現」而言是同一件事——暫停決策與需求衰減、
## 顯示「被天神召喚中」，這裡不分流，呼叫端各自判斷「什麼時候該叫入眠」，
## 這裡只負責「入眠時該做什麼」
var is_offline_asleep := false
var _offline_asleep_since_unix := 0.0	# Time.get_unix_time_from_system()，算現實 72 小時用

## 現實 72 小時未恢復即達踢出門檻（《10》§4.5）。踢出後具體要怎麼處理
## （存檔怎麼標記、要不要真的移除節點）留給後續 issue 拍板——這則只確保
## 「已經入眠多久」量得到，不擅自決定踢出當下要做什麼
const OFFLINE_KICK_THRESHOLD_SEC := 72 * 3600

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
	# GRAVE_SLOT_OFFSETS 的個數就是墓位上限（兩者改動要一起改，見常數註解）——
	# 個數兜不起來時越早炸越好，不然墓位會配置到沒有偏移座標的索引
	assert(GRAVE_SLOT_OFFSETS.size() == CEMETERY_GRAVE_CAPACITY)
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
	_apply_grave_visual(is_buried)

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
	_rescued_haulers.clear()
	stop_moving()  # 立即停止移動
	print_debug("Character %s 進入昏迷，計時器已啟動" % character_name)

## 死亡／昏迷／治療中／入眠都不能動：死亡是終局的石化，昏迷是暫時的石化，
## 治療是「住院中」，入眠是「被天神召喚中」（issue #827，《10》§4.5），四者
## 共用同一個移動鎖（《99》P-27／藥草鋪筆記／《規格書09》§1），供 move_to()
## 與 _decide_velocity()（含 Player 覆寫）共用
func _is_movement_locked() -> bool:
	return (
		is_dead
		or has_condition(CONDITION_INCAPACITATED)
		or _treatment_start_minute != -1
		or is_offline_asleep
	)

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

	# 被救助：通知每個搬運者的救助鉤子（見 _on_rescued()）。搬運者只會被
	# stop_haul() 從 _hauled_by 移除，沒有 _exit_tree() 清理時，搬運者若被
	# queue_free() 直接砍掉，_hauled_by 會留著已釋放的殘留參照——!= null
	# 擋不住這個，已釋放的 Object 不會自動變成 null，要用 is_instance_valid()
	# （CodeRabbit review 抓到）。_rescued_haulers 仍要記——不是為了擋重複的
	# 關係定性（已拿掉，見 _on_rescued() 說明），是擋同一位搬運者的事實句被
	# 重複記兩次
	for hauler in _hauled_by:
		if is_instance_valid(hauler) and not _rescued_haulers.has(hauler):
			_on_rescued(hauler)
			_rescued_haulers.append(hauler)

	print_debug("Character %s 昏迷已結束（被搬走）" % character_name)

## 被搬運者救助的收尾鉤子（含 _attach_haul() 補發的晚到搬運者）。基底只是
## 掛點，跟 _on_attacked() 同一個理由——Player 沒有記憶系統可寫，只有 Agent
## 需要記事實句。
##
## 刻意不在這裡對關係做任何定性（2026-08-24 拿掉固定公式，#601 拿掉 trust
## 欄位本身，見全專案盤點的原則二／三審查）：跟 _on_attacked() 同一個問題——
## 引擎用固定公式（+15）幫「被救助」這件事定性成該加多少信任，AI 沒機會表態；
## trust 也從沒被任何公式當輸入。事件本身照樣要記成事實句給 AI
## （見 agent.gd 覆寫），該不該信任由 AI 自己判斷
func _on_rescued(_hauler: Character) -> void:
	pass

## 由搬運動作（#161 haul）調用，標記此角色正在被搬運。
## 若該角色昏迷，搬運會立即結束昏迷（《99》P-27）——不能只設旗標等下一次
## _update_incapacitation()（每遊戲分鐘才跑一次）才處理：stop_haul() 若搶在
## 下一個 time_changed 之前執行，_is_being_carried 會被重設回 false，
## _end_incapacitation() 永遠不會被呼叫到，角色維持昏迷、也拿不到 health
## 恢復（CodeRabbit review 抓到）
func set_being_carried(is_carried: bool) -> void:
	if is_carried and has_condition(CONDITION_INCAPACITATED):
		_is_being_carried = true
		_end_incapacitation()
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

	global_position = anchors.resolve_for(self, "herb_shop")

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

## 恢復某角色的生理數值到安全水平——_complete_treatment()（昏迷治療完成）與
## revive()（復活成功）共用同一套數字，避免兩處各自維護一份清單日後 drift；
## 目的是避免治療／復活完立刻因為某項生理數值歸零重新觸發 condition
func _restore_stats_to_safe_levels(target: Character) -> void:
	if target.stats == null:
		return
	target.stats.set_value("health", 50.0)		# 設定一個中等恢復量
	target.stats.set_value("injury", 0.0)
	target.stats.set_value("alcohol", 0.0)		# 清除酒精
	target.stats.set_value("satiety", 50.0)	# 恢復飽食度
	target.stats.set_value("hydration", 50.0)	# 恢復水分
	target.stats.set_value("stamina", EXHAUSTION_RECOVERY_THRESHOLD + 1.0)	# 恢復體力，超過力竭恢復門檻
	target.stats.set_value("wakefulness", 50.0)	# 恢復清醒度
	target.stats.set_value("hygiene", 50.0)	# 恢復衛生

## 治療完成：解除所有異常狀態、恢復 health 和 injury、結束昏迷
func _complete_treatment() -> void:
	print_debug("Character %s 藥草鋪治療完成" % character_name)

	# 恢復 health／injury（《99》P-27、P-28）與其他生理數值到安全水平，
	# 避免治療完立即重新觸發 condition
	_restore_stats_to_safe_levels(self)

	# 清除所有異常狀態
	conditions.clear()
	_incapacitation_start_minute = -1
	_treatment_start_minute = -1
	_treatment_location = ""

	print_debug("Character %s 已恢復可行動" % character_name)


# ---- 死亡 ----

## 死亡流程（#379，《規格書09》§1／§2）。這批 issue 只處理
## 「health≤0→昏迷→逾時未獲救治→死亡」這一條觸發路徑；餓死／渴死／老化／
## 瞬間死亡 Flag 等其餘觸發源留給後續 issue，各自準備好 death_cause 文案後
## 呼叫這裡收尾即可，不需要重做狀態機本身。這裡只負責觸發與石化，墓園／安葬
## 見 bury()（#380），corpse_decay 達 100 自動立無名碑見 _erect_unmarked_grave()（#387）
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

## 安葬視覺切換（issue #832，《規格書09》§1）：bury()／_erect_unmarked_grave()
## 安葬完成時 true，revive()／存讀檔還原成活人時 false。取代而非疊加本體貼圖——
## 安葬前後外觀要能一眼分辨（issue #832 的問題本身），已安葬的屍體不再顯示
## 「這個人」，改顯示墓碑。跟 _apply_death_tint() 同一個理由要擋 sprite==null：
## load_save_data() 可能在進場景樹前、sprite 還沒 @onready 就先被呼叫，
## _ready() 會在 sprite 就緒後補呼叫一次（見該函式）
func _apply_grave_visual(buried: bool) -> void:
	if buried:
		if _grave_marker == null:
			_grave_marker = GraveMarker.new()
			_grave_marker.position = Vector2(0, -12)		# 跟 AnimatedSprite2D.offset（character.tscn）同一個值，讓墓碑對齊原本的本體位置
			add_child(_grave_marker)
		if sprite != null:
			sprite.visible = false
	else:
		if _grave_marker != null:
			_grave_marker.queue_free()
			_grave_marker = null
		if sprite != null:
			sprite.visible = true

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
	return anchors.resolve_from_position(get_body_position())

## 屍體腐壞（《規格書09》§3-4）：死亡後每 tick +0.7，clamp 在 [0,100]——
## 100/0.7 除不盡，不 clamp 會在某個 tick 算出 100.1，讓存檔的 CHECK 約束
## 寫入失敗（規格書原文引用 issue #451 CodeRabbit review 踩過的坑）。達到
## 100 且還沒被安葬、還沒立過碑時，交給 _erect_unmarked_grave() 自動立無名碑
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
	# grave_id 仍是 null 才觸發：避免每個超過 100 之後的 tick 都重複嘗試立碑
	# （已安葬的屍體 corpse_decay 理論上不會再被呼叫到這裡，is_buried 這個
	# 條件只是雙重保險）
	if corpse_decay >= 100.0 and not is_buried and grave_id == null:
		_erect_unmarked_grave()


# ---- 安葬（#380／#387，《規格書09》§3-2／§3-4／§6） ----

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

## 6 個墓位相對墓園錨點的偏移座標，3×2 排列（issue #833）。角色影格是 16×16px
## （見 assets/characters），橫向間距 20px、縱向間距 20px 確保相鄰墓位的
## get_pick_rect() 不會重疊；四角墓位離錨點最遠 sqrt(20²+10²)≈22.4px，仍在
## BURY_RANGE／DEATH_LOCATION_RADIUS（32px）內，不影響既有的距離與地點判斷。
## 個數固定對應 CEMETERY_GRAVE_CAPACITY，兩者改動要一起改
const GRAVE_SLOT_OFFSETS: Array[Vector2] = [
	Vector2(-20, -10), Vector2(0, -10), Vector2(20, -10),
	Vector2(-20, 10), Vector2(0, 10), Vector2(20, 10),
]

const BURY_OK := ""
const BURY_TARGET_NOT_FOUND := "TARGET_NOT_FOUND"
const BURY_TARGET_IS_SELF := "TARGET_IS_SELF"
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
	if corpse == self:
		return BURY_TARGET_IS_SELF
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
	_assign_cemetery_grave_slot(corpse)

	# 解除既有搬運關係——is_being_hauled() 在 _decide_velocity() 裡排在
	# petrified 鎖定之前（見該函式註解），is_buried 本身不會讓身體停止跟著
	# 搬運者走，不主動放手的話墓碑會被拖出墓園
	corpse._release_all_haulers()
	corpse._apply_grave_visual(true)

	print_debug("Character %s 安葬了 %s" % [character_name, corpse.character_name])
	return BURY_OK

## 位置是否落在墓園錨點範圍內。跟 _resolve_death_location() 同一種
## place_anchors 查詢模式，但這裡只需要布林值，不需要地點名稱本身
func _is_at_cemetery(position: Vector2) -> bool:
	var tree := get_tree()
	if tree == null:
		return false
	var anchors := tree.get_first_node_in_group("place_anchors")
	if anchors == null:
		return false
	return anchors.resolve_from_position(position) == CEMETERY_PLACE_NAME

## 目前已佔用的墓碑格數：場上所有已安葬角色的數量。不另外維護一個計數器——
## 死亡角色不會被移除節點（見 _die()），直接數 is_buried 的人數就是即時正確
## 答案，跟 hauler_count() 數 _hauled_by 而不是另存一個計數欄位同一種作法
func _cemetery_grave_count() -> int:
	var count := 0
	for node in get_tree().get_nodes_in_group("characters"):
		if node is Character and (node as Character).is_buried:
			count += 1
	return count

## 目前空著的墓位索引，跟 _cemetery_grave_count() 同一種「不另存計數器」寫法——
## 直接掃場上已安葬且 grave_slot_index 已分配的角色，找 GRAVE_SLOT_OFFSETS
## 範圍內第一個沒被占用的索引。呼叫端已經用 _cemetery_grave_count() 檢查過
## 還有空位，理論上不會拿到 -1，這裡仍防呆回傳 -1 避免呼叫端誤用越界索引
func _cemetery_free_grave_slot() -> int:
	var occupied: Array[int] = []
	for node in get_tree().get_nodes_in_group("characters"):
		if node is Character and (node as Character).is_buried:
			occupied.append((node as Character).grave_slot_index)
	for i in GRAVE_SLOT_OFFSETS.size():
		if not occupied.has(i):
			return i
	return -1

## 把 corpse 吸附到一個空的墓位座標（issue #833）：bury()／_erect_unmarked_grave()
## 立碑成功時共用，修掉「所有墓碑疊在同一個錨點，後面的永遠點不到」的問題
## （selection.gd::character_at() 用 pick_rect 中心距離判勝負，座標相同時
## 恆平局，先加入場景樹的永遠贏）。呼叫端負責先確保 corpse 已經在墓園範圍內——
## bury() 靠人為把屍體搬過去，_erect_unmarked_grave() 直接把角色傳送過去（issue
## #856）——這裡只管分配座標；仍保留 _is_at_cemetery() 防呆，理論上呼叫端保證
## 成立不該觸發，避免未來新增呼叫端漏做這一步時默默吸到錯的地方
func _assign_cemetery_grave_slot(corpse: Character) -> void:
	if not _is_at_cemetery(corpse.get_body_position()):
		return
	var slot := _cemetery_free_grave_slot()
	if slot < 0:
		return
	corpse.grave_slot_index = slot
	var anchors := get_tree().get_first_node_in_group("place_anchors")
	if anchors == null:
		return
	corpse.global_position = anchors.resolve(CEMETERY_PLACE_NAME) + GRAVE_SLOT_OFFSETS[slot]

## 屍體腐壞見底、沒人安葬時，引擎自動立「無名碑」（#387，《規格書09》§1／§3-4）：
## 確保每一個死亡都會被記錄。跟 bury() 的差別只在「誰做的」——is_buried 一樣設
## true，但 buried_by 留 null（自動、非人為），is_anonymous 設 true 讓墓碑面板
## 只顯示死亡原因與日期（§4-3）。2026-09-01（issue #856）拍板：無名碑跟人為安葬
## 一樣要搬到墓園，兩條路徑統一收斂到「已安葬（墓園）」——這裡沒有人手動把屍體
## 搬過去，所以直接傳送到墓園錨點，再交給 _assign_cemetery_grave_slot() 吸附到
## 空位。跟 bury() 共用同一組 CEMETERY_GRAVE_CAPACITY 上限（§6 拍板：滿格時
## 兩者都直接失敗）——滿格時這裡直接放棄，corpse_decay 已經是 100、grave_id
## 仍是 null，_update_corpse_decay() 之後每個 tick 都會重試，直到有格子空出來。
## 墓園錨點不存在也走同一套防呆（比照滿格放棄、下個 tick 重試），所以錨點檢查
## 放在動 is_buried／grave_id 之前——那兩個欄位一動，重試條件就永遠不成立了
func _erect_unmarked_grave() -> void:
	if _cemetery_grave_count() >= CEMETERY_GRAVE_CAPACITY:
		return
	var anchors := get_tree().get_first_node_in_group("place_anchors")
	if anchors == null or not anchors.has(CEMETERY_PLACE_NAME):
		return
	is_buried = true
	grave_id = "grave_%s" % character_id
	buried_by = null
	buried_tick = _current_tick()
	is_anonymous = true
	# 跟 bury() 同一個理由：is_buried 不會讓身體停止跟著搬運者走，
	# 傳送到墓園後不放手的話，下一幀就被拖出墓園（見 _decide_velocity()）
	_release_all_haulers()
	global_position = anchors.resolve(CEMETERY_PLACE_NAME)
	_assign_cemetery_grave_slot(self)
	_apply_grave_visual(true)
	print_debug("Character %s 腐壞見底，自動立無名碑" % character_name)


## 解除自己（屍體）身上的全部搬運關係，bury() 與 revive() 共用——兩邊「為什麼
## 要主動放手」的情境理由各自寫在呼叫端，這裡只管怎麼放。搬運者節點可能已被
## queue_free()：沒有 stop_haul() 能幫忙清 _hauled_by，殘留參照只能自己抹掉。
## 不能用 erase()——typed array（Array[Character]）的 erase() 會先跑
## ContainerTypeValidate，DEBUG 下對已釋放實例直接 ERR_FAIL、元素原封不動，
## 殘留參照清不掉（is_being_hauled() 恆 true，復活後角色卡住不能動）；
## 用反向索引走訪＋remove_at() 才確定清得掉，而 stop_haul() 內部的
## _detach_haul() 只移除當前索引，反向走訪安全
func _release_all_haulers() -> void:
	for i in range(_hauled_by.size() - 1, -1, -1):
		# 刻意不標型別：標了 Character 會在指定已釋放實例時再撞一次型別檢查
		var hauler = _hauled_by[i]
		if is_instance_valid(hauler):
			# notify_target=false（2026-08-31 拍板）：被安葬／復活者不是自己掙脫
			# 的，「你掙脫了搬運。」對他是假事實句（原則二）——安葬情境死者已無
			# AI 決策迴圈可消化這句，推了也沒意義；復活情境他實際遭遇的事實由
			# 「你被天神復活了」交代，這裡不再重複定性。搬運者端「你放開了%s。」
			# 是事實句，照常發
			hauler.stop_haul(false)
		else:
			_hauled_by.remove_at(i)

# ---- 復活（issue #386，《規格書09》§8） ----

## 免費復活窗口：死亡後 24 現實小時內，判斷依據是 death_at（真實 UTC 時間戳，
## 不是遊戲內 tick／day）——世界關閉、暫停或調整時間流速都不影響這個判斷
const REVIVE_FREE_WINDOW_HOURS := 24.0

## 付費復活的固定金額（2026-08-27 拍板暫定值，待經濟數值實測後調整，見
## note/規格書/09_死亡屍體與墓園.md §8）：不隨時間遞增、不隨角色地位浮動，
## 依 is_buried 選一般或較高金額，兩者互斥二選一，不疊加
const REVIVE_FEE_NORMAL := 50
const REVIVE_FEE_BURIED := 100

## 跟 BURY_RANGE／HUNT_RANGE 同一種「2 格內」距離門檻
const REVIVE_RANGE := 32.0

const REVIVE_OK := ""
const REVIVE_TARGET_NOT_FOUND := "TARGET_NOT_FOUND"
const REVIVE_TARGET_IS_SELF := "TARGET_IS_SELF"
const REVIVE_TARGET_NOT_DEAD := "TARGET_NOT_DEAD"
const REVIVE_TOO_FAR := "TOO_FAR"
## 跟 Inventory.MONEY_NOT_ENOUGH 用同一個字串——這樣 FAILURE_MESSAGE_KEYS
## 既有的 "NOT_ENOUGH" → FAIL_NOT_ENOUGH 對照可以直接沿用，不用另外註冊一筆
const REVIVE_NOT_ENOUGH_MONEY := "NOT_ENOUGH"

## 復活。self 是掏錢做這件事的天神（Player），corpse 是要復活的屍體——跟
## bury() 同一種寫法：一路檢查，任何一關不過就回失敗碼，全過才真的寫入狀態。
## 24 小時內免費，超過就從 self 的 inventory 扣款——付錢的是操作復活的玩家，
## 不是屍體本人，死人沒有錢包可扣。未下葬與已下葬同一套流程判定，只有超過
## 免費窗口時的金額不同（見《規格書09》§8）
func revive(corpse: Character) -> String:
	if corpse == null or not is_instance_valid(corpse):
		return REVIVE_TARGET_NOT_FOUND
	if corpse == self:
		return REVIVE_TARGET_IS_SELF
	if not corpse.is_dead:
		return REVIVE_TARGET_NOT_DEAD
	if get_body_position().distance_to(corpse.get_body_position()) > REVIVE_RANGE:
		return REVIVE_TOO_FAR

	if not corpse._is_within_free_revival_window():
		var fee := REVIVE_FEE_BURIED if corpse.is_buried else REVIVE_FEE_NORMAL
		if inventory == null or inventory.spend(fee) != Inventory.MONEY_OK:
			return REVIVE_NOT_ENOUGH_MONEY

	corpse._clear_death_state()

	# 解除既有搬運關係——跟 bury() 同一個理由：is_dead 變 false 後移動鎖解除，
	# 但 _decide_velocity() 的 is_being_hauled() 判斷排在最前面且不看 is_dead，
	# 不主動放手的話復活的角色會一直卡在「跟著搬運者走」，AI 決策或玩家自己
	# 的移動意圖完全進不去
	corpse._release_all_haulers()

	# 恢復到安全值，跟 _complete_treatment()（昏迷治療完成）同一套「安全水平」
	# 數字，理由見那邊：避免復活完立刻又因為某項生理數值歸零重新觸發 condition
	_restore_stats_to_safe_levels(corpse)

	# 事實句只有 Agent 有 AI 決策迴圈可以注入——Player 沒有 _push_daily_event()，
	# 跟 haul()／stop_haul() 通知搬運事件同一種 is_in_group("agents") 判斷寫法
	if corpse.is_in_group("agents"):
		(corpse as Agent)._push_daily_event("你被天神復活了，你知道是天神把你救回來的。")

	print_debug("Character %s 被 %s 復活了" % [corpse.character_name, character_name])
	return REVIVE_OK

## death_at（真實 UTC 時間戳）距現在是否在 24 小時內。death_at 理論上一定
## 有值（is_dead=true 時 _die()／load_save_data() 都會寫入），空字串防呆視為
## 已逾期——沒有時間戳就沒辦法判斷「免費」，寧可保守收費也不要誤放行
func _is_within_free_revival_window() -> bool:
	if death_at.is_empty():
		return false
	var death_unix := Time.get_unix_time_from_datetime_string(death_at.trim_suffix("Z"))
	var now_unix := Time.get_unix_time_from_system()
	return now_unix - death_unix <= REVIVE_FREE_WINDOW_HOURS * 3600.0

## 死亡欄位與外觀全部清空，回到「活人」狀態——load_save_data() 讀到 is_dead=false
## 存檔、以及 revive() 復活成功時共用同一套清理，避免兩處各自維護一份一樣的
## 欄位清單
func _clear_death_state() -> void:
	conditions = conditions.filter(func(c): return c["type"] != CONDITION_PETRIFIED)
	_apply_death_tint(false)
	_apply_grave_visual(false)
	is_dead = false
	death_tick = -1
	death_day = -1
	death_at = ""
	death_cause = ""
	death_location_id = ""
	last_words = null
	corpse_decay = 0.0
	is_buried = false
	grave_id = null
	grave_slot_index = -1
	buried_by = null
	buried_tick = -1
	is_anonymous = false
# ---- 打獵 ----

const HUNT_RANGE := 32.0		# 跟 ATTACK_RANGE／BURY_RANGE 同一種距離門檻，2 格

const HUNT_OK := ""
const HUNT_TARGET_NOT_FOUND := "TARGET_NOT_FOUND"
const HUNT_TOO_FAR := "TOO_FAR"
const HUNT_NO_INVENTORY := "NO_INVENTORY"
const HUNT_NO_SPACE := "NO_SPACE"

## 打獵（issue #573）。跟 attack()／bury() 同一種寫法：一路檢查，任何一關
## 不過就回失敗碼，全過才真的寫入狀態——但成不成功這件事本身**不是**這裡決定的：
## hunt_small／hunt_large 在《01-2》SUCCESS_PARAMS 表上，擲骰已經在
## Agent.resolve() 那關做完，這個函式只在骰過「成功」之後才會被呼叫，
## 這裡的檢查只是防呆（動物在擲骰之後、真正執行之前的這段空窗期跑走／被
## 別人先獵走），不是機率判定
func hunt(animal: Animal) -> String:
	if animal == null or not is_instance_valid(animal) or animal.is_queued_for_deletion():
		return HUNT_TARGET_NOT_FOUND
	if get_body_position().distance_to(animal.global_position) > HUNT_RANGE:
		return HUNT_TOO_FAR
	if inventory == null:
		return HUNT_NO_INVENTORY

	var item_id: String = animal.game_type
	var add_reason := inventory.add_item(item_id)
	if add_reason != Inventory.ADD_OK:
		return HUNT_NO_SPACE

	animal.remove_from_world()
	print_debug("Character %s 獵到了一隻 %s" % [character_name, item_id])
	return HUNT_OK


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
	# 已經存在的對話，沒擋之後別人再對死屍發起新對話——死屍不該再被搭話。
	# is_offline_asleep 同理：入眠中對話照開的話，下一輪 next_line() 的「…」
	# 泡泡會蓋掉「被天神召喚中」的入眠指示，AI 對話請求也照發
	return not _working and not is_dead and not is_offline_asleep

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

func exit_conversation(_reason: String = "") -> void:
	_conversation = null
	# 對話不管用哪種原因結束（正常收尾／被打斷／走遠）都會呼叫到這裡，是
	# 唯一保證「這場對話真的結束了」的單一收斂點。agent.gd::next_line() 的
	# 「思考中」提示改用 bubble.hold() 撐住整個等待期間，沒有 say() 排隊顯示
	# 那種自動消失的時間兜底——LLM 還沒回應、玩家就走遠的話，沒人會去收這顆
	# 泡泡。在這裡統一 release_hold() 收掉，release_hold() 沒在 hold 時本來就是
	# no-op，不用先判斷有沒有真的在 hold
	if bubble != null:
		bubble.release_hold()

# 自己主動離開對話
func leave_conversation() -> void:
	if _conversation != null:
		_conversation.interrupt()

## 進入入眠（issue #827）：暫停 Stats 衰減、用持續顯示的泡泡標示「被天神
## 召喚中」（不是一般台詞排隊顯示，靠 bubble.hold() 撐住，直到 exit_offline_
## sleep() 才收掉，跟 next_line() 的「思考中」泡泡同一種持續提示手法）。
## reason 目前只用來記錄／除錯（例如 "model_unavailable"、"human_afk"），
## 不影響行為——§4.5／§6.4 兩種觸發情境對外表現完全一樣，呼叫端自己決定
## 什麼時候該叫這個，這裡不做任何觸發判斷
func enter_offline_sleep(reason: String) -> void:
	if is_offline_asleep:
		return
	is_offline_asleep = true
	_offline_asleep_since_unix = Time.get_unix_time_from_system()
	# 比照 _die() 先例用 force_interrupt() 一次收尾：入眠當下可能正在移動、
	# 對話中或工作中——對話不收掉的話 conversation.gd 會繼續要台詞，下一輪
	# next_line() 的「…」泡泡會蓋掉入眠指示、AI 對話請求也照發。旗標先設
	# true 再收尾，_on_action_interrupted()／_reevaluate() 的入眠守衛才接得住，
	# 不會反過來對入眠者問出新決策（_is_movement_locked() 已涵蓋
	# is_offline_asleep，force_interrupt() 裡的 stop_moving() 收掉當下已在
	# 移動中的那一段，跟 _start_incapacitation() 同一個理由）
	force_interrupt()
	if stats != null:
		stats.all_drift_paused = true
	if bubble != null:
		bubble.hold(L10n.t("STATUS_OFFLINE_ASLEEP"))
	print_debug("Character %s: 進入入眠狀態（%s）" % [character_name, reason])

## 恢復。呼叫端負責判斷「已經恢復連線／真人回來了」才呼叫，這裡只負責收尾——
## 跟 enter_offline_sleep() 一樣不做任何判斷，純粹執行
func exit_offline_sleep() -> void:
	if not is_offline_asleep:
		return
	is_offline_asleep = false
	_offline_asleep_since_unix = 0
	if stats != null:
		stats.all_drift_paused = false
	if bubble != null:
		bubble.release_hold()

## 現實 72 小時未恢復是否已達踢出門檻。只回報，不執行任何踢出動作——見
## OFFLINE_KICK_THRESHOLD_SEC 的說明
func is_offline_kick_eligible() -> bool:
	if not is_offline_asleep:
		return false
	return Time.get_unix_time_from_system() - _offline_asleep_since_unix >= OFFLINE_KICK_THRESHOLD_SEC

## interrupt=true 立刻蓋掉正在顯示/排隊中的內容（LLM 回應等待中的「…」要被
## 真正的台詞立刻換掉，不能排在它後面等它自己的顯示時間跑完）。
## 預設 false 維持原本「不打斷正在講的話」的排隊語意，其餘呼叫端不用改
##
## 廣播 speech_heard 不分呼叫來源——一般聊天輸入框（chat_input.gd）跟
## talk_to() 正式對話（conversation.gd）都算「說了一句話」，《07》§3
## 定義的「聽覺（一般說話）3 格」是物理上聽不聽得到，不分是哪種介面講出來的
## （issue #669）。
##
## broadcast=false：內部系統 fallback 泡泡（`!?`／`！` 這類感測不到 LLM
## 回應時的寫死反應）不是「這個角色真的說了什麼」，不該算進《07》§3 的
## 「聽得到的對話」——放行的話，鄰近的 LLM 角色會把這句 `!?` 當成一句話
## 排進自己的事實句佇列、觸發一次決策，決策若同樣問不到結果又冒出自己的
## `!?`，在 3 格範圍內連環擴散成一波決策請求風暴（CodeRabbit review 抓到，
## PR #674）。所有這類 fallback 泡泡呼叫端都要傳 false，見 agent.gd／player.gd
## 的 _on_noise_heard()／_on_speech_heard()／_react_to_spotted_fallback()
func say(line: String, interrupt: bool = false, broadcast: bool = true) -> void:
	if bubble == null:
		return
	if interrupt:
		bubble.clear()
	bubble.say(line)
	spoke.emit(line)
	if broadcast:
		_broadcast_speech(line)

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
##
## interrupt=true：同一句失敗訊息沒有「排隊播完」的價值，玩家只在意
## 「剛剛那下有沒有反應」，連續觸發時最新一次的判定結果直接蓋掉舊的
## 排隊訊息，不會像 bubble.gd::say() 預設那樣逐句累積（issue #773）
func report_action_failure(action_label: String, reason: String) -> void:
	push_warning("%s: %s 失敗（%s）" % [character_name, action_label, reason])

	var key: String = FAILURE_MESSAGE_KEYS.get(reason, "")
	say(L10n.t(key) if not key.is_empty() else reason, true)

## 這個角色對話中的下一句話由誰產生、內容是什麼。基底不知道答案——
## 本機玩家要等打字（見 player.gd），本機 Agent 要打 AIService（見 agent.gd），
## 兩者由子類別覆寫。conversation.gd 只問「輪到你了，下一句是什麼」，不問
## 「你是誰」，之後要接遠端角色（伺服器轉發）也只是再多一個覆寫，會話層不用改。
##
## 回傳 {"ok": bool, "engage": bool, "line": String, "end": bool}：ok=false 代表
## 這一輪要不到台詞（LLM 停用/逾時/驗證失敗），呼叫端（conversation.gd）要轉去
## fallback，不是把空字串當成正常台詞講出去。engage 只在第一輪（turns 空陣列，
## 被搭話的那一方）才可能是 false——對象選擇不理會這次搭話，line/end 這時沒有
## 內容可看，其餘輪次 engage 恆為 true（issue #630）
func next_line(_listener: Character, _turns: Array[Dictionary], _max_turns: int) -> Dictionary:
	push_error("%s: next_line() 沒有被子類別覆寫" % character_name)
	return {"ok": false}

## 聽者的對稱退出點（issue #691，《99》P-31）。基底預設一律想繼續聽——
## Player 沒有 LLM 可問，要不要退出交給玩家自己走遠（Conversation.MAX_DISTANCE）
## 或站著不理，不需要引擎額外問一次。只有 Agent 覆寫成真正的 LLM 決策
func wants_to_continue(_speaker: Character, _turns: Array[Dictionary]) -> bool:
	return true

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

## 廣播半徑（像素），3 格——《07》§3 定案「聽覺（一般說話）3 格」，跟
## NOISE_RADIUS（shout／make_noise 的 8 格）是刻意分開的兩個數字
const SPEECH_HEARD_RADIUS := 48.0

## 對外廣播「這裡說了一句話」，範圍內每個角色都會收到 speech_heard 訊號，
## 帶實際講的內容——跟 make_noise() 只給「有聲音發生」這個事實不同，
## 一般說話《07》§3 定義的本來就是「聽得到的對話」，內容是客觀事實（誰講了
## 什麼字），要不要反應、反應是什麼由收到的那一方自己決定，感測/反應分離
## 的理由跟 make_noise() 一樣（issue #669，見 [[聽覺感測]]）
func _broadcast_speech(line: String) -> void:
	for other in get_tree().get_nodes_in_group("characters"):
		if other == self:
			continue
		if get_body_position().distance_to(other.get_body_position()) <= SPEECH_HEARD_RADIUS:
			other.speech_heard.emit(self, line)


# ---- 工作 ----

var _working := false

## 這次工作已經過了幾個遊戲分鐘——跟 work_progress 的進度條算的是同一個數字
## （_run_work() 每過一個 GameClock.time_changed 就加一），只是這裡另外存一份
## 給 get_work_minutes_remaining() 讀（issue #663）。注意：合併 #725 之後工作
## 站的 ETA（get_wait_minutes()／飄字）改用工作站自己的 per-slot 計數器，這個
## 方法目前沒有呼叫端，留作角色端的同一件事實視圖
var _work_elapsed_minutes := 0

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
	_work_elapsed_minutes = 0
	stop_moving()
	if work_progress != null:
		work_progress.show_progress(0.0)
	_run_work(workstation, _work_session_id)
	return WORK_OK

## 這次工作還要幾分鐘才會做滿——沒在工作回 0。目前沒有呼叫端（工作站 ETA
## 在 #725 多名額版改由 per-slot 計數器計算），留作角色端的事實視圖（issue #663）
func get_work_minutes_remaining() -> int:
	if not _working:
		return 0
	return maxi(0, WORK_DURATION_MINUTES - _work_elapsed_minutes)

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

		_work_elapsed_minutes = i + 1
		if work_progress != null:
			work_progress.show_progress(float(i + 1) / float(WORK_DURATION_MINUTES))

	_end_work(workstation)
	if inventory != null:
		inventory.add_money(WORK_PAYMENT)
		if money_popup != null:
			money_popup.show_change(WORK_PAYMENT)

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
## place 是地點名（"tavern"／"herb_shop"），不是機台節點——issue #572 拿掉了
## 販賣機實體道具，商店綁在地點本身，見 world/shop.gd
func buy_from(place: String, item_id: String) -> String:
	if not Shop.has_shop(place):
		return BUY_TARGET_NOT_FOUND
	var anchors := get_tree().get_first_node_in_group("place_anchors")
	if anchors == null or not anchors.has(place):
		return BUY_TARGET_NOT_FOUND
	if get_body_position().distance_to(anchors.resolve(place)) > BUY_RANGE:
		return BUY_TOO_FAR
	if inventory == null:
		return BUY_NO_INVENTORY

	var price := Shop.get_price(place, item_id)
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


# ---- 採集 ----

# 在藥草叢採集一份藥草（#574）：跟 buy_from() 一樣只管「把東西塞進背包」——
# 地點對不對、擲不擲得過成功率是 resolve() 的事（見 agent.gd 的 SUCCESS_PARAMS／
# _roll_success()），這裡假設呼叫端已經確認過那兩件事才會呼叫。add_item()
# 內部已處理堆疊規則，回傳值直接轉傳（ADD_OK 剛好也是空字串，跟 GATHER_OK
# 同一個值，不用另外映射）。hygiene 扣點（《99》P-65）只在真的採到東西時扣——
# 背包滿了採集失敗，不該連累角色平白變髒
func gather() -> String:
	if inventory == null:
		return GATHER_NO_INVENTORY
	if stats == null:
		return GATHER_NO_STATS
	var reason := inventory.add_item("herb")
	if reason == Inventory.ADD_OK:
		_apply_action_dirty("gather")
	return reason

# 依 Stats.ACTION_DIRTY 表，把某個離散動作對應的扣點一次套用到 stats 上。
# 跟 agent.gd 的 ACTION_RECOVERY／_apply_action_recovery() 是同一張表的反面
# ——那邊是「持續狀態每遊戲分鐘回一點」，這裡是「動作執行成功時扣一次」，
# 放在 Character 而不是 Agent：gather()／perform() 兩個呼叫端都在這個基底，
# Player 也要能觸發，不能只讓 Agent 看得到
func _apply_action_dirty(action: String) -> void:
	if stats == null:
		return
	var dirty_list: Array = Stats.ACTION_DIRTY.get(action, [])
	for dirty in dirty_list:
		stats.add(dirty["stat"], dirty["amount"])


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


# ---- 表演 ----

## 目前是否正在表演（#575）。跟 is_working() 同一種「多分鐘長動作進行中」
## 旗標，Vision 偵測到的路人靠這個判斷要不要把「有人在表演」餵給自己的 AI
var _performing := false
var _perform_session_id := 0

func is_performing() -> bool:
	return _performing

## 手持 instrument 就地表演，任意地點皆可（#575 拍板：不像 work_at() 要先有
## 工作站）。跟 eat()／drink() 一樣先做前置檢查、才有副作用；但表演不是瞬間
## 完成，是跟 work_at() 同一種「立刻回傳 OK、實際過程交給協程跑」的長動作
## ——duration 夠長，範圍內的路人才有機會被 Vision 偵測到、問過自己的 AI
## 要不要打賞。hygiene 扣點（《99》P-65，`Stats.ACTION_DIRTY`）是一次性
## （每次「開始表演」扣一次），不是既有 drift 機制的量級，這裡刻意不套用
## Stats 既有的每分鐘漂移模式
func perform() -> String:
	if inventory == null:
		return PERFORM_NO_INVENTORY
	if not inventory.has_item("instrument"):
		return PERFORM_NO_INSTRUMENT
	if stats == null:
		return PERFORM_NO_STATS
	if is_in_conversation() or _working or _performing or _is_movement_locked():
		return PERFORM_BUSY

	_apply_action_dirty("perform")
	_performing = true
	stop_moving()
	_run_perform(_perform_session_id)
	return PERFORM_OK

## 表演協程本體：跟 _run_work() 同一種「逐遊戲分鐘等 GameClock.time_changed」
## 寫法，用 session_id 擋掉中途被 force_interrupt() 提前結束後、舊協程醒來
## 時又重複收尾一次（同一招見 _run_work() 的 session_id 比對）
func _run_perform(session_id: int) -> void:
	for i in PERFORM_DURATION_MINUTES:
		await GameClock.time_changed
		if session_id != _perform_session_id:
			return
	_end_perform(true)

## completed：跑滿 PERFORM_DURATION_MINUTES 自然結束傳 true，force_interrupt()
## 中途打斷傳 false（CodeRabbit review 抓到：兩種原本都會落進同一個
## _on_perform_finished()，被打斷的表演會被誤記成正常結束）
func _end_perform(completed: bool) -> void:
	_performing = false
	_perform_session_id += 1
	_on_perform_finished(completed)

## 表演結束的收尾鉤子，基底 no-op——跟 _on_work_finished() 同一個理由，Player
## 沒有行程可言，只有 Agent 需要清目前任務並重新問決策
func _on_perform_finished(_completed: bool) -> void:
	pass

# ---- 使用背包目前選取的道具 ----

# 玩家按下 use_item 鍵時，使用快捷欄目前選取格裡的東西（#611）。跟 eat()／
# drink() 的差異：那兩個是「自動找背包裡第一個符合分類的物品」，這裡固定用
# 玩家自己選的那一格——選到的不是食物/飲品就直接失敗，不會幫忙跳去找別的。
# 是不是消耗品交給 inventory.use_item() 的 is_consumable 參數判斷，這裡只
# 負責把分類轉成布林值；其餘原因碼直接轉傳，見上面 USE_ITEM_* 常數的說明
func use_selected_item() -> String:
	if is_dead:
		return USE_ITEM_IS_DEAD
	if inventory == null:
		return USE_ITEM_NO_INVENTORY

	var slot := inventory.get_slot(inventory.get_selected_index())
	if slot.is_empty():
		return USE_ITEM_NO_SELECTION
	if stats == null:
		return USE_ITEM_NO_STATS

	var item_id: String = slot["item_id"]
	var item := ItemDatabase.get_item(item_id)
	var category: String = item.get("category", "")
	var is_consumable := category == "food" or category == "drink"

	var use_reason := inventory.use_item(item_id, stats, item, is_consumable)
	if use_reason != Inventory.USE_OK:
		return use_reason

	apply_personality_delta(item.get("personality_delta", {}))
	return USE_ITEM_OK


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


func attack(other: Character) -> String:
	# 死屍不能發起攻擊（跟 talk_to()／use_selected_item() 擋自己這側同一種
	# 修法）：is_dead 之後沒有任何地方會停用玩家的 _unhandled_input()，死屍
	# 照樣能右鍵開打。只擋攻擊者這一側，攻擊死屍（other.is_dead）的既有行為不變
	if is_dead:
		return ATTACK_IS_DEAD
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
			# 立即同步昏迷判定，跟上面 bleeding 同一個理由（#821）：不等
			# _update_conditions() 的下一次 tick（最長約 10 秒空窗期）才發現
			# health 已經歸零。判定條件跟 _update_conditions() 完全一致
			if other.stats.get_value("health") <= 0.0 and not other.has_condition(CONDITION_INCAPACITATED):
				other._start_incapacitation()
	# 先記事實句再中斷（issue #851）：force_interrupt() 會觸發 Agent 立即問一次
	# 新決策（_on_action_interrupted()），那次決策組信封是同步進行、不等
	# _on_attacked()——順序反過來的話，事實句進了 _pending_fact_lines 也趕不上
	# 那次立即決策，AI 完全不知道自己剛被打。other._on_attacked() 只是記事實句，
	# 不依賴 force_interrupt() 做過的任何清理
	other._on_attacked(self)
	other.force_interrupt()
	return ATTACK_OK

## 被攻擊的收尾鉤子。基底只是掛點——Player 沒有記憶系統可寫，只有 Agent
## 需要把這件事記成事實句給下次決策／反思用（見 agent.gd 覆寫）。
##
## 刻意不在這裡對關係做任何定性（2026-08-24 拿掉固定公式，#601 拿掉 trust
## 欄位本身，見全專案盤點的原則二／三審查）：引擎用固定公式幫「被攻擊」這件事
## 定性成「值 -50 信任」，AI 完全沒機會表態，跟《00》原則二「引擎只給事件，
## 不給情緒」相反；trust 也從沒被任何公式當輸入（只餵給 LLM 讀），不符合《00》
## 原則三的留存門檻，因此整條移除。事件本身照樣完整記成事實句給 AI
## （見 agent.gd 覆寫），該不該信任由 AI 自己判斷、記在自己的記憶系統裡
func _on_attacked(attacker: Character) -> void:
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
	if _performing:
		_end_perform(false)
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
		"performing": is_performing(),
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

	# 欄名跟 relationships.gd 的 record 一致（met_count），不要在這裡改名——
	# 讀過 relationships.gd 的人會在 snapshot 上找不到。用純量 accessor
	# 不用 get_record()，後者每筆都 duplicate(true) 深拷一份只為了讀一個數字
	if relationships != null:
		var known := relationships.known_ids()
		if not known.is_empty():
			var relations := {}
			for other_id in known:
				relations[other_id] = {
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
		"home_location_id": home_location_id,
		"age": age,
		"incapacitation_start_minute": _incapacitation_start_minute,
		"is_being_carried": _is_being_carried,
		"treatment_start_minute": _treatment_start_minute,
		"treatment_location": _treatment_location,
		# 睡前反思（#349）會用 personality_delta 累積調整這 10 項，跨天累積的
		# 性格漂移不該因為重開就被重置回建角當下的原始值——跟 today_plan「跨天
		# 承諾不該憑空消失」同一個道理（見 note/技術/存檔.md）
		"personality": personality.duplicate(true),
		# 讀檔後保留角色存檔當下的情緒殘留，不要每次重開都歸零成 neutral
		# （issue #688，2026-08-30 拍板）：長期記憶（L2/L4）本來就會存，角色
		# 讀檔後記得起因事件，卻沒有對應的情緒表現，比 current_goal 消失更
		# 容易讓人覺得「斷片」——見 note/技術/存檔.md「決策情境欄位」
		"emotion": emotion.duplicate(true),
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
		"grave_slot_index": grave_slot_index,
		"buried_by": buried_by,
		"buried_tick": buried_tick,
		"is_anonymous": is_anonymous,
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
	# 缺席（issue #391 前的舊存檔）沿用目前值，不強制清空——讀檔當下
	# _ensure_npc_record() 若發現這裡是空字串，本來就會重新跑 round-robin 分配
	var loaded_home: Variant = data.get("home_location_id", home_location_id)
	home_location_id = loaded_home if loaded_home is String else home_location_id
	# 缺席（issue #837 前的舊存檔）沿用目前值——大多數情況下這是 spawn_character()
	# 剛從角色庫寫入的真實年齡，比灌回 -1「未知」更正確；型別不對／範圍不對
	# （只接受 -1 或 16–70，見《規格書01》§1-1）同理不強制清空，沿用目前值
	# （CodeRabbit review 抓到，PR #845）
	var loaded_age: Variant = data.get("age", age)
	if loaded_age is int or loaded_age is float:
		# JsonSaveService 走 JSON.parse_string()，JSON 數字一律回 float（#862
		# 同型陷阱）——只驗 is int 會讓存檔年齡永不生效；int() 轉型後再驗範圍
		var age_value: int = int(loaded_age)
		age = age_value if age_value == -1 or (age_value >= 16 and age_value <= 70) else age

	# 還原昏迷與治療狀態（用 -1 作為哨兵值表示未進入該狀態，其餘合法值是
	# GameClock.hour*60+GameClock.minute 那個 [0, 1439] 範圍——只驗證 is int
	# 不夠，-2 這種值會通過型別檢查、又不等於 -1，被當成合法的昏迷/治療
	# 時間點還原，角色可能被錯誤鎖定或直接進入治療流程）
	# JsonSaveService 走 JSON.parse_string()，JSON 數字一律回 float（同上面
	# age 的 #862 同型陷阱，issue #861）——只驗 is int 會讓存檔的昏迷/治療
	# 時間點永不生效；int() 轉型後再驗範圍
	var loaded_incap: Variant = data.get("incapacitation_start_minute", _incapacitation_start_minute)
	if loaded_incap is int or loaded_incap is float:
		var incap_value: int = int(loaded_incap)
		_incapacitation_start_minute = incap_value if incap_value == -1 or (incap_value >= 0 and incap_value < 1440) else _incapacitation_start_minute
	var loaded_carried: Variant = data.get("is_being_carried", _is_being_carried)
	_is_being_carried = loaded_carried if loaded_carried is bool else _is_being_carried
	var loaded_treat_start: Variant = data.get("treatment_start_minute", _treatment_start_minute)
	if loaded_treat_start is int or loaded_treat_start is float:
		var treat_start_value: int = int(loaded_treat_start)
		_treatment_start_minute = treat_start_value if treat_start_value == -1 or (treat_start_value >= 0 and treat_start_value < 1440) else _treatment_start_minute
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
		# is int or is float：JsonSaveService（目前生效中的 SaveService，見
		# project.godot autoload）走 JSON.parse_string() 讀檔，所有數字一律回傳
		# TYPE_FLOAT（沒有 int/float 之分，同一個理由見 game_manager.gd
		# apply_world_save_data() 讀 hour/minute 那段註解）。這裡原本只接受
		# is int，讀回來的 float 值直接被判定成「型別不對」，整個 fallback 回
		# 節點剛生成時的預設值（death_tick=-1／death_day=-1）——不是保留存檔前
		# 的值，因為讀檔當下節點本來就是全新建立的，墓碑面板因此顯示「死於
		# 第 -1 天」。跟下面 corpse_decay 用同一套 is int or is float 判斷、
		# int() 轉型（issue #857）
		var loaded_tick: Variant = data.get("death_tick", death_tick)
		death_tick = int(loaded_tick) if (loaded_tick is int or loaded_tick is float) else death_tick
		var loaded_day: Variant = data.get("death_day", death_day)
		death_day = int(loaded_day) if (loaded_day is int or loaded_day is float) else death_day
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
		# 缺席預設 false／null／null／-1，不是沿用目前值，跟 is_dead 同一個理由
		# （CodeRabbit review 抓到）：is_buried／grave_id 沿用目前值的話，跟這裡
		# 剛修過的 buried_by／buried_tick（缺席即歸零）放在一起會兜出矛盾狀態——
		# 同一節點先載入已安葬存檔、再載入一份沒有安葬欄位的舊死亡存檔時，
		# is_buried 會留 true、grave_id 留舊值，但 buried_by／buried_tick 已經是
		# null／-1，變成「安葬了但沒人知道誰安葬的、何時安葬的」
		var loaded_buried: Variant = data.get("is_buried", false)
		is_buried = loaded_buried if loaded_buried is bool else false
		var loaded_grave: Variant = data.get("grave_id", null)
		grave_id = loaded_grave if (loaded_grave == null or loaded_grave is String) else null
		# 缺席預設 -1（未分配），不是沿用目前值，跟 is_buried／grave_id 同一個理由——
		# 這是這則 issue 新增的欄位，既有存檔都沒有這個 key
		var loaded_slot: Variant = data.get("grave_slot_index", -1)
		# 同 death_tick／death_day（issue #857）：JSON 讀回來的整數一律是 float
		# （JsonSaveService 走 JSON.parse_string()），is int 判斷會整條 fallback
		# 到 -1，墓位索引讀檔後遺失、下次安葬疊墓。比照同一套 is int or is float
		# + int() 轉型
		var slot_is_number := loaded_slot is int or loaded_slot is float
		grave_slot_index = int(loaded_slot) if (slot_is_number and int(loaded_slot) >= -1 and int(loaded_slot) < GRAVE_SLOT_OFFSETS.size()) else -1
		var loaded_buried_by: Variant = data.get("buried_by", null)
		buried_by = loaded_buried_by if (loaded_buried_by == null or (loaded_buried_by is String and not loaded_buried_by.is_empty())) else null
		# 同上 death_tick／death_day：JSON 讀回來的整數是 float，is int 判斷
		# 會整條 fallback 到 -1（issue #857）
		var loaded_buried_tick: Variant = data.get("buried_tick", -1)
		var buried_tick_is_number := loaded_buried_tick is int or loaded_buried_tick is float
		buried_tick = int(loaded_buried_tick) if (buried_tick_is_number and (int(loaded_buried_tick) == -1 or int(loaded_buried_tick) >= 0)) else -1
		var loaded_anonymous: Variant = data.get("is_anonymous", false)
		is_anonymous = loaded_anonymous if loaded_anonymous is bool else false

		# 治療欄位跟 _die() 同一個理由清掉（CodeRabbit review 抓到）：上面幾行
		# 只還原死亡欄位本身，沒清掉治療欄位——若這份存檔或載入前的角色狀態剛好
		# 帶著沒清乾淨的 treatment_start_minute，_update_treatment() 沒有 is_dead
		# 判斷，60 分鐘後 _complete_treatment() 會把 petrified 一起清掉、救活死屍
		_treatment_start_minute = -1
		_treatment_location = ""

		conditions.clear()
		conditions.append({"type": CONDITION_PETRIFIED, "turns_left": -1})
		_apply_death_tint(true)
		_apply_grave_visual(is_buried)
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
		# 會出現 is_dead=false 但外觀／conditions 仍是死屍的矛盾狀態。跟 revive()
		# 共用同一套清理（見該函式），存讀檔與真的復活是同一件事：把死亡欄位
		# 與外觀恢復成活人狀態
		_clear_death_state()

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

	# 情緒殘留還原（issue #688，2026-08-30 拍板）：直接套用存檔當下的
	# duration_left，不透過 set_emotion() 重算——那會用「現在」的
	# stability／grudge 重新推算一個全新的滿額 duration，蓋掉存檔當下
	# 其實已經倒數剩沒多少的真實殘留值。缺欄位（#688 之前的舊存檔）沿用
	# 目前值，不強制歸零——跟 personality 同一個理由，不是每次讀檔都該
	# 清空的東西
	if data.has("emotion") and data["emotion"] is Dictionary:
		var loaded_emotion: Dictionary = data["emotion"]
		if _is_valid_emotion_data(loaded_emotion):
			emotion = loaded_emotion.duplicate(true)
			# JsonSaveService 走 JSON.parse_string()，JSON 數字一律回 float
			# （issue #861，同 #862 型別陷阱）；intensity／duration_left 是
			# 離散單位（見 269 行），型別檢查通過後這裡轉型成 int，避免
			# emotion 字典裡殘留 float 值
			emotion["intensity"] = int(emotion["intensity"])
			emotion["duration_left"] = int(emotion["duration_left"])
		else:
			push_error("Character %s: 存檔的 emotion 資料結構不合法，保留目前情緒" % character_name)

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

# 存檔的 emotion 必須恰好是這 4 項欄位、型別與值域都合法才准覆寫目前情緒——
# 跟 _is_valid_personality_data() 同一種「寧可整包不套用，也不要讓半殘資料
# 靜默生效」的態度（issue #688）
const _EMOTION_FIELDS := ["type", "intensity", "cause_event_id", "duration_left"]

func _is_valid_emotion_data(loaded: Dictionary) -> bool:
	if loaded.size() != _EMOTION_FIELDS.size():
		return false
	for key in _EMOTION_FIELDS:
		if not loaded.has(key):
			return false
	if not (loaded["type"] is String) or not EMOTION_TYPES.has(loaded["type"]):
		return false
	if not (loaded["intensity"] is int or loaded["intensity"] is float) or loaded["intensity"] < 0 or loaded["intensity"] > 100:
		return false
	if not (loaded["cause_event_id"] is String):
		return false
	if not (loaded["duration_left"] is int or loaded["duration_left"] is float) or loaded["duration_left"] < 0 or loaded["duration_left"] > EMOTION_DURATION_MAX:
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

## 給 player.gd 用：搬運中按 E 要嘗試安葬／放下，需要知道搬的是誰
## （issue #826）。NPC 走 _pursue_bury_task()，從 LLM 給的 target 名字另外
## 查角色，不透過這個搬運中狀態，不需要這個 getter
func get_hauling_target() -> Character:
	return _hauling_target

func effective_speed() -> float:
	return SPEED * _speed_multiplier

func start_haul(target: Character) -> String:
	if target == null:
		return HAUL_TARGET_NOT_FOUND
	if target == self:
		return HAUL_TARGET_IS_SELF
	if target.is_buried:
		return HAUL_TARGET_ALREADY_BURIED
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

func stop_haul(notify_target: bool = true) -> void:
	if _hauling_target != null:
		var target := _hauling_target
		target._detach_haul(self)
		# 雙人搬運時（《99》P-27 #8），其中一人放手不該讓另一人還在搬的目標被標記成沒人搬
		if not target.is_being_hauled():
			target.set_being_carried(false)		# #271: 通知昏迷機制
			if is_in_group("agents"):
				(self as Agent)._push_daily_event("你放開了%s。" % target.character_name, [target.character_id])
			# notify_target=false：放手不是被搬運者自己掙脫時（引擎側釋放，
			# 被搬運者並未掙脫），應傳 false——「你掙脫了搬運。」對當事人是
			# 假事實句，違反原則二（引擎只給事件，不給情緒／不編造當事人沒做
			# 的動作），真正的遭遇由觸發動作的一方自行交代，這裡保持沉默。
			# 其餘呼叫端是否也該統一傳 false，見 issue #779。
			# 搬運者自己的「你放開了%s。」是事實句，維持照發
			if notify_target and target.is_in_group("agents"):
				(target as Agent)._push_daily_event("你掙脫了搬運。")
		_hauling_target = null
	_speed_multiplier = 1.0

func _attach_haul(hauler: Character) -> void:
	if not _hauled_by.has(hauler):
		_hauled_by.append(hauler)

	# 這位是第一位搬運者已經觸發過 _end_incapacitation() 之後才加入的第二位——
	# set_being_carried(true) 的 has_condition(CONDITION_INCAPACITATED) 判斷這時
	# 已經是 false，不會再幫他跑一次救助流程，這裡補發他這次事件該記的事實句
	# （見 _on_rescued()）。_rescued_haulers 非空才代表「這次真的發生過救助」，
	# 不是隨便一次沒昏迷的搬運（例如搬天神之石這種一般 carryable 物件）也誤記
	if not _rescued_haulers.is_empty() and not _rescued_haulers.has(hauler):
		_on_rescued(hauler)
		_rescued_haulers.append(hauler)

func _detach_haul(hauler: Character) -> void:
	_hauled_by.erase(hauler)
	# 最後一位搬運者放手時清掉這次事件的名單——不清的話，A 救到人放手後，
	# 之後任何人（B）再搬運同一個已經不昏迷的角色，_attach_haul() 會誤判
	# 「這次事件還在補發」而多記一次救助事實句（CodeRabbit review 抓到）
	if _hauled_by.is_empty():
		_rescued_haulers.clear()

## 離開場景樹前放掉搬運關係的兩個方向——GameManager 可以直接對角色呼叫
## queue_free()，不經過 stop_haul()：
## 1. 自己正在搬別人：stop_haul() 處理，會通知對方的 _hauled_by 移除自己
## 2. 自己正被別人搬：對方的 _hauling_target 還指著即將消失的 self，
##    對方之後呼叫 stop_haul() 會對已釋放的目標呼叫 _detach_haul()；
##    _hauled_by[0] 剛好是自己的話，_follow_hauler() 也會繼續朝著已釋放
##    的目標跟隨。逐一通知每個搬運者放手，再清空自己這邊的紀錄
##（CodeRabbit review 抓到，原本只處理了第 1 種方向）
func _exit_tree() -> void:
	stop_haul()
	for hauler in _hauled_by.duplicate():
		if is_instance_valid(hauler) and hauler._hauling_target == self:
			hauler.stop_haul()
	_hauled_by.clear()
	_is_being_carried = false


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
