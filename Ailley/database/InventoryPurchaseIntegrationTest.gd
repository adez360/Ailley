extends Node

## =====================================================
## InventoryPurchaseIntegrationTest
##
## 這一輪只驗證：
##
##   VendingMachine
##       ↓
##   Character.buy_from()
##       ↓
##   Inventory.add_item()
##       ↓
##   Inventory.slots
##       ↓
##   Inventory.changed
##       ↓
##   CharacterStatePersistence
##       ↓
##   npc_inventory
##
## 不修改正式 Inventory / CharacterStatePersistence。
## 先把「購買後為什麼 SAVE 0 slot」隔離出來。
##
## 使用：
##   在正常遊戲場景新增 Node，
##   掛本腳本後執行。
##
## 測試會直接呼叫目前遊戲中的 Player：
##   add_item("bread", 1)
##   add_item("water", 1)
##
## 再嘗試透過附近販賣機：
##   buy_from(machine, "bread")
##   buy_from(machine, "water")
##
## 最後讀 SQLite npc_inventory。
## =====================================================


var passed := 0
var failed := 0
var skipped := 0


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	print("")
	print("=====================================================")
	print("[InventoryPurchaseIntegrationTest] START")
	print("=====================================================")

	while not DatabaseManager.is_ready:
		await get_tree().process_frame

	var character := _find_player()

	if character == null:
		_fail(
			"Player",
			"找不到 player group 的 Character。"
		)
		_finish()
		return

	if character.inventory == null:
		_fail(
			"Inventory",
			"Player 沒有 Inventory。"
		)
		_finish()
		return

	print(
		"[TEST] Player = %s | id = %s"
		% [
			character.character_name,
			character.character_id
		]
	)

	# -------------------------------------------------
	# 1. 直接測 Inventory.add_item()
	# -------------------------------------------------

	var bread_before := character.inventory.count_item("bread")
	var water_before := character.inventory.count_item("water")
	var money_before := character.inventory.get_money()

	print(
		"[TEST] add_item 前：bread=%d water=%d money=%d"
		% [
			bread_before,
			water_before,
			money_before
		]
	)

	var bread_result := character.inventory.add_item(
		"bread",
		1
	)

	print(
		"[TEST] add_item bread result = %s"
		% bread_result
	)

	var bread_after := character.inventory.count_item("bread")

	if bread_after == bread_before + 1:
		_pass(
			"Inventory.add_item bread"
		)
	else:
		_fail(
			"Inventory.add_item bread",
			"預期 %d，實際 %d"
			% [
				bread_before + 1,
				bread_after
			]
		)

	var water_result := character.inventory.add_item(
		"water",
		1
	)

	print(
		"[TEST] add_item water result = %s"
		% water_result
	)

	var water_after := character.inventory.count_item("water")

	if water_after == water_before + 1:
		_pass(
			"Inventory.add_item water"
		)
	else:
		_fail(
			"Inventory.add_item water",
			"預期 %d，實際 %d"
			% [
				water_before + 1,
				water_after
			]
		)

	# -------------------------------------------------
	# 2. 印出實際 slots
	# -------------------------------------------------

	_print_inventory(character)

	# -------------------------------------------------
	# 3. 等 changed / Persistence 完成一個 frame
	# -------------------------------------------------

	await get_tree().process_frame

	# -------------------------------------------------
	# 4. 直接讀 SQLite
	# -------------------------------------------------

	var db_rows := DatabaseManager.select(
		"npc_inventory",
		"npc_id = '%s'"
		% _escape_sql(character.character_id),
		[
			"slot",
			"item_id",
			"count",
			"decay",
			"durability"
		]
	)

	print(
		"[TEST] SQLite npc_inventory rows = %d"
		% db_rows.size()
	)

	for row in db_rows:
		print(
			"[TEST][DB] slot=%s item=%s count=%s decay=%s durability=%s"
			% [
				str(row.get("slot", "")),
				str(row.get("item_id", "")),
				str(row.get("count", "")),
				str(row.get("decay", "")),
				str(row.get("durability", ""))
			]
		)

	if _db_has_item(
		db_rows,
		"bread"
	):
		_pass(
			"SQLite bread"
		)
	else:
		_fail(
			"SQLite bread",
			"runtime 有 bread，但 npc_inventory 找不到。"
		)

	if _db_has_item(
		db_rows,
		"water"
	):
		_pass(
			"SQLite water"
		)
	else:
		_fail(
			"SQLite water",
			"runtime 有 water，但 npc_inventory 找不到。"
		)

	# -------------------------------------------------
	# 5. 測試實際販賣機
	# -------------------------------------------------

	var machine := _find_nearest_vending_machine(
		character
	)

	if machine == null:
		_skip(
			"Character.buy_from",
			"找不到範圍內販賣機，跳過 buy_from() 測試。"
		)
	else:
		print(
			"[TEST] 找到販賣機：%s"
			% machine.name
		)

		var machine_money_before := (
			character.inventory.get_money()
		)

		var result_bread := character.buy_from(
			machine,
			"bread"
		)

		print(
			"[TEST] buy bread result = %s"
			% result_bread
		)

		if result_bread == Character.BUY_OK:
			_pass(
				"Character.buy_from bread"
			)
		else:
			_fail(
				"Character.buy_from bread",
				"result=%s"
				% result_bread
			)

		var result_water := character.buy_from(
			machine,
			"water"
		)

		print(
			"[TEST] buy water result = %s"
			% result_water
		)

		if result_water == Character.BUY_OK:
			_pass(
				"Character.buy_from water"
			)
		else:
			_fail(
				"Character.buy_from water",
				"result=%s"
				% result_water
			)

		print(
			"[TEST] money：%d -> %d"
			% [
				machine_money_before,
				character.inventory.get_money()
			]
		)

		_print_inventory(character)

		await get_tree().process_frame

		var purchase_rows := DatabaseManager.select(
			"npc_inventory",
			"npc_id = '%s'"
			% _escape_sql(character.character_id),
			[
				"slot",
				"item_id",
				"count",
				"decay",
				"durability"
			]
		)

		print(
			"[TEST] 購買後 SQLite rows = %d"
			% purchase_rows.size()
		)

		for row in purchase_rows:
			print(
				"[TEST][PURCHASE DB] slot=%s item=%s count=%s"
				% [
					str(row.get("slot", "")),
					str(row.get("item_id", "")),
					str(row.get("count", ""))
				]
			)

		# 驗證購買後的資料
		var purchased_bread_count := _db_count_item(purchase_rows, "bread")
		var purchased_water_count := _db_count_item(purchase_rows, "water")

		if purchased_bread_count >= 1:
			_pass("購買後 SQLite bread 數量")
		else:
			_fail(
				"購買後 SQLite bread",
				"預期至少 1，實際 %d" % purchased_bread_count
			)

		if purchased_water_count >= 1:
			_pass("購買後 SQLite water 數量")
		else:
			_fail(
				"購買後 SQLite water",
				"預期至少 1，實際 %d" % purchased_water_count
			)

	# -------------------------------------------------
	# 清理測試資料
	# -------------------------------------------------

	_cleanup_test_data(character, bread_before, water_before, money_before)

	# -------------------------------------------------
	# 結果
	# -------------------------------------------------

	_finish()


