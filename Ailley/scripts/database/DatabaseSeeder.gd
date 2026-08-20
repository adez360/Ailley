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
##
## 物品清單以 res://data/items.json（ItemDatabase）為單一事實來源，
## 這裡只補 ItemDatabase 沒有的平衡數值（base_price／effect_* 等）。
## ITEM_BALANCE 的 key 一定要能在 ItemDatabase 查到，查不到視為設定
## 錯誤直接擋下，避免兩份清單各自漂移出不存在的物品。
## =====================================================


## ITEM_BALANCE 裡不是每個 item 都寫 decay_rate／durability_cost——
## 沒寫不代表「保留資料庫現有值」，是「這個 item 目前不需要偏離 schema
## 預設值」。_upsert_item() 對已存在的 row 走 UPDATE，SQL 只會覆寫
## item_data 裡實際出現的欄位；缺席的欄位不會被觸碰，導致「這個欄位曾經
## 設過值、後來從 ITEM_BALANCE 拿掉」時既有存檔仍停在舊值，永遠同步不到
## 目前的定義。seed_items() 用這份預設值墊底、讓 ITEM_BALANCE 的值覆蓋，
## 確保每個 item_data 一定完整列出這兩欄，跟 ItemSchema.gd 的
## DEFAULT 對齊。
const OPTIONAL_ITEM_FIELD_DEFAULTS := {
	"decay_rate": 0.0,
	"durability_cost": 0
}


