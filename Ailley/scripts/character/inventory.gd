class_name Inventory
extends Node


## 角色的物品容器。快捷欄與主背包共用同一個陣列——「把快捷欄的東西丟進背包」
## 是搬 index，不是跨容器搬移。掛在 Character 基底而不是 Player：
## 核心約束「Player 能做到的，Agent 也必須能做到」，Agent 沒有 UI 也要查得到背包。
##
## 一格的資料照規格書 08 §1：
## {item_id, count, decay, durability}
##
## 堆疊規則見 §4，_add_stackable() / _add_unstackable()
## 各自對應規則 #1 #2。
##
## 金錢也在這裡。
##
## 格子或金錢真的變了才發 changed。
##
## =====================================================
## 物品使用
##
## Inventory 不直接查 DatabaseManager。
##
## Character 負責從 item definition 取得：
##
##     effect_satiety
##     effect_hydration
##     effect_alcohol
##     effect_injury
##
## 再呼叫：
##
##     inventory.use_item(
##         item_id,
##         stats,
##         effects,
##         is_consumable
##     )
##
## Inventory 只負責：
##
##     1. 確認物品存在
##     2. 確認是否可消耗
##     3. 套用 Stats 效果
##     4. 成功後消耗 1 個物品
##
## =====================================================


signal changed


const HOTBAR_SIZE := 9
const MAIN_SIZE := 27
const SIZE := HOTBAR_SIZE + MAIN_SIZE
const MAX_STACK := 30
# index 0..8 快捷欄，9..35 主背包


## 同 item_id 且 decay 差距在這個範圍內
## 才能疊進同一格。08 §4 規則 #1
const STACK_DECAY_TOLERANCE := 10


## =====================================================
## add_item() 的失敗原因碼
## =====================================================

const ADD_OK := ""
const ADD_NO_SPACE := "NO_SPACE"
const ADD_INVALID_COUNT := "INVALID_COUNT"


## =====================================================
## remove_item() 的失敗原因碼
## =====================================================

const REMOVE_OK := ""
const REMOVE_NOT_FOUND := "NOT_FOUND"
const REMOVE_INVALID_COUNT := "INVALID_COUNT"


## =====================================================
## use_item() 的回傳原因碼
## =====================================================

const USE_OK := ""
const USE_NOT_FOUND := "NOT_FOUND"
const USE_NOT_CONSUMABLE := "NOT_CONSUMABLE"
const USE_INVALID_STATS := "INVALID_STATS"
const USE_INVALID_EFFECT := "INVALID_EFFECT"
const USE_REMOVE_FAILED := "REMOVE_FAILED"


## =====================================================
## 金錢
## =====================================================

const DEFAULT_MONEY := 300


## add_money() / spend() 的失敗原因碼
const MONEY_OK := ""
const MONEY_NOT_ENOUGH := "NOT_ENOUGH"
const MONEY_INVALID_AMOUNT := "INVALID_AMOUNT"


## =====================================================
## Inventory Data
## =====================================================

var slots: Array[Dictionary] = []


# 快捷欄選到第幾格。
# 這是資料層狀態不是 UI 狀態——UI 只是顯示它，
# Agent 沒有 UI 也要有「手上拿著什麼」這個概念。
var _selected_index := 0


# 私有而不是像 slots 那樣公開：
# 金錢只有「進帳」與「扣款」兩種合法異動。
var _money := DEFAULT_MONEY


# 在 _init() 而不是 _ready() 配置，
# 這樣 Inventory.new() 出來的實例還沒進場景樹
# 就已經是合法容器。
func _init() -> void:

	slots.resize(SIZE)

	for i in SIZE:

		slots[i] = {}


# =====================================================
# 查詢
# =====================================================

# 該格內容的副本，空格回空 Dictionary。
# 索引越界一律當空格不拋錯。
func get_slot(index: int) -> Dictionary:

	if index < 0 or index >= SIZE:

		return {}


	return slots[index].duplicate()


# =====================================================
# Count Item
# =====================================================

func count_item(item_id: String) -> int:

	var total := 0


	for i in SIZE:

		var slot: Dictionary = slots[i]


		if slot.is_empty():

			continue


		if slot["item_id"] == item_id:

			total += int(
				slot["count"]
			)


	return total


