class_name Stats
extends Node

## 角色的數值。取代 villager 時代的 Needs（四個寫死的變數，
## 每加一項就要改 _process、needs_attention、get_lowest_need 三個地方）。
##
## 要加一項數值只要在 SPEC 加一列，其餘程式都不用動（連 debug 主控台的顯示也是）：
##   label    顯示名稱的翻譯 key（res://locale/game.csv 的 STAT_*）。
##            這裡刻意存 key 不存字：SPEC 是純資料，翻譯留給顯示端做
##   drift    每現實秒往 toward 靠近多少，0 表示不會自然變化
##   toward   數值自然漂向哪裡。需求類漂向 0（會餓、會累），心情漂回平常值
##   is_need  是不是「低了就該去解決」的東西。心情不是，所以不會被
##            get_lowest_need() 選中，也不算進 needs_attention()
##   place    去哪裡能解決這項需求。只是地點「名稱」，座標由 scripts/world/places.gd
##            的 PlaceAnchors 解析 —— Stats 不可以依賴場景，否則就沒辦法
##            在沒有場景的情況下（例如日後的存檔／單元測試）使用
##
## energy 的 place 是寫死的 home_001，這是從舊 villager.gd 照搬過來的。
## 每個角色的家其實不一樣，正確作法是讀該角色自己的家 —— 等行程表改由 AI
## 維護（計畫 §5.1）時一併處理，那時「家在哪」本來就要變成角色的屬性

const MIN := 0.0
const MAX := 100.0
const CRITICAL := 30.0		# 低於這個值算「該處理了」

const SPEC := {
	"satiety": {"label": "STAT_SATIETY", "drift": 3.0, "toward": 0.0, "start": 100.0, "is_need": true, "place": "restaurant"},
	"energy": {"label": "STAT_ENERGY", "drift": 1.0, "toward": 0.0, "start": 100.0, "is_need": true, "place": "home_001"},
	"social": {"label": "STAT_SOCIAL", "drift": 0.5, "toward": 0.0, "start": 100.0, "is_need": true, "place": "square"},
	"fun": {"label": "STAT_FUN", "drift": 0.2, "toward": 0.0, "start": 100.0, "is_need": true, "place": "square"},
	"mood": {"label": "STAT_MOOD", "drift": 0.5, "toward": 50.0, "start": 50.0, "is_need": false, "place": ""},
}

var values := {}


func _ready() -> void:
	for key in SPEC:
		values[key] = SPEC[key]["start"]

func _process(delta: float) -> void:
	for key in SPEC:
		var spec: Dictionary = SPEC[key]
		if spec["drift"] == 0.0:
			continue
		values[key] = move_toward(values[key], spec["toward"], spec["drift"] * delta)

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
