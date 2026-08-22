@tool
class_name TestInventoryStackCap
extends McpTestSuite

## 測試 Issue #411：物品欄 30 個堆疊上限強制

func suite_name() -> String:
	return "inventory_stack_cap"


func test_single_slot_30_cap() -> void:
	# 驗證單格最多 30 個
	var inv = Inventory.new()
	var result = inv.add_item("bread", 30)
	_assert_eq(result, Inventory.ADD_OK, "添加 30 個應成功")

	var slot = inv.get_slot(0)
	_assert_eq(slot.get("count", -1), 30, "第 0 格應有 30 個")


func test_overflow_opens_new_slot() -> void:
	# 驗證第 31 個物品開新格
	var inv = Inventory.new()
	inv.add_item("bread", 30)
	var result = inv.add_item("bread", 1)
	_assert_eq(result, Inventory.ADD_OK, "添加第 31 個應打開新格")

	var slot0 = inv.get_slot(0)
	_assert_eq(slot0.get("count", -1), 30, "第 0 格應維持 30 個")

	var slot1 = inv.get_slot(1)
	_assert_eq(slot1.get("count", -1), 1, "第 1 格應有 1 個")


func test_multiple_slots_distribution() -> void:
	# 驗證 60 個物品精確分配到第 0、1 格各 30 個，其餘格保持空白
	var inv = Inventory.new()
	var result = inv.add_item("herb_soup", 60, 0)
	_assert_eq(result, Inventory.ADD_OK, "添加 60 個應成功")

	var slot0 = inv.get_slot(0)
	_assert_eq(slot0.get("count", -1), 30, "第 0 格應有 30 個")

	var slot1 = inv.get_slot(1)
	_assert_eq(slot1.get("count", -1), 30, "第 1 格應有 30 個")

	for i in range(2, inv.SIZE):
		if not inv.get_slot(i).is_empty():
			_failed = true
			_message = "第 %d 格應保持空白，卻有物品" % i


func test_full_inventory_rejection() -> void:
	# 驗證背包滿載時拒絕新增（36 格 × 30 = 1080）
	var inv = Inventory.new()
	var result = inv.add_item("bread", 1080)
	_assert_eq(result, Inventory.ADD_OK, "應能填滿背包")

	result = inv.add_item("bread", 1)
	_assert_eq(result, Inventory.ADD_NO_SPACE, "滿載時應返回 ADD_NO_SPACE")

	var total = inv.count_item("bread")
	_assert_eq(total, 1080, "失敗時不應改變內容")


func test_decay_tolerance_respects_cap() -> void:
	# 驗證衰腐容差範圍內會合併進未滿的既有格（同時尊重上限）
	var inv = Inventory.new()
	inv.add_item("bread", 25, 10)
	var result = inv.add_item("bread", 5, 15)  # decay 差 5，容差內，第 0 格還有空間
	_assert_eq(result, Inventory.ADD_OK, "容差範圍內應合併進第 0 格")

	var slot0 = inv.get_slot(0)
	_assert_eq(slot0.get("count", -1), 30, "第 0 格應合併為 30")
	_assert_eq(slot0.get("decay", -1), 15, "第 0 格 decay 應取較高值 15")

	var slot1 = inv.get_slot(1)
	_assert_eq(slot1.is_empty(), true, "第 1 格應保持空白")


func test_atomicity_on_failure() -> void:
	# 驗證失敗時的原子性：剩餘容量 30（1 個空格），新增 31 個應整批失敗，
	# 而不是先佔滿那 30 個空間才發現還差 1 個
	var inv = Inventory.new()
	inv.add_item("bread", 1050)  # 35 格滿，剩 1 個空格（30 容量）

	var snapshot: Array[Dictionary] = []
	for i in range(inv.SIZE):
		snapshot.append(inv.get_slot(i))

	var result = inv.add_item("bread", 31)
	_assert_eq(result, Inventory.ADD_NO_SPACE, "超出剩餘容量應失敗")

	for i in range(inv.SIZE):
		if inv.get_slot(i) != snapshot[i]:
			_failed = true
			_message = "第 %d 格在失敗後被改動" % i


# 測試輔助方法
func _assert_eq(actual: Variant, expected: Variant, message: String) -> void:
	_assertion_count += 1
	if actual != expected:
		_failed = true
		_message = "%s（實際：%s，預期：%s）" % [message, actual, expected]
