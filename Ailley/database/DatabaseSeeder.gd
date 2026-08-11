##	負責第一次建立遊戲時的初始資料

class_name DatabaseSeeder
extends RefCounted


## ============================================================
## Ailley Database Seeder
## ============================================================
##
## 負責：
##
## 1. 載入 places.json
## 2. 建立 location
##
## 3. 載入 npc_schedule.json
## 4. 建立 npc
## 5. 建立 npc_state
## 6. 建立 npc_schedule
##
## DatabaseSeeder 不負責建立資料表。
## DatabaseSchema 負責資料表。
##
## ============================================================


const PLACES_FILE := "res://data/places.json"
const NPC_SCHEDULE_FILE := "res://data/npc_schedule.json"


# ============================================================
# 初始化
# ============================================================

func initialize() -> bool:

	print("========================================")
	print("[DatabaseSeeder] Starting database seeding...")
	print("========================================")

	if not DatabaseManager.is_ready:
		push_error(
			"[DatabaseSeeder] DatabaseManager is not ready."
		)
		return false

	# --------------------------------------------------------
	# 1. 地點
	# --------------------------------------------------------

	if not _seed_places():
		push_error(
			"[DatabaseSeeder] Failed to seed places."
		)
		return false

	# --------------------------------------------------------
	# 2. NPC + State + Schedule
	# --------------------------------------------------------

	if not _seed_npcs():
		push_error(
			"[DatabaseSeeder] Failed to seed NPCs."
		)
		return false

	print("========================================")
	print("[DatabaseSeeder] Database seeding completed.")
	print("========================================")

	return true


# ============================================================
# Seed Places
# ============================================================
#
# 來源：
#
# res://data/places.json
#
# 目前 places.json：
#
# home_001
# home_002
# home_003
# home_004
# home_005
# farm
# shop
# restaurant
# temple
# square
#
# ============================================================

func _seed_places() -> bool:

	print("")
	print("[DatabaseSeeder] Loading places.json...")

	var data = _load_json(PLACES_FILE)

	if data == null:
		return false

	if not data.has("places"):
		push_error(
			"[DatabaseSeeder] places.json does not contain 'places'."
		)
		return false

	var places = data["places"]

	if not places is Dictionary:
		push_error(
			"[DatabaseSeeder] 'places' must be a Dictionary."
		)
		return false

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


# ============================================================
# Seed NPC
# ============================================================
#
# 來源：
#
# res://data/npc_schedule.json
#
# 目前 NPC：
#
# npc001
# npc002
# npc003
# npc004
# npc005
# npc006
#
# ============================================================
#
# 目前 npc_schedule.json 尚未提供完整 NPC 資料：
#
# name
# age
# gender
# village_id
# personality
# appearance
# occupation
# etc.
#
# 所以這個階段：
#
# name       = npc_id
# age        = 18
# gender     = other
# village_id = default_village
#
# 後面建立正式 NPC JSON 後再更新。
#
# ============================================================

func _seed_npcs() -> bool:

	print("")
	print("[DatabaseSeeder] Loading npc_schedule.json...")

	var data = _load_json(NPC_SCHEDULE_FILE)

	if data == null:
		return false

	if not data.has("villagers"):

		push_error(
			"[DatabaseSeeder] npc_schedule.json "
			+ "does not contain 'villagers'."
		)

		return false

	var villagers = data["villagers"]

	if not villagers is Array:

		push_error(
			"[DatabaseSeeder] 'villagers' must be an Array."
		)

		return false

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

		var npc_id := str(
			villager["id"]
		)

		# ----------------------------------------------------
		# NPC 初始位置
		# ----------------------------------------------------

		var initial_location := (
			_get_initial_npc_location(villager)
		)

		# ----------------------------------------------------
		# 建立 NPC
		# ----------------------------------------------------

		if not _create_npc(npc_id):

			push_error(
				"[DatabaseSeeder] Failed to create NPC: "
				+ npc_id
			)

			return false

		# ----------------------------------------------------
		# 建立 NPC State
		# ----------------------------------------------------

		if not _create_npc_state(
			npc_id,
			initial_location
		):

			push_error(
				"[DatabaseSeeder] Failed to create NPC state: "
				+ npc_id
			)

			return false

		# ----------------------------------------------------
		# 建立 NPC 基礎資料
		# ----------------------------------------------------

		if not _create_npc_default_data(npc_id):

			push_error(
				"[DatabaseSeeder] Failed to create NPC default data: "
				+ npc_id
			)

			return false

		# ----------------------------------------------------
		# 建立每日行程
		# ----------------------------------------------------

		if not _seed_npc_schedule(
			npc_id,
			villager
		):

			push_error(
				"[DatabaseSeeder] Failed to seed NPC schedule: "
				+ npc_id
			)

			return false

		print(
			"[DatabaseSeeder] NPC seeded: ",
			npc_id,
			" -> ",
			initial_location
		)

	return true


# ============================================================
# 建立 NPC
# ============================================================

func _create_npc(
	npc_id: String
) -> bool:

	var query := """
	INSERT OR IGNORE INTO npc (
		npc_id,
		name,
		age,
		gender,
		village_id,
		character,
		reputation,
		money,
		system_prompt,
		description,
		is_active
	)
	VALUES (
		'%s',
		'%s',
		18,
		'other',
		'default_village',
		'',
		0,
		0,
		'',
		'',
		1
	);
	""" % [
		_sql_escape(npc_id),
		_sql_escape(npc_id)
	]

	return DatabaseManager.execute(query)


