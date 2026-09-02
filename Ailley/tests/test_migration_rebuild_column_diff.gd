@tool
class_name TestMigrationRebuildColumnDiff
extends McpTestSuite

## DatabaseSchema 的 migration 重建工具擴充欄位形狀差異宣告的回歸測試
## （issue #962）：_migrate_rebuild_verify_column_shape() 從「兩邊欄位集合
## 必須完全一致」改成「差異只要落在 expected_added／expected_removed 宣告
## 範圍內就放行」，_migrate_rebuild_single_table()／_migrate_rebuild_table_group()
## 的 INSERT 改成明確指名共同欄位，不再靠 SELECT * 位置對應。
##
## 這裡直接呼叫 DatabaseSchema 的 static func（RefCounted + class_name，
## test_run 的 tool 環境下不是 placeholder，見 note/技術/自動化測試.md
## 「核心限制」），接自己的 scratch SQLite 連線建最小測試表，不碰任何正式
## schema 或種子資料——跟 test_sql_injection.gd 同一套隔離慣例。
##
## 既有 migration（3／7／9）目前只用到 expected_added 這個方向（migration 9
## 的 location entry，見 DatabaseSchema.gd），expected_removed 方向還沒有
## 任何正式 migration 使用（migration 10 仍是手刻版本，見它自己的檔頭
## 註解），這裡用合成情境直接驗證這個方向本身是對的。

const SCRATCH_DB_NAME := "__test_migration_rebuild_column_diff_scratch"

var _db: SQLite = null
var _scratch_db_path := ""


## 目標形狀比 old 多一欄 b（模擬「這次 migration 順便新增欄位」）。
class _SchemaAddColumn:
	static func create(db) -> bool:
		return db.query(
			"CREATE TABLE IF NOT EXISTS rebuild_add (id TEXT PRIMARY KEY, a TEXT, b TEXT DEFAULT 'default_b');"
		)


## 目標形狀比 old 少一欄 c（模擬「這次 migration 順便刪除欄位」）。
class _SchemaRemoveColumn:
	static func create(db) -> bool:
		return db.query(
			"CREATE TABLE IF NOT EXISTS rebuild_remove (id TEXT PRIMARY KEY, a TEXT);"
		)


## 同時新增 b、刪除 c——驗證兩個方向可以在同一次重建裡一起宣告。
class _SchemaAddAndRemoveColumn:
	static func create(db) -> bool:
		return db.query(
			"CREATE TABLE IF NOT EXISTS rebuild_add_remove (id TEXT PRIMARY KEY, a TEXT, b TEXT DEFAULT 'default_b');"
		)


## 欄位名稱跟 old 完全相同、只是順序不同——驗證新版驗證邏輯只比對名稱集合，
## 不再要求順序一致。
class _SchemaReordered:
	static func create(db) -> bool:
		return db.query(
			"CREATE TABLE IF NOT EXISTS rebuild_reorder (a TEXT, id TEXT PRIMARY KEY);"
		)


func suite_name() -> String:
	return "migration_rebuild_column_diff"


func suite_setup(_ctx: Dictionary) -> void:
	_scratch_db_path = "user://%s_%s.db" % [
		SCRATCH_DB_NAME,
		CheckoutIsolation.compute_hash()
	]

	DirAccess.remove_absolute(ProjectSettings.globalize_path(_scratch_db_path))

	_db = SQLite.new()
	_db.path = _scratch_db_path
	_db.foreign_keys = true

	if not _db.open_db():
		fail_setup("scratch SQLite 開不起來：%s" % _db.error_message)
		return


func suite_teardown() -> void:
	if _db != null:
		_db.close_db()
		_db = null
	if not _scratch_db_path.is_empty():
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_scratch_db_path))


## =====================================================
## _migrate_rebuild_verify_column_shape()：純欄位形狀比對，不搬資料
## =====================================================

func test_verify_allows_declared_added_column() -> void:
	_db.query("DROP TABLE IF EXISTS verify_add_old;")
	_db.query("DROP TABLE IF EXISTS verify_add_new;")
	_db.query("CREATE TABLE verify_add_old (id TEXT PRIMARY KEY, a TEXT);")
	_db.query("CREATE TABLE verify_add_new (id TEXT PRIMARY KEY, a TEXT, b TEXT);")

	assert_true(
		DatabaseSchema._migrate_rebuild_verify_column_shape(
			_db, "verify_add_old", "verify_add_new", ["b"], []
		),
		"new 多出一個宣告過的欄位 b，應該放行"
	)


