extends GutTest

func test_add_stackable_respects_30_item_cap() -> void:
	var inventory := Inventory.new()

	# 添加 30 个物品到一格 —— 应该成功
	var result = inventory.add_item("bread", 30)
	assert_eq(result, Inventory.ADD_OK, "添加 30 个物品应该成功")

	var slot = inventory.get_slot(0)
	assert_eq(slot["count"], 30, "第 0 格应该有 30 个物品")

	# 再添加 1 个 —— 应该开新格，不会超过 30 个
	result = inventory.add_item("bread", 1)
	assert_eq(result, Inventory.ADD_OK, "添加第 31 个物品应该打开新格")

	var slot1 = inventory.get_slot(1)
	assert_eq(slot1["count"], 1, "第 1 格应该有 1 个物品")
	assert_eq(slot["count"], 30, "第 0 格仍应该有 30 个物品（未更改）")

	# 测试：添加超过一个格子容量的物品
	result = inventory.add_item("herb_soup", 60, 0)
	assert_eq(result, Inventory.ADD_OK, "添加 60 个物品应该成功（占用 2 格）")

	# 找到这些物品的位置
	var soup_count = inventory.count_item("herb_soup")
	assert_eq(soup_count, 60, "物品总数应该是 60")

	# 验证每一格都不超过 30 个
	for i in range(inventory.SIZE):
		var s = inventory.get_slot(i)
		if not s.is_empty():
			assert_le(s["count"], 30, "第 %d 格的物品数不应超过 30" % i)

func test_stack_cap_with_decay_tolerance() -> void:
	var inventory := Inventory.new()

	# 添加一格有 30 个、decay=10 的食物
	var result = inventory.add_item("bread", 30, 10)
	assert_eq(result, Inventory.ADD_OK)

	# 尝试添加 decay=15 的面包（差距是 5，在容差 10 以内）
	# 应该能堆进同一格，但由于格子已满，应该打开新格
	result = inventory.add_item("bread", 5, 15)
	assert_eq(result, Inventory.ADD_OK, "decay 容差范围内应该尝试同一格，但满了应该打开新格")

	var slot0 = inventory.get_slot(0)
	assert_eq(slot0["count"], 30, "第 0 格应该维持 30 个")

	var slot1 = inventory.get_slot(1)
	assert_eq(slot1["count"], 5, "第 1 格应该有新的 5 个")
	assert_eq(slot1["decay"], 15, "新格的 decay 应该是 15")

func test_no_space_when_cap_filled() -> void:
	var inventory := Inventory.new()

	# 填满整个背包，每格都是 30 个
	# 背包共 36 格，每格 30 个 = 1080 个总容量
	var result = inventory.add_item("bread", 1080)
	assert_eq(result, Inventory.ADD_OK, "应该能添加 1080 个物品填满背包")

	# 现在再加 1 个应该失败
	result = inventory.add_item("bread", 1)
	assert_eq(result, Inventory.ADD_NO_SPACE, "没有空间应该返回 ADD_NO_SPACE")

	# 背包内容应该不变
	var total = inventory.count_item("bread")
	assert_eq(total, 1080, "失败时背包内容应该不变")

func test_atomicity_on_stack_cap_failure() -> void:
	var inventory := Inventory.new()

	# 添加 36 格 × 30 个 = 1080
	inventory.add_item("bread", 1080)

	# 标记一个已知的格子状态
	var slot0_before = inventory.get_slot(0).duplicate()

	# 尝试添加超过容量的物品，应该失败且不改动任何格
	var result = inventory.add_item("bread", 50)
	assert_eq(result, Inventory.ADD_NO_SPACE, "应该失败")

	var slot0_after = inventory.get_slot(0)
	assert_eq(slot0_after, slot0_before, "失败时不应该改动任何格")
