extends Node

## =====================================================
## MigrationV3Test
##
## 驗證 issue #446／DatabaseSchema migration 3：
## 既有資料庫（缺 NOT NULL 主鍵約束）的 memories／memory_related_npcs／
## npc_appearance／npc_last_action／npc_occupation，跑過
## DatabaseSchema.initialize() 之後主鍵補上 NOT NULL、原有資料保留、
## 外鍵仍然生效。
##
## 使用方式：
## 1. 將本檔放到：
##      res://scripts/database/MigrationV3Test.gd
## 2. 建立一個暫時測試場景：
##      Node
##        └── MigrationV3Test
## 3. 將本腳本掛在 MigrationV3Test。
## 4. 執行測試場景。
##
## 注意：
## - 不使用 DatabaseManager 的正式資料庫（DATABASE_PATH），自己開一條獨立
##   的 SQLite 連線指向暫存檔，模擬「舊版程式碼建出來的資料庫」，測試結束
##   立刻刪除，不影響任何人的存檔。
## - 手刻的「舊版」CREATE TABLE 欄位順序照抄現行 *Schema.gd，只故意省略
##   主鍵欄位的 NOT NULL——重現 #446 描述的既有資料庫欄位定義。欄位順序
##   要跟現行 schema 一致，因為 migration 用 `INSERT INTO x SELECT * FROM
##   x_old` 是按欄位順序複製，順序對不上會複製到錯的欄位。
## =====================================================


const TEST_DB_PATH := "user://__migration_v3_test.db"

const MEMORY_A := "__migration_v3_test_mem_a"
const MEMORY_B := "__migration_v3_test_mem_b"
const NPC_A := "__migration_v3_test_npc_a"
const NPC_B := "__migration_v3_test_npc_b"
const LOCATION_A := "__migration_v3_test_loc_a"
const ITEM_A := "__migration_v3_test_item_a"

const REBUILT_TABLES := [
	"memories",
	"npc_appearance",
	"npc_last_action",
	"npc_occupation"
]

