extends Node

## =====================================================
## MigrationV8Test
##
## 驗證 issue #561／DatabaseSchema migration 8：既有資料庫（缺 NOT NULL
## 主鍵約束）的 npc／location，跑過 DatabaseSchema.initialize() 之後主鍵
## 補上 NOT NULL、原有資料保留、外鍵仍然生效。做法跟 MigrationV3Test／
## MigrationV6Test 同一套。
##
## location 有 7 張表外鍵指向它（npc 本身也是其中一張，透過
## home_location_id），npc 則有近 20 張表外鍵指向它（含比原始設計晚出現的
## npc_action_history），其中 grave／memories 還各自帶一張自己的子表
## （grave_epitaphs／memory_related_npcs）——改名 location／npc 時，SQLite
## 會把全部這些表的外鍵定義自動改指向暫存表名，這裡種好整條依附鏈的資料，
## 驗證重建後全部表的資料都保留、外鍵都改指向新表而不是停留在暫存表名。
##
## 使用方式：
## 1. 將本檔放到：
##      res://scripts/database/MigrationV8Test.gd
## 2. 建立一個暫時測試場景：
##      Node
##        └── MigrationV8Test
## 3. 將本腳本掛在 MigrationV8Test。
## 4. 執行測試場景。
##
## 注意：
## - 不使用 DatabaseManager 的正式資料庫（DATABASE_PATH），自己開一條獨立
##   的 SQLite 連線指向暫存檔，模擬「舊版程式碼建出來的資料庫」，測試結束
##   立刻刪除，不影響任何人的存檔。
## - npc／location 的舊版 CREATE TABLE 故意省略主鍵欄位的 NOT NULL——重現
##   既有資料庫的欄位定義，這是 migration 8 保證會修好的情形。其餘依附表
##   本身主鍵沒有 NOT NULL 缺口（migration 3／7 已修過，或本來就是
##   INTEGER PRIMARY KEY AUTOINCREMENT／已宣告 NOT NULL 的複合主鍵），
##   直接呼叫對應 *Schema.gd 的 create(db) 建立即可，不需要另外手刻舊版
##   SQL，也不會跟真實 schema 定義漂移。
## - user_version 設成 7（模擬「已經套用過 migration 2-7，只差 8」），
##   跟 MigrationV6Test 設成 5 是同一套模擬手法。
## =====================================================


const TEST_DB_PATH := "user://__migration_v8_test.db"

const LOCATION_A := "__migration_v8_test_loc_a"
const NPC_A := "__migration_v8_test_npc_a"
const NPC_B := "__migration_v8_test_npc_b"
const WORLD_A := "__migration_v8_test_world_a"
const ITEM_A := "__migration_v8_test_item_a"
const MEMORY_A := "__migration_v8_test_memory_a"

## 直接補 NOT NULL 主鍵的 2 張目標表。
const REBUILT_TABLES := [
	"location",
	"npc"
]

## 外鍵指向 npc／location（部分還帶自己的子表），重建時必須連帶處理的
## 依附表——本身主鍵沒有 NOT NULL 缺口，只驗證資料與外鍵沒有在重建過程中
## 被波及。
const DEPENDENT_TABLES := [
	"grave",
	"grave_epitaphs",
	"memories",
	"memory_related_npcs",
	"money_transaction",
	"item_transaction",
	"npc_action_history",
	"npc_appearance",
	"npc_condition",
	"npc_daily_plan",
	"npc_emotion",
	"npc_goal",
	"npc_home_storage",
	"npc_inventory",
	"npc_last_action",
	"npc_occupation",
	"npc_personality",
	"npc_relations",
	"npc_schedule",
	"npc_state",
	"npc_taboo",
	"npc_wallet",
	"world_character_state"
]