# =====================================================
# Has Item
# =====================================================

func has_item(
	item_id: String,
	count: int = 1
) -> bool:

	if count <= 0:

		return false


	return count_item(
		item_id
	) >= count


# =====================================================
# Find Empty Slot
# =====================================================

func find_first_empty() -> int:

	for i in SIZE:

		if slots[i].is_empty():

			return i


	return -1


# =====================================================
# 異動
# =====================================================

# 加入物品。
#
# durability 留 -1：
#     代表這批物品用 decay 追蹤，
#     會嘗試疊進相容的既有格。
#
# durability >= 0：
#     carry 類，
#     一件佔一格、不可疊。
func add_item(
	item_id: String,
	count: int = 1,
	decay: int = 0,
	durability: int = -1
) -> String:

	if count <= 0:

		return ADD_INVALID_COUNT


	var reason := (
		_add_unstackable(
			item_id,
			count,
			decay,
			durability
		)
		if durability >= 0
		else
		_add_stackable(
			item_id,
			count,
			decay
		)
	)


	if reason == ADD_OK:

		changed.emit()


	return reason


func _add_stackable(
	item_id: String,
	count: int,
	decay: int
) -> String:

	# -------------------------------------------------
	# 先計算總容量（相容的已有格 + 空格）
	# -------------------------------------------------

	var total_capacity := 0

	# 計算相容已有格的可用空間
	for i in SIZE:

		var slot: Dictionary = slots[i]

		if slot.is_empty():
			continue

		if str(
			slot.get(
				"item_id",
				""
			)
		) != item_id:
			continue

		if int(
			slot.get(
				"durability",
				-1
			)
		) >= 0:
			continue

		if (
			absi(
				int(
					slot.get(
						"decay",
						0
					)
				)
				- decay
			)
			> STACK_DECAY_TOLERANCE
		):
			continue

		var current := clampi(
			int(
				slot.get(
					"count",
					0
				)
			),
			0,
			MAX_STACK
		)

		var space := (
			MAX_STACK
			- current
		)

		if space > 0:
			total_capacity += space

	# 計算空格數量
	var empty_slots := 0
	for i in SIZE:
		if slots[i].is_empty():
			empty_slots += 1

	total_capacity += empty_slots * MAX_STACK

	# 驗證總容量是否足夠
	if total_capacity < count:
		return ADD_NO_SPACE


	var remaining := count


	# -------------------------------------------------
	# 先填入已有的相容 stack。
	#
	# 每一格最多 MAX_STACK = 30。
	# 如果原本已有 25，這次加入 20，
	# 會變成：
	#
	#   原格 25 → 30
	#   新格 20 → 15
	#
	# 不允許任何 runtime slot 超過 30。
	# -------------------------------------------------

	for i in SIZE:

		if remaining <= 0:

			break


		var slot: Dictionary = slots[i]


		if slot.is_empty():

			continue


		if str(
			slot.get(
				"item_id",
				""
			)
		) != item_id:

			continue


		if int(
			slot.get(
				"durability",
				-1
			)
		) >= 0:

			continue


		if (
			absi(
				int(
					slot.get(
						"decay",
						0
					)
				)
				- decay
			)
			> STACK_DECAY_TOLERANCE
		):

			continue


		var current := clampi(
			int(
				slot.get(
					"count",
					0
				)
			),
			0,
			MAX_STACK
		)


		var space := (
			MAX_STACK
			- current
		)


		if space <= 0:

			continue


		var add_count := mini(
			remaining,
			space
		)


		slot["count"] = (
			current
			+ add_count
		)


		# 取較差（較高）的 decay。
		slot["decay"] = maxi(
			int(
				slot.get(
					"decay",
					0
				)
			),
			decay
		)


		remaining -= add_count


	# -------------------------------------------------
	# 還有剩餘數量就建立新的 stack。
	# 每個新 stack 仍然最多 30。
	# -------------------------------------------------

	while remaining > 0:

		var empty := find_first_empty()


		if empty == -1:

			return ADD_NO_SPACE


		var add_count := mini(
			remaining,
			MAX_STACK
		)


		slots[empty] = {
			"item_id": item_id,
			"count": add_count,
			"decay": decay,
			"durability": -1
		}


		remaining -= add_count


	return ADD_OK