func test_verify_allows_declared_removed_column() -> void:
	_db.query("DROP TABLE IF EXISTS verify_remove_old;")
	_db.query("DROP TABLE IF EXISTS verify_remove_new;")
	_db.query("CREATE TABLE verify_remove_old (id TEXT PRIMARY KEY, a TEXT, c TEXT);")
	_db.query("CREATE TABLE verify_remove_new (id TEXT PRIMARY KEY, a TEXT);")

	assert_true(
		DatabaseSchema._migrate_rebuild_verify_column_shape(
			_db, "verify_remove_old", "verify_remove_new", [], ["c"]
		),
		"old 多出一個宣告過的欄位 c，應該放行"
	)


func test_verify_rejects_undeclared_diff() -> void:
	_db.query("DROP TABLE IF EXISTS verify_reject_old;")
	_db.query("DROP TABLE IF EXISTS verify_reject_new;")
	_db.query("CREATE TABLE verify_reject_old (id TEXT PRIMARY KEY, a TEXT, c TEXT);")
	_db.query("CREATE TABLE verify_reject_new (id TEXT PRIMARY KEY, a TEXT, b TEXT);")

	# 不宣告任何差異（預設空陣列）——跟 #962 之前「一有差異就拒絕」的行為
	# 一致，這是既有 migration 3／7 仍在依賴的回歸保證。
	assert_true(
		not DatabaseSchema._migrate_rebuild_verify_column_shape(
			_db, "verify_reject_old", "verify_reject_new"
		),
		"沒宣告過的差異（old 多 c、new 多 b）應該被拒絕，不是放行"
	)


func test_verify_allows_reordered_columns_without_declaration() -> void:
	_db.query("DROP TABLE IF EXISTS verify_reorder_old;")
	_db.query("DROP TABLE IF EXISTS verify_reorder_new;")
	_db.query("CREATE TABLE verify_reorder_old (id TEXT PRIMARY KEY, a TEXT);")
	_db.query("CREATE TABLE verify_reorder_new (a TEXT, id TEXT PRIMARY KEY);")

	assert_true(
		DatabaseSchema._migrate_rebuild_verify_column_shape(
			_db, "verify_reorder_old", "verify_reorder_new"
		),
		"欄位名稱集合相同、只是順序不同時應該放行——INSERT 已改成明確指名" +
		"欄位，不再靠 SELECT * 位置對應，順序不影響正確性"
	)


## =====================================================
## _migrate_rebuild_common_columns()：算出的共同欄位清單
## =====================================================

func test_common_columns_excludes_added_and_removed() -> void:
	_db.query("DROP TABLE IF EXISTS common_old;")
	_db.query("DROP TABLE IF EXISTS common_new;")
	_db.query("CREATE TABLE common_old (id TEXT PRIMARY KEY, a TEXT, c TEXT);")
	_db.query("CREATE TABLE common_new (id TEXT PRIMARY KEY, a TEXT, b TEXT);")

	var columns := DatabaseSchema._migrate_rebuild_common_columns(_db, "common_old", "common_new")

	assert_eq(columns, ["id", "a"], "共同欄位應該只剩 id／a，b（新增）與 c（刪除）都不該出現")


## =====================================================
## _migrate_rebuild_single_table()：端到端重建＋搬資料
## =====================================================

func test_single_table_rebuild_fills_added_column_with_default() -> void:
	_db.query("DROP TABLE IF EXISTS rebuild_add;")
	_db.query("CREATE TABLE rebuild_add (id TEXT PRIMARY KEY, a TEXT);")
	_db.query_with_bindings(
		"INSERT INTO rebuild_add (id, a) VALUES (?, ?);", ["row1", "seed_a"]
	)

	var ok := DatabaseSchema._migrate_rebuild_single_table(
		_db, "rebuild_add", _SchemaAddColumn, false, ["b"], []
	)

	assert_true(ok, "宣告 expected_added=[\"b\"] 的重建應該成功")

	if ok:
		_db.query_with_bindings("SELECT a, b FROM rebuild_add WHERE id = ?;", ["row1"])
		var rows: Array = _db.query_result
		assert_eq(rows.size(), 1, "重建後應該還查得到原本那一列")
		if rows.size() == 1:
			assert_eq(rows[0]["a"], "seed_a", "共同欄位 a 的資料應該原封不動搬過去")
			assert_eq(
				rows[0]["b"], "default_b",
				"新欄位 b 沒有出現在明確指名的 INSERT 欄位清單裡，應該吃到 CREATE TABLE 的 DEFAULT"
			)


