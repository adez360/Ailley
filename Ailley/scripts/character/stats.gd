class_name Stats
extends Node

## 角色狀態數值。
##
## npc_state 的正式生理欄位：
##   satiety / hydration / stamina / wakefulness / hygiene
##   alcohol / health / injury
##
## 所有數值都是 0-100。
##
## 舊系統仍可能呼叫：
##   energy / thirst / sleepiness
##
## 這三個名稱透過 LEGACY_ALIASES 對應到 canonical key，
## 不另外建立第二份狀態，避免遊戲與 SQLite 出現兩套數值。


const MIN := 0.0
const MAX := 100.0
const CRITICAL := 30.0


const LEGACY_ALIASES := {
	"energy": "stamina"
}


const SPEC := {
	# -------------------------------------------------
	# 正式生理狀態：對齊 npc_state
	# -------------------------------------------------

	"satiety": {
		"label": "STAT_SATIETY",
		"drift": 3.0,
		"toward": 0.0,
		"start": 100.0,
		"is_need": true,
		"place": "restaurant"
	},

	"hydration": {
		"label": "STAT_HYDRATION",
		"drift": 0.0,
		"toward": 80.0,
		"start": 80.0,
		"is_need": true,
		"place": "home_001"
	},

	"stamina": {
		"label": "STAT_STAMINA",
		"drift": 1.0,
		"toward": 0.0,
		"start": 80.0,
		"is_need": true,
		"place": "home_001"
	},

	"wakefulness": {
		"label": "STAT_WAKEFULNESS",
		"drift": 1.0,
		"toward": 0.0,
		"start": 90.0,
		"is_need": true,
		"place": "home_001"
	},

	"hygiene": {
		"label": "STAT_HYGIENE",
		"drift": 0.0,
		"toward": 70.0,
		"start": 70.0,
		"is_need": true,
		"place": "home_001"
	},

	"alcohol": {
		"label": "STAT_ALCOHOL",
		"drift": 0.0,
		"toward": 0.0,
		"start": 0.0,
		"is_need": false,
		"place": ""
	},

	"health": {
		"label": "STAT_HEALTH",
		"drift": 0.0,
		"toward": 100.0,
		"start": 100.0,
		"is_need": false,
		"place": ""
	},

	"injury": {
		"label": "STAT_INJURY",
		"drift": 0.0,
		"toward": 0.0,
		"start": 0.0,
		"is_need": false,
		"place": ""
	},

	# -------------------------------------------------
	# 目前 main 仍有消費者的非生理狀態
	# 暫時保留，不寫入 npc_state。
	# -------------------------------------------------

	"social": {
		"label": "STAT_SOCIAL",
		"drift": 0.5,
		"toward": 0.0,
		"start": 100.0,
		"is_need": true,
		"place": "square"
	},

	"fun": {
		"label": "STAT_FUN",
		"drift": 0.2,
		"toward": 0.0,
		"start": 100.0,
		"is_need": true,
		"place": "square"
	},

	"mood": {
		"label": "STAT_MOOD",
		"drift": 0.5,
		"toward": 50.0,
		"start": 50.0,
		"is_need": false,
		"place": ""
	},
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

		values[key] = move_toward(
			values[key],
			spec["toward"],
			spec["drift"] * delta
		)


func _canonical_key(key: String) -> String:
	return str(LEGACY_ALIASES.get(key, key))


func get_value(key: String) -> float:
	var canonical := _canonical_key(key)

	if not SPEC.has(canonical):
		return 0.0

	return float(values.get(canonical, SPEC[canonical]["start"]))


func set_value(key: String, value: float) -> void:
	var canonical := _canonical_key(key)

	if not SPEC.has(canonical):
		push_error("Stats: 沒有這項數值 %s" % key)
		return

	values[canonical] = clampf(value, MIN, MAX)


func add(key: String, delta: float) -> void:
	set_value(key, get_value(key) + delta)


func is_need(key: String) -> bool:
	var canonical := _canonical_key(key)
	return SPEC.has(canonical) and SPEC[canonical]["is_need"]


func needs_attention() -> bool:
	for key in SPEC:
		if is_need(key) and values[key] < CRITICAL:
			return true

	return false


func get_lowest_need() -> String:
	var lowest := ""
	var lowest_value := INF

	for key in SPEC:
		if not is_need(key):
			continue

		if values[key] < lowest_value:
			lowest_value = values[key]
			lowest = key

	return lowest


func get_place_for_need(key: String) -> String:
	var canonical := _canonical_key(key)

	if not SPEC.has(canonical):
		return ""

	return str(SPEC[canonical]["place"])


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
