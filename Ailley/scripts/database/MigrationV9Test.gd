extends Node

## =====================================================
## MigrationV9Test
##
## 驗證 issue #601／DatabaseSchema migration 9：既有資料庫的 npc_relations
## 帶著已經沒有引擎消費者的 relations_trust 欄位，跑過 DatabaseSchema.initialize()
## 之後這一欄消失、其餘欄位（character_id／target_id／relations_appearance_cache／
## updated_at）與資料保留、外鍵與索引仍然生效。做法跟 MigrationV3Test／
## MigrationV6Test／MigrationV8Test 同一套。
##
## npc_relations 沒有其他表外鍵指向它（它自己外鍵指向 npc），單表重建即可，
## 但因為要拿掉一整欄，migration 走的是「明確列出保留欄位複製」而不是
## _migrate_rebuild_single_table() 的 INSERT ... SELECT *，這裡順便驗證
## 這條複製路徑沒有把資料錯位。
##
## 種子資料把 user_version 設成 8（migration 8 之後、9 之前的狀態），
## 讓 initialize() 只跑 migration 9，隔離驗證這一條。
##
## 另外還跑一段 user_version = 7 的完整鏈測試（_run_v7_chain_test()）：
## migration 8（issue #607）本身也會重建 npc_relations，而它拿掉 relations_trust
## 之前是呼叫活的 NPCRelationsSchema——issue #601 把 relations_trust 從那個
## class 移除後，DatabaseSchema._migrate_v8_notnull_primary_keys() 改成動態
## 判斷舊表有沒有這欄，有的話改用凍結的 _migrate_v8_create_npc_relations_with_trust()
## 重建（原樣保留，留給 migration 9 拿掉）。這段測的就是這條動態判斷本身：
## 種一個貨真價實帶 relations_trust 資料的 user_version=7 資料庫，驗證一路
## 經過 migration 8、9 之後，資料沒有因為欄位形狀比對而中止、trust 正確消失。
##
## 使用方式：
## 1. 本檔位置：res://scripts/database/MigrationV9Test.gd
## 2. 建立暫時測試場景：
##      Node
##        └── MigrationV9Test（掛本腳本）
## 3. 執行測試場景。
##
## 注意：不使用 DatabaseManager 的正式資料庫，自己開一條獨立 SQLite 連線
## 指向暫存檔，測試結束立刻刪除。
## =====================================================


const TEST_DB_PATH := "user://__migration_v9_test.db"

const NPC_A := "__migration_v9_test_npc_a"
const NPC_B := "__migration_v9_test_npc_b"
const LOCATION_A := "__migration_v9_test_loc_a"
const APPEARANCE := "剪短灰髮、左手皮手套"

var passed := 0
var failed := 0
var db: SQLite


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	print("")
	print("=====================================================")
	print("[MigrationV9Test] START")
	print("=====================================================")

	_run_isolated_v9_test()
	_run_v7_chain_test()

	_finish()


## 隔離測試：user_version 種在 8（migration 9 之前一步），只驗證 migration 9
## 自己那段「拿掉 relations_trust」的邏輯。
func _run_isolated_v9_test() -> void:
	_delete_test_db()

	db = SQLite.new()
	db.path = TEST_DB_PATH
	db.foreign_keys = true

	if not db.open_db():
		_fail("open_db", db.error_message)
		return

	if not _seed_legacy_schema():
		_fail("seed_legacy_schema", "建立舊版 schema／種子資料失敗")
		return

	var pre_count := _count_rows("npc_relations")

	if not DatabaseSchema.initialize(db):
		_fail("DatabaseSchema.initialize", "回傳 false")
		return

	_check(
		"user_version bumped to CURRENT_VERSION",
		_get_user_version() == DatabaseSchema.CURRENT_VERSION,
		"got %d, expected %d" % [_get_user_version(), DatabaseSchema.CURRENT_VERSION]
	)

	_check(
		"npc_relations 不再有 relations_trust 欄位",
		not _has_column("npc_relations", "relations_trust"),
		"PRAGMA table_info(npc_relations) 仍列出 relations_trust"
	)

	for col in ["relation_id", "character_id", "target_id", "relations_appearance_cache", "updated_at"]:
		_check(
			"npc_relations 保留 %s 欄位" % col,
			_has_column("npc_relations", col),
			"PRAGMA table_info(npc_relations) 少了 %s" % col
		)

	_check(
		"npc_relations 列數保留（原 %d 筆）" % pre_count,
		_count_rows("npc_relations") == pre_count,
		"pre=%d post=%d" % [pre_count, _count_rows("npc_relations")]
	)

	_check(
		"npc_relations 資料沒有錯位（character_id／target_id／appearance_cache）",
		_relation_row_preserved(),
		"重建後那筆資料的欄位值跟 seed 不符"
	)

	_check(
		"外鍵仍然生效（npc_relations → npc）",
		not _can_insert_orphan_relation(),
		"指向不存在 npc_id 的資料竟然插入成功，FK 沒生效"
	)

	_check(
		"索引重建（idx_npc_relations_character 存在）",
		_index_exists("idx_npc_relations_character"),
		"重建後查不到 idx_npc_relations_character"
	)

	_check(
		"PRAGMA foreign_key_check 沒有違規",
		_foreign_key_check_clean(),
		"PRAGMA foreign_key_check 回傳非空結果"
	)

	db.close_db()
	db = null
	_delete_test_db()


