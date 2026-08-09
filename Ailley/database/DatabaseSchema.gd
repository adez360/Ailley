##	CREATE TABLE
##	CREATE INDEX
##	CREATE VIEW

class_name DatabaseSchema
extends RefCounted

## ============================================================
## Ailley Database Schema
## ============================================================
##
## 負責：
## 1. 建立所有 SQLite 資料表
## 2. 建立資料表之間的 Foreign Key
## 3. 建立常用 Index
##
## 不負責：
## - 開啟資料庫
## - 關閉資料庫
## - 插入遊戲初始資料
## - NPC / Event / Item 的實際操作
##
## DatabaseManager 負責資料庫連線。
## DatabaseSeeder 負責初始資料。
##
## ============================================================


const SCHEMA_VERSION := 1


## ============================================================
## 初始化整個 Database Schema
## ============================================================

func initialize() -> bool:
	print("[DatabaseSchema] Initializing database schema...")

	# 啟用 SQLite Foreign Key
	if not _enable_foreign_keys():
		return false

	# 建立資料表
	if not _create_location_table():
		return false

	if not _create_npc_table():
		return false

	if not _create_item_table():
		return false

	if not _create_recipe_table():
		return false

	if not _create_recipe_ingredient_table():
		return false

	if not _create_event_table():
		return false

	# 建立 Index
	if not _create_indexes():
		return false

	print(
		"[DatabaseSchema] Database schema initialized successfully. Version: ",
		SCHEMA_VERSION
	)

	return true


## ============================================================
## SQLite Foreign Key
## ============================================================

func _enable_foreign_keys() -> bool:
	var query := """
	PRAGMA foreign_keys = ON;
	"""

	return DatabaseManager.execute(query)


## ============================================================
## LOCATION
## ============================================================
##
## 世界中的地點。
##
## 例如：
## town_01
## house_01
## shop_01
## forest_01
##
## parent_location_id：
## 用來建立地點階層。
##
## 例如：
##
## town
##  ├── house
##  ├── shop
##  └── tavern
##
## ============================================================

func _create_location_table() -> bool:
	var query := """
	CREATE TABLE IF NOT EXISTS location (
		id INTEGER PRIMARY KEY AUTOINCREMENT,

		location_id TEXT NOT NULL UNIQUE,

		name TEXT NOT NULL,

		description TEXT NOT NULL DEFAULT '',

		parent_location_id TEXT DEFAULT NULL,

		location_type TEXT NOT NULL DEFAULT '',

		is_active INTEGER NOT NULL DEFAULT 1,

		FOREIGN KEY (parent_location_id)
			REFERENCES location(location_id)
			ON DELETE SET NULL
			ON UPDATE CASCADE
	);
	"""

	return DatabaseManager.execute(query)


## ============================================================
## NPC
## ============================================================
##
## 遊戲中的 NPC。
##
## location_id 對應 location.location_id
##
## ============================================================

func _create_npc_table() -> bool:
	var query := """
	CREATE TABLE IF NOT EXISTS npc (
		id INTEGER PRIMARY KEY AUTOINCREMENT,

		npc_id TEXT NOT NULL UNIQUE,

		name TEXT NOT NULL,

		location_id TEXT DEFAULT NULL,

		description TEXT NOT NULL DEFAULT '',

		age INTEGER DEFAULT NULL,

		gender TEXT NOT NULL DEFAULT '',

		personality TEXT NOT NULL DEFAULT '',

		is_active INTEGER NOT NULL DEFAULT 1,

		FOREIGN KEY (location_id)
			REFERENCES location(location_id)
			ON DELETE SET NULL
			ON UPDATE CASCADE
	);
	"""

	return DatabaseManager.execute(query)


## ============================================================
## ITEM
## ============================================================
##
## 遊戲中的所有物品。
##
## 例如：
##
## apple
## wood
## iron
## sword
## potion
##
## ============================================================

func _create_item_table() -> bool:
	var query := """
	CREATE TABLE IF NOT EXISTS item (
		id INTEGER PRIMARY KEY AUTOINCREMENT,

		item_id TEXT NOT NULL UNIQUE,

		name TEXT NOT NULL,

		description TEXT NOT NULL DEFAULT '',

		item_type TEXT NOT NULL DEFAULT '',

		max_stack INTEGER NOT NULL DEFAULT 1,

		is_active INTEGER NOT NULL DEFAULT 1
	);
	"""

	return DatabaseManager.execute(query)