var passed := 0
var failed := 0
var db: SQLite


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	print("")
	print("=====================================================")
	print("[MigrationV8Test] START")
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
		"npc 資料內容保留",
		_npc_content_preserved(),
		"重建後 npc.name 欄位跟原始資料不符"
	)

	_check(
		"location 資料內容保留",
		_location_content_preserved(),
		"重建後 location.name 欄位跟原始資料不符"
	)

	_check(
		"NOT NULL 真的擋下 NULL 主鍵 INSERT（npc）",
		not _can_insert_null_npc_id(),
		"NULL npc_id 竟然插入成功，NOT NULL 沒生效"
	)

	_check(
		"外鍵仍然生效（npc_wallet → npc）",
		not _can_insert_orphan_npc_wallet(),
		"指向不存在 npc_id 的資料竟然插入成功，FK 沒生效"
	)

	for table in _all_user_tables():
		_check(
			"%s 外鍵沒有殘留指向暫存表" % table,
			not _foreign_key_targets_stale_table(table),
			"PRAGMA foreign_key_list(%s) 有外鍵仍指向 *__migrate_rebuild_old" % table
		)

	_check(
		"沒有殘留的 __migrate_rebuild_old 暫存表",
		_all_user_tables().filter(
			func(t: String): return t.ends_with("__migrate_rebuild_old")
		).is_empty(),
		"sqlite_master 還留著重建用的暫存表"
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

## 完整比照 LocationSchema.gd 目前的欄位（順序也要一致），只把主鍵的
## NOT NULL 拿掉——_migrate_rebuild_verify_column_shape() 用欄位名稱與
## 順序比對新舊表，缺欄位或順序不同會被當成「這個既有資料庫超出這個
## migration 的範圍」直接中止，不是這次要測的情境。
func _legacy_location_sql() -> String:
	return """
	CREATE TABLE location (
		location_id TEXT PRIMARY KEY,
		name TEXT NOT NULL,
		description TEXT DEFAULT '',
		location_type TEXT DEFAULT '',
		capacity INTEGER NOT NULL DEFAULT 0,
		danger INTEGER NOT NULL DEFAULT 0,
		is_active INTEGER NOT NULL DEFAULT 1
	);
	"""


## 完整比照 NPCSchema.gd 目前的欄位（順序也要一致），只把主鍵的 NOT NULL
## 拿掉，理由同 _legacy_location_sql()。
func _legacy_npc_sql() -> String:
	return """
	CREATE TABLE npc (
		npc_id TEXT PRIMARY KEY,
		name TEXT NOT NULL,
		age INTEGER NOT NULL DEFAULT 30,
		gender TEXT NOT NULL DEFAULT 'other',
		village_id TEXT NOT NULL DEFAULT 'default_village',
		character TEXT DEFAULT '',
		reputation INTEGER NOT NULL DEFAULT 0,
		system_prompt TEXT DEFAULT '',
		words_to_creator TEXT DEFAULT '',
		is_spoken INTEGER NOT NULL DEFAULT 0,
		generated_at TEXT,
		spoken_at TEXT,
		trigger TEXT,
		home_location_id TEXT NOT NULL,
		decision_source TEXT NOT NULL DEFAULT 'local',
		model_name TEXT DEFAULT '',
		is_active INTEGER NOT NULL DEFAULT 1,
		created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
		updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
		FOREIGN KEY (home_location_id)
			REFERENCES location(location_id)
			ON DELETE RESTRICT
	);
	"""


## 完整比照 NPCStateSchema.gd 目前的欄位（順序也要一致），只把主鍵的
## NOT NULL 拿掉——npc_state 本身在 migration 7 已經修過 NOT NULL，這裡
## 刻意重現「修過之前」的舊形狀，只用來驗證 migration 8 對它的
## repair_null_pk=false（預設）defensive 判斷本身是正確的，不代表這個
## table 在真正的 migration 鏈（3→8 依序套用）裡還可能出現這個缺口。
func _legacy_npc_state_sql() -> String:
	return """
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
	"""


func _seed_legacy_schema() -> bool:
	# --- location（舊版：location_id 缺 NOT NULL）---
	if not db.query(_legacy_location_sql()):
		push_error("[MigrationV8Test] seed location 建表失敗: " + db.error_message)
		return false

	# --- npc（舊版：npc_id 缺 NOT NULL）---
	if not db.query(_legacy_npc_sql()):
		push_error("[MigrationV8Test] seed npc 建表失敗: " + db.error_message)
		return false

	# world／item 本身不在這次 NOT NULL 修復範圍內，照現行 *Schema.gd 建立
	# 即可——這裡只需要它們當 money_transaction 以外幾張表的父表。
	if not WorldSchema.create(db) or not ItemSchema.create(db):
		push_error("[MigrationV8Test] seed world/item 失敗: " + db.error_message)
		return false

	# 全部依附表本身主鍵沒有 NOT NULL 缺口（已在 migration 3／7 修過，或本來
	# 就是 INTEGER PRIMARY KEY AUTOINCREMENT／已宣告 NOT NULL 的複合主鍵），
	# 直接用現行 *Schema.gd 建立，不需要另外手刻舊版 SQL。
	var dependent_schemas := [
		GraveSchema, GraveEpitaphSchema, MemorySchema, MoneyTransactionSchema,
		ItemTransactionSchema, NPCActionHistorySchema, NPCAppearanceSchema, NPCConditionSchema,
		NPCDailyPlanSchema, NPCEmotionSchema, NPCGoalSchema, NPCHomeStorageSchema,
		NPCInventorySchema, NPCLastActionSchema, NPCOccupationSchema,
		NPCPersonalitySchema, NPCRelationsSchema, NPCScheduleSchema,
		NPCStateSchema, NPCTabooSchema, NPCWalletSchema, WorldCharacterStateSchema
	]

	for schema in dependent_schemas:
		if not schema.create(db):
			push_error("[MigrationV8Test] seed 依附表建表失敗: " + db.error_message)
			return false

	# --- 父表資料 ---
	if not db.query_with_bindings(
		"INSERT INTO location (location_id, name) VALUES (?, ?);",
		[LOCATION_A, "測試地點"]
	):
		push_error("[MigrationV8Test] seed location 資料失敗: " + db.error_message)
		return false

	if not db.query_with_bindings(
		"INSERT INTO npc (npc_id, name, home_location_id) VALUES (?, ?, ?);",
		[NPC_A, "測試角色A", LOCATION_A]
	) or not db.query_with_bindings(
		"INSERT INTO npc (npc_id, name, home_location_id) VALUES (?, ?, ?);",
		[NPC_B, "測試角色B", LOCATION_A]
	):
		push_error("[MigrationV8Test] seed npc 資料失敗: " + db.error_message)
		return false

	if not db.query_with_bindings(
		"INSERT INTO world (world_id) VALUES (?);", [WORLD_A]
	):
		push_error("[MigrationV8Test] seed world 資料失敗: " + db.error_message)
		return false

	if not db.query_with_bindings(
		"INSERT INTO item (item_id, name) VALUES (?, ?);", [ITEM_A, "測試道具"]
	):
		push_error("[MigrationV8Test] seed item 資料失敗: " + db.error_message)
		return false

	# --- 依附表資料：整條鏈都種到，兩層鏈（grave→grave_epitaphs、
	# memories→memory_related_npcs）也要涵蓋 ---
	if not db.query_with_bindings(
		"""
		INSERT INTO grave (npc_id, location_id, buried_by)
		VALUES (?, ?, ?);
		""",
		[NPC_A, LOCATION_A, NPC_B]
	):
		push_error("[MigrationV8Test] seed grave 失敗: " + db.error_message)
		return false

	if not db.query("SELECT last_insert_rowid() AS id;"):
		push_error("[MigrationV8Test] 讀 grave_id 失敗: " + db.error_message)
		return false
	var grave_id: int = int(db.query_result[0].get("id", 0))

	if not db.query_with_bindings(
		"INSERT INTO grave_epitaphs (grave_id, npc_id, content) VALUES (?, ?, ?);",
		[grave_id, NPC_B, "測試悼詞"]
	):
		push_error("[MigrationV8Test] seed grave_epitaphs 失敗: " + db.error_message)
		return false

	if not db.query_with_bindings(
		"""
		INSERT INTO memories
			(memory_id, npc_id, content, created_tick, created_day, location_id)
		VALUES (?, ?, ?, ?, ?, ?);
		""",
		[MEMORY_A, NPC_A, "測試記憶", 1, 1, LOCATION_A]
	):
		push_error("[MigrationV8Test] seed memories 失敗: " + db.error_message)
		return false

	if not db.query_with_bindings(
		"INSERT INTO memory_related_npcs (memory_id, npc_id) VALUES (?, ?);",
		[MEMORY_A, NPC_B]
	):
		push_error("[MigrationV8Test] seed memory_related_npcs 失敗: " + db.error_message)
		return false

	if not db.query_with_bindings(
		"""
		INSERT INTO money_transaction (from_npc_id, to_npc_id, amount)
		VALUES (?, ?, ?);
		""",
		[NPC_A, NPC_B, 10]
	):
		push_error("[MigrationV8Test] seed money_transaction 失敗: " + db.error_message)
		return false

	if not db.query_with_bindings(
		"""
		INSERT INTO item_transaction (from_npc_id, to_npc_id, item_id, quantity)
		VALUES (?, ?, ?, ?);
		""",
		[NPC_A, NPC_B, ITEM_A, 1]
	):
		push_error("[MigrationV8Test] seed item_transaction 失敗: " + db.error_message)
		return false

	if not db.query_with_bindings(
		"""
		INSERT INTO npc_action_history (npc_id, game_day, game_minute, action)
		VALUES (?, ?, ?, ?);
		""",
		[NPC_A, 1, 480, "eat"]
	):
		push_error("[MigrationV8Test] seed npc_action_history 失敗: " + db.error_message)
		return false

	if not db.query_with_bindings(
		"INSERT INTO npc_appearance (npc_id) VALUES (?);", [NPC_A]
	):
		push_error("[MigrationV8Test] seed npc_appearance 失敗: " + db.error_message)
		return false

	if not db.query_with_bindings(
		"INSERT INTO npc_condition (npc_id, type) VALUES (?, ?);", [NPC_A, "sleepy"]
	):
		push_error("[MigrationV8Test] seed npc_condition 失敗: " + db.error_message)
		return false

	if not db.query_with_bindings(
		"INSERT INTO npc_daily_plan (npc_id, game_day) VALUES (?, ?);", [NPC_A, 1]
	):
		push_error("[MigrationV8Test] seed npc_daily_plan 失敗: " + db.error_message)
		return false

	if not db.query_with_bindings(
		"INSERT INTO npc_emotion (npc_id) VALUES (?);", [NPC_A]
	):
		push_error("[MigrationV8Test] seed npc_emotion 失敗: " + db.error_message)
		return false

	if not db.query_with_bindings(
		"INSERT INTO npc_goal (npc_id) VALUES (?);", [NPC_A]
	):
		push_error("[MigrationV8Test] seed npc_goal 失敗: " + db.error_message)
		return false

	if not db.query_with_bindings(
		"""
		INSERT INTO npc_home_storage (npc_id, item_id, slot)
		VALUES (?, ?, ?);
		""",
		[NPC_A, ITEM_A, 0]
	):
		push_error("[MigrationV8Test] seed npc_home_storage 失敗: " + db.error_message)
		return false

	if not db.query_with_bindings(
		"INSERT INTO npc_inventory (npc_id, slot, item_id) VALUES (?, ?, ?);",
		[NPC_A, 0, ITEM_A]
	):
		push_error("[MigrationV8Test] seed npc_inventory 失敗: " + db.error_message)
		return false

	if not db.query_with_bindings(
		"INSERT INTO npc_last_action (npc_id) VALUES (?);", [NPC_A]
	):
		push_error("[MigrationV8Test] seed npc_last_action 失敗: " + db.error_message)
		return false

	if not db.query_with_bindings(
		"INSERT INTO npc_occupation (npc_id) VALUES (?);", [NPC_A]
	):
		push_error("[MigrationV8Test] seed npc_occupation 失敗: " + db.error_message)
		return false

	if not db.query_with_bindings(
		"INSERT INTO npc_personality (npc_id) VALUES (?);", [NPC_A]
	):
		push_error("[MigrationV8Test] seed npc_personality 失敗: " + db.error_message)
		return false

	if not db.query_with_bindings(
		"INSERT INTO npc_relations (character_id, target_id) VALUES (?, ?);",
		[NPC_A, NPC_B]
	):
		push_error("[MigrationV8Test] seed npc_relations 失敗: " + db.error_message)
		return false

	if not db.query_with_bindings(
		"INSERT INTO npc_schedule (npc_id, start_time) VALUES (?, ?);",
		[NPC_A, "08:00"]
	):
		push_error("[MigrationV8Test] seed npc_schedule 失敗: " + db.error_message)
		return false

	if not db.query_with_bindings(
		"INSERT INTO npc_state (npc_id) VALUES (?);", [NPC_A]
	):
		push_error("[MigrationV8Test] seed npc_state 失敗: " + db.error_message)
		return false

	if not db.query_with_bindings(
		"INSERT INTO npc_taboo (npc_id) VALUES (?);", [NPC_A]
	):
		push_error("[MigrationV8Test] seed npc_taboo 失敗: " + db.error_message)
		return false

	if not db.query_with_bindings(
		"INSERT INTO npc_wallet (npc_id) VALUES (?);", [NPC_A]
	):
		push_error("[MigrationV8Test] seed npc_wallet 失敗: " + db.error_message)
		return false

	if not db.query_with_bindings(
		"""
		INSERT INTO world_character_state (world_id, npc_id, pos_x, pos_y)
		VALUES (?, ?, ?, ?);
		""",
		[WORLD_A, NPC_A, 10.0, 20.0]
	):
		push_error("[MigrationV8Test] seed world_character_state 失敗: " + db.error_message)
		return false

	if not db.query("PRAGMA user_version = 7;"):
		push_error("[MigrationV8Test] 設定 user_version 失敗: " + db.error_message)
		return false

	return true


## npc／location 都是根表（主鍵不是外鍵），NULL 主鍵可以安全補新 UUID
## （issue #566／P-69，跟 migration 7 的 world 同一套判斷）。種各一筆主鍵
## 是 NULL 的舊資料列，跑完 migration 後驗證：migration 成功、列數保留、
## NULL 那筆補到一個合法的 UUID。
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

	if not db.query(_legacy_location_sql()):
		_fail("null_pk_repair/seed location", db.error_message)
		return

	if not db.query(_legacy_npc_sql()):
		_fail("null_pk_repair/seed npc", db.error_message)
		return

	if not db.query_with_bindings(
		"INSERT INTO location (location_id, name) VALUES (?, ?);",
		[LOCATION_A, "測試地點"]
	) or not db.query_with_bindings(
		"INSERT INTO location (location_id, name) VALUES (?, ?);",
		[null, "沒有主鍵的舊地點"]
	):
		_fail("null_pk_repair/seed location rows", db.error_message)
		return

	if not db.query_with_bindings(
		"INSERT INTO npc (npc_id, name, home_location_id) VALUES (?, ?, ?);",
		[NPC_A, "測試角色A", LOCATION_A]
	) or not db.query_with_bindings(
		"INSERT INTO npc (npc_id, name, home_location_id) VALUES (?, ?, ?);",
		[null, "沒有主鍵的舊角色", LOCATION_A]
	):
		_fail("null_pk_repair/seed npc rows", db.error_message)
		return

	if not db.query("PRAGMA user_version = 7;"):
		_fail("null_pk_repair/set user_version", db.error_message)
		return

	_check(
		"npc／location 有 NULL 主鍵列時 migration 仍然成功（根表可以補新 ID）",
		DatabaseSchema.initialize(db),
		"initialize() 回傳 false"
	)

	_check(
		"location 列數保留（NULL 主鍵那筆沒被丟掉）",
		_count_rows("location") == 2,
		"got %d, expected 2" % _count_rows("location")
	)

	_check(
		"npc 列數保留（NULL 主鍵那筆沒被丟掉）",
		_count_rows("npc") == 2,
		"got %d, expected 2" % _count_rows("npc")
	)

	_check(
		"location 的 NULL 主鍵那筆補到一個合法的 UUID",
		_null_pk_row_repaired("location", "location_id", "name", "沒有主鍵的舊地點"),
		"name='沒有主鍵的舊地點' 那一列查不到，或補上去的 location_id 不像 UUID"
	)

	_check(
		"npc 的 NULL 主鍵那筆補到一個合法的 UUID",
		_null_pk_row_repaired("npc", "npc_id", "name", "沒有主鍵的舊角色"),
		"name='沒有主鍵的舊角色' 那一列查不到，或補上去的 npc_id 不像 UUID"
	)

	db.close_db()
	db = null
	_delete_test_db()


## 挑一張主鍵同時是外鍵的依附表（npc_state，指向 npc）：NULL 代表「不知道
## 這筆屬於哪個 npc」，這個資訊已經遺失，migration 7 對它維持預設
## repair_null_pk=false，不能亂補（issue #566／P-69，跟 migration 7 對
## npc_state 的判斷一致）。種一筆 npc_id 是 NULL 的舊資料列，驗證 migration
## 中止、ROLLBACK、原資料沒被動過。
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
		_legacy_location_sql(),
		_legacy_npc_sql(),
		_legacy_npc_state_sql()
	]

	for sql in statements:
		if not db.query(sql):
			_fail("null_pk_reject/seed", db.error_message)
			return

	if not db.query_with_bindings(
		"INSERT INTO location (location_id, name) VALUES (?, ?);",
		[LOCATION_A, "測試地點"]
	):
		_fail("null_pk_reject/seed location", db.error_message)
		return

	if not db.query_with_bindings(
		"INSERT INTO npc (npc_id, name, home_location_id) VALUES (?, ?, ?);",
		[NPC_A, "測試角色A", LOCATION_A]
	):
		_fail("null_pk_reject/seed npc", db.error_message)
		return

	if not db.query_with_bindings(
		"INSERT INTO npc_state (npc_id, satiety) VALUES (?, ?);", [null, 13.0]
	):
		_fail("null_pk_reject/seed npc_state", db.error_message)
		return

	if not db.query("PRAGMA user_version = 7;"):
		_fail("null_pk_reject/set user_version", db.error_message)
		return

	_check(
		"npc_state 有 NULL 主鍵列時 migration 中止（PK 同時是外鍵，不能亂補）",
		not DatabaseSchema.initialize(db),
		"initialize() 回傳 true——NULL 主鍵卻放行了"
	)

	_check(
		"中止後 user_version 保持在 7（ROLLBACK，不是半套）",
		_get_user_version() == 7,
		"got %d, expected 7" % _get_user_version()
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


func _npc_content_preserved() -> bool:
	if not db.query_with_bindings(
		"SELECT name FROM npc WHERE npc_id = ?;", [NPC_A]
	):
		return false

	if db.query_result.is_empty():
		return false

	return String(db.query_result[0].get("name", "")) == "測試角色A"


func _location_content_preserved() -> bool:
	if not db.query_with_bindings(
		"SELECT name FROM location WHERE location_id = ?;", [LOCATION_A]
	):
		return false

	if db.query_result.is_empty():
		return false

	return String(db.query_result[0].get("name", "")) == "測試地點"


func _can_insert_null_npc_id() -> bool:
	return db.query_with_bindings(
		"INSERT INTO npc (npc_id, name, home_location_id) VALUES (?, ?, ?);",
		[null, "不該插入成功", LOCATION_A]
	)


func _can_insert_orphan_npc_wallet() -> bool:
	return db.query_with_bindings(
		"INSERT INTO npc_wallet (npc_id) VALUES (?);",
		["__migration_v8_test_nonexistent_npc"]
	)


## 回傳資料庫裡所有應用程式 table（排除 sqlite_ 內部表）。用查詢代替
## 硬寫清單（REBUILT_TABLES／DEPENDENT_TABLES）——漏掉某張依附表時，
## 硬寫的清單也會一起漏掉，正好驗不到「表被 CASCADE 清空」這個最危險
## 的情形；REBUILT_TABLES 本身也可能帶外鍵（npc.home_location_id 指向
## location），查全部 table 才會連它們一起驗到。
func _all_user_tables() -> Array:
	if not db.query(
		"SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%';"
	):
		return []

	return (db.query_result as Array).map(func(row): return String(row.get("name", "")))


## PRAGMA foreign_key_list 的 "table" 欄位是這個外鍵目前實際指向的表名。
## 重建 npc／location 時如果漏了連帶重建某張依附表，它的外鍵會停留在
## SQLite 改名時自動重寫的暫存表名（例如 npc__migrate_rebuild_old），
## 而不是恢復指向新建的 npc／location。
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
func _null_pk_row_repaired(
	table: String, pk_column: String, marker_column: String, marker_value: String
) -> bool:
	if not db.query_with_bindings(
		"SELECT %s FROM %s WHERE %s = ?;" % [pk_column, table, marker_column],
		[marker_value]
	):
		return false

	if db.query_result.is_empty():
		return false

	var raw_id = db.query_result[0].get(pk_column, null)
	if typeof(raw_id) != TYPE_STRING:
		return false

	var repaired_id: String = raw_id
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
	print("[MigrationV8Test] RESULT")
	print("=====================================================")
	print("PASS: ", passed)
	print("FAIL: ", failed)

	if failed == 0:
		print("[MigrationV8Test] ALL TESTS PASSED")
	else:
		push_error("[MigrationV8Test] %d test(s) failed." % failed)

	print("=====================================================")

	queue_free()


func _delete_test_db() -> void:
	if FileAccess.file_exists(TEST_DB_PATH):
		DirAccess.remove_absolute(TEST_DB_PATH)
