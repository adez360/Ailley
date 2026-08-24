extends Node

## =====================================================
## MigrationV6Test
##
## 驗證 issue #514／DatabaseSchema migration 6：既有資料庫（缺 NOT NULL
## 主鍵約束）的 world／item／npc_state／npc_emotion／npc_goal，跑過
## DatabaseSchema.initialize() 之後主鍵補上 NOT NULL、原有資料保留、
## 外鍵仍然生效。做法跟 MigrationV3Test 同一套。
##
## npc_state／npc_emotion／npc_goal 沒有其他表外鍵指向它們，也沒有任何
## CREATE INDEX（*Schema.gd 查證過），單表重建即可，不需要驗證索引。
##
## world／item 不是這種情形——world_character_state 外鍵指向
## world(world_id) ON DELETE CASCADE，npc_inventory／npc_home_storage／
## item_transaction 外鍵指向 item(item_id) ON DELETE RESTRICT。這裡額外
## seed 這 4 張依賴表的資料，驗證重建 world／item 後：這 4 張表的資料
## 沒有被 DROP 舊 world／item 時的隱含 DELETE（CASCADE）／FK 違規
## （RESTRICT）波及，外鍵也確實改指向新表而不是還留在暫存表名上
## （CodeRabbit review 抓到：原本的實作只重建 world／item 本身，沒有
## 連帶重建這 4 張子表）。
##
## issue #566／P-59：也驗證主鍵「已經是 NULL」的舊資料列——world 是根表
## （主鍵不是外鍵），NULL 主鍵要補新 UUID 保留；npc_state 主鍵同時是外鍵
## （指向 npc），NULL 沒辦法補，migration 要中止。
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
## - world／item 的舊版 CREATE TABLE 故意省略主鍵欄位的 NOT NULL——重現
##   既有資料庫的欄位定義，這是 migration 6 保證會修好的情形。
##   world_character_state／npc_inventory／npc_home_storage／
##   item_transaction 本身不在 NOT NULL 修復範圍內（它們的主鍵原本就
##   沒問題），照現行 *Schema.gd 原樣建立即可，只是拿來驗證它們的外鍵
##   在 world／item 重建過程中沒有被波及。
## =====================================================


const TEST_DB_PATH := "user://__migration_v6_test.db"

const NPC_A := "__migration_v6_test_npc_a"
const LOCATION_A := "__migration_v6_test_loc_a"
const WORLD_A := "__migration_v6_test_world_a"
const ITEM_A := "__migration_v6_test_item_a"

## 直接補 NOT NULL 主鍵的 5 張目標表。
const REBUILT_TABLES := [
	"world",
	"item",
	"npc_state",
	"npc_emotion",
	"npc_goal"
]