## item_id -> 平衡數值。key 必須存在於 res://data/items.json，
## 否則 seed_items() 會擋下並回報錯誤。
const ITEM_BALANCE := {
	"water": {
		"name": "Water",
		"item_type": "drink",
		"description": "Clean drinking water.",
		"base_price": 2,
		"max_stack": 30,
		"is_consumable": 1,
		"is_perishable": 0,
		"effect_satiety": 0,
		"effect_hydration": 40,
		"effect_alcohol": 0,
		"effect_injury": 0
	},

	"ale": {
		"name": "Ale",
		"item_type": "drink",
		"description": "A common alcoholic drink.",
		"base_price": 10,
		"max_stack": 30,
		"is_consumable": 1,
		"is_perishable": 1,
		"decay_rate": 0.3,
		"effect_satiety": 0,
		"effect_hydration": 20,
		"effect_alcohol": 25,
		"effect_injury": 0
	},

	"cooked_meat": {
		"name": "Cooked Meat",
		"item_type": "food",
		"description": "Cooked meat.",
		"base_price": 25,
		"max_stack": 30,
		"is_consumable": 1,
		"is_perishable": 1,
		"decay_rate": 0.5,
		"effect_satiety": 40,
		"effect_hydration": 0,
		"effect_alcohol": 0,
		"effect_injury": 0
	},

	"herb_soup": {
		"name": "Herb Soup",
		"item_type": "food",
		"description": "A warm herb soup.",
		"base_price": 15,
		"max_stack": 30,
		"is_consumable": 1,
		"is_perishable": 1,
		"decay_rate": 0.8,
		"effect_satiety": 20,
		"effect_hydration": 0,
		"effect_alcohol": 0,
		"effect_injury": 0
	},

	"medicine": {
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
		"effect_injury": -30
	},

	"bread": {
		"name": "Bread",
		"item_type": "food",
		"description": "Freshly baked bread.",
		"base_price": 12,
		"max_stack": 30,
		"is_consumable": 1,
		"is_perishable": 1,
		"decay_rate": 0.3,
		"effect_satiety": 25,
		"effect_hydration": 0,
		"effect_alcohol": 0,
		"effect_injury": 0
	},

	"fish_dish": {
		"name": "Fish Dish",
		"item_type": "food",
		"description": "A cooked fish dish.",
		"base_price": 20,
		"max_stack": 30,
		"is_consumable": 1,
		"is_perishable": 1,
		"decay_rate": 0.5,
		"effect_satiety": 35,
		"effect_hydration": 0,
		"effect_alcohol": 0,
		"effect_injury": 0
	},

	"spirit": {
		"name": "Spirit",
		"item_type": "drink",
		"description": "A strong distilled liquor.",
		"base_price": 22,
		"max_stack": 30,
		"is_consumable": 1,
		"is_perishable": 1,
		"effect_satiety": 0,
		"effect_hydration": 10,
		"effect_alcohol": 45,
		"effect_injury": 0
	},

	"small_game": {
		"name": "Small Game",
		"item_type": "small_game",
		"description": "A small hunted animal; needs cooking before it can be eaten.",
		"base_price": 30,
		"max_stack": 30,
		"is_consumable": 0,
		"is_perishable": 1,
		"decay_rate": 0.8,
		"effect_satiety": 0,
		"effect_hydration": 0,
		"effect_alcohol": 0,
		"effect_injury": 0
	},

	"large_game": {
		"name": "Large Game",
		"item_type": "large_game",
		"description": "A large hunted animal; needs cooking before it can be eaten.",
		"base_price": 90,
		"max_stack": 30,
		"is_consumable": 0,
		"is_perishable": 1,
		"decay_rate": 0.6,
		"effect_satiety": 0,
		"effect_hydration": 0,
		"effect_alcohol": 0,
		"effect_injury": 0
	},

	"fish": {
		"name": "Fish",
		"item_type": "seafood",
		"description": "A freshly caught fish; needs cooking before it can be eaten.",
		"base_price": 25,
		"max_stack": 30,
		"is_consumable": 0,
		"is_perishable": 1,
		"decay_rate": 1.0,
		"effect_satiety": 0,
		"effect_hydration": 0,
		"effect_alcohol": 0,
		"effect_injury": 0
	},

	"herb": {
		"name": "Herb",
		"item_type": "gathered",
		"description": "A medicinal herb, used for crafting medicine.",
		"base_price": 18,
		"max_stack": 30,
		"is_consumable": 0,
		"is_perishable": 1,
		"decay_rate": 0.4,
		"effect_satiety": 0,
		"effect_hydration": 0,
		"effect_alcohol": 0,
		"effect_injury": 0
	},

	"wild_fruit": {
		"name": "Wild Fruit",
		"item_type": "gathered",
		"description": "A wild fruit foraged from the field.",
		"base_price": 8,
		"max_stack": 30,
		"is_consumable": 0,
		"is_perishable": 1,
		"decay_rate": 0.9,
		"effect_satiety": 0,
		"effect_hydration": 0,
		"effect_alcohol": 0,
		"effect_injury": 0
	},

	"knife": {
		"name": "Knife",
		"item_type": "carry",
		"description": "Improves hunting success rate.",
		"base_price": 120,
		"max_stack": 1,
		"is_consumable": 0,
		"is_perishable": 0,
		"durability_cost": 2,
		"effect_satiety": 0,
		"effect_hydration": 0,
		"effect_alcohol": 0,
		"effect_injury": 0
	},

	"good_knife": {
		"name": "Good Knife",
		"item_type": "carry",
		"description": "A finely crafted knife; improves hunting success rate further.",
		"base_price": 350,
		"max_stack": 1,
		"is_consumable": 0,
		"is_perishable": 0,
		"durability_cost": 1,
		"effect_satiety": 0,
		"effect_hydration": 0,
		"effect_alcohol": 0,
		"effect_injury": 0
	},

	"instrument": {
		"name": "Instrument",
		"item_type": "carry",
		"description": "Improves performance success rate.",
		"base_price": 200,
		"max_stack": 1,
		"is_consumable": 0,
		"is_perishable": 0,
		"durability_cost": 1,
		"effect_satiety": 0,
		"effect_hydration": 0,
		"effect_alcohol": 0,
		"effect_injury": 0
	},

	"clothes_basic": {
		"name": "Basic Clothes",
		"item_type": "carry",
		"description": "Ordinary clothing.",
		"base_price": 60,
		"max_stack": 1,
		"is_consumable": 0,
		"is_perishable": 0,
		"effect_satiety": 0,
		"effect_hydration": 0,
		"effect_alcohol": 0,
		"effect_injury": 0
	},

	"battery": {
		"name": "Battery",
		"item_type": "carry",
		"description": "A story item tied to the flag system; not tradeable.",
		"base_price": 0,
		"max_stack": 1,
		"is_consumable": 0,
		"is_perishable": 0,
		"effect_satiety": 0,
		"effect_hydration": 0,
		"effect_alcohol": 0,
		"effect_injury": 0
	}
}


