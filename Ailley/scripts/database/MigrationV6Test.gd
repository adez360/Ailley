extends Node

## =====================================================
## MigrationV6Test
##
## 驗證 issue #514／DatabaseSchema migration 6：既有資料庫（缺 NOT NULL
## 主鍵約束）的 world／item／npc_state／npc_emotion／npc_goal，跑過
## DatabaseSchema.initialize() 之後主鍵補上 NOT NULL、原有資料保留、
## 外鍵仍然生效。做法跟 MigrationV3Test 同一套，差在這 5 張表沒有其他表
## 外鍵指向它們（不需要 memories 那種雙表協同重建），也沒有任何
## CREATE INDEX（*Schema.gd 查證過），不需要驗證索引重建後有沒有保留。
##
## 使用方式：
## 1. 將本檔放到：
##      res://scripts/database/MigrationV6Test.gd
## 2. 建立一個暫時測試場景：
##      Node
##        └── MigrationV6Test
## 3. 將本腳本掛在 MigrationV6Test。
## 4. 執行測試場景。
##
## 注意：
## - 不使用 DatabaseManager 的正式資料庫（DATABASE_PATH），自己開一條獨立
##   的 SQLite 連線指向暫存檔，模擬「舊版程式碼建出來的資料庫」，測試結束
##   立刻刪除，不影響任何人的存檔。
## - 手刻的「舊版」CREATE TABLE 欄位順序照抄現行 *Schema.gd，只故意省略
##   主鍵欄位的 NOT NULL——重現既有資料庫的欄位定義，這是 migration 6
##   保證會修好的情形。
## =====================================================


const TEST_DB_PATH := "user://__migration_v6_test.db"

const NPC_A := "__migration_v6_test_npc_a"
const LOCATION_A := "__migration_v6_test_loc_a"
const WORLD_A := "__migration_v6_test_world_a"
const ITEM_A := "__migration_v6_test_item_a"

const REBUILT_TABLES := [
	"world",
	"item",
	"npc_state",
	"npc_emotion",
	"npc_goal"
]

var passed := 0
var failed := 0
var db: SQLite


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	print("")
	print("=====================================================")
	print("[MigrationV6Test] START")
	print("=====================================================")

	_delete_test_db()

	db = SQLite.new()
	db.path = TEST_DB_PATH
	db.foreign_keys = true

	if not db.open_db():
		_fail("open_db", db.error_message)
		_finish()
		return

	if not _seed_legacy_schema():
		_fail("seed_legacy_schema", "建立舊版 schema／種子資料失敗")
		_finish()
		return

	var pre_counts := _row_counts()

	if not DatabaseSchema.initialize(db):
		_fail("DatabaseSchema.initialize", "回傳 false")
		_finish()
		return

	_check(
		"user_version bumped to CURRENT_VERSION",
		_get_user_version() == DatabaseSchema.CURRENT_VERSION,
		"got %d, expected %d" % [_get_user_version(), DatabaseSchema.CURRENT_VERSION]
	)

	for table in REBUILT_TABLES:
		_check(
			"%s 主鍵補上 NOT NULL" % table,
			_primary_key_is_notnull(table),
			"PRAGMA table_info(%s) 顯示主鍵欄位 notnull != 1" % table
		)

	var post_counts := _row_counts()
	for table in pre_counts:
		_check(
			"%s 列數保留（原 %d 筆）" % [table, pre_counts[table]],
			post_counts.get(table, -1) == pre_counts[table],
			"pre=%d post=%d" % [pre_counts[table], post_counts.get(table, -1)]
		)

	_check(
		"npc_state 資料內容保留",
		_npc_state_content_preserved(),
		"重建後 satiety 欄位跟原始資料不符"
	)

	_check(
		"NOT NULL 真的擋下 NULL 主鍵 INSERT（world）",
		not _can_insert_null_world_id(),
		"NULL world_id 竟然插入成功，NOT NULL 沒生效"
	)

	_check(
		"外鍵仍然生效（npc_emotion → npc）",
		not _can_insert_orphan_npc_emotion(),
		"指向不存在 npc_id 的資料竟然插入成功，FK 沒生效"
	)

	_finish()