## 完整鏈測試：user_version 種在 7，只種 location／npc（真實主鍵，不需要
## repair_null_pk）與帶 relations_trust 資料的 npc_relations——其餘表交給
## initialize() 內建的 schemas 陣列用 CREATE TABLE IF NOT EXISTS 自己補齊
## （全新、0 筆資料，migration 8 重建它們時形狀天生一致，不需要另外種）。
## 一路跑過 migration 8（動態判斷出 npc_relations 帶 relations_trust，改用
## 凍結的 with-trust 形狀重建）與 migration 9（拿掉 relations_trust），
## 驗證這條完整鏈不會被 issue #601 的欄位變更中止，資料正確保留。
func _run_v7_chain_test() -> void:
	_delete_test_db()

	db = SQLite.new()
	db.path = TEST_DB_PATH
	db.foreign_keys = true

	if not db.open_db():
		_fail("v7_chain/open_db", db.error_message)
		return

	# location／npc 直接用現行 *Schema.gd 建立（不是手刻舊版 SQL）：這裡不測
	# migration 8 的 NOT NULL 修復（MigrationV8Test 已經測過），只是要有真實的
	# 父表資料給 npc_relations 掛。用現行 schema 建立可以避免它們自己在
	# migration 8 重建時撞上欄位形狀比對——道理跟下面 npc_relations 刻意用
	# 凍結形狀（而不是現行 NPCRelationsSchema）相反：npc_relations 才是這個
	# migration 真正要驗證的那張表。
	if not LocationSchema.create(db):
		_fail("v7_chain/seed location schema", db.error_message)
		return

	if not NPCSchema.create(db):
		_fail("v7_chain/seed npc schema", db.error_message)
		return

	if not DatabaseSchema._migrate_v8_create_npc_relations_with_trust(db):
		_fail("v7_chain/seed npc_relations schema", db.error_message)
		return

	if not db.query_with_bindings(
		"INSERT INTO location (location_id, name) VALUES (?, ?);",
		[LOCATION_A, "測試地點"]
	):
		_fail("v7_chain/seed location row", db.error_message)
		return

	if not db.query_with_bindings(
		"INSERT INTO npc (npc_id, name, home_location_id) VALUES (?, ?, ?);",
		[NPC_A, "測試角色A", LOCATION_A]
	) or not db.query_with_bindings(
		"INSERT INTO npc (npc_id, name, home_location_id) VALUES (?, ?, ?);",
		[NPC_B, "測試角色B", LOCATION_A]
	):
		_fail("v7_chain/seed npc rows", db.error_message)
		return

	if not db.query_with_bindings(
		"""
		INSERT INTO npc_relations
			(character_id, target_id, relations_trust, relations_appearance_cache)
		VALUES (?, ?, ?, ?);
		""",
		[NPC_A, NPC_B, 73, APPEARANCE]
	):
		_fail("v7_chain/seed npc_relations row", db.error_message)
		return

	if not db.query("PRAGMA user_version = 7;"):
		_fail("v7_chain/set user_version", db.error_message)
		return

	_check(
		"v7 資料庫（npc_relations 帶 relations_trust）一路跑過 migration 8／9 不中止",
		DatabaseSchema.initialize(db),
		"initialize() 回傳 false——migration 8 的動態判斷可能又被欄位形狀比對擋下"
	)

	_check(
		"v7_chain: user_version bumped to CURRENT_VERSION",
		_get_user_version() == DatabaseSchema.CURRENT_VERSION,
		"got %d, expected %d" % [_get_user_version(), DatabaseSchema.CURRENT_VERSION]
	)

	_check(
		"v7_chain: npc_relations 不再有 relations_trust 欄位",
		not _has_column("npc_relations", "relations_trust"),
		"PRAGMA table_info(npc_relations) 仍列出 relations_trust"
	)

	_check(
		"v7_chain: npc_relations 資料經過 8／9 兩次重建沒有錯位或遺失",
		_relation_row_preserved(),
		"重建後那筆資料的欄位值跟 seed 不符，或整筆不見了"
	)

	_check(
		"v7_chain: PRAGMA foreign_key_check 沒有違規",
		_foreign_key_check_clean(),
		"PRAGMA foreign_key_check 回傳非空結果"
	)

	db.close_db()
	db = null
	_delete_test_db()


