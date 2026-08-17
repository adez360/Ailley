extends Node


## =====================================================
## Ailley SQLite Database Manager
##
## 負責：
##
## 1. 開啟 user://game.db
## 2. 建立 DatabaseSchema
## 3. 統一管理 SQLite CRUD
## 4. 啟動 CharacterStatePersistence
##
## CRUD 使用 godot-sqlite：
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


const DATABASE_PATH := "user://game.db"

# CRUD 診斷用的逐筆 print()。單一角色同步一輪就會觸發數十次 CRUD，
# 正常遊玩預設關閉；除錯時改成 true。錯誤路徑一律用 push_error()，
# 不受這個開關影響。
const VERBOSE_SQL := false


var db: SQLite
var is_ready := false

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
	# -------------------------------------------------

	DatabaseSeeder.seed_all()


	# -------------------------------------------------
	# CharacterStatePersistence
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

		return []


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

		return []


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


	if VERBOSE_SQL:
		print(
			"[Database] UPDATE | table=%s | conditions=%s | data=%s"
			% [
				table,
				conditions,
				update_data
			]
		)


	if db.update_rows(
		table,
		conditions,
		update_data
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


	if db.delete_rows(
		table,
		conditions
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

func begin_transaction() -> bool:

	return query(
		"BEGIN TRANSACTION;"
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
		"res://database/CharacterStatePersistence.gd"
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