# ============================================================
# 建立 NPC State
# ============================================================

func _create_npc_state(
	npc_id: String,
	location_id: String
) -> bool:

	var location_sql := "NULL"

	if not location_id.is_empty():

		location_sql = (
			"'%s'"
			% _sql_escape(location_id)
		)

	var query := """
	INSERT OR IGNORE INTO npc_state (
		npc_id,
		hunger,
		thirst,
		stamina,
		sleepiness,
		hygiene,
		alcohol,
		health,
		injury,
		location_id
	)
	VALUES (
		'%s',
		0,
		0,
		100,
		0,
		100,
		0,
		100,
		0,
		%s
	);
	""" % [
		_sql_escape(npc_id),
		location_sql
	]

	return DatabaseManager.execute(query)


# ============================================================
# 建立 NPC 預設資料
# ============================================================
#
# 建立：
#
# npc_personality
# npc_emotion
# npc_goal
#
# 其他資料表因為是 1:N：
#
# appearance
# taboo
# condition
# daily_plan
# inventory
# home_storage
# relations
#
# 初始狀態不需要建立空資料。
#
# ============================================================

func _create_npc_default_data(
	npc_id: String
) -> bool:

	# --------------------------------------------------------
	# Personality
	# --------------------------------------------------------

	var personality_query := """
	INSERT OR IGNORE INTO npc_personality (
		npc_id
	)
	VALUES (
		'%s'
	);
	""" % _sql_escape(npc_id)

	if not DatabaseManager.execute(
		personality_query
	):

		return false


	# --------------------------------------------------------
	# Emotion
	# --------------------------------------------------------

	var emotion_query := """
	INSERT OR IGNORE INTO npc_emotion (
		npc_id,
		emotion_type,
		intensity,
		duration_left
	)
	VALUES (
		'%s',
		'neutral',
		0,
		0
	);
	""" % _sql_escape(npc_id)

	if not DatabaseManager.execute(
		emotion_query
	):

		return false


	# --------------------------------------------------------
	# Goal
	# --------------------------------------------------------

	var goal_query := """
	INSERT OR IGNORE INTO npc_goal (
		npc_id,
		current_goal
	)
	VALUES (
		'%s',
		NULL
	);
	""" % _sql_escape(npc_id)

	if not DatabaseManager.execute(
		goal_query
	):

		return false


	return true


# ============================================================
# Seed NPC Schedule
# ============================================================
#
# 將：
#
# npc_schedule.json
#
# 寫入：
#
# npc_schedule
#
# ============================================================

func _seed_npc_schedule(
	npc_id: String,
	villager: Dictionary
) -> bool:

	if not villager.has("schedule"):

		print(
			"[DatabaseSeeder] NPC has no schedule: ",
			npc_id
		)

		return true

	var schedule = villager["schedule"]

	if not schedule is Array:

		push_error(
			"[DatabaseSeeder] Invalid schedule for NPC: "
			+ npc_id
		)

		return false

	for schedule_data in schedule:

		if not schedule_data is Dictionary:

			push_error(
				"[DatabaseSeeder] Invalid schedule entry for NPC: "
				+ npc_id
			)

			return false

		var start_time := str(
			schedule_data.get("time", "")
		)

		var location_id := str(
			schedule_data.get("place", "")
		)

		var action := str(
			schedule_data.get("action", "")
		)

		if start_time.is_empty():

			push_error(
				"[DatabaseSeeder] Schedule entry missing time: "
				+ npc_id
			)

			return false

		# ----------------------------------------------------
		# 確認 Location
		# ----------------------------------------------------

		if not location_id.is_empty():

			var location_result := DatabaseManager.select(
				"""
				SELECT location_id
				FROM location
				WHERE location_id = '%s'
				LIMIT 1;
				""" % _sql_escape(location_id)
			)

			if location_result.is_empty():

				push_error(
					"[DatabaseSeeder] Schedule references "
					+ "unknown location: "
					+ location_id
					+ " for NPC "
					+ npc_id
				)

				return false


		# ----------------------------------------------------
		# 寫入 Schedule
		# ----------------------------------------------------

		var query := """
		INSERT OR IGNORE INTO npc_schedule (
			npc_id,
			start_time,
			end_time,
			location_id,
			action
		)
		VALUES (
			'%s',
			'%s',
			NULL,
			'%s',
			'%s'
		);
		""" % [
			_sql_escape(npc_id),
			_sql_escape(start_time),
			_sql_escape(location_id),
			_sql_escape(action)
		]

		if not DatabaseManager.execute(query):

			push_error(
				"[DatabaseSeeder] Failed to insert schedule: "
				+ npc_id
				+ " / "
				+ start_time
			)

			return false

	return true


# ============================================================
# 取得 NPC 初始位置
# ============================================================
#
# 使用 schedule 第一筆 place。
#
# 例如：
#
# 08:00 → home_001
#
# 則：
#
# npc_state.location_id = home_001
#
# ============================================================

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
		first_schedule.get(
			"place",
			""
		)
	)


# ============================================================
# JSON Loader
# ============================================================

func _load_json(
	path: String
):

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

	var json = JSON.parse_string(
		content
	)

	if json == null:

		push_error(
			"[DatabaseSeeder] Failed to parse JSON: "
			+ path
		)

		return null

	return json


# ============================================================
# SQL String Escape
# ============================================================

func _sql_escape(
	value: String
) -> String:

	return value.replace(
		"'",
		"''"
	)