## ============================================================
## RECIPE
## ============================================================
##
## 製作配方。
##
## result_item_id：
## 製作完成後產生的物品。
##
## 例如：
##
## recipe_apple_pie
##     ↓
## result_item_id = apple_pie
##
## ============================================================

func _create_recipe_table() -> bool:
	var query := """
	CREATE TABLE IF NOT EXISTS recipe (
		id INTEGER PRIMARY KEY AUTOINCREMENT,

		recipe_id TEXT NOT NULL UNIQUE,

		name TEXT NOT NULL,

		result_item_id TEXT DEFAULT NULL,

		result_amount INTEGER NOT NULL DEFAULT 1,

		description TEXT NOT NULL DEFAULT '',

		is_active INTEGER NOT NULL DEFAULT 1,

		FOREIGN KEY (result_item_id)
			REFERENCES item(item_id)
			ON DELETE SET NULL
			ON UPDATE CASCADE
	);
	"""

	return DatabaseManager.execute(query)


## ============================================================
## RECIPE INGREDIENT
## ============================================================
##
## 配方所需材料。
##
## recipe 與 item 是多對多關係。
##
## 例如：
##
## apple_pie
## ├── apple × 2
## ├── flour × 1
## └── sugar × 1
##
## 因此不能直接把 ingredient 寫在 recipe 裡。
##
## 使用中介表：
##
## recipe
##    │
##    ▼
## recipe_ingredient
##    │
##    ▼
## item
##
## ============================================================

func _create_recipe_ingredient_table() -> bool:
	var query := """
	CREATE TABLE IF NOT EXISTS recipe_ingredient (
		id INTEGER PRIMARY KEY AUTOINCREMENT,

		recipe_id TEXT NOT NULL,

		item_id TEXT NOT NULL,

		amount INTEGER NOT NULL DEFAULT 1,

		UNIQUE (recipe_id, item_id),

		FOREIGN KEY (recipe_id)
			REFERENCES recipe(recipe_id)
			ON DELETE CASCADE
			ON UPDATE CASCADE,

		FOREIGN KEY (item_id)
			REFERENCES item(item_id)
			ON DELETE CASCADE
			ON UPDATE CASCADE
	);
	"""

	return DatabaseManager.execute(query)


## ============================================================
## EVENT
## ============================================================
##
## 遊戲事件。
##
## Event 可以發生在特定 Location。
##
## 例如：
##
## festival_001
## quest_001
## shop_event_001
## npc_meeting_001
##
## ============================================================

func _create_event_table() -> bool:
	var query := """
	CREATE TABLE IF NOT EXISTS event (
		id INTEGER PRIMARY KEY AUTOINCREMENT,

		event_id TEXT NOT NULL UNIQUE,

		name TEXT NOT NULL,

		description TEXT NOT NULL DEFAULT '',

		location_id TEXT DEFAULT NULL,

		event_type TEXT NOT NULL DEFAULT '',

		start_time TEXT DEFAULT NULL,

		end_time TEXT DEFAULT NULL,

		is_active INTEGER NOT NULL DEFAULT 1,

		FOREIGN KEY (location_id)
			REFERENCES location(location_id)
			ON DELETE SET NULL
			ON UPDATE CASCADE
	);
	"""

	return DatabaseManager.execute(query)


## ============================================================
## INDEX
## ============================================================
##
## Index 用來提高常用查詢速度。
##
## ============================================================

func _create_indexes() -> bool:

	var queries := [

		# NPC → Location
		"""
		CREATE INDEX IF NOT EXISTS idx_npc_location
		ON npc(location_id);
		""",

		# Event → Location
		"""
		CREATE INDEX IF NOT EXISTS idx_event_location
		ON event(location_id);
		""",

		# Recipe → Result Item
		"""
		CREATE INDEX IF NOT EXISTS idx_recipe_result_item
		ON recipe(result_item_id);
		""",

		# Recipe Ingredient → Item
		"""
		CREATE INDEX IF NOT EXISTS idx_recipe_ingredient_item
		ON recipe_ingredient(item_id);
		""",

		# Location → Parent Location
		"""
		CREATE INDEX IF NOT EXISTS idx_location_parent
		ON location(parent_location_id);
		""",

		# NPC active status
		"""
		CREATE INDEX IF NOT EXISTS idx_npc_active
		ON npc(is_active);
		""",

		# Event active status
		"""
		CREATE INDEX IF NOT EXISTS idx_event_active
		ON event(is_active);
		"""
	]

	for query in queries:
		if not DatabaseManager.execute(query):
			push_error(
				"[DatabaseSchema] Failed to create database index."
			)
			return false

	return true
