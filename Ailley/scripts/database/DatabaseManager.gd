extends Node


## =====================================================
## Ailley SQLite Database Manager
##
## 負責：
##
## 1. 開啟 DATABASE_PATH（依 checkout 算 hash，見下方）
## 2. 建立 DatabaseSchema
## 3. 統一管理 SQLite CRUD
## 4. 啟動 CharacterStatePersistence
##
## 只有 insert() 走 addon 的 insert_row；select() / update() / delete() 都是
## 自己拼 SQL 交給 query_with_bindings()（update() / delete() 見兩個函式的
## 註解——addon 的 update_rows / delete_rows 會把外層 begin_transaction()
## 開的交易提早 COMMIT 掉）。不管走哪條路，data 的值一律用 bindings 綁定，
## 不自己把值拼進 SQL 字串 —— 這個專案的記憶內容是 LLM 產的，拼字串等於
## 把它交給模型改寫。
##
##   insert_row()
##   select_rows / query_with_bindings
##   update_rows()
##   delete_rows()
##
## 對外 CRUD 介面：
##
##   query() / select() / select_where() / insert() / update() / delete()
##   begin_transaction() / commit_transaction() / rollback_transaction()
##
## 注意：
## conditions 是由程式內部組出的 SQL WHERE 條件。
## 不應直接放入玩家輸入。查詢有使用者可控或需要轉義的值時，
## 優先用 select_where() 走 bindings，不要自己 escape_sql_string() 拼字串。
## =====================================================


## user:// 只依 project.godot 的 project name 解析實體路徑，同一台機器上
## 所有 worktree／checkout 的 project name 都相同，寫死檔名會讓全機所有
## 平行 Godot process 共用同一個實體 SQLite 檔案、互相覆寫或撞 schema
## （issue #334）。用 CheckoutIsolation 算出的雜湊接在檔名後，讓不同
## worktree／匯出版本各自落地成不同檔案（issue #769／#987）。
var DATABASE_PATH := _compute_database_path()

# CRUD 診斷用的逐筆 print()。單一角色同步一輪就會觸發數十次 CRUD，
# 正常遊玩預設關閉；除錯時改成 true。錯誤路徑一律用 push_error()，
# 不受這個開關影響。
const VERBOSE_SQL := false


static func _compute_database_path() -> String:
	return "user://game_%s.db" % CheckoutIsolation.compute_hash()


var db: SQLite
var is_ready := false

## select()／select_where() 回傳空 Array 時，這個角色是「查詢真的失敗」
## 還是「查詢成功、只是沒有符合的資料列」無法從回傳值本身分辨——兩者都是
## `[]`。呼叫端（尤其是 has_character()／has_world() 這種把 is_empty() 當
## 存在判斷用的地方）需要分辨時，緊接著呼叫後檢查這個旗標。只有 select()／
## select_where() 會寫它；insert()／update()／delete() 有自己的 bool 回傳值，
## 不受影響。單一 Godot process 對應單一 db 連線，沒有並行呼叫，
## 呼叫完立刻檢查不會被別的查詢蓋掉（issue #439）
var last_query_failed := false

## is_ready 只代表「連線與 schema 都開好，CRUD 可以用」——DatabaseSeeder
## 自己就要靠 CRUD 才能把基礎資料寫進去，所以不能拿 is_ready 當作「seed
## 已完成」的訊號。呼叫端需要「基礎資料真的補齊了嗎」這個答案時
## 應該同時檢查這個旗標，而不是只看 is_ready。
var is_seeded := false

# table -> Array[String]，_table_has_column() 的欄位快取，
# schema 建立後不會再變，查一次記住即可，不必每次 UPDATE 都跑 PRAGMA
var _table_columns_cache := {}


# =====================================================
# Lifecycle
# =====================================================

