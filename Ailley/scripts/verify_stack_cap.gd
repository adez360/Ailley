#!/usr/bin/env -S godot --headless --path . -s
## 驗證 30 個堆疊上限的獨立測試腳本
## 用法：godot --headless --path . -s scripts/verify_stack_cap.gd

extends SceneTree

func _initialize() -> void:
	# 直接執行驗證，避免等待場景載入
	await process_frame
	verify_all()
	quit()

func verify_all() -> void:
	print("=== 堆疊數量上限驗證 ===\n")

	# 測試 1：單格 30 個上限
	print("Test 1: 單格 30 個上限")
	var inv = Inventory.new()
	var result = inv.add_item("bread", 30)
	assert(result == Inventory.ADD_OK, "添加 30 個應成功")
	var slot = inv.get_slot(0)
	assert(slot["count"] == 30, "第 0 格應有 30 個")
	print("✓ 單格能放 30 個\n")

	# 測試 2：超過 30 個時開新格
	print("Test 2: 超過上限開新格")
	result = inv.add_item("bread", 1)
	assert(result == Inventory.ADD_OK, "添加第 31 個應成功但開新格")
	slot = inv.get_slot(0)
	assert(slot["count"] == 30, "第 0 格應維持 30 個")
	var slot1 = inv.get_slot(1)
	assert(slot1["count"] == 1, "第 1 格應有 1 個")
	print("✓ 第 31 個物品開新格\n")

	# 測試 3：大量物品分配到多個格
	print("Test 3: 60 個物品分配到 2 格")
	inv = Inventory.new()
	result = inv.add_item("herb_soup", 60, 0)
	assert(result == Inventory.ADD_OK, "添加 60 個應成功")
	var total = inv.count_item("herb_soup")
	assert(total == 60, "總數應是 60")

	# 驗證每格都不超過 30
	var max_in_slot = 0
	for i in range(inv.SIZE):
		var s = inv.get_slot(i)
		if not s.is_empty():
			if s["count"] > max_in_slot:
				max_in_slot = s["count"]
			assert(s["count"] <= 30, "第 %d 格超過 30 個: %d" % [i, s["count"]])
	print("✓ 60 個物品分配正確，最大格: %d 個\n" % max_in_slot)

	# 測試 4：背包滿載 (36 格 × 30 = 1080)
	print("Test 4: 背包滿載測試")
	inv = Inventory.new()
	result = inv.add_item("bread", 1080)
	assert(result == Inventory.ADD_OK, "應能添加 1080 個填滿背包")
	result = inv.add_item("bread", 1)
	assert(result == Inventory.ADD_NO_SPACE, "應返回 ADD_NO_SPACE")
	print("✓ 滿載時正確返回 ADD_NO_SPACE\n")

	# 測試 5：衰腐容差範圍內堆疊（同時尊重上限）
	print("Test 5: 衰腐容差範圍內的堆疊")
	inv = Inventory.new()
	result = inv.add_item("bread", 30, 10)
	assert(result == Inventory.ADD_OK)
	result = inv.add_item("bread", 5, 15)  # decay 差 5，在容差 10 內
	assert(result == Inventory.ADD_OK, "衰腐容差內應堆疊或開新格")
	slot = inv.get_slot(0)
	assert(slot["count"] == 30, "第 0 格應保持 30（已滿）")
	slot1 = inv.get_slot(1)
	assert(slot1["count"] == 5, "新格應有 5 個")
	print("✓ 容差範圍內正確堆疊或開新格\n")

	# 測試 6：失敗的原子性
	print("Test 6: 失敗時的原子性")
	inv = Inventory.new()
	inv.add_item("bread", 1080)
	var snapshot = inv.get_slot(0).duplicate()
	result = inv.add_item("bread", 50)
	assert(result == Inventory.ADD_NO_SPACE, "超過容量應失敗")
	var after = inv.get_slot(0)
	assert(after == snapshot, "失敗時不應改動任何格")
	print("✓ 失敗時保持原子性\n")

	print("=== 所有測試通過 ✓ ===")
