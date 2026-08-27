extends Node

## =====================================================
## DatabaseCRUDTest
##
## SQLite Schema 對齊清單 §5 第 2 步：
## 26 張 SQLite table 各 INSERT 一筆、SELECT 一筆，
## 並額外驗證 DatabaseManager 的 UPDATE / DELETE。
##
## 使用方式：
## 1. 將本檔放到：
##      res://scripts/database/DatabaseCRUDTest.gd
## 2. 建立一個暫時測試場景：
##      Node
##        └── DatabaseCRUDTest
## 3. 將本腳本掛在 DatabaseCRUDTest。
## 4. 確認 DatabaseManager 是 Autoload。
## 5. 測試前刪除 DatabaseManager.DATABASE_PATH 指向的資料庫檔案
##    （檔名依 checkout 算 hash，見 DatabaseManager.gd）。
## 6. 執行測試場景。
##
## 注意：
## - 不修改任何正式 Schema。
## - 不使用 DatabaseSeeder 建立測試資料。
## - 測試資料全部使用 __crud_test_ 前綴。
## - 測試結束會清掉自己建立的資料。
## - 26 張表 = 25 個 Schema class + MemorySchema 額外建立的
##   memory_related_npcs。
## =====================================================

const PREFIX := "__crud_test_"

const LOCATION_A := PREFIX + "location_a"
const LOCATION_B := PREFIX + "location_b"

const NPC_A := PREFIX + "npc_a"
const NPC_B := PREFIX + "npc_b"

const ITEM_A := PREFIX + "item_a"

const MEMORY_A := PREFIX + "memory_a"


