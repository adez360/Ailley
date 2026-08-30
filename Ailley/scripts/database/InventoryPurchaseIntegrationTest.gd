extends Node

## =====================================================
## InventoryPurchaseIntegrationTest
##
## 這一輪只驗證：
##
##   Character.buy_from()（商店綁地點，見 world/shop.gd，issue #572）
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
## 再嘗試透過附近商店（bread／water 都在 tavern 目錄）：
##   buy_from("tavern", "bread")
##   buy_from("tavern", "water")
##
## 最後讀 SQLite npc_inventory。
## =====================================================


var passed := 0
var failed := 0
var skipped := 0

const INVENTORY_SYNC_TIMEOUT_FRAMES := 60


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	print("")
	print("=====================================================")
	print("[InventoryPurchaseIntegrationTest] START")
	print("=====================================================")

	var ready_wait_frames := 0
	const READY_WAIT_TIMEOUT_FRAMES := 300

	while not DatabaseManager.is_seeded:
		ready_wait_frames += 1
		if ready_wait_frames > READY_WAIT_TIMEOUT_FRAMES:
			_fail(
				"DatabaseManager.is_seeded",
				"等待逾時（%d frames），資料庫可能初始化失敗" % READY_WAIT_TIMEOUT_FRAMES
			)
			_finish()
			return
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
	# 3. 等 changed / Persistence 完成
	#
	# CharacterStatePersistence 用 call_deferred() 排程寫入，
	# 不保證落在固定幀數內完成，所以用 poll 等到真的存完，
	# 不要用猜測的 await frame 次數。
	# -------------------------------------------------

	await _wait_for_inventory_sync()

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

	var db_bread_count := _db_count_item(db_rows, "bread")

	if db_bread_count == bread_after:
		_pass(
			"SQLite bread 數量"
		)
	else:
		_fail(
			"SQLite bread 數量",
			"runtime %d，npc_inventory %d" % [bread_after, db_bread_count]
		)

	var db_water_count := _db_count_item(db_rows, "water")

	if db_water_count == water_after:
		_pass(
			"SQLite water 數量"
		)
	else:
		_fail(
			"SQLite water 數量",
			"runtime %d，npc_inventory %d" % [water_after, db_water_count]
		)

	# -------------------------------------------------
	# 5. 測試實際商店（issue #572：商店綁地點，不是機台節點）
	# -------------------------------------------------

	var shop_place := _find_nearby_shop_place(
		character
	)

	if shop_place.is_empty():
		_skip(
			"Character.buy_from",
			"不在任何商店地點的 BUY_RANGE 內，跳過 buy_from() 測試。"
		)
	else:
		print(
			"[TEST] 找到商店地點：%s"
			% shop_place
		)

		var machine_money_before := (
			character.inventory.get_money()
		)

		var result_bread := character.buy_from(
			shop_place,
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
			shop_place,
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

		var runtime_bread_after_purchase := character.inventory.count_item("bread")
		var runtime_water_after_purchase := character.inventory.count_item("water")

		await _wait_for_inventory_sync()

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

		# 驗證購買後的資料：跟購買完成當下的 runtime 數量逐項比對，
		# 不只看「有沒有這個 item_id」，避免漏寫入的 diff 被掩蓋
		var purchased_bread_count := _db_count_item(purchase_rows, "bread")
		var purchased_water_count := _db_count_item(purchase_rows, "water")

		if purchased_bread_count == runtime_bread_after_purchase:
			_pass("購買後 SQLite bread 數量")
		else:
			_fail(
				"購買後 SQLite bread",
				"runtime %d，npc_inventory %d"
				% [runtime_bread_after_purchase, purchased_bread_count]
			)

		if purchased_water_count == runtime_water_after_purchase:
			_pass("購買後 SQLite water 數量")
		else:
			_fail(
				"購買後 SQLite water",
				"runtime %d，npc_inventory %d"
				% [runtime_water_after_purchase, purchased_water_count]
			)

	# -------------------------------------------------
	# 清理測試資料
	# -------------------------------------------------

	await _cleanup_test_data(character, bread_before, water_before, money_before)

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


## 商店不再是場景物件（issue #572），直接對 Shop.CATALOGS 的每個地點各查一次
## 距離，跟 player.gd::_nearest_shop_place() 同一套判斷，只是這裡不檢查面向——
## 這支腳本是手動掛上去跑的診斷工具，不是玩家操作路徑
func _find_nearby_shop_place(
	character: Character
) -> String:

	var anchors := get_tree().get_first_node_in_group("place_anchors")
	if anchors == null:
		return ""

	var nearest := ""
	var shortest := Character.BUY_RANGE

	for place in Shop.CATALOGS:
		if not anchors.has(place):
			continue

		var distance := (
			character.get_body_position()
			.distance_to(anchors.resolve(place))
		)

		if distance <= shortest:
			shortest = distance
			nearest = place

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


## 等到 CharacterStatePersistence 的 deferred inventory SAVE 真正跑完，
## 而不是賭固定幀數——call_deferred() 何時真正執行不保證落在單一幀內，
## 單次 await process_frame 可能在 SAVE 完成前就繼續，讓後面的 SELECT
## 斷言間歇性失敗。逾時時明確呼叫 _fail()——原本想讓後面的 SELECT 斷言
## 自然失敗，但 _cleanup_test_data() 這條路徑逾時後不會再做任何斷言，
## 且 _run() 的購買後斷言只檢查「至少一筆」，逾時後可能被同一張表裡
## 舊資料矇混過去，兩者都不保證逾時會被觀察到。
func _wait_for_inventory_sync() -> void:

	var persistence := DatabaseManager.get_node_or_null(
		"CharacterStatePersistence"
	)

	if persistence == null or not persistence.has_method("has_pending_inventory_sync"):
		_fail(
			"CharacterStatePersistence 不存在",
			"找不到 CharacterStatePersistence node 或缺少 "
			+ "has_pending_inventory_sync()，無法確認 inventory 是否已同步"
		)
		return

	var frames := 0

	while (
		persistence.has_pending_inventory_sync()
		and frames < INVENTORY_SYNC_TIMEOUT_FRAMES
	):
		await get_tree().process_frame
		frames += 1

	if persistence.has_pending_inventory_sync():
		_fail(
			"庫存同步逾時",
			"等待 %d frame 後 CharacterStatePersistence 仍有未完成的 inventory sync"
			% INVENTORY_SYNC_TIMEOUT_FRAMES
		)


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
	await _wait_for_inventory_sync()

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