# =====================================================
# 舊版 schema（缺 NOT NULL 主鍵）＋ 種子資料
# =====================================================

func _seed_legacy_schema() -> bool:
	var statements := [
		# 最小化父表，只給下面幾張子表滿足 FK 用，跟這次 migration 無關。
		"CREATE TABLE npc (npc_id TEXT PRIMARY KEY);",
		"CREATE TABLE location (location_id TEXT PRIMARY KEY);",

		# --- world（舊版：world_id 缺 NOT NULL）---
		"""
		CREATE TABLE world (
			world_id TEXT PRIMARY KEY,
			day INTEGER NOT NULL DEFAULT 1,
			allow_player_join INTEGER NOT NULL DEFAULT 0,
			created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
			updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
		);
		""",

		# --- item（舊版：item_id 缺 NOT NULL）---
		"""
		CREATE TABLE item (
			item_id TEXT PRIMARY KEY,
			name TEXT NOT NULL,
			item_type TEXT NOT NULL DEFAULT 'misc',
			description TEXT DEFAULT '',
			base_price INTEGER NOT NULL DEFAULT 0,
			max_stack INTEGER NOT NULL DEFAULT 30,
			is_consumable INTEGER NOT NULL DEFAULT 0,
			is_perishable INTEGER NOT NULL DEFAULT 0,
			decay_rate REAL NOT NULL DEFAULT 0,
			durability_cost INTEGER NOT NULL DEFAULT 0,
			effect_satiety INTEGER NOT NULL DEFAULT 0,
			effect_hydration INTEGER NOT NULL DEFAULT 0,
			effect_alcohol INTEGER NOT NULL DEFAULT 0,
			effect_injury INTEGER NOT NULL DEFAULT 0,
			is_active INTEGER NOT NULL DEFAULT 1
		);
		""",

		# --- npc_state（舊版：npc_id 缺 NOT NULL）---
		"""
		CREATE TABLE npc_state (
			npc_id TEXT PRIMARY KEY,
			satiety REAL NOT NULL DEFAULT 100.0,
			hydration REAL NOT NULL DEFAULT 80.0,
			stamina REAL NOT NULL DEFAULT 80.0,
			wakefulness REAL NOT NULL DEFAULT 90.0,
			hygiene REAL NOT NULL DEFAULT 70.0,
			alcohol REAL NOT NULL DEFAULT 0.0,
			health REAL NOT NULL DEFAULT 100.0,
			injury REAL NOT NULL DEFAULT 0.0,
			location_id TEXT,
			FOREIGN KEY (npc_id) REFERENCES npc(npc_id) ON DELETE CASCADE,
			FOREIGN KEY (location_id) REFERENCES location(location_id) ON DELETE SET NULL
		);
		""",

		# --- npc_emotion（舊版：npc_id 缺 NOT NULL）---
		"""
		CREATE TABLE npc_emotion (
			npc_id TEXT PRIMARY KEY,
			emotion TEXT NOT NULL DEFAULT 'neutral',
			intensity INTEGER NOT NULL DEFAULT 0,
			cause_event_id TEXT,
			duration_left INTEGER NOT NULL DEFAULT 0,
			updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
			FOREIGN KEY (npc_id) REFERENCES npc(npc_id) ON DELETE CASCADE
		);
		""",

		# --- npc_goal（舊版：npc_id 缺 NOT NULL）---
		"""
		CREATE TABLE npc_goal (
			npc_id TEXT PRIMARY KEY,
			current_goal TEXT NOT NULL DEFAULT '',
			updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
			FOREIGN KEY (npc_id) REFERENCES npc(npc_id) ON DELETE CASCADE
		);
		"""
	]

	for sql in statements:
		if not db.query(sql):
			push_error("[MigrationV6Test] seed CREATE TABLE failed: " + db.error_message)
			return false

	if not db.query_with_bindings(
		"INSERT INTO npc (npc_id) VALUES (?);", [NPC_A]
	) or not db.query_with_bindings(
		"INSERT INTO location (location_id) VALUES (?);", [LOCATION_A]
	):
		push_error("[MigrationV6Test] seed 父表資料失敗: " + db.error_message)
		return false

	if not db.query_with_bindings(
		"INSERT INTO world (world_id, day) VALUES (?, ?);",
		[WORLD_A, 5]
	):
		push_error("[MigrationV6Test] seed world 失敗: " + db.error_message)
		return false

	if not db.query_with_bindings(
		"INSERT INTO item (item_id, name) VALUES (?, ?);",
		[ITEM_A, "測試道具"]
	):
		push_error("[MigrationV6Test] seed item 失敗: " + db.error_message)
		return false

	if not db.query_with_bindings(
		"INSERT INTO npc_state (npc_id, satiety, location_id) VALUES (?, ?, ?);",
		[NPC_A, 42.0, LOCATION_A]
	):
		push_error("[MigrationV6Test] seed npc_state 失敗: " + db.error_message)
		return false

	if not db.query_with_bindings(
		"INSERT INTO npc_emotion (npc_id, emotion, intensity) VALUES (?, ?, ?);",
		[NPC_A, "joy", 50]
	):
		push_error("[MigrationV6Test] seed npc_emotion 失敗: " + db.error_message)
		return false

	if not db.query_with_bindings(
		"INSERT INTO npc_goal (npc_id, current_goal) VALUES (?, ?);",
		[NPC_A, "測試目標"]
	):
		push_error("[MigrationV6Test] seed npc_goal 失敗: " + db.error_message)
		return false

	if not db.query("PRAGMA user_version = 5;"):
		push_error("[MigrationV6Test] 設定 user_version 失敗: " + db.error_message)
		return false

	return true