func _ready() -> void:

	db = SQLite.new()

	db.path = DATABASE_PATH

	# 必須在 open_db() 前設定。
	# addon 會在開啟資料庫時設定 foreign_keys。
	db.foreign_keys = true


	if not db.open_db():

		push_error(
			"[Database] Failed to open %s: %s"
			% [
				DATABASE_PATH,
				db.error_message
			]
		)

		return


	print(
		"[Database] Opened database successfully: %s"
		% DATABASE_PATH
	)


	# -------------------------------------------------
	# Schema
	# -------------------------------------------------

	if not DatabaseSchema.initialize(db):

		push_error(
			"[Database] DatabaseSchema.initialize() failed."
		)

		db.close_db()

		return


	is_ready = true


	print(
		"[Database] Ready: %s"
		% DATABASE_PATH
	)


	# -------------------------------------------------
	# Seed
	#
	# DatabaseSeeder 自己要靠 is_ready 才能呼叫 CRUD，所以要排在
	# is_ready = true 之後；但 is_seeded 要等 seed 真的成功才設，
	# 消費端不該把「schema 開好」跟「基礎資料補齊」看成同一件事。
	# -------------------------------------------------

	if not DatabaseSeeder.seed_all():

		push_error(
			"[Database] "
			+ "Seed 失敗，資料庫可能不完整，不標記為 is_seeded。"
		)

	else:

		is_seeded = true


		# -------------------------------------------------
		# CharacterStatePersistence
		#
		# 排在 is_seeded 分支裡——item 這類基礎資料沒補齊時就開始寫入，
		# CharacterStatePersistence 可能因為外鍵約束（item_id 對不到任何
		# item row）整批失敗（CodeRabbit review 抓到）
		# -------------------------------------------------

		call_deferred(
			"_start_character_state_persistence"
		)


# =====================================================
# Exit
# =====================================================

func _exit_tree() -> void:

	if db != null:

		db.close_db()

		db = null

		is_ready = false
		is_seeded = false


# =====================================================
# Generic Query
# =====================================================

func query(
	sql: String,
	bindings: Array = []
) -> bool:

	if not _require_ready():
		return false


	if db.query_with_bindings(
		sql,
		bindings
	):

		return true


	push_error(
		"[Database] Query failed: %s\n%s"
		% [
			db.error_message,
			sql
		]
	)

	return false


# =====================================================
# Last Query Result
# =====================================================

func get_last_result() -> Array:

	if db == null:
		return []

	return db.query_result


# =====================================================
# SELECT
# =====================================================

func select(
	table: String,
	conditions: String = "",
	columns: Array = ["*"]
) -> Array:

	if not _require_ready():
		last_query_failed = true
		return []


	var cols := (
		", ".join(columns)
		if columns.size() > 0
		else "*"
	)


	var sql := (
		"SELECT %s FROM %s"
		% [
			cols,
			table
		]
	)


	if not conditions.is_empty():

		sql += (
			" WHERE %s"
			% conditions
		)


	if VERBOSE_SQL:
		print(
			"[Database] SELECT | table=%s | conditions=%s"
			% [
				table,
				conditions
			]
		)


	if not db.query_with_bindings(
		sql,
		[]
	):

		push_error(
			"[Database] SELECT FROM %s failed: %s"
			% [
				table,
				db.error_message
			]
		)

		last_query_failed = true
		return []


	last_query_failed = false
	return db.query_result


# =====================================================
# SELECT（bindings 版）
#
# conditions 帶 "?" 佔位符，值透過 bindings 陣列由
# query_with_bindings() 處理，不必自己轉義後拼字串。
# 呼叫端要用使用者可控或需要轉義的值組 WHERE 條件時，
# 一律走這個而不是自己 escape_sql_string() 轉義後拼進 select()。
# =====================================================

func select_where(
	table: String,
	where_sql: String,
	bindings: Array = [],
	columns: Array = ["*"]
) -> Array:

	if not _require_ready():
		last_query_failed = true
		return []


	var cols := (
		", ".join(columns)
		if columns.size() > 0
		else "*"
	)


	var sql := (
		"SELECT %s FROM %s"
		% [
			cols,
			table
		]
	)


	if not where_sql.is_empty():

		sql += (
			" WHERE %s"
			% where_sql
		)


	if VERBOSE_SQL:
		print(
			"[Database] SELECT_WHERE | table=%s | where=%s | bindings=%s"
			% [
				table,
				where_sql,
				bindings
			]
		)


	if not db.query_with_bindings(
		sql,
		bindings
	):

		push_error(
			"[Database] SELECT_WHERE FROM %s failed: %s"
			% [
				table,
				db.error_message
			]
		)

		last_query_failed = true
		return []


	last_query_failed = false
	return db.query_result