var passed := 0
var failed := 0
var db: SQLite


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	print("")
	print("=====================================================")
	print("[MigrationV3Test] START")
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

	_check(
		"memory_related_npcs 複合主鍵補上 NOT NULL",
		_primary_key_is_notnull("memory_related_npcs"),
		"PRAGMA table_info(memory_related_npcs) 顯示主鍵欄位 notnull != 1"
	)

	var post_counts := _row_counts()
	for table in pre_counts:
		_check(
			"%s 列數保留（原 %d 筆）" % [table, pre_counts[table]],
			post_counts.get(table, -1) == pre_counts[table],
			"pre=%d post=%d" % [pre_counts[table], post_counts.get(table, -1)]
		)

	_check(
		"memories 資料內容保留",
		_memory_content_preserved(),
		"重建後 content 欄位跟原始資料不符"
	)

	_check(
		"NOT NULL 真的擋下 NULL 主鍵 INSERT",
		not _can_insert_null_memory_id(),
		"NULL memory_id 竟然插入成功，NOT NULL 沒生效"
	)

	_check(
		"外鍵仍然生效（memory_related_npcs → memories）",
		not _can_insert_orphan_related_npc(),
		"指向不存在 memory_id 的資料竟然插入成功，FK 沒生效"
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
		"CREATE TABLE item (item_id TEXT PRIMARY KEY);",

		# --- memories（舊版：memory_id 缺 NOT NULL）---
		"""
		CREATE TABLE memories (
			memory_id TEXT PRIMARY KEY,
			npc_id TEXT NOT NULL,
			level INTEGER NOT NULL DEFAULT 1,
			content TEXT NOT NULL,
			valence TEXT NOT NULL DEFAULT 'neutral',
			importance INTEGER NOT NULL DEFAULT 0,
			decay_value INTEGER NOT NULL DEFAULT 100,
			created_tick INTEGER NOT NULL,
			created_day INTEGER NOT NULL,
			location_id TEXT,
			created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
			embedding TEXT,
			FOREIGN KEY (npc_id) REFERENCES npc(npc_id) ON DELETE CASCADE,
			FOREIGN KEY (location_id) REFERENCES location(location_id) ON DELETE SET NULL
		);
		""",

		# --- memory_related_npcs（舊版：memory_id／npc_id 缺 NOT NULL）---
		"""
		CREATE TABLE memory_related_npcs (
			memory_id TEXT,
			npc_id TEXT,
			PRIMARY KEY (memory_id, npc_id),
			FOREIGN KEY (memory_id) REFERENCES memories(memory_id) ON DELETE CASCADE,
			FOREIGN KEY (npc_id) REFERENCES npc(npc_id) ON DELETE CASCADE
		);
		""",

		# --- npc_appearance（舊版：npc_id 缺 NOT NULL）---
		"""
		CREATE TABLE npc_appearance (
			npc_id TEXT PRIMARY KEY,
			hair_id TEXT DEFAULT '',
			face_id TEXT DEFAULT '',
			clothes_id TEXT DEFAULT '',
			decoration1_id TEXT DEFAULT '',
			decoration2_id TEXT DEFAULT '',
			updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
			FOREIGN KEY (npc_id) REFERENCES npc(npc_id) ON DELETE CASCADE
		);
		""",

		# --- npc_last_action（舊版：npc_id 缺 NOT NULL）---
		"""
		CREATE TABLE npc_last_action (
			npc_id TEXT PRIMARY KEY,
			action TEXT NOT NULL DEFAULT '',
			target TEXT NOT NULL DEFAULT '',
			success INTEGER,
			reason TEXT,
			location_id TEXT,
			target_npc_id TEXT,
			target_item_id TEXT,
			action_started_at TEXT,
			action_finished_at TEXT,
			updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
			FOREIGN KEY (npc_id) REFERENCES npc(npc_id) ON DELETE CASCADE,
			FOREIGN KEY (location_id) REFERENCES location(location_id) ON DELETE SET NULL,
			FOREIGN KEY (target_npc_id) REFERENCES npc(npc_id) ON DELETE SET NULL,
			FOREIGN KEY (target_item_id) REFERENCES item(item_id) ON DELETE SET NULL
		);
		""",

		# --- npc_occupation（舊版：npc_id 缺 NOT NULL）---
		"""
		CREATE TABLE npc_occupation (
			npc_id TEXT PRIMARY KEY,
			occupation TEXT NOT NULL DEFAULT '',
			occupation_level INTEGER NOT NULL DEFAULT 1,
			workplace_id TEXT,
			work_start_time TEXT DEFAULT '',
			work_end_time TEXT DEFAULT '',
			salary INTEGER NOT NULL DEFAULT 0,
			working_days TEXT DEFAULT '',
			occupation_description TEXT DEFAULT '',
			is_employed INTEGER NOT NULL DEFAULT 0,
			updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
			FOREIGN KEY (npc_id) REFERENCES npc(npc_id) ON DELETE CASCADE,
			FOREIGN KEY (workplace_id) REFERENCES location(location_id) ON DELETE SET NULL
		);
		"""
	]

	for sql in statements:
		if not db.query(sql):
			push_error("[MigrationV3Test] seed CREATE TABLE failed: " + db.error_message)
			return false

	if not db.query_with_bindings(
		"INSERT INTO npc (npc_id) VALUES (?);", [NPC_A]
	) or not db.query_with_bindings(
		"INSERT INTO npc (npc_id) VALUES (?);", [NPC_B]
	) or not db.query_with_bindings(
		"INSERT INTO location (location_id) VALUES (?);", [LOCATION_A]
	) or not db.query_with_bindings(
		"INSERT INTO item (item_id) VALUES (?);", [ITEM_A]
	):
		push_error("[MigrationV3Test] seed 父表資料失敗: " + db.error_message)
		return false

	if not db.query_with_bindings(
		"""
		INSERT INTO memories
			(memory_id, npc_id, level, content, valence, importance,
			 decay_value, created_tick, created_day, location_id)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
		""",
		[MEMORY_A, NPC_A, 2, "測試記憶內容 A", "neutral", 50, 100, 10, 1, LOCATION_A]
	) or not db.query_with_bindings(
		"""
		INSERT INTO memories
			(memory_id, npc_id, level, content, valence, importance,
			 decay_value, created_tick, created_day, location_id)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
		""",
		[MEMORY_B, NPC_A, 2, "測試記憶內容 B", "positive", 60, 80, 20, 1, null]
	):
		push_error("[MigrationV3Test] seed memories 失敗: " + db.error_message)
		return false

	if not db.query_with_bindings(
		"INSERT INTO memory_related_npcs (memory_id, npc_id) VALUES (?, ?);",
		[MEMORY_A, NPC_B]
	):
		push_error("[MigrationV3Test] seed memory_related_npcs 失敗: " + db.error_message)
		return false

	if not db.query_with_bindings(
		"INSERT INTO npc_appearance (npc_id, hair_id) VALUES (?, ?);",
		[NPC_A, "test_hair"]
	):
		push_error("[MigrationV3Test] seed npc_appearance 失敗: " + db.error_message)
		return false

	if not db.query_with_bindings(
		"""
		INSERT INTO npc_last_action (npc_id, action, target, success, reason)
		VALUES (?, ?, ?, ?, ?);
		""",
		[NPC_A, "eat", "apple", null, null]
	):
		push_error("[MigrationV3Test] seed npc_last_action 失敗: " + db.error_message)
		return false

	if not db.query_with_bindings(
		"""
		INSERT INTO npc_occupation (npc_id, occupation, occupation_level, is_employed)
		VALUES (?, ?, ?, ?);
		""",
		[NPC_A, "farmer", 1, 1]
	):
		push_error("[MigrationV3Test] seed npc_occupation 失敗: " + db.error_message)
		return false

	if not db.query("PRAGMA user_version = 2;"):
		push_error("[MigrationV3Test] 設定 user_version 失敗: " + db.error_message)
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

	for table in ["memories", "memory_related_npcs", "npc_appearance", "npc_last_action", "npc_occupation"]:
		if db.query("SELECT COUNT(*) AS c FROM %s;" % table):
			counts[table] = int(db.query_result[0].get("c", -1))
		else:
			counts[table] = -1

	return counts