var passed := 0
var failed := 0


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	# 等 DatabaseManager._ready() 完成並建立全部 Schema。
	while not DatabaseManager.is_ready:
		await get_tree().process_frame

	print("")
	print("=====================================================")
	print("[DatabaseCRUDTest] START")
	print("=====================================================")

	_cleanup_test_data()

	var ok := true

	# -------------------------------------------------
	# 基礎父資料
	# -------------------------------------------------

	ok = _test_insert_select(
		"location",
		LOCATION_A,
		{
			"location_id": LOCATION_A,
			"name": "CRUD測試地點A",
			"description": "SQLite CRUD test",
			"location_type": "test",
			"capacity": 10,
			"danger": 5,
			"is_active": 1
		},
		"location_id"
	) and ok

	ok = _test_insert_select(
		"location",
		LOCATION_B,
		{
			"location_id": LOCATION_B,
			"name": "CRUD測試地點B",
			"description": "SQLite CRUD test",
			"location_type": "test",
			"capacity": 10,
			"danger": 0,
			"is_active": 1
		},
		"location_id"
	) and ok

	ok = _test_insert_select(
		"item",
		ITEM_A,
		{
			"item_id": ITEM_A,
			"name": "CRUD測試物品",
			"item_type": "misc",
			"description": "SQLite CRUD test",
			"base_price": 1,
			"max_stack": 30,
			"is_consumable": 0,
			"is_perishable": 0,
			"decay_rate": 0,
			"durability_cost": 0,
			"effect_satiety": 0,
			"effect_hydration": 0,
			"effect_alcohol": 0,
			"effect_injury": 0,
			"is_active": 1
		},
		"item_id"
	) and ok

	ok = _test_insert_select(
		"npc",
		NPC_A,
		{
			"npc_id": NPC_A,
			"name": "測試甲",
			"age": 30,
			"gender": "other",
			"village_id": "default_village",
			"character": "SQLite CRUD test",
			"reputation": 0,
			"system_prompt": "",
			"words_to_creator": "測試",
			"is_spoken": 0,
			"home_location_id": LOCATION_A,
			"decision_source": "local",
			"model_name": "CRUDTest",
			"is_active": 1
		},
		"npc_id"
	) and ok

	ok = _test_insert_select(
		"npc",
		NPC_B,
		{
			"npc_id": NPC_B,
			"name": "測試乙",
			"age": 30,
			"gender": "other",
			"village_id": "default_village",
			"character": "SQLite CRUD test",
			"reputation": 0,
			"system_prompt": "",
			"words_to_creator": "測試",
			"is_spoken": 0,
			"home_location_id": LOCATION_B,
			"decision_source": "local",
			"model_name": "CRUDTest",
			"is_active": 1
		},
		"npc_id"
	) and ok

	# -------------------------------------------------
	# 1. npc_state
	# -------------------------------------------------

	ok = _test_insert_select(
		"npc_state",
		NPC_A,
		{
			"npc_id": NPC_A,
			"satiety": 100,
			"hydration": 80,
			"stamina": 80,
			"wakefulness": 90,
			"hygiene": 70,
			"alcohol": 0,
			"health": 100,
			"injury": 0,
			"location_id": LOCATION_A
		},
		"npc_id"
	) and ok

	# -------------------------------------------------
	# 2. npc_schedule
	# -------------------------------------------------

	ok = _test_insert_select(
		"npc_schedule",
		"schedule",
		{
			"npc_id": NPC_A,
			"start_time": "08:00",
			"end_time": "09:00",
			"location_id": LOCATION_A,
			"action": "測試"
		},
		"npc_id"
	) and ok

	# -------------------------------------------------
	# 3. npc_personality
	# -------------------------------------------------

	ok = _test_insert_select(
		"npc_personality",
		NPC_A,
		{"npc_id": NPC_A},
		"npc_id"
	) and ok

	# -------------------------------------------------
	# 4. npc_appearance
	# -------------------------------------------------

	ok = _test_insert_select(
		"npc_appearance",
		NPC_A,
		{
			"npc_id": NPC_A,
			"hair_id": "test_hair",
			"face_id": "test_face",
			"clothes_id": "test_clothes",
			"decoration1_id": "",
			"decoration2_id": ""
		},
		"npc_id"
	) and ok

	# -------------------------------------------------
	# 5. npc_occupation
	# -------------------------------------------------

	ok = _test_insert_select(
		"npc_occupation",
		NPC_A,
		{
			"npc_id": NPC_A,
			"occupation": "tester",
			"occupation_level": 1,
			"workplace_id": LOCATION_A,
			"work_start_time": "09:00",
			"work_end_time": "17:00",
			"salary": 0,
			"working_days": "all",
			"occupation_description": "SQLite CRUD test",
			"is_employed": 0
		},
		"npc_id"
	) and ok

	# -------------------------------------------------
	# 6. npc_taboo
	# -------------------------------------------------

	ok = _test_insert_select(
		"npc_taboo",
		"taboo",
		{
			"npc_id": NPC_A,
			"taboo_type": "test",
			"description": "測試禁忌",
			"severity": 50,
			"is_active": 1
		},
		"npc_id"
	) and ok

	# -------------------------------------------------
	# 7. npc_emotion
	# -------------------------------------------------

	ok = _test_insert_select(
		"npc_emotion",
		NPC_A,
		{
			"npc_id": NPC_A,
			"emotion": "neutral",
			"intensity": 0,
			"cause_event_id": "evt_crud_test",
			"duration_left": 0
		},
		"npc_id"
	) and ok

	# -------------------------------------------------
	# 8. npc_condition
	# -------------------------------------------------

	ok = _test_insert_select(
		"npc_condition",
		"condition",
		{
			"npc_id": NPC_A,
			"type": "injured",
			"turns_left": 1
		},
		"npc_id"
	) and ok

	# -------------------------------------------------
	# 9. npc_goal
	# -------------------------------------------------

	ok = _test_insert_select(
		"npc_goal",
		NPC_A,
		{
			"npc_id": NPC_A,
			"current_goal": "測試目標"
		},
		"npc_id"
	) and ok

	# -------------------------------------------------
	# 10. npc_daily_plan
	# -------------------------------------------------

	ok = _test_insert_select(
		"npc_daily_plan",
		"daily_plan",
		{
			"npc_id": NPC_A,
			"game_day": 1,
			"text": "測試每日計畫",
			"is_done": 0
		},
		"npc_id"
	) and ok

	# -------------------------------------------------
	# 11. npc_last_action
	# -------------------------------------------------

	ok = _test_insert_select(
		"npc_last_action",
		NPC_A,
		{
			"npc_id": NPC_A,
			"action": "test_action",
			"target": "test_target",
			"success": 1,
			"reason": null,
			"location_id": LOCATION_A,
			"target_npc_id": NPC_B,
			"target_item_id": ITEM_A,
			"action_started_at": "2026-08-17 00:00:00",
			"action_finished_at": "2026-08-17 00:01:00"
		},
		"npc_id"
	) and ok

	# -------------------------------------------------
	# 12. memories
	# -------------------------------------------------

	ok = _test_insert_select(
		"memories",
		MEMORY_A,
		{
			"memory_id": MEMORY_A,
			"npc_id": NPC_A,
			"level": 1,
			"content": "測試記憶",
			"valence": "neutral",
			"importance": 10,
			"decay_value": 100,
			"created_tick": 1,
			"created_day": 1,
			"location_id": LOCATION_A,
			"embedding": null
		},
		"memory_id"
	) and ok

	# -------------------------------------------------
	# 13. memory_related_npcs
	# -------------------------------------------------

	ok = _test_insert_select(
		"memory_related_npcs",
		"memory_relation",
		{
			"memory_id": MEMORY_A,
			"npc_id": NPC_B
		},
		"memory_id"
	) and ok

	# -------------------------------------------------
	# 14. npc_death 已移除（死碼，死亡狀態走 JSON，見《99》P-50）
	# -------------------------------------------------

	# -------------------------------------------------
	# 15. grave
	# -------------------------------------------------

	ok = _test_insert_select(
		"grave",
		"grave",
		{
			"npc_id": NPC_B,
			"is_anonymous": 0,
			"location_id": LOCATION_B,
			"buried_tick": 2,
			"buried_by": NPC_A,
			"death_cause": "CRUD 測試",
			"last_words": "測試遺言",
			"words_to_creator": "測試"
		},
		"npc_id"
	) and ok

	var grave_rows := DatabaseManager.select(
		"grave",
		"npc_id = '%s'" % NPC_B,
		["grave_id"]
	)

	if grave_rows.is_empty():
		_fail("grave", "無法取得測試 grave_id")
		_cleanup_test_data()
		print("")
		print("=====================================================")
		print("[DatabaseCRUDTest] RESULT")
		print("=====================================================")
		print("PASS: ", passed)
		print("FAIL: ", failed)

		if failed == 0:
			print("[DatabaseCRUDTest] ALL TESTS PASSED")
		else:
			push_error(
				"[DatabaseCRUDTest] %d test(s) failed."
				% failed
			)

		print("=====================================================")

		queue_free()
		return
	else:
		passed += 1
		print("[PASS] grave_id SELECT")

	var grave_id := int(
		grave_rows[0].get("grave_id", 0)
	)

	# -------------------------------------------------
	# 16. grave_highlights 已移除（死碼，life_highlights 走 JSON，見《99》P-50）
	# -------------------------------------------------

	# -------------------------------------------------
	# 17. grave_epitaphs
	# -------------------------------------------------

	ok = _test_insert_select(
		"grave_epitaphs",
		"grave_epitaph",
		{
			"grave_id": grave_id,
			"npc_id": NPC_A,
			"content": "測試墓誌銘"
		},
		"grave_id"
	) and ok

	# -------------------------------------------------
	# 18. item
	# 已經測試過
	# -------------------------------------------------

	# -------------------------------------------------
	# 19. npc_inventory
	# -------------------------------------------------

	ok = _test_insert_select(
		"npc_inventory",
		"inventory",
		{
			"npc_id": NPC_A,
			"slot": 0,
			"item_id": ITEM_A,
			"count": 1,
			"decay": 0,
			"durability": 100
		},
		"npc_id"
	) and ok

	# -------------------------------------------------
	# 20. npc_home_storage
	# -------------------------------------------------

	ok = _test_insert_select(
		"npc_home_storage",
		"home_storage",
		{
			"npc_id": NPC_A,
			"item_id": ITEM_A,
			"count": 1,
			"decay": 0,
			"durability": 100,
			"slot": 0
		},
		"npc_id"
	) and ok

	# -------------------------------------------------
	# 21. npc_relations
	# -------------------------------------------------

	ok = _test_insert_select(
		"npc_relations",
		"relations",
		{
			"character_id": NPC_A,
			"target_id": NPC_B,
			"relations_appearance_cache": "測試"
		},
		"character_id"
	) and ok

	# -------------------------------------------------
	# 22. npc_wallet
	# -------------------------------------------------

	ok = _test_insert_select(
		"npc_wallet",
		NPC_A,
		{
			"npc_id": NPC_A,
			"money": 300
		},
		"npc_id"
	) and ok

	# -------------------------------------------------
	# 23. money_transaction
	# -------------------------------------------------

	ok = _test_insert_select(
		"money_transaction",
		"money_transaction",
		{
			"from_npc_id": NPC_A,
			"to_npc_id": NPC_B,
			"amount": 1,
			"transaction_type": "trade",
			"description": PREFIX + "money"
		},
		"description"
	) and ok

	# -------------------------------------------------
	# 24. item_transaction
	# -------------------------------------------------

	ok = _test_insert_select(
		"item_transaction",
		"item_transaction",
		{
			"from_npc_id": NPC_A,
			"to_npc_id": NPC_B,
			"item_id": ITEM_A,
			"quantity": 1,
			"transaction_type": "trade",
			"description": PREFIX + "item"
		},
		"description"
	) and ok

	# -------------------------------------------------
	# 25. UPDATE 驗證
	# -------------------------------------------------

	var update_ok := DatabaseManager.update(
		"npc_state",
		{"health": 88},
		"npc_id = '%s'" % NPC_A
	)

	if update_ok:
		var updated := DatabaseManager.select(
			"npc_state",
			"npc_id = '%s'" % NPC_A,
			["health"]
		)

		if not updated.is_empty() and float(updated[0].get("health", -1)) == 88.0:
			passed += 1
			print("[PASS] UPDATE npc_state.health = 88")
		else:
			_fail("UPDATE", "寫入後讀回 health 不是 88")
	else:
		_fail("UPDATE", "DatabaseManager.update() 失敗")

	# -------------------------------------------------
	# 26. DELETE 驗證
	# -------------------------------------------------

	var delete_ok := DatabaseManager.delete(
		"npc_goal",
		"npc_id = '%s'" % NPC_A
	)

	if delete_ok:
		var deleted := DatabaseManager.select(
			"npc_goal",
			"npc_id = '%s'" % NPC_A,
			["npc_id"]
		)

		if deleted.is_empty():
			passed += 1
			print("[PASS] DELETE npc_goal")
		else:
			_fail("DELETE", "刪除後仍讀得到 npc_goal")
	else:
		_fail("DELETE", "DatabaseManager.delete() 失敗")

	# -------------------------------------------------
	# 清理
	# -------------------------------------------------

	_cleanup_test_data()

	print("")
	print("=====================================================")
	print("[DatabaseCRUDTest] RESULT")
	print("=====================================================")
	print("PASS: ", passed)
	print("FAIL: ", failed)

	if failed == 0:
		print("[DatabaseCRUDTest] ALL TESTS PASSED")
	else:
		push_error(
			"[DatabaseCRUDTest] %d test(s) failed."
			% failed
		)

	print("=====================================================")

	queue_free()