func _add_unstackable(
	item_id: String,
	count: int,
	decay: int,
	durability: int
) -> String:

	var empties: Array[int] = []


	for i in SIZE:

		if slots[i].is_empty():

			empties.append(i)


			if empties.size() == count:

				break


	if empties.size() < count:

		return ADD_NO_SPACE


	for i in empties:

		slots[i] = {
			"item_id": item_id,
			"count": 1,
			"decay": decay,
			"durability": durability
		}


	return ADD_OK


# 同 item_id、無 durability（decay 類）、
# decay 差距在容許範圍內的既有格。
func _find_stackable_slot(
	item_id: String,
	decay: int
) -> int:

	for i in SIZE:

		var slot: Dictionary = slots[i]


		if (
			slot.is_empty()
			or slot["item_id"] != item_id
		):

			continue


		if int(
			slot["durability"]
		) >= 0:

			continue


		if int(
			slot["count"]
		) >= MAX_STACK:

			continue


		if (
			absi(
				int(slot["decay"])
				- decay
			)
			<= STACK_DECAY_TOLERANCE
		):

			return i


	return -1


# =====================================================
# Remove Item
# =====================================================

func remove_item(
	item_id: String,
	count: int = 1
) -> String:

	if count <= 0:

		return REMOVE_INVALID_COUNT


	if count_item(item_id) < count:

		return REMOVE_NOT_FOUND


	var remaining := count


	for i in SIZE:

		if remaining <= 0:

			break


		var slot: Dictionary = slots[i]


		if (
			slot.is_empty()
			or slot["item_id"] != item_id
		):

			continue


		var take := mini(
			remaining,
			int(slot["count"])
		)


		slot["count"] = (
			int(slot["count"])
			- take
		)


		remaining -= take


		if int(
			slot["count"]
		) <= 0:

			slots[i] = {}


	changed.emit()

	return REMOVE_OK


# =====================================================
# Use Item
# =====================================================