## 外鍵指向 world／item、重建時必須連帶處理的依賴表——本身主鍵沒有
## NOT NULL 缺口，只驗證資料沒有在重建過程中被波及。
const DEPENDENT_TABLES := [
	"world_character_state",
	"npc_inventory",
	"npc_home_storage",
	"item_transaction"
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

	var pre_counts := _row_counts(REBUILT_TABLES + DEPENDENT_TABLES)

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

	var post_counts := _row_counts(REBUILT_TABLES + DEPENDENT_TABLES)
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

	for table in DEPENDENT_TABLES:
		_check(
			"%s 外鍵沒有殘留指向暫存表" % table,
			not _foreign_key_targets_stale_table(table),
			"PRAGMA foreign_key_list(%s) 有外鍵仍指向 *__migrate_rebuild_old" % table
		)

	_check(
		"PRAGMA foreign_key_check 沒有違規",
		_foreign_key_check_clean(),
		"PRAGMA foreign_key_check 回傳非空結果——重建後有外鍵資料對不上"
	)

	_run_null_pk_repair_test()
	_run_null_pk_reject_test()

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
		""",

		# --- world_character_state（照現行 schema，主鍵本身沒問題）---
		"""
		CREATE TABLE world_character_state (
			world_id TEXT NOT NULL,
			npc_id TEXT NOT NULL,
			pos_x REAL NOT NULL DEFAULT 0.0,
			pos_y REAL NOT NULL DEFAULT 0.0,
			current_place TEXT,
			current_state TEXT,
			updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
			PRIMARY KEY (world_id, npc_id),
			FOREIGN KEY (world_id) REFERENCES world(world_id) ON DELETE CASCADE,
			FOREIGN KEY (npc_id) REFERENCES npc(npc_id) ON DELETE CASCADE
		);
		""",

		# --- npc_inventory（照現行 schema，主鍵本身沒問題）---
		"""
		CREATE TABLE npc_inventory (
			inventory_id INTEGER PRIMARY KEY AUTOINCREMENT,
			npc_id TEXT NOT NULL,
			slot INTEGER NOT NULL,
			item_id TEXT NOT NULL,
			count INTEGER NOT NULL DEFAULT 0,
			decay INTEGER NOT NULL DEFAULT 0,
			durability INTEGER NOT NULL DEFAULT 100,
			FOREIGN KEY (npc_id) REFERENCES npc(npc_id) ON DELETE CASCADE,
			FOREIGN KEY (item_id) REFERENCES item(item_id) ON DELETE RESTRICT,
			UNIQUE (npc_id, slot)
		);
		""",

		# --- npc_home_storage（照現行 schema，主鍵本身沒問題）---
		"""
		CREATE TABLE npc_home_storage (
			storage_id INTEGER PRIMARY KEY AUTOINCREMENT,
			npc_id TEXT NOT NULL,
			item_id TEXT NOT NULL,
			count INTEGER NOT NULL DEFAULT 0,
			decay INTEGER NOT NULL DEFAULT 0,
			durability INTEGER NOT NULL DEFAULT 100,
			slot INTEGER NOT NULL,
			updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
			FOREIGN KEY (npc_id) REFERENCES npc(npc_id) ON DELETE CASCADE,
			FOREIGN KEY (item_id) REFERENCES item(item_id) ON DELETE RESTRICT,
			UNIQUE (npc_id, slot)
		);
		""",

		# --- item_transaction（照現行 schema，主鍵本身沒問題）---
		"""
		CREATE TABLE item_transaction (
			transaction_id INTEGER PRIMARY KEY AUTOINCREMENT,
			from_npc_id TEXT,
			to_npc_id TEXT,
			item_id TEXT NOT NULL,
			quantity INTEGER NOT NULL,
			transaction_type TEXT NOT NULL DEFAULT 'trade',
			description TEXT NOT NULL DEFAULT '',
			created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
			FOREIGN KEY (from_npc_id) REFERENCES npc(npc_id) ON DELETE CASCADE,
			FOREIGN KEY (to_npc_id) REFERENCES npc(npc_id) ON DELETE CASCADE,
			FOREIGN KEY (item_id) REFERENCES item(item_id) ON DELETE RESTRICT,
			CHECK (quantity > 0),
			CHECK (from_npc_id IS NOT NULL OR to_npc_id IS NOT NULL)
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

	if not db.query_with_bindings(
		"INSERT INTO world_character_state (world_id, npc_id, pos_x, pos_y) VALUES (?, ?, ?, ?);",
		[WORLD_A, NPC_A, 10.0, 20.0]
	):
		push_error("[MigrationV6Test] seed world_character_state 失敗: " + db.error_message)
		return false

	if not db.query_with_bindings(
		"INSERT INTO npc_inventory (npc_id, slot, item_id, count) VALUES (?, ?, ?, ?);",
		[NPC_A, 0, ITEM_A, 3]
	):
		push_error("[MigrationV6Test] seed npc_inventory 失敗: " + db.error_message)
		return false

	if not db.query_with_bindings(
		"INSERT INTO npc_home_storage (npc_id, item_id, count, slot) VALUES (?, ?, ?, ?);",
		[NPC_A, ITEM_A, 5, 0]
	):
		push_error("[MigrationV6Test] seed npc_home_storage 失敗: " + db.error_message)
		return false

	if not db.query_with_bindings(
		"""
		INSERT INTO item_transaction (from_npc_id, to_npc_id, item_id, quantity)
		VALUES (?, ?, ?, ?);
		""",
		[NPC_A, null, ITEM_A, 1]
	):
		push_error("[MigrationV6Test] seed item_transaction 失敗: " + db.error_message)
		return false

	if not db.query("PRAGMA user_version = 5;"):
		push_error("[MigrationV6Test] 設定 user_version 失敗: " + db.error_message)
		return false

	return true


## world 是根表——world_id 不是外鍵，NULL 主鍵可以安全補新 UUID
## （issue #566／P-59）。種一筆 world_id 是 NULL 的舊資料列，跑完
## migration 後驗證：migration 成功、列數保留、NULL 那筆補到一個合法的
## UUID，其他欄位（day）內容沒有被搞壞。
func _run_null_pk_repair_test() -> void:
	if db != null:
		db.close_db()
		db = null

	_delete_test_db()

	db = SQLite.new()
	db.path = TEST_DB_PATH
	db.foreign_keys = true

	if not db.open_db():
		_fail("null_pk_repair/open_db", db.error_message)
		return

	if not db.query(
		"""
		CREATE TABLE world (
			world_id TEXT PRIMARY KEY,
			day INTEGER NOT NULL DEFAULT 1,
			allow_player_join INTEGER NOT NULL DEFAULT 0,
			created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
			updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
		);
		"""
	):
		_fail("null_pk_repair/seed", db.error_message)
		return

	if not db.query_with_bindings(
		"INSERT INTO world (world_id, day) VALUES (?, ?);", [WORLD_A, 5]
	) or not db.query_with_bindings(
		"INSERT INTO world (world_id, day) VALUES (?, ?);", [null, 99]
	):
		_fail("null_pk_repair/seed world", db.error_message)
		return

	if not db.query("PRAGMA user_version = 5;"):
		_fail("null_pk_repair/set user_version", db.error_message)
		return

	_check(
		"world 有 NULL 主鍵列時 migration 仍然成功（根表可以補新 ID）",
		DatabaseSchema.initialize(db),
		"initialize() 回傳 false"
	)

	_check(
		"world 列數保留（NULL 主鍵那筆沒被丟掉）",
		_count_rows("world") == 2,
		"got %d, expected 2" % _count_rows("world")
	)

	_check(
		"NULL 主鍵那筆補到一個合法的 UUID",
		_null_pk_row_repaired(),
		"day=99 那一列查不到，或補上去的 world_id 不像 UUID"
	)

	db.close_db()
	db = null
	_delete_test_db()


## npc_state 的主鍵同時是外鍵（指向 npc），NULL 代表「不知道這筆屬於
## 哪個 npc」，這個資訊已經遺失，不能補新 ID（issue #566／P-59）。種一筆
## npc_id 是 NULL 的舊資料列，驗證 migration 中止、ROLLBACK、原資料沒被
## 動過。
func _run_null_pk_reject_test() -> void:
	if db != null:
		db.close_db()
		db = null

	_delete_test_db()

	db = SQLite.new()
	db.path = TEST_DB_PATH
	db.foreign_keys = true

	if not db.open_db():
		_fail("null_pk_reject/open_db", db.error_message)
		return

	var statements := [
		"CREATE TABLE npc (npc_id TEXT PRIMARY KEY);",
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
			FOREIGN KEY (npc_id) REFERENCES npc(npc_id) ON DELETE CASCADE
		);
		"""
	]

	for sql in statements:
		if not db.query(sql):
			_fail("null_pk_reject/seed", db.error_message)
			return

	if not db.query_with_bindings(
		"INSERT INTO npc_state (npc_id, satiety) VALUES (?, ?);", [null, 13.0]
	):
		_fail("null_pk_reject/seed npc_state", db.error_message)
		return

	if not db.query("PRAGMA user_version = 5;"):
		_fail("null_pk_reject/set user_version", db.error_message)
		return

	_check(
		"npc_state 有 NULL 主鍵列時 migration 中止（PK 同時是外鍵，不能亂補）",
		not DatabaseSchema.initialize(db),
		"initialize() 回傳 true——NULL 主鍵卻放行了"
	)

	_check(
		"中止後 user_version 保持在 5（ROLLBACK，不是半套）",
		_get_user_version() == 5,
		"got %d, expected 5" % _get_user_version()
	)

	_check(
		"中止後 npc_state 舊資料仍在原表",
		_null_pk_reject_row_survived(),
		"npc_state 裡查不到 seed 時插入的 satiety=13.0"
	)

	db.close_db()
	db = null
	_delete_test_db()


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


func _row_counts(tables: Array) -> Dictionary:
	var counts := {}

	for table in tables:
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


## PRAGMA foreign_key_list 的 "table" 欄位是這個外鍵目前實際指向的表名。
## 重建 world／item 時如果漏了連帶重建這幾張依賴表，它們的外鍵會停留在
## SQLite 改名時自動重寫的暫存表名（例如 world__migrate_rebuild_old），
## 而不是恢復指向新建的 world／item——CodeRabbit review 抓到的正是這個。
func _foreign_key_targets_stale_table(table: String) -> bool:
	if not db.query("PRAGMA foreign_key_list(%s);" % table):
		return true

	for row in (db.query_result as Array):
		var target: String = row.get("table", "")
		if target.ends_with("__migrate_rebuild_old"):
			return true

	return false


func _foreign_key_check_clean() -> bool:
	if not db.query("PRAGMA foreign_key_check;"):
		return false

	return (db.query_result as Array).is_empty()


func _count_rows(table: String) -> int:
	if not db.query("SELECT COUNT(*) AS c FROM %s;" % table):
		return -1

	return int(db.query_result[0].get("c", -1))


## UUID v4 是 36 字元、4 個連字號（8-4-4-4-12）。不驗證精確演算法，
## 只驗證「看起來像 UUID」——這裡的重點是主鍵補上了合法值、資料沒對錯欄位。
func _null_pk_row_repaired() -> bool:
	if not db.query_with_bindings("SELECT world_id FROM world WHERE day = ?;", [99]):
		return false

	if db.query_result.is_empty():
		return false

	var repaired_id: String = db.query_result[0].get("world_id", "")
	return repaired_id.length() == 36 and repaired_id.count("-") == 4


func _null_pk_reject_row_survived() -> bool:
	if not db.query_with_bindings(
		"SELECT satiety FROM npc_state WHERE satiety = ?;", [13.0]
	):
		return false

	return not db.query_result.is_empty()


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