# =====================================================
# INSERT
#
# 失敗時直接看得到 SQLite error。
# 個別 table 的寫入後驗證（例如 npc_inventory）不在這裡做，
# 屬於通用 CRUD 不該知道特定 table 的欄位形狀，
# 由呼叫端（例如 CharacterStatePersistence）自行驗證。
# =====================================================

func insert(
	table: String,
	data: Dictionary
) -> bool:

	if not _require_ready():
		return false


	if table.strip_edges().is_empty():

		push_error(
			"[Database] INSERT table name is empty."
		)

		return false


	if data.is_empty():

		push_error(
			"[Database] INSERT data is empty | table=%s"
			% table
		)

		return false


	if VERBOSE_SQL:
		print(
			"[Database] INSERT START | table=%s"
			% table
		)

		print(
			"[Database] INSERT DATA | table=%s | data=%s"
			% [
				table,
				data
			]
		)


	# -------------------------------------------------
	# 實際 INSERT
	# -------------------------------------------------

	var result := db.insert_row(
		table,
		data
	)


	if VERBOSE_SQL:
		print(
			"[Database] INSERT RESULT | table=%s | result=%s | error=%s"
			% [
				table,
				str(result),
				db.error_message
			]
		)


	if not result:

		push_error(
			"[Database] INSERT INTO %s failed: %s"
			% [
				table,
				db.error_message
			]
		)

		return false


	if VERBOSE_SQL:
		print(
			"[Database] INSERT PASS | table=%s"
			% table
		)


	return true


# =====================================================
# UPDATE
# =====================================================

## 不走 addon 的 db.update_rows()——實測過（2026-08-18）它會把外層
## begin_transaction() 開的交易提早 COMMIT 掉（db.delete_rows() 同一個
## 毛病，db.insert_row() 沒有），"cannot commit - no transaction is active"
## 就是這樣來的，跟呼叫端寫得對不對無關。改用 query_with_bindings() 自己
## 拼帶 ? 佔位符的 UPDATE，值一樣是綁定參數，不是拼字串，不影響檔頭那條
## 「不要自己把值拼進 SQL 字串」的規則
func update(
	table: String,
	data: Dictionary,
	conditions: String
) -> bool:

	if not _require_ready():
		return false


	if conditions.strip_edges().is_empty():

		push_error(
			"[Database] UPDATE requires conditions."
		)

		return false


	if data.is_empty():

		push_error(
			"[Database] UPDATE data is empty | table=%s"
			% table
		)

		return false


	# -------------------------------------------------
	# Schema 中有 updated_at 的 table
	# 由 DatabaseManager 統一維護。
	# -------------------------------------------------

	var update_data := data.duplicate(
		true
	)


	if _table_has_column(
		table,
		"updated_at"
	):

		update_data["updated_at"] = (
			Time.get_datetime_string_from_system(
				true,
				false
			)
		)


	var assignments := []
	var bindings := []
	for key in update_data:
		assignments.append("%s = ?" % key)
		bindings.append(update_data[key])

	var sql := "UPDATE %s SET %s WHERE %s" % [
		table, ", ".join(assignments), conditions
	]

	if VERBOSE_SQL:
		print(
			"[Database] UPDATE | table=%s | conditions=%s | data=%s"
			% [
				table,
				conditions,
				update_data
			]
		)


	if db.query_with_bindings(
		sql,
		bindings
	):

		return true


	push_error(
		"[Database] UPDATE %s failed: %s"
		% [
			table,
			db.error_message
		]
	)

	return false


# =====================================================
# DELETE
# =====================================================

