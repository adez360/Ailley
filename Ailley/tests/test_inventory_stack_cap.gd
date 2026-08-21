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
	# 驗證 60 個物品分配到 2 格
	var inv = Inventory.new()
	var result = inv.add_item("herb_soup", 60, 0)
	_assert_eq(result, Inventory.ADD_OK, "添加 60 個應成功")

	var total = inv.count_item("herb_soup")
	_assert_eq(total, 60, "總數應是 60 個")

	# 驗證每格都不超過 30 個
	for i in range(inv.SIZE):
		var s = inv.get_slot(i)
		if not s.is_empty():
			if s.get("count", 0) > 30:
				_failed = true
				_message = "第 %d 格超過 30 個: %d" % [i, s["count"]]


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
	# 驗證衰腐容差範圍內的堆疊（同時尊重上限）
	var inv = Inventory.new()
	inv.add_item("bread", 30, 10)
	var result = inv.add_item("bread", 5, 15)  # decay 差 5，容差內
	_assert_eq(result, Inventory.ADD_OK, "容差範圍應堆疊或開新格")

	var slot0 = inv.get_slot(0)
	_assert_eq(slot0.get("count", -1), 30, "第 0 格應保持 30")

	var slot1 = inv.get_slot(1)
	_assert_eq(slot1.get("count", -1), 5, "第 1 格應有 5 個")


func test_atomicity_on_failure() -> void:
	# 驗證失敗時的原子性
	var inv = Inventory.new()
	inv.add_item("bread", 1080)

	var snapshot = inv.get_slot(0).duplicate()
	var result = inv.add_item("bread", 50)
	_assert_eq(result, Inventory.ADD_NO_SPACE, "超容量應失敗")

	var after = inv.get_slot(0)
	if snapshot != after:
		_failed = true
		_message = "失敗時不應改動任何格"


# 測試輔助方法
func _assert_eq(actual: Variant, expected: Variant, message: String) -> void:
	_assertion_count += 1
	if actual != expected:
		_failed = true
		_message = "%s（實際：%s，預期：%s）" % [message, actual, expected]
