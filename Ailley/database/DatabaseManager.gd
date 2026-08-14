extends Node

## Ailley SQLite Database Manager
##
## 只負責三件事：
## 1. 開啟 user://game.db
## 2. 建立所有資料表（實際內容在 DatabaseSchema）
## 3. 把 godot-sqlite 的 CRUD 轉出去
##
## CRUD 一律走 addon 的 insert_row / select_rows / update_rows / delete_rows，
## 值會由 addon 綁定成參數。不要自己把值拼進 SQL 字串 ——
## 這個專案的記憶內容是 LLM 產的，拼字串等於把它交給模型改寫。
##
## conditions 參數是 WHERE 子句（不含 WHERE 關鍵字），它是原始 SQL，
## 只能由程式碼自己組，不可以放模型或玩家輸入的字串。


const DATABASE_PATH := "user://game.db"


var db: SQLite
var is_ready := false


func _ready() -> void:
	db = SQLite.new()
	db.path = DATABASE_PATH

	# 必須在 open_db() 之前設定：addon 是在開檔時才送出 PRAGMA foreign_keys
	db.foreign_keys = true

	if not db.open_db():
		push_error(
			"[Database] Failed to open %s: %s"
			% [DATABASE_PATH, db.error_message]
		)
		return

	if not DatabaseSchema.initialize(db):
		db.close_db()
		return

	is_ready = true

	print("[Database] Ready: ", DATABASE_PATH)


func _exit_tree() -> void:
	if db != null:
		db.close_db()


## 執行任意 SQL。值放進 bindings，不要拼進 sql。
func query(sql: String, bindings: Array = []) -> bool:
	if not _require_ready():
		return false

	if db.query_with_bindings(sql, bindings):
		return true

	push_error(
		"[Database] Query failed: %s\n%s"
		% [db.error_message, sql]
	)
	return false


## 上一次 query() / select() 的原始結果。
func get_last_result() -> Array:
	return db.query_result if db != null else []


func select(
	table: String,
	conditions: String = "",
	columns: Array = ["*"]
) -> Array:
	if not _require_ready():
		return []

	return db.select_rows(table, conditions, columns)


func insert(table: String, data: Dictionary) -> bool:
	if not _require_ready():
		return false

	if db.insert_row(table, data):
		return true

	push_error(
		"[Database] INSERT INTO %s failed: %s"
		% [table, db.error_message]
	)
	return false


func update(
	table: String,
	data: Dictionary,
	conditions: String
) -> bool:
	if not _require_ready():
		return false

	# 空 conditions 會變成「更新整張表」，不是呼叫端想要的
	if conditions.strip_edges().is_empty():
		push_error("[Database] UPDATE requires conditions.")
		return false

	if db.update_rows(table, conditions, data):
		return true

	push_error(
		"[Database] UPDATE %s failed: %s"
		% [table, db.error_message]
	)
	return false


func delete(table: String, conditions: String) -> bool:
	if not _require_ready():
		return false

	# 空 conditions 會清空整張表
	if conditions.strip_edges().is_empty():
		push_error("[Database] DELETE requires conditions.")
		return false

	if db.delete_rows(table, conditions):
		return true

	push_error(
		"[Database] DELETE FROM %s failed: %s"
		% [table, db.error_message]
	)
	return false


func begin_transaction() -> bool:
	return query("BEGIN TRANSACTION;")


func commit_transaction() -> bool:
	return query("COMMIT;")


func rollback_transaction() -> bool:
	return query("ROLLBACK;")


func _require_ready() -> bool:
	if is_ready:
		return true

	push_error("[Database] Database is not ready.")
	return false
