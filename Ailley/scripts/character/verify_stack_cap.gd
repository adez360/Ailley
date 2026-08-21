#!/usr/bin/env -S godot --headless --path . -s
## 驗證 30 個堆疊上限的獨立測試腳本
## 用法：godot --headless --path . -s scripts/character/verify_stack_cap.gd

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

	# 測試 3：大量物品精確分配到 2 格
	print("Test 3: 60 個物品分配到 2 格")
	inv = Inventory.new()
	result = inv.add_item("herb_soup", 60, 0)
	assert(result == Inventory.ADD_OK, "添加 60 個應成功")
	var slot_a = inv.get_slot(0)
	assert(slot_a["count"] == 30, "第 0 格應有 30 個")
	var slot_b = inv.get_slot(1)
	assert(slot_b["count"] == 30, "第 1 格應有 30 個")
	for i in range(2, inv.SIZE):
		assert(inv.get_slot(i).is_empty(), "第 %d 格應保持空白" % i)
	print("✓ 60 個物品精確分配到第 0、1 格各 30 個\n")

	# 測試 4：背包滿載 (36 格 × 30 = 1080)
	print("Test 4: 背包滿載測試")
	inv = Inventory.new()
	result = inv.add_item("bread", 1080)
	assert(result == Inventory.ADD_OK, "應能添加 1080 個填滿背包")
	result = inv.add_item("bread", 1)
	assert(result == Inventory.ADD_NO_SPACE, "應返回 ADD_NO_SPACE")
	print("✓ 滿載時正確返回 ADD_NO_SPACE\n")

	# 測試 5：衰腐容差範圍內合併進未滿的既有格（同時尊重上限）
	print("Test 5: 衰腐容差範圍內的堆疊")
	inv = Inventory.new()
	result = inv.add_item("bread", 25, 10)
	assert(result == Inventory.ADD_OK)
	result = inv.add_item("bread", 5, 15)  # decay 差 5，在容差 10 內，第 0 格還有空間
	assert(result == Inventory.ADD_OK, "衰腐容差內應合併進第 0 格")
	slot = inv.get_slot(0)
	assert(slot["count"] == 30, "第 0 格應合併為 30")
	assert(slot["decay"] == 15, "第 0 格 decay 應取較高值 15")
	slot1 = inv.get_slot(1)
	assert(slot1.is_empty(), "第 1 格應保持空白")
	print("✓ 容差範圍內正確合併進既有格\n")

	# 測試 6：失敗的原子性（剩餘容量 30，新增 31 應整批失敗）
	print("Test 6: 失敗時的原子性")
	inv = Inventory.new()
	inv.add_item("bread", 1050)  # 35 格滿，剩 1 個空格（30 容量）
	var snapshot: Array[Dictionary] = []
	for i in range(inv.SIZE):
		snapshot.append(inv.get_slot(i))
	result = inv.add_item("bread", 31)
	assert(result == Inventory.ADD_NO_SPACE, "超出剩餘容量應失敗")
	for i in range(inv.SIZE):
		assert(inv.get_slot(i) == snapshot[i], "第 %d 格在失敗後被改動" % i)
	print("✓ 失敗時保持原子性\n")

	print("=== 所有測試通過 ✓ ===")