func test_single_table_rebuild_drops_removed_column_data() -> void:
	_db.query("DROP TABLE IF EXISTS rebuild_remove;")
	_db.query("CREATE TABLE rebuild_remove (id TEXT PRIMARY KEY, a TEXT, c TEXT);")
	_db.query_with_bindings(
		"INSERT INTO rebuild_remove (id, a, c) VALUES (?, ?, ?);",
		["row1", "seed_a", "seed_c_should_be_dropped"]
	)

	var ok := DatabaseSchema._migrate_rebuild_single_table(
		_db, "rebuild_remove", _SchemaRemoveColumn, false, [], ["c"]
	)

	assert_true(ok, "宣告 expected_removed=[\"c\"] 的重建應該成功")

	if ok:
		_db.query("PRAGMA table_info(rebuild_remove);")
		var columns: Array = (_db.query_result as Array).map(func(row): return row.get("name", ""))
		assert_true(not columns.has("c"), "重建後的表不該再有 c 欄位")

		_db.query_with_bindings("SELECT a FROM rebuild_remove WHERE id = ?;", ["row1"])
		var rows: Array = _db.query_result
		assert_eq(rows.size(), 1, "重建後應該還查得到原本那一列")
		if rows.size() == 1:
			assert_eq(rows[0]["a"], "seed_a", "保留的欄位 a 資料應該原封不動")


func test_single_table_rebuild_handles_add_and_remove_together() -> void:
	_db.query("DROP TABLE IF EXISTS rebuild_add_remove;")
	_db.query("CREATE TABLE rebuild_add_remove (id TEXT PRIMARY KEY, a TEXT, c TEXT);")
	_db.query_with_bindings(
		"INSERT INTO rebuild_add_remove (id, a, c) VALUES (?, ?, ?);",
		["row1", "seed_a", "seed_c_should_be_dropped"]
	)

	var ok := DatabaseSchema._migrate_rebuild_single_table(
		_db, "rebuild_add_remove", _SchemaAddAndRemoveColumn, false, ["b"], ["c"]
	)

	assert_true(ok, "同時宣告 expected_added=[\"b\"]／expected_removed=[\"c\"] 的重建應該成功")

	if ok:
		_db.query_with_bindings("SELECT a, b FROM rebuild_add_remove WHERE id = ?;", ["row1"])
		var rows: Array = _db.query_result
		assert_eq(rows.size(), 1, "重建後應該還查得到原本那一列")
		if rows.size() == 1:
			assert_eq(rows[0]["a"], "seed_a", "共同欄位 a 的資料應該原封不動搬過去")
			assert_eq(rows[0]["b"], "default_b", "新欄位 b 應該吃到 DEFAULT")

		_db.query("PRAGMA table_info(rebuild_add_remove);")
		var columns: Array = (_db.query_result as Array).map(func(row): return row.get("name", ""))
		assert_true(not columns.has("c"), "重建後的表不該再有 c 欄位")


func test_single_table_rebuild_rejects_undeclared_diff() -> void:
	_db.query("DROP TABLE IF EXISTS rebuild_reject;")
	_db.query("CREATE TABLE rebuild_reject (id TEXT PRIMARY KEY, a TEXT, legacy_extra TEXT);")
	_db.query_with_bindings(
		"INSERT INTO rebuild_reject (id, a, legacy_extra) VALUES (?, ?, ?);",
		["row1", "seed_a", "should_not_be_silently_dropped"]
	)

	# 故意不宣告 legacy_extra 是預期被刪除的欄位——重建應該拒絕，不是靜默
	# 把它當成「反正沒宣告就不搬」處理掉。
	var ok := DatabaseSchema._migrate_rebuild_single_table(
		_db, "rebuild_reject", _SchemaRemoveColumn, false, [], []
	)

	assert_true(not ok, "old 有一個沒宣告過的欄位 legacy_extra，重建應該拒絕")


func test_common_columns_reorder_still_copies_by_name() -> void:
	_db.query("DROP TABLE IF EXISTS rebuild_reorder;")
	_db.query("CREATE TABLE rebuild_reorder (id TEXT PRIMARY KEY, a TEXT);")
	_db.query_with_bindings(
		"INSERT INTO rebuild_reorder (id, a) VALUES (?, ?);", ["row1", "seed_a"]
	)

	var ok := DatabaseSchema._migrate_rebuild_single_table(
		_db, "rebuild_reorder", _SchemaReordered
	)

	assert_true(ok, "欄位順序不同、名稱集合相同時，重建應該成功（不需要宣告任何差異）")

	if ok:
		_db.query_with_bindings("SELECT a FROM rebuild_reorder WHERE id = ?;", ["row1"])
		var rows: Array = _db.query_result
		assert_eq(rows.size(), 1, "重建後應該還查得到原本那一列")
		if rows.size() == 1:
			assert_eq(rows[0]["a"], "seed_a", "改名指定欄位的 INSERT 不受新表欄位順序影響，資料應該對到正確欄位")
