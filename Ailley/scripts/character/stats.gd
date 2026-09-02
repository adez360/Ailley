class_name Stats
extends Node

## 角色的數值。取代 villager 時代的 Needs（四個寫死的變數，
## 每加一項就要改 _process、needs_attention、get_lowest_need 三個地方）。
##
## 要加一項數值只要在 SPEC 加一列，其餘程式都不用動（連 debug 主控台的顯示也是）：
##   label    顯示名稱的翻譯 key（res://locale/game.csv 的 STAT_*）。
##            這裡刻意存 key 不存字：SPEC 是純資料，翻譯留給顯示端做
##   drift    每 tick（GameClock.GAME_MINUTES_PER_TICK＝10 遊戲分鐘）往 toward
##            靠近多少，0 表示不會自然變化
##   toward   數值自然漂向哪裡。需求類漂向 0（會餓、會累），心情漂回平常值
##   is_need  是不是「低了就該去解決」的東西。心情不是，所以不會被
##            get_lowest_need() 選中，也不算進 needs_attention()
##   place    去哪裡能解決這項需求。只是地點「名稱」，座標由 scripts/world/places.gd
##            的 PlaceAnchors 解析 —— Stats 不可以依賴場景，否則就沒辦法
##            在沒有場景的情況下（例如日後的存檔／單元測試）使用
##
## stamina 的 place 是寫死的 home，這是從舊 villager.gd 照搬過來的。
## 每個角色的家其實不一樣，正確作法是讀該角色自己的家 —— 等行程表改由 AI
## 維護（計畫 §5.1）時一併處理，那時「家在哪」本來就要變成角色的屬性
##
## satiety/hydration/stamina/wakefulness/hygiene/alcohol/health/injury 8 項是
## 規格書《01》§4-1 `state.physical` 的欄位。satiety/hydration/stamina/
## wakefulness 4 項 drift 已改依 issue #730 的節奏重新推導（一天總掉量對齊
## 最好的食物/飲料道具補的量，或 CRITICAL 門檻），不再是《01》表訂原始值——
## 那份原始值換算成現實時間遠比一輪 LLM 決策快，角色不到一天就會餓死/渴死。
## alcohol/injury 是事件累積型（預設 0，靠外部事件推高），is_need 故意留 false，
## 不參與 get_lowest_need()/needs_attention()（見《99》P-32 追加決策）；
## hygiene/health 雖然也是「越高越好」，但目前沒有對應的 place 可去，
## 同樣不參與這兩個函式，只靠外部事件寫入——hygiene 2026-08-24 起也拿掉 drift，
## 不再自然漂移，改成打獵/採集/表演等工作動作直接扣（見《99》P-65、下面的
## `ACTION_DIRTY` 表）。沒有 drift 不等於數值凍結不動——`wash` 已經是既有的
## `ACTION_RECOVERY`（agent.gd）項目，會直接把 hygiene 往上加，drift 只是
## 不再自己往下掉

const MIN := 0.0
const MAX := 100.0
const CRITICAL := 30.0		# 低於這個值算「該處理了」

const SPEC := {
	"satiety": {"label": "STAT_SATIETY", "drift": 0.278, "toward": 0.0, "start": 100.0, "is_need": true, "place": "tavern"},
	"hydration": {"label": "STAT_HYDRATION", "drift": 0.278, "toward": 0.0, "start": 80.0, "is_need": true, "place": "tavern"},
	"stamina": {"label": "STAT_STAMINA", "drift": 0.35, "toward": 0.0, "start": 80.0, "is_need": true, "place": "home"},
	"wakefulness": {"label": "STAT_WAKEFULNESS", "drift": 0.42, "toward": 0.0, "start": 90.0, "is_need": true, "place": "home"},
	"hygiene": {"label": "STAT_HYGIENE", "drift": 0.0, "toward": 0.0, "start": 70.0, "is_need": false, "place": ""},
	"alcohol": {"label": "STAT_ALCOHOL", "drift": 3.0, "toward": 0.0, "start": 0.0, "is_need": false, "place": ""},
	"health": {"label": "STAT_HEALTH", "drift": 0.0, "toward": 100.0, "start": 100.0, "is_need": false, "place": ""},
	"injury": {"label": "STAT_INJURY", "drift": 0.5, "toward": 0.0, "start": 0.0, "is_need": false, "place": ""},
}

