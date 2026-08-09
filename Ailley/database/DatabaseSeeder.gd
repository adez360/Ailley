##	負責第一次建立遊戲時的初始資料

class_name DatabaseSeeder
extends RefCounted


## ============================================================
## Ailley Database Seeder
## ============================================================
##
## 負責：
## 1. 將 res://data/ 中的靜態遊戲資料寫入 SQLite
## 2. 第一次啟動時建立初始資料
## 3. 重複啟動時不重複建立資料
##
## 資料來源：
##
## res://data/places.json
## res://data/npc_schedule.json
##
## 注意：
## DatabaseSeeder 不負責建立資料表。
## DatabaseSchema 負責資料表。
##
## ============================================================


const PLACES_FILE := "res://data/places.json"
const NPC_SCHEDULE_FILE := "res://data/npc_schedule.json"


## ============================================================
## 初始化 Seeder
## ============================================================

func initialize() -> bool:
	print("[DatabaseSeeder] Starting database seeding...")

	if not _seed_places():
		push_error("[DatabaseSeeder] Failed to seed places.")
		return false

	if not _seed_npcs():
		push_error("[DatabaseSeeder] Failed to seed NPCs.")
		return false

	print("[DatabaseSeeder] Database seeding completed.")

	return true


## ============================================================
## Seed Places
## ============================================================
##
## 來源：
## res://data/places.json
##
## 目前 Ailley places.json：
##
## home_001
## home_002
## home_003
## home_004
## home_005
## farm
## shop
## restaurant
## temple
## square
##
## ============================================================

func _seed_places() -> bool:
	print("[DatabaseSeeder] Loading places.json...")

	var data = _load_json(PLACES_FILE)

	if data == null:
		return false

	if not data.has("places"):
		push_error(
			"[DatabaseSeeder] places.json does not contain 'places'."
		)
		return false

	var places: Dictionary = data["places"]

	for location_id in places.keys():
		var place_data = places[location_id]

		if not place_data is Dictionary:
			push_error(
				"[DatabaseSeeder] Invalid place data: "
				+ str(location_id)
			)
			return false

		var location_type := str(
			place_data.get("type", "")
		)

		var capacity := int(
			place_data.get("capacity", 0)
		)

		var description := (
			"Type: %s | Capacity: %d"
			% [
				location_type,
				capacity
			]
		)

		var query := """
		INSERT OR IGNORE INTO location (
			location_id,
			name,
			description,
			location_type,
			is_active
		)
		VALUES (
			'%s',
			'%s',
			'%s',
			'%s',
			1
		);
		""" % [
			_sql_escape(str(location_id)),
			_sql_escape(str(location_id)),
			_sql_escape(description),
			_sql_escape(location_type)
		]

		if not DatabaseManager.execute(query):
			push_error(
				"[DatabaseSeeder] Failed to insert location: "
				+ str(location_id)
			)
			return false

		print(
			"[DatabaseSeeder] Location seeded: ",
			location_id
		)

	return true


## ============================================================
## Seed NPC
## ============================================================
##
## 來源：
## res://data/npc_schedule.json
##
## 目前 NPC：
##
## npc001
## npc002
## npc003
## npc004
## npc005
## npc006
##
## 注意：
## 目前 npc_schedule.json 沒有提供 NPC 的正式名稱、
## 年齡、性別、人格等完整角色資料。
##
## 因此這一階段只建立：
##
## npc_id
## name
## location_id
##
## name 暫時使用 npc_id。
##
## 後續建立正式 NPC 資料來源後再更新。
##
## ============================================================

func _seed_npcs() -> bool:
	print("[DatabaseSeeder] Loading npc_schedule.json...")

	var data = _load_json(NPC_SCHEDULE_FILE)

	if data == null:
		return false

	if not data.has("villagers"):
		push_error(
			"[DatabaseSeeder] npc_schedule.json does not contain 'villagers'."
		)
		return false

	var villagers: Array = data["villagers"]

	for villager in villagers:

		if not villager is Dictionary:
			push_error(
				"[DatabaseSeeder] Invalid NPC data."
			)
			return false

		if not villager.has("id"):
			push_error(
				"[DatabaseSeeder] NPC does not contain id."
			)
			return false

		var npc_id := str(villager["id"])

		var current_location := _get_initial_npc_location(
			villager
		)

		var query := """
		INSERT OR IGNORE INTO npc (
			npc_id,
			name,
			location_id,
			description,
			is_active
		)
		VALUES (
			'%s',
			'%s',
			'%s',
			'',
			1
		);
		""" % [
			_sql_escape(npc_id),
			_sql_escape(npc_id),
			_sql_escape(current_location)
		]

		if not DatabaseManager.execute(query):
			push_error(
				"[DatabaseSeeder] Failed to insert NPC: "
				+ npc_id
			)
			return false

		print(
			"[DatabaseSeeder] NPC seeded: ",
			npc_id,
			" -> ",
			current_location
		)

	return true


## ============================================================
## 取得 NPC 初始位置
## ============================================================
##
## 使用 schedule 的第一筆資料。
##
## 例如：
##
## npc001
## 08:00 → home_001
##
## 所以初始 location_id：
##
## home_001
##
## ============================================================

func _get_initial_npc_location(
	villager: Dictionary
) -> String:

	if not villager.has("schedule"):
		return ""

	var schedule = villager["schedule"]

	if not schedule is Array:
		return ""

	if schedule.is_empty():
		return ""

	var first_schedule = schedule[0]

	if not first_schedule is Dictionary:
		return ""

	return str(
		first_schedule.get("place", "")
	)


## ============================================================
## JSON Loader
## ============================================================

func _load_json(path: String):
	if not FileAccess.file_exists(path):
		push_error(
			"[DatabaseSeeder] File not found: "
			+ path
		)
		return null

	var file := FileAccess.open(
		path,
		FileAccess.READ
	)

	if file == null:
		push_error(
			"[DatabaseSeeder] Failed to open file: "
			+ path
		)
		return null

	var content := file.get_as_text()

	file.close()

	var json = JSON.parse_string(content)

	if json == null:
		push_error(
			"[DatabaseSeeder] Failed to parse JSON: "
			+ path
		)
		return null

	return json


## ============================================================
## SQL String Escape
## ============================================================
##
## SQLite 字串中的：
##
## '
##
## 必須轉成：
##
## ''
##
## 例如：
##
## Mary's Shop
##
## ↓
##
## Mary''s Shop
##
## ============================================================

func _sql_escape(value: String) -> String:
	return value.replace("'", "''")
