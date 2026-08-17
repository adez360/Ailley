class_name DatabaseSeeder
extends RefCounted


## =====================================================
## DatabaseSeeder
##
## 負責建立遊戲第一次啟動時需要的基礎測試資料。
##
## 目前先處理：
##
##     item
##
## 之後 NPC / location / recipe 等資料也可以繼續放進來。
##
## Seeder 不負責：
##
##     - 建立資料表
##     - 修改 Schema
##     - 遊戲中的資料更新
##
## Schema：
##     DatabaseSchema
##
## CRUD：
##     DatabaseManager
##
## Seed：
##     DatabaseSeeder
## =====================================================


## =====================================================
## Entry Point
## =====================================================

static func seed_all() -> void:

	if not DatabaseManager.is_ready:

		push_error(
			"[DatabaseSeeder] "
			+ "DatabaseManager 尚未準備完成。"
		)

		return


	print(
		"[DatabaseSeeder] 開始建立基礎資料..."
	)


	seed_items()


	print(
		"[DatabaseSeeder] 基礎資料建立完成。"
	)


## =====================================================
## Item Seed
## =====================================================

static func seed_items() -> void:

	# -------------------------------------------------
	# Water
	# -------------------------------------------------

	_insert_item_if_missing({
		"item_id": "water",
		"name": "Water",
		"item_type": "drink",
		"description": "Clean drinking water.",
		"base_price": 2,
		"max_stack": 30,
		"is_consumable": 1,
		"is_perishable": 1,

		"effect_satiety": 0,
		"effect_hydration": 40,
		"effect_alcohol": 0,
		"effect_injury": 0,

		"is_active": 1
	})


	# -------------------------------------------------
	# Ale
	# -------------------------------------------------

	_insert_item_if_missing({
		"item_id": "ale",
		"name": "Ale",
		"item_type": "drink",
		"description": "A common alcoholic drink.",
		"base_price": 10,
		"max_stack": 30,
		"is_consumable": 1,
		"is_perishable": 1,

		"effect_satiety": 0,
		"effect_hydration": 20,
		"effect_alcohol": 25,
		"effect_injury": 0,

		"is_active": 1
	})


	# -------------------------------------------------
	# Cooked Meat
	# -------------------------------------------------

	_insert_item_if_missing({
		"item_id": "cooked_meat",
		"name": "Cooked Meat",
		"item_type": "food",
		"description": "Cooked meat.",
		"base_price": 25,
		"max_stack": 30,
		"is_consumable": 1,
		"is_perishable": 1,

		"effect_satiety": 40,
		"effect_hydration": 0,
		"effect_alcohol": 0,
		"effect_injury": 0,

		"is_active": 1
	})


	# -------------------------------------------------
	# Herb Soup
	# -------------------------------------------------

	_insert_item_if_missing({
		"item_id": "herb_soup",
		"name": "Herb Soup",
		"item_type": "food",
		"description": "A warm herb soup.",
		"base_price": 15,
		"max_stack": 30,
		"is_consumable": 1,
		"is_perishable": 1,

		"effect_satiety": 20,
		"effect_hydration": 0,
		"effect_alcohol": 0,
		"effect_injury": 0,

		"is_active": 1
	})


	# -------------------------------------------------
	# Medicine
	# -------------------------------------------------

	_insert_item_if_missing({
		"item_id": "medicine",
		"name": "Medicine",
		"item_type": "medicine",
		"description": "Medicine for treating injuries.",
		"base_price": 45,
		"max_stack": 30,
		"is_consumable": 1,
		"is_perishable": 0,

		"effect_satiety": 0,
		"effect_hydration": 0,
		"effect_alcohol": 0,
		"effect_injury": -30,

		"is_active": 1
	})


	print(
		"[DatabaseSeeder] Item seed 完成。"
	)


## =====================================================
## Insert Item If Missing
## =====================================================

static func _insert_item_if_missing(
	item_data: Dictionary
) -> bool:

	var item_id := str(
		item_data.get(
			"item_id",
			""
		)
	)


	if item_id.is_empty():

		push_error(
			"[DatabaseSeeder] "
			+ "item_id 不可以是空字串。"
		)

		return false


	# -------------------------------------------------
	# 檢查是否已存在
	# -------------------------------------------------

	var existing := DatabaseManager.select(
		"item",
		"item_id = '%s'"
		% _escape_sql(item_id),
		[
			"item_id"
		]
	)


	if not existing.is_empty():

		print(
			"[DatabaseSeeder] "
			+ "item 已存在：%s"
			% item_id
		)

		return true


	# -------------------------------------------------
	# INSERT
	# -------------------------------------------------

	if not DatabaseManager.insert(
		"item",
		item_data
	):

		push_error(
			"[DatabaseSeeder] "
			+ "建立 item 失敗：%s"
			% item_id
		)

		return false


	print(
		"[DatabaseSeeder] "
		+ "建立 item：%s"
		% item_id
	)

	return true


## =====================================================
## SQL Escape
## =====================================================

static func _escape_sql(
	value: String
) -> String:

	return value.replace(
		"'",
		"''"
	)