## 工作動作扣 hygiene 用（《99》P-65），形狀比照 agent.gd 的 `ACTION_RECOVERY`
## 但語意相反：`ACTION_RECOVERY` 是「持續狀態每遊戲分鐘回一點」，這裡是
## 「離散動作執行成功時一次性扣一次」，放在 Stats 而不是 Agent，是因為
## `gather()`／`perform()` 的呼叫端 `Character` 是兩者共同的基底，Player
## 也走得到，不能只讓 Agent 看得到這張表。
## `hunt_small`／`hunt_large` 數值已定案，但那兩個動作本身還沒進
## `IMPLEMENTED_ACTIONS` 白名單（見 #573），先留在表裡，實際扣點呼叫等
## 該 issue 落地時再接上
const ACTION_DIRTY := {
	"hunt_small": [{"stat": "hygiene", "amount": -5.0}],
	"hunt_large": [{"stat": "hygiene", "amount": -12.0}],
	"gather": [{"stat": "hygiene", "amount": -3.0}],
	"perform": [{"stat": "hygiene", "amount": -1.0}],
}

var values := {}

## `bleeding` condition 期間 `injury` 原本每 tick −0.5 的自然衰減要暫停
## （《02》§2-2 附注，唯一的例外規則）。由 Character 依 conditions 狀態設定，
## Stats 自己不知道 conditions 是什麼
var injury_decay_paused := false

## 入眠狀態（issue #827，《10》§4.5「玩家離線處置」）：所有需求暫停衰減，
## 不會因此餓死。跟 injury_decay_paused 同一種寫法——由 Character 依
## is_offline_asleep 設定，Stats 自己不知道為什麼要暫停，也不管是哪個原因
## （真人離線／模型失效）觸發的入眠，兩種情境對 Stats 而言是同一件事
var all_drift_paused := false


func _ready() -> void:
	for key in SPEC:
		values[key] = SPEC[key]["start"]
	if GameClock:
		GameClock.time_changed.connect(_on_time_changed)

func _on_time_changed(_hour: int, _minute: int) -> void:
	# Stats 漂移在全局分鐘邊界執行，以全局時間為準而非本地累計
	if _minute % GameClock.GAME_MINUTES_PER_TICK == 0:
		_apply_drift()

func _apply_drift() -> void:
	if all_drift_paused:
		return
	for key in SPEC:
		var spec: Dictionary = SPEC[key]
		if spec["drift"] == 0.0:
			continue
		if key == "injury" and injury_decay_paused:
			continue
		values[key] = move_toward(values[key], spec["toward"], spec["drift"])

func get_value(key: String) -> float:
	return values.get(key, 0.0)

func set_value(key: String, value: float) -> void:
	if not SPEC.has(key):
		push_error("Stats: 沒有這項數值 %s" % key)
		return
	values[key] = clampf(value, MIN, MAX)

func add(key: String, delta: float) -> void:
	set_value(key, get_value(key) + delta)

func is_need(key: String) -> bool:
	return SPEC.has(key) and SPEC[key]["is_need"]

# 有任何一項需求跌破閾值。心情不算 —— 心情差不是「去某個地點就能解決」的事
func needs_attention() -> bool:
	for key in SPEC:
		if is_need(key) and values[key] < CRITICAL:
			return true
	return false

# 最低的那一項需求，用來決定該優先滿足什麼
func get_lowest_need() -> String:
	var lowest := ""
	var lowest_value := INF

	for key in SPEC:
		if is_need(key) and values[key] < lowest_value:
			lowest_value = values[key]
			lowest = key

	return lowest

# 去哪裡能解決這項需求。不是需求（心情）或沒有這項數值都回空字串
#
# 只回名稱，不回座標。呼叫端拿到之後走 scripts/world/places.gd 的 PlaceAnchors，
# 那裡才知道現在是哪張地圖、錨點擺在哪
func get_place_for_need(key: String) -> String:
	if not SPEC.has(key):
		return ""
	return SPEC[key]["place"]

# 現在最該去的地方。系統分析計畫 §5 指定這是 AI 請求逾時後的 fallback 路徑：
# 問不到 AI 就先去滿足最低的那項需求，而不是站在原地
func get_lowest_need_place() -> String:
	return get_place_for_need(get_lowest_need())


# ---- 存檔 ----

func get_save_data() -> Dictionary:
	return values.duplicate(true)

# 缺的欄位用 SPEC 的 start 補，不當成錯誤——SPEC 加一項是預期會發生的事，
# 不該讓舊存檔讀不起來
func load_save_data(data: Dictionary) -> void:
	for key in SPEC:
		values[key] = data.get(key, SPEC[key]["start"])
