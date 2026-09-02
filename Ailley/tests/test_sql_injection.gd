@tool
class_name TestSqlInjection
extends McpTestSuite

## DatabaseManager 對 SQL Injection 的兩層防護的回歸測試（issue #808）：
##
## 1. insert()/update()/query() 的資料值一律走 db.insert_row()/
##    db.query_with_bindings() 綁定參數，不拼字串——任何文字都只是被綁進
##    一個參數位置存進資料庫，不會被當成 SQL 語法解析。
## 2. select()/update()/delete() 的 WHERE 條件是呼叫端自行組的原始 SQL 字串
##    （需要 bindings 的查詢請改用 select_where()，見 DatabaseManager.gd 檔頭），
##    把文字拼進條件前靠 DatabaseManager.escape_sql_string() 轉義（單引號雙寫，
##    SQL 字串轉義的標準寫法）。
##
##    覆蓋範圍：本套件只覆蓋 DatabaseManager.escape_sql_string() 這一份，
##    sqlite_save_service.gd:451 的 _esc() 等處另有自己的同義副本（轉義規則
##    相同、不是同一行程式碼），不在覆蓋範圍。
##
## 不能直接用 autoload 單例（`DatabaseManager.xxx`）測：DatabaseManager.gd
## 不是 @tool script，test_run 在編輯器的 tool 環境裡執行，這時候引用
## autoload 名字拿到的只是型別為 Node 的 placeholder，呼叫任何腳本自己定義
## 的方法（insert()／select()／escape_sql_string()……）都會炸
## 「Attempt to call a method on a placeholder instance」——連 project_run
## 先把遊戲跑起來也一樣，test_run 不會跑進正在玩的那個遊戲行程裡，只在編輯器
## 自己的 tool 環境執行（實測過，見 PR 說明）。
##
## 改成用 load() 直接建一個獨立的 DatabaseManager 腳本實例（不透過 autoload
## 名字），接自己的 scratch SQLite 檔案、自建一張最小的測試表，這樣拿到的是
## 真正的物件（不是 placeholder），insert()/select()/select_where()/update()/
## delete()/escape_sql_string() 都是同一份正式程式碼，只是資料庫檔案跟正式
## 存檔完全分開，不會動到玩家真正的存檔。

## scratch DB 的實體路徑不能寫死：user:// 只認 project name、不分 worktree
## （見 note/技術/存檔.md「user:// 只認 project name，不分 worktree」），
## 比照 DatabaseManager.DATABASE_PATH（issue #334）用這個 checkout 的 res://
## 絕對路徑 sha256 組出實際路徑，多個平行 worktree 同時 test_run 才不會
## 共用／互刪同一份檔案。const 不能呼叫函式，這裡只留名稱，路徑在
## suite_setup() 內組（_scratch_db_path）。
const SCRATCH_DB_NAME := "__test_sql_injection_scratch"
const TAUTOLOGY_PAYLOAD := "x' OR '1'='1"
const DROP_PAYLOAD := "x'; DROP TABLE scratch; --"
const UNION_PAYLOAD := "x' UNION SELECT sql FROM sqlite_master --"

var _dbm: Node = null
var _scratch_db_path := ""


func suite_name() -> String:
	return "sql_injection"


func suite_setup(_ctx: Dictionary) -> void:
	var script: Script = load("res://scripts/database/DatabaseManager.gd")
	if script == null:
		fail_setup("找不到 res://scripts/database/DatabaseManager.gd")
		return

	_scratch_db_path = "user://%s_%s.db" % [
		SCRATCH_DB_NAME,
		CheckoutIsolation.compute_hash()
	]

	_dbm = script.new()
	# 不用 track()：那是給「每個測試各自建、每個測試跑完就該回收」的物件用的
	# （McpTestRunner 每一個 test_*() 跑完都會呼叫 _free_tracked()）。_dbm 是
	# suite 層級、整個 suite 共用同一個實例，生命週期要撐到 suite_teardown()，
	# 用 track() 會讓它在第一個測試跑完後就被釋放，後面的測試全部炸
	# 「previously freed」——改成自己在 suite_teardown() 手動 free()

	# 不呼叫 _dbm._ready()——那會去開正式存檔的 DATABASE_PATH。這裡自己接一個
	# scratch db，只建這個測試需要的最小表，不碰任何正式 schema 或種子資料
	DirAccess.remove_absolute(ProjectSettings.globalize_path(_scratch_db_path))

	_dbm.db = SQLite.new()
	_dbm.db.path = _scratch_db_path

	if not _dbm.db.open_db():
		fail_setup("scratch SQLite 開不起來：%s" % _dbm.db.error_message)
		return

	if not _dbm.db.query("CREATE TABLE IF NOT EXISTS scratch (id TEXT PRIMARY KEY, note TEXT)"):
		fail_setup("scratch 表建不起來：%s" % _dbm.db.error_message)
		return

	_dbm.is_ready = true


func suite_teardown() -> void:
	if _dbm != null and _dbm.db != null:
		_dbm.db.close_db()
	if _dbm != null:
		_dbm.free()
		_dbm = null
	if not _scratch_db_path.is_empty():
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_scratch_db_path))