func _test_insert_select(
	table: String,
	label: String,
	data: Dictionary,
	key_column: String
) -> bool:

	if not DatabaseManager.insert(table, data):
		_fail(label, "INSERT 失敗")
		return false

	var key_value := str(
		data.get(key_column, "")
	)

	var condition := ""

	# 自增主鍵的測試資料沒有 key_value，因此改用第一個
	# 非時間欄位條件。
	if key_value.is_empty():
		if table == "npc_schedule":
			condition = "npc_id = '%s' AND start_time = '08:00'" % NPC_A
		elif table == "npc_taboo":
			condition = "npc_id = '%s' AND taboo_type = 'test'" % NPC_A
		elif table == "npc_condition":
			condition = "npc_id = '%s' AND type = 'injured'" % NPC_A
		elif table == "npc_daily_plan":
			condition = "npc_id = '%s' AND game_day = 1" % NPC_A
		elif table == "grave_epitaphs":
			condition = "grave_id = %d AND npc_id = '%s'" % [
				int(data["grave_id"]),
				str(data["npc_id"])
			]
		else:
			condition = "1 = 0"
	else:
		if key_value.is_valid_int() and table == "grave_epitaphs":
			condition = "%s = %d" % [key_column, int(key_value)]
		else:
			condition = "%s = '%s'" % [
				key_column,
				_escape_sql(key_value)
			]

	var rows := DatabaseManager.select(
		table,
		condition,
		[key_column if key_column != "" else "*"]
	)

	if rows.is_empty():
		_fail(label, "INSERT 成功但 SELECT 找不到資料")
		return false

	passed += 1
	print("[PASS] %s INSERT + SELECT" % label)
	return true