## 使用一個消耗品。
##
## 注意：
## Inventory 不負責查詢 SQLite。
##
## effects 格式：
##
## {
##     "effect_satiety": 40,
##     "effect_hydration": 20,
##     "effect_alcohol": 25,
##     "effect_injury": -30
## }
##
## Stats.add() 會負責將數值限制在 0~100。
##
## 只有物品效果套用後，
## 才會消耗背包中的 1 個物品。
##
## 例如：
## water：
##     hydration +40
##
## ale：
##     hydration +20
##     alcohol +25
##
## cooked_meat：
##     satiety +40
##
## herb_soup：
##     satiety +20
##
## medicine：
##     injury -30
##
func use_item(
	item_id: String,
	stats: Stats,
	effects: Dictionary,
	is_consumable: bool = true
) -> String:

	# -------------------------------------------------
	# 1. Stats 必須存在
	# -------------------------------------------------

	if stats == null:

		push_warning(
			"[Inventory] "
			+ "使用物品失敗：Stats 不存在。"
		)

		return USE_INVALID_STATS


	# -------------------------------------------------
	# 2. 必須持有物品
	# -------------------------------------------------

	if not has_item(
		item_id,
		1
	):

		push_warning(
			"[Inventory] "
			+ "使用物品失敗：背包沒有 %s。"
			% item_id
		)

		return USE_NOT_FOUND


	# -------------------------------------------------
	# 3. 必須是消耗品
	# -------------------------------------------------

	if not is_consumable:

		push_warning(
			"[Inventory] "
			+ "%s 不是可消耗物品。"
			% item_id
		)

		return USE_NOT_CONSUMABLE


	# -------------------------------------------------
	# 4. 讀取效果
	# -------------------------------------------------

	var effect_satiety := float(
		effects.get(
			"effect_satiety",
			0.0
		)
	)


	var effect_hydration := float(
		effects.get(
			"effect_hydration",
			0.0
		)
	)


	var effect_alcohol := float(
		effects.get(
			"effect_alcohol",
			0.0
		)
	)


	var effect_injury := float(
		effects.get(
			"effect_injury",
			0.0
		)
	)


	# -------------------------------------------------
	# 5. 驗證效果數值
	# -------------------------------------------------

	if (
		not is_finite(effect_satiety)
		or not is_finite(effect_hydration)
		or not is_finite(effect_alcohol)
		or not is_finite(effect_injury)
	):

		push_error(
			"[Inventory] "
			+ "%s 的物品效果包含無效數值。"
			% item_id
		)

		return USE_INVALID_EFFECT


	# -------------------------------------------------
	# 6. 套用效果
	#
	# Stats.add() 會自動限制 0~100。
	# -------------------------------------------------

	if effect_satiety != 0.0:

		stats.add(
			"satiety",
			effect_satiety
		)


	if effect_hydration != 0.0:

		stats.add(
			"hydration",
			effect_hydration
		)


	if effect_alcohol != 0.0:

		stats.add(
			"alcohol",
			effect_alcohol
		)


	if effect_injury != 0.0:

		stats.add(
			"injury",
			effect_injury
		)


	# -------------------------------------------------
	# 7. 效果套用成功後才移除 1 個
	# -------------------------------------------------

	var remove_reason := remove_item(
		item_id,
		1
	)


	if remove_reason != REMOVE_OK:

		push_error(
			"[Inventory] "
			+ "使用 %s 後移除物品失敗：%s"
			% [
				item_id,
				remove_reason
			]
		)

		return USE_REMOVE_FAILED


	# -------------------------------------------------
	# 8. Debug
	# -------------------------------------------------

	print(
		"[Inventory] 使用物品：%s | "
		+ "satiety=%+.1f "
		+ "hydration=%+.1f "
		+ "alcohol=%+.1f "
		+ "injury=%+.1f"
		% [
			item_id,
			effect_satiety,
			effect_hydration,
			effect_alcohol,
			effect_injury
		]
	)


	return USE_OK


# =====================================================
# Move Slot
# =====================================================

# 搬到空格；
# 目的地非空就失敗，不覆蓋。
# 要交換兩個已佔用的格用 swap_slot()。
func move_slot(
	from: int,
	to: int
) -> bool:

	if (
		from < 0
		or from >= SIZE
		or to < 0
		or to >= SIZE
		or from == to
	):

		return false


	if (
		slots[from].is_empty()
		or not slots[to].is_empty()
	):

		return false


	slots[to] = slots[from]

	slots[from] = {}


	changed.emit()

	return true


func swap_slot(
	a: int,
	b: int
) -> bool:

	if (
		a < 0
		or a >= SIZE
		or b < 0
		or b >= SIZE
		or a == b
	):

		return false


	var tmp := slots[a]

	slots[a] = slots[b]

	slots[b] = tmp


	changed.emit()

	return true


# =====================================================
# 快捷欄選格
# =====================================================

func get_selected_index() -> int:

	return _selected_index


func set_selected_index(
	index: int
) -> void:

	_selected_index = clampi(
		index,
		0,
		HOTBAR_SIZE - 1
	)


# =====================================================
# 金錢
# =====================================================

func get_money() -> int:

	return _money


# 進帳。
func add_money(
	amount: int
) -> String:

	if amount <= 0:

		return MONEY_INVALID_AMOUNT


	_money += amount

	changed.emit()

	return MONEY_OK


# 扣款。
func spend(
	amount: int
) -> String:

	if amount <= 0:

		return MONEY_INVALID_AMOUNT


	if _money < amount:

		return MONEY_NOT_ENOUGH


	_money -= amount

	changed.emit()

	return MONEY_OK


# =====================================================
# Agent 查詢
# =====================================================

# 不含空格的密集摘要，
# 給行為判定與日後的 AI payload 用。
func get_summary() -> Array[Dictionary]:

	var result: Array[Dictionary] = []


	for i in SIZE:

		if not slots[i].is_empty():

			var entry: Dictionary = (
				slots[i].duplicate()
			)

			entry["slot"] = i

			result.append(
				entry
			)


	return result