func teardown() -> void:
	_dbm.delete("scratch", "id LIKE 'row_%'")


## escape_sql_string() 本身：單引號要雙寫，其他字元不動——這是 SQL 字串
## 轉義的標準寫法（讓攻擊者塞的 ' 沒辦法提前結束字面值，斷句去接後面的 SQL）
func test_escape_doubles_single_quotes() -> void:
	assert_eq(
		_dbm.escape_sql_string(TAUTOLOGY_PAYLOAD),
		"x'' OR ''1''=''1",
		"單引號應該被雙寫成兩個單引號"
	)
	assert_eq(
		_dbm.escape_sql_string("no quotes here"),
		"no quotes here",
		"沒有單引號的字串不該被改動"
	)


## 攻擊字串當一般欄位值走 insert()（bound 路徑）存進去，讀回來要逐字相同——
## 證明綁定參數把任何文字都當純資料存，不會被解析成 SQL 語法
func test_malicious_string_round_trips_verbatim_through_bound_insert() -> void:
	var combined := TAUTOLOGY_PAYLOAD + " | " + DROP_PAYLOAD + " | " + UNION_PAYLOAD

	assert_true(
		_dbm.insert("scratch", {"id": "row_roundtrip", "note": combined}),
		"帶攻擊字串的 insert() 不該因為內容含特殊字元而失敗"
	)

	var rows: Array = _dbm.select_where(
		"scratch", "id = ?", ["row_roundtrip"], ["note"]
	)

	assert_eq(rows.size(), 1, "應該查得到剛插入的那一列")
	if rows.size() == 1:
		assert_eq(
			rows[0]["note"],
			combined,
			"bound 路徑讀回來的字串應該跟存進去的一模一樣，不多不少"
		)


## 永真式（' OR '1'='1）payload 走 escape_sql_string() 拼進 select() 的
## conditions，轉義後應該變成一整段字面值，查不到任何一列——不能讓它
## 繞過原本的 id 比對、變成回傳全表
func test_tautology_condition_matches_nothing() -> void:
	assert_true(
		_dbm.insert("scratch", {"id": "row_tautology", "note": "irrelevant"}),
		"前置資料插不進去，下面的「查不到任何一列」就不具意義"
	)

	var condition := "id = '%s'" % _dbm.escape_sql_string(TAUTOLOGY_PAYLOAD)
	var rows: Array = _dbm.select("scratch", condition, ["id"])

	assert_false(
		_dbm.last_query_failed,
		"轉義後的條件應該是合法 SQL，查詢不該失敗——select() 對「查詢失敗」與「沒有符合的列」都回 []，空陣列若只是錯誤就不代表沒被繞過"
	)

	assert_eq(
		rows.size(), 0,
		"永真式 payload 轉義後應該查不到任何一列，不該繞過條件回傳全表"
	)


## '; DROP TABLE scratch; --' payload 走 escape_sql_string() 拼進 update() 的
## conditions，不該讓 DROP TABLE 真的執行——執行後 scratch 表要還在、列數不變
func test_drop_table_condition_does_not_drop_table() -> void:
	assert_true(_dbm.insert("scratch", {"id": "row_drop_update", "note": "irrelevant"}))

	var before_count: int = _dbm.select("scratch", "", ["id"]).size()

	var condition := "id = '%s'" % _dbm.escape_sql_string(DROP_PAYLOAD)
	# update() 比對不到任何列也算成功（影響 0 列不是錯誤）——這裡真正要驗證
	# 的是下面的表還在、列數沒被改動，不是這個回傳值本身
	_dbm.update("scratch", {"note": "changed"}, condition)

	var table_rows: Array = _dbm.select(
		"sqlite_master", "type = 'table' AND name = 'scratch'", ["name"]
	)
	assert_eq(table_rows.size(), 1, "scratch 表在 DROP TABLE payload 之後應該還在")

	var after_count: int = _dbm.select("scratch", "", ["id"]).size()
	assert_eq(after_count, before_count, "scratch 表列數不該因為 DROP TABLE payload 而改變")


## 同一個 DROP payload 換一條路徑（delete()）打，一樣不該真的砍表
func test_drop_table_condition_via_delete_does_not_drop_table() -> void:
	assert_true(_dbm.insert("scratch", {"id": "row_drop_delete", "note": "irrelevant"}))

	var before_count: int = _dbm.select("scratch", "", ["id"]).size()

	var condition := "id = '%s'" % _dbm.escape_sql_string(DROP_PAYLOAD)
	_dbm.delete("scratch", condition)

	var table_rows: Array = _dbm.select(
		"sqlite_master", "type = 'table' AND name = 'scratch'", ["name"]
	)
	assert_eq(table_rows.size(), 1, "scratch 表在 DROP TABLE payload（走 delete()）之後應該還在")

	var after_count: int = _dbm.select("scratch", "", ["id"]).size()
	assert_eq(
		after_count, before_count,
		"delete() 的條件比對不到任何列，不該有任何列被刪掉（也不該砍表）"
	)