func _find_player() -> Character:
	for node in get_tree().get_nodes_in_group("characters"):
		var character := node as Character

		if character == null:
			continue

		if character.is_in_group("player"):
			return character

	return null


func _find_nearest_vending_machine(
	character: Character
) -> VendingMachine:

	var nearest: VendingMachine = null
	var shortest := Character.BUY_RANGE

	for node in get_tree().get_nodes_in_group(
		"vending_machines"
	):
		var machine := node as VendingMachine

		if machine == null:
			continue

		var distance := (
			character.get_body_position()
			.distance_to(machine.global_position)
		)

		if distance <= shortest:
			shortest = distance
			nearest = machine

	return nearest


func _print_inventory(
	character: Character
) -> void:

	print(
		"[TEST] Runtime inventory："
		+ "money=%d"
		% character.inventory.get_money()
	)

	var found := 0

	for i in character.inventory.SIZE:
		var slot: Dictionary = (
			character.inventory.get_slot(i)
		)

		if slot.is_empty():
			continue

		found += 1

		print(
			"[TEST][RUNTIME] slot=%d item=%s count=%s decay=%s durability=%s"
			% [
				i,
				str(slot.get("item_id", "")),
				str(slot.get("count", "")),
				str(slot.get("decay", "")),
				str(slot.get("durability", ""))
			]
		)

	print(
		"[TEST] Runtime occupied slots = %d"
		% found
	)


func _db_has_item(
	rows: Array,
	item_id: String
) -> bool:

	for row in rows:
		if str(
			row.get(
				"item_id",
				""
			)
		) == item_id:
			return true

	return false


func _db_count_item(
	rows: Array,
	item_id: String
) -> int:

	var total := 0

	for row in rows:
		if str(row.get("item_id", "")) == item_id:
			total += int(row.get("count", 0))

	return total


func _pass(label: String) -> void:
	passed += 1
	print("[PASS] %s" % label)


func _fail(
	label: String,
	message: String
) -> void:
	failed += 1
	push_error(
		"[FAIL] %s: %s"
		% [
			label,
			message
		]
	)


func _skip(
	label: String,
	message: String
) -> void:
	skipped += 1
	print("[SKIP] %s: %s" % [label, message])


func _finish() -> void:
	print("")
	print("=====================================================")
	print("[InventoryPurchaseIntegrationTest] RESULT")
	print("=====================================================")
	print("PASS: ", passed)
	print("FAIL: ", failed)
	print("SKIP: ", skipped)

	if failed == 0 and skipped == 0:
		print(
			"[InventoryPurchaseIntegrationTest] "
			+ "INVENTORY PURCHASE PIPELINE PASSED"
		)
	elif failed == 0:
		print(
			"[InventoryPurchaseIntegrationTest] "
			+ "%d test(s) skipped — coverage incomplete."
			% skipped
		)
	else:
		push_error(
			"[InventoryPurchaseIntegrationTest] "
			+ "%d test(s) failed."
			% failed
		)

	print("=====================================================")

	queue_free()


func _cleanup_test_data(
	character: Character,
	bread_before: int,
	water_before: int,
	money_before: int
) -> void:
	if character == null or character.inventory == null:
		return

	# 移除測試新增的 bread 和 water
	var bread_current := character.inventory.count_item("bread")
	var water_current := character.inventory.count_item("water")

	if bread_current > bread_before:
		character.inventory.remove_item("bread", bread_current - bread_before)

	if water_current > water_before:
		character.inventory.remove_item("water", water_current - water_before)

	# 還原金錢
	var money_current := character.inventory.get_money()
	if money_current < money_before:
		character.inventory.add_money(money_before - money_current)
	elif money_current > money_before:
		character.inventory.spend(money_current - money_before)

	# 等待 persistence 完成
	await get_tree().process_frame

	print(
		"[TEST] 測試資料已清理：bread=%d->%d water=%d->%d money=%d->%d"
		% [
			bread_current,
			character.inventory.count_item("bread"),
			water_current,
			character.inventory.count_item("water"),
			money_current,
			character.inventory.get_money()
		]
	)


func _escape_sql(
	value: String
) -> String:
	return value.replace(
		"'",
		"''"
	)