# =====================================================
# 舊版 schema（帶 relations_trust）＋ 種子資料
# =====================================================

func _seed_legacy_schema() -> bool:
	var statements := [
		"CREATE TABLE npc (npc_id TEXT PRIMARY KEY);",

		# --- npc_relations（舊版：還帶 relations_trust）---
		"""
		CREATE TABLE npc_relations (
			relation_id INTEGER PRIMARY KEY AUTOINCREMENT,
			character_id TEXT NOT NULL,
			target_id TEXT NOT NULL,
			relations_trust INTEGER NOT NULL DEFAULT 20
				CHECK (relations_trust BETWEEN 0 AND 100),
			relations_appearance_cache TEXT NOT NULL DEFAULT ''
				CHECK (length(relations_appearance_cache) <= 20),
			updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
			FOREIGN KEY (character_id) REFERENCES npc(npc_id) ON DELETE CASCADE,
			FOREIGN KEY (target_id) REFERENCES npc(npc_id) ON DELETE CASCADE,
			UNIQUE (character_id, target_id),
			CHECK (character_id <> target_id)
		);
		""",
		"CREATE INDEX idx_npc_relations_character ON npc_relations(character_id);",
		"CREATE INDEX idx_npc_relations_target ON npc_relations(target_id);"
	]

	for sql in statements:
		if not db.query(sql):
			push_error("[MigrationV9Test] seed CREATE 失敗: " + db.error_message)
			return false

	if not db.query_with_bindings("INSERT INTO npc (npc_id) VALUES (?);", [NPC_A]) \
			or not db.query_with_bindings("INSERT INTO npc (npc_id) VALUES (?);", [NPC_B]):
		push_error("[MigrationV9Test] seed npc 失敗: " + db.error_message)
		return false

	if not db.query_with_bindings(
		"""
		INSERT INTO npc_relations
			(character_id, target_id, relations_trust, relations_appearance_cache)
		VALUES (?, ?, ?, ?);
		""",
		[NPC_A, NPC_B, 73, APPEARANCE]
	):
		push_error("[MigrationV9Test] seed npc_relations 失敗: " + db.error_message)
		return false

	if not db.query("PRAGMA user_version = 8;"):
		push_error("[MigrationV9Test] 設定 user_version 失敗: " + db.error_message)
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


func _has_column(table: String, column: String) -> bool:
	if not db.query("PRAGMA table_info(%s);" % table):
		return false
	for row in (db.query_result as Array):
		if String(row.get("name", "")) == column:
			return true
	return false


func _count_rows(table: String) -> int:
	if not db.query("SELECT COUNT(*) AS c FROM %s;" % table):
		return -1
	return int(db.query_result[0].get("c", -1))


func _relation_row_preserved() -> bool:
	if not db.query_with_bindings(
		"""
		SELECT target_id, relations_appearance_cache
		FROM npc_relations WHERE character_id = ?;
		""",
		[NPC_A]
	):
		return false
	if db.query_result.is_empty():
		return false
	var row: Dictionary = db.query_result[0]
	return String(row.get("target_id", "")) == NPC_B \
		and String(row.get("relations_appearance_cache", "")) == APPEARANCE


func _can_insert_orphan_relation() -> bool:
	return db.query_with_bindings(
		"INSERT INTO npc_relations (character_id, target_id) VALUES (?, ?);",
		["__migration_v9_test_nonexistent", NPC_B]
	)


func _index_exists(index_name: String) -> bool:
	if not db.query_with_bindings(
		"SELECT name FROM sqlite_master WHERE type = 'index' AND name = ?;",
		[index_name]
	):
		return false
	return not (db.query_result as Array).is_empty()


func _foreign_key_check_clean() -> bool:
	if not db.query("PRAGMA foreign_key_check;"):
		return false
	return (db.query_result as Array).is_empty()


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
	print("[MigrationV9Test] RESULT")
	print("=====================================================")
	print("PASS: ", passed)
	print("FAIL: ", failed)

	if failed == 0:
		print("[MigrationV9Test] ALL TESTS PASSED")
	else:
		push_error("[MigrationV9Test] %d test(s) failed." % failed)

	print("=====================================================")

	queue_free()


func _delete_test_db() -> void:
	if FileAccess.file_exists(TEST_DB_PATH):
		DirAccess.remove_absolute(TEST_DB_PATH)