func _cleanup_test_data() -> void:
	# 交易紀錄先刪，避免 item / NPC 的 FK 阻擋清理。
	DatabaseManager.delete(
		"item_transaction",
		"description LIKE '%s%%'" % _escape_sql(PREFIX)
	)

	DatabaseManager.delete(
		"money_transaction",
		"description LIKE '%s%%'" % _escape_sql(PREFIX)
	)

	# 關聯記憶。
	DatabaseManager.delete(
		"memory_related_npcs",
		"memory_id LIKE '%s%%'" % _escape_sql(PREFIX)
	)

	DatabaseManager.delete(
		"memories",
		"memory_id LIKE '%s%%'" % _escape_sql(PREFIX)
	)

	# NPC child tables；大部分有 ON DELETE CASCADE，
	# 但明確刪除可以讓測試更容易定位 FK 問題。
	DatabaseManager.delete(
		"npc_relations",
		"character_id LIKE '%s%%' OR target_id LIKE '%s%%'"
		% [_escape_sql(PREFIX), _escape_sql(PREFIX)]
	)

	DatabaseManager.delete(
		"npc_inventory",
		"npc_id LIKE '%s%%'" % _escape_sql(PREFIX)
	)

	DatabaseManager.delete(
		"npc_home_storage",
		"npc_id LIKE '%s%%'" % _escape_sql(PREFIX)
	)

	DatabaseManager.delete(
		"npc_wallet",
		"npc_id LIKE '%s%%'" % _escape_sql(PREFIX)
	)

	DatabaseManager.delete(
		"npc_last_action",
		"npc_id LIKE '%s%%'" % _escape_sql(PREFIX)
	)

	DatabaseManager.delete(
		"npc_daily_plan",
		"npc_id LIKE '%s%%'" % _escape_sql(PREFIX)
	)

	DatabaseManager.delete(
		"npc_goal",
		"npc_id LIKE '%s%%'" % _escape_sql(PREFIX)
	)

	DatabaseManager.delete(
		"npc_condition",
		"npc_id LIKE '%s%%'" % _escape_sql(PREFIX)
	)

	DatabaseManager.delete(
		"npc_emotion",
		"npc_id LIKE '%s%%'" % _escape_sql(PREFIX)
	)

	DatabaseManager.delete(
		"npc_taboo",
		"npc_id LIKE '%s%%'" % _escape_sql(PREFIX)
	)

	DatabaseManager.delete(
		"npc_occupation",
		"npc_id LIKE '%s%%'" % _escape_sql(PREFIX)
	)

	DatabaseManager.delete(
		"npc_appearance",
		"npc_id LIKE '%s%%'" % _escape_sql(PREFIX)
	)

	DatabaseManager.delete(
		"npc_personality",
		"npc_id LIKE '%s%%'" % _escape_sql(PREFIX)
	)

	DatabaseManager.delete(
		"npc_schedule",
		"npc_id LIKE '%s%%'" % _escape_sql(PREFIX)
	)

	DatabaseManager.delete(
		"npc_state",
		"npc_id LIKE '%s%%'" % _escape_sql(PREFIX)
	)

	# 墓園相關。先刪 epitaphs（子表），再刪 grave（父表）——
	# grave_highlights／npc_death 已移除，不用再清（見《99》P-50）。
	DatabaseManager.delete(
		"grave_epitaphs",
		"npc_id LIKE '%s%%'" % _escape_sql(PREFIX)
	)

	DatabaseManager.delete(
		"grave",
		"npc_id LIKE '%s%%'" % _escape_sql(PREFIX)
	)

	# 最後刪 NPC。
	DatabaseManager.delete(
		"npc",
		"npc_id LIKE '%s%%'" % _escape_sql(PREFIX)
	)

	# 測試物品與地點。
	DatabaseManager.delete(
		"item",
		"item_id LIKE '%s%%'" % _escape_sql(PREFIX)
	)

	DatabaseManager.delete(
		"location",
		"location_id LIKE '%s%%'" % _escape_sql(PREFIX)
	)


func _fail(label: String, message: String) -> void:
	failed += 1
	push_error(
		"[FAIL] %s: %s"
		% [label, message]
	)


func _escape_sql(value: String) -> String:
	return value.replace("'", "''")