## 同 update() 的理由，不走 db.delete_rows()——它一樣會把外層交易提早
## COMMIT 掉。conditions 本來就是隻能由程式碼組的原始 SQL（見檔頭），
## 這裡沒有值要綁定，直接拼進 DELETE 語句
func delete(
	table: String,
	conditions: String
) -> bool:

	if not _require_ready():
		return false


	if conditions.strip_edges().is_empty():

		push_error(
			"[Database] DELETE requires conditions."
		)

		return false


	if VERBOSE_SQL:
		print(
			"[Database] DELETE | table=%s | conditions=%s"
			% [
				table,
				conditions
			]
		)


	if db.query_with_bindings(
		"DELETE FROM %s WHERE %s" % [table, conditions],
		[]
	):

		return true


	push_error(
		"[Database] DELETE FROM %s failed: %s"
		% [
			table,
			db.error_message
		]
	)

	return false


# =====================================================
# Transactions
# =====================================================

## BEGIN IMMEDIATE，不是預設的 deferred BEGIN——deferred 讓兩個連線可以先各自
## 讀到同一份快照，其中一個要寫入時才去搶鎖，衝突時機不確定（有時第一次寫入
## 就失敗、有時要等到 commit 才失敗）。IMMEDIATE 在 BEGIN 當下就直接拿寫鎖，
## 拿不到立刻確定失敗，不會有「讀完才發現寫不進去」的中間態。
##
## 沒有重試／backoff：MVP 單一 Godot process 對應單一 db 連線，同一個連線
## 不會有兩個交易互搶（實測過，第二次 BEGIN 直接失敗，見
## note/技術/存檔.md），這裡預留的是「同一 checkout 被多個 process 開啟、
## 搶同一份 DATABASE_PATH」的情況（跨 checkout 已靠雜湊隔開，不會撞）。
## 目前沒有任何呼叫端會製造這個情境（沒有多人連線）。真的接上多 process
## 寫入時才需要決定重試策略，不在這裡先猜
func begin_transaction() -> bool:

	return query(
		"BEGIN IMMEDIATE;"
	)


func commit_transaction() -> bool:

	return query(
		"COMMIT;"
	)


func rollback_transaction() -> bool:

	return query(
		"ROLLBACK;"
	)


# =====================================================
# Table Column Check
# =====================================================

func _table_has_column(
	table: String,
	column_name: String
) -> bool:

	if table.strip_edges().is_empty():
		return false


	if not _table_columns_cache.has(table):

		# PRAGMA 查詢會覆寫 db.query_result，先保存呼叫端原本的結果，
		# 查完欄位資訊後還原，避免 get_last_result() 拿到 PRAGMA 的資料
		var saved_query_result: Array = db.query_result

		if not db.query_with_bindings(
			"PRAGMA table_info(%s);"
			% table,
			[]
		):

			db.query_result = saved_query_result
			return false


		var columns := []

		for row in db.query_result:
			columns.append(
				str(
					row.get(
						"name",
						""
					)
				)
			)

		db.query_result = saved_query_result

		_table_columns_cache[table] = columns


	return column_name in _table_columns_cache[table]


# =====================================================
# Ready Check
# =====================================================

func _require_ready() -> bool:

	if is_ready:
		return true


	push_error(
		"[Database] Database is not ready."
	)

	return false


# =====================================================
# SQL Escape
#
# 給 update()/delete() 的 conditions 字串用——godot-sqlite
# 的 update_rows()/delete_rows() 不支援 bindings，仍得手動
# 轉義後拼字串。全專案共用這一份，其他檔案不要各自再刻一份，
# 呼叫 DatabaseManager.escape_sql_string()。
#
# SELECT 條件請改用 select_where()，走 bindings 不必轉義。
# =====================================================

func escape_sql_string(
	value: String
) -> String:

	return value.replace(
		"'",
		"''"
	)


# =====================================================
# CharacterStatePersistence
# =====================================================

func _start_character_state_persistence() -> void:

	if not is_inside_tree():
		return


	var script: Script = load(
		"res://scripts/database/CharacterStatePersistence.gd"
	)


	if script == null:

		push_error(
			"[Database] 找不到 CharacterStatePersistence.gd。"
		)

		return


	var existing := get_node_or_null(
		"CharacterStatePersistence"
	)


	if existing != null:

		print(
			"[Database] CharacterStatePersistence 已存在，"
			+ "不重複建立。"
		)

		return


	var persistence: Node = script.new()

	persistence.name = (
		"CharacterStatePersistence"
	)


	add_child(
		persistence
	)


	print(
		"[Database] CharacterStatePersistence started."
	)