# =====================================================
# 驗證用小工具
# =====================================================

func _get_user_version() -> int:
	if not db.query("PRAGMA user_version;"):
		return -1

	var result: Array = db.query_result
	if result.is_empty():
		return -1

	return int(result[0].values()[0])


func _primary_key_is_notnull(table: String) -> bool:
	if not db.query("PRAGMA table_info(%s);" % table):
		return false

	var pk_columns := (db.query_result as Array).filter(
		func(row): return int(row.get("pk", 0)) != 0
	)

	if pk_columns.is_empty():
		return false

	for col in pk_columns:
		if int(col.get("notnull", 0)) != 1:
			return false

	return true


func _row_counts() -> Dictionary:
	var counts := {}

	for table in REBUILT_TABLES:
		if db.query("SELECT COUNT(*) AS c FROM %s;" % table):
			counts[table] = int(db.query_result[0].get("c", -1))
		else:
			counts[table] = -1

	return counts


func _npc_state_content_preserved() -> bool:
	if not db.query_with_bindings(
		"SELECT satiety FROM npc_state WHERE npc_id = ?;", [NPC_A]
	):
		return false

	if db.query_result.is_empty():
		return false

	return is_equal_approx(float(db.query_result[0].get("satiety", 0.0)), 42.0)


func _can_insert_null_world_id() -> bool:
	return db.query_with_bindings(
		"INSERT INTO world (world_id, day) VALUES (?, ?);",
		[null, 1]
	)


func _can_insert_orphan_npc_emotion() -> bool:
	return db.query_with_bindings(
		"INSERT INTO npc_emotion (npc_id, emotion) VALUES (?, ?);",
		["__migration_v6_test_nonexistent_npc", "neutral"]
	)


# =====================================================
# 報告與收尾
# =====================================================

func _check(label: String, condition: bool, detail: String) -> void:
	if condition:
		passed += 1
		print("[PASS] %s" % label)
	else:
		_fail(label, detail)


func _fail(label: String, message: String) -> void:
	failed += 1
	push_error("[FAIL] %s: %s" % [label, message])


func _finish() -> void:
	if db != null:
		db.close_db()
		db = null

	_delete_test_db()

	print("")
	print("=====================================================")
	print("[MigrationV6Test] RESULT")
	print("=====================================================")
	print("PASS: ", passed)
	print("FAIL: ", failed)

	if failed == 0:
		print("[MigrationV6Test] ALL TESTS PASSED")
	else:
		push_error("[MigrationV6Test] %d test(s) failed." % failed)

	print("=====================================================")

	queue_free()


func _delete_test_db() -> void:
	if FileAccess.file_exists(TEST_DB_PATH):
		DirAccess.remove_absolute(TEST_DB_PATH)