func _memory_content_preserved() -> bool:
	if not db.query_with_bindings(
		"SELECT content FROM memories WHERE memory_id = ?;", [MEMORY_A]
	):
		return false

	if db.query_result.is_empty():
		return false

	return db.query_result[0].get("content", "") == "測試記憶內容 A"


func _can_insert_null_memory_id() -> bool:
	return db.query_with_bindings(
		"""
		INSERT INTO memories
			(memory_id, npc_id, level, content, created_tick, created_day)
		VALUES (?, ?, ?, ?, ?, ?);
		""",
		[null, NPC_A, 1, "不該插入成功", 1, 1]
	)


func _can_insert_orphan_related_npc() -> bool:
	return db.query_with_bindings(
		"INSERT INTO memory_related_npcs (memory_id, npc_id) VALUES (?, ?);",
		["__migration_v3_test_nonexistent_memory", NPC_A]
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
	print("[MigrationV3Test] RESULT")
	print("=====================================================")
	print("PASS: ", passed)
	print("FAIL: ", failed)

	if failed == 0:
		print("[MigrationV3Test] ALL TESTS PASSED")
	else:
		push_error("[MigrationV3Test] %d test(s) failed." % failed)

	print("=====================================================")

	queue_free()


func _delete_test_db() -> void:
	if FileAccess.file_exists(TEST_DB_PATH):
		DirAccess.remove_absolute(TEST_DB_PATH)
