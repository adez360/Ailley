class_name Inventory
extends Node

## 角色的物品容器。快捷欄與主背包共用同一個陣列——「把快捷欄的東西丟進背包」
## 是搬 index，不是跨容器搬移。掛在 Character 基底而不是 Player：
## 核心約束「Player 能做到的，Agent 也必須能做到」，Agent 沒有 UI 也要查得到背包。
##
## 一格的資料照規格書 08 §1：{item_id, count, decay, durability}，空格是 {}。
## 堆疊規則見 §4，_add_stackable() / _add_unstackable() 各自對應規則 #1 #2。

const HOTBAR_SIZE := 9
const MAIN_SIZE := 27
const SIZE := HOTBAR_SIZE + MAIN_SIZE		# index 0..8 快捷欄，9..35 主背包

## 同 item_id 且 decay 差距在這個範圍內才能疊進同一格。08 §4 規則 #1
const STACK_DECAY_TOLERANCE := 10

## add_item() 的失敗原因碼。比照 character.gd 的 TALK_*——
## 計畫 §5.3 要求每個動作都要能講出為什麼失敗，AI 才有辦法重排行程
const ADD_OK := ""
const ADD_NO_SPACE := "NO_SPACE"

## remove_item() 的失敗原因碼
const REMOVE_OK := ""
const REMOVE_NOT_FOUND := "NOT_FOUND"

var slots: Array[Dictionary] = []

# 快捷欄選到第幾格。這是資料層狀態不是 UI 狀態——UI 只是顯示它，
# Agent 沒有 UI 也要有「手上拿著什麼」這個概念
var _selected_index := 0


func _ready() -> void:
	slots.resize(SIZE)
	for i in SIZE:
		slots[i] = {}


# ---- 查詢 ----

# 該格內容的副本，空格回空 Dictionary。索引越界一律當空格不拋錯——
# 呼叫端（debug 指令、日後的 UI）常常是先算出索引才驗證，越界不該是例外路徑
func get_slot(index: int) -> Dictionary:
	if index < 0 or index >= SIZE:
		return {}
	return slots[index].duplicate()

func count_item(item_id: String) -> int:
	var total := 0
	for slot in slots:
		if slot.get("item_id", "") == item_id:
			total += int(slot["count"])
	return total

func has_item(item_id: String, count: int = 1) -> bool:
	return count_item(item_id) >= count

func find_first_empty() -> int:
	for i in SIZE:
		if slots[i].is_empty():
			return i
	return -1


# ---- 異動 ----

# 加入物品。成功回傳 ADD_OK（空字串），沒位置回傳 ADD_NO_SPACE，且不動任何格——
# 失敗是原子的，不會半途占掉一部分槽位又回報失敗。
#
# durability 留 -1（預設）代表這批物品用 decay 追蹤，會嘗試疊進相容的既有格；
# 傳 0 以上代表 carry 類，08 §4 規則 #2 一件佔一格、不可疊。
# 物品定義檔不在這則範圍內，呼叫端目前得自己講清楚這批是哪一種
func add_item(item_id: String, count: int = 1, decay: int = 0, durability: int = -1) -> String:
	if durability >= 0:
		return _add_unstackable(item_id, count, decay, durability)
	return _add_stackable(item_id, count, decay)

func _add_stackable(item_id: String, count: int, decay: int) -> String:
	var target := _find_stackable_slot(item_id, decay)
	if target != -1:
		var slot: Dictionary = slots[target]
		slot["count"] = int(slot["count"]) + count
		slot["decay"] = maxi(int(slot["decay"]), decay)		# 取較差（較高）的 decay
		return ADD_OK

	var empty := find_first_empty()
	if empty == -1:
		return ADD_NO_SPACE

	slots[empty] = {"item_id": item_id, "count": count, "decay": decay, "durability": -1}
	return ADD_OK

func _add_unstackable(item_id: String, count: int, decay: int, durability: int) -> String:
	var empties: Array[int] = []
	for i in SIZE:
		if slots[i].is_empty():
			empties.append(i)
			if empties.size() == count:
				break

	if empties.size() < count:
		return ADD_NO_SPACE

	for i in empties:
		slots[i] = {"item_id": item_id, "count": 1, "decay": decay, "durability": durability}
	return ADD_OK

# 同 item_id、無 durability（decay 類）、decay 差距在容許範圍內的既有格。找不到回 -1
func _find_stackable_slot(item_id: String, decay: int) -> int:
	for i in SIZE:
		var slot: Dictionary = slots[i]
		if slot.is_empty() or slot["item_id"] != item_id:
			continue
		if int(slot["durability"]) >= 0:
			continue
		if absi(int(slot["decay"]) - decay) <= STACK_DECAY_TOLERANCE:
			return i
	return -1

# 移除物品，成功回傳 REMOVE_OK，數量不足回傳 REMOVE_NOT_FOUND 且不動任何格——
# 同樣是原子的，不會先扣掉一部分才發現不夠
func remove_item(item_id: String, count: int = 1) -> String:
	if count_item(item_id) < count:
		return REMOVE_NOT_FOUND

	var remaining := count
	for i in SIZE:
		if remaining <= 0:
			break

		var slot: Dictionary = slots[i]
		if slot.is_empty() or slot["item_id"] != item_id:
			continue

		var take := mini(remaining, int(slot["count"]))
		slot["count"] = int(slot["count"]) - take
		remaining -= take
		if int(slot["count"]) <= 0:
			slots[i] = {}

	return REMOVE_OK

# 搬到空格；目的地非空就失敗，不覆蓋。要交換兩個已佔用的格用 swap_slot()
func move_slot(from: int, to: int) -> bool:
	if from < 0 or from >= SIZE or to < 0 or to >= SIZE or from == to:
		return false
	if slots[from].is_empty() or not slots[to].is_empty():
		return false

	slots[to] = slots[from]
	slots[from] = {}
	return true

func swap_slot(a: int, b: int) -> bool:
	if a < 0 or a >= SIZE or b < 0 or b >= SIZE or a == b:
		return false

	var tmp := slots[a]
	slots[a] = slots[b]
	slots[b] = tmp
	return true


# ---- 快捷欄選格 ----

func get_selected_index() -> int:
	return _selected_index

func set_selected_index(index: int) -> void:
	_selected_index = clampi(index, 0, HOTBAR_SIZE - 1)


# ---- Agent 查詢 ----

# 不含空格的密集摘要，給行為判定與日後的 AI payload 用。
# 每筆補一個 slot 索引，回傳的是副本，改它不會動到內部狀態
func get_summary() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for i in SIZE:
		if not slots[i].is_empty():
			var entry := slots[i].duplicate()
			entry["slot"] = i
			result.append(entry)
	return result