## =====================================================
## Entry Point
## =====================================================

## 回傳 false 代表至少一項基礎資料建立失敗（缺 item_id 對應、或 INSERT 失敗）。
## 呼叫端（DatabaseManager）必須把這個結果反映到 is_seeded，
## 不能讓「資料不完整」跟「基礎資料已補齊」看起來一樣。
static func seed_all() -> bool:

	print(
		"[DatabaseSeeder] 開始建立基礎資料..."
	)


	var ok := seed_items()


	if ok:

		print(
			"[DatabaseSeeder] 基礎資料建立完成。"
		)

	else:

		push_error(
			"[DatabaseSeeder] "
			+ "基礎資料建立未完全成功，詳見上方錯誤訊息。"
		)


	return ok


## =====================================================
## Item Seed
## =====================================================

## 回傳 false 代表至少一個 item_id 沒能正確建立
## （ITEM_BALANCE 查不到 ItemDatabase 對應項目、或 INSERT 失敗）。
static func seed_items() -> bool:

	var ok := true


	for item_id in ITEM_BALANCE:

		if not ItemDatabase.has_item(item_id):

			push_error(
				"[DatabaseSeeder] "
				+ "ITEM_BALANCE 有 %s，但 res://data/items.json 沒有這個 item_id。"
				% item_id
			)

			ok = false
			continue


		var item_data: Dictionary = (
			OPTIONAL_ITEM_FIELD_DEFAULTS
		).duplicate()

		item_data.merge(
			ITEM_BALANCE[item_id],
			true
		)

		item_data["item_id"] = item_id
		item_data["is_active"] = 1

		if not _upsert_item(
			item_id,
			item_data
		):

			ok = false


	print(
		"[DatabaseSeeder] Item seed 完成。"
		if ok
		else "[DatabaseSeeder] Item seed 有錯誤，詳見上方錯誤訊息。"
	)

	return ok


## =====================================================
## Upsert Item
##
## item 是全域目錄表，沒有任何其他地方會在執行期改動它——
## 每次開機都用 ITEM_BALANCE／ItemDatabase 目前的定義覆蓋既有 row，
## 兩份清單改了任何欄位，既有存檔的 SQLite 都會跟著同步，
## 不會停留在第一次建立當下的舊值。
## =====================================================

static func _upsert_item(
	item_id: String,
	item_data: Dictionary
) -> bool:

	# -------------------------------------------------
	# 檢查是否已存在
	# -------------------------------------------------

	var existing := DatabaseManager.select_where(
		"item",
		"item_id = ?",
		[
			item_id
		],
		[
			"item_id"
		]
	)


	if not existing.is_empty():

		var updated := DatabaseManager.update(
			"item",
			item_data,
			"item_id = '%s'"
			% DatabaseManager.escape_sql_string(item_id)
		)

		if not updated:

			push_error(
				(
					"[DatabaseSeeder] "
					+ "更新 item 失敗：%s | DB=%s"
				) % [
					item_id,
					DatabaseManager.db.error_message
				]
			)

			return false

		print(
			(
				"[DatabaseSeeder] "
				+ "item 已同步：%s"
			) % item_id
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
