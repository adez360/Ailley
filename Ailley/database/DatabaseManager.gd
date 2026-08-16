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
## 注意：
## conditions 是由程式內部組出的 SQL WHERE 條件。
## 不應直接放入玩家輸入。
## =====================================================


const DATABASE_PATH := "user://game.db"


var db: SQLite
var is_ready := false


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
# INSERT
#
# 這裡增加完整診斷。
#
# 特別針對目前 npc_inventory 問題：
#
#   INSERT START
#   INSERT DATA
#   INSERT RESULT
#   INSERT VERIFY
#
# 如果 INSERT 失敗，可以直接看到 SQLite error。
# 如果 addon 回傳 true 但資料不存在，
# 也會直接被驗證抓出來。
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


	# -------------------------------------------------
	# 特別針對 npc_inventory：
	#
	# insert_row() 成功後再確認 row 是否真的存在。
	#
	# 不改變一般 table 的 CRUD 行為。
	# -------------------------------------------------

	if table == "npc_inventory":

		var npc_id := str(
			data.get(
				"npc_id",
				""
			)
		)


		var slot := int(
			data.get(
				"slot",
				-1
			)
		)


		if npc_id.is_empty():

			push_error(
				"[Database] npc_inventory INSERT "
				+ "成功回傳，但 npc_id 為空。"
			)

			return false


		if slot < 0:

			push_error(
				"[Database] npc_inventory INSERT "
				+ "成功回傳，但 slot 無效：%d"
				% slot
			)

			return false


		var verify_rows := select(
			"npc_inventory",
			"npc_id = '%s' AND slot = %d"
			% [
				_escape_sql(npc_id),
				slot
			],
			[
				"npc_id",
				"slot",
				"item_id",
				"count",
				"decay",
				"durability"
			]
		)


		print(
			"[Database] npc_inventory INSERT VERIFY | "
			+ "npc=%s | slot=%d | rows=%d"
			% [
				npc_id,
				slot,
				verify_rows.size()
			]
		)


		if verify_rows.is_empty():

			push_error(
				"[Database] npc_inventory INSERT "
				+ "回傳成功，但 SELECT 驗證不到資料："
				+ "npc=%s slot=%d"
				% [
					npc_id,
					slot
				]
			)

			return false


		print(
			"[Database] npc_inventory INSERT VERIFIED | "
			+ "npc=%s | slot=%d | row=%s"
			% [
				npc_id,
				slot,
				verify_rows[0]
			]
		)


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


	if not db.query_with_bindings(
		"PRAGMA table_info(%s);"
		% table,
		[]
	):

		return false


	for row in db.query_result:

		if str(
			row.get(
				"name",
				""
			)
		) == column_name:

			return true


	return false


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
# =====================================================

func _escape_sql(
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
