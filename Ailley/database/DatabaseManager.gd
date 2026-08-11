extends Node

## Ailley SQLite Database Manager
##
## 負責：
## 1. 開啟 SQLite
## 2. 建立資料庫 Schema
## 3. 執行 SQL
## 4. SELECT
## 5. INSERT
## 6. UPDATE
## 7. DELETE
## 8. Transaction
## 9. 執行初始資料 Seeder


const DATABASE_PATH := "user://game.db"


var db: SQLite
var is_ready := false


func _ready() -> void:

	print("[Database] Initializing database...")


	# ==================================================
	# 建立 SQLite
	# ==================================================

	db = SQLite.new()

	db.path = DATABASE_PATH


	# ==================================================
	# 開啟資料庫
	# ==================================================

	if not db.open_db():

		push_error(
			"[Database] Failed to open database: "
			+ DATABASE_PATH
		)

		return


	is_ready = true


	print(
		"[Database] Database opened successfully: ",
		DATABASE_PATH
	)


	# ==================================================
	# 啟用 Foreign Key
	# ==================================================

	if not db.query(
		"PRAGMA foreign_keys = ON;"
	):

		push_error(
			"[Database] Failed to enable foreign keys."
		)

		is_ready = false

		return


	print(
		"[Database] Foreign keys enabled."
	)


	# ==================================================
	# 建立資料表
	# ==================================================

	if not DatabaseSchema.initialize(db):

		push_error(
			"[Database] Database schema initialization failed."
		)

		is_ready = false

		return


	print(
		"[Database] Database schema initialized."
	)


	# ==================================================
	# Seeder
	# ==================================================

	if not DatabaseSeeder.initialize(db):

		push_error(
			"[Database] Database seeding failed."
		)

		is_ready = false

		return


	print(
		"[Database] Database initialization completed."
	)


# ======================================================
# Execute
# ======================================================

func execute(query: String) -> bool:

	if not is_ready:

		push_error(
			"[Database] Database is not ready."
		)

		return false


	var success := db.query(query)


	if not success:

		push_error(
			"[Database] SQL query failed:\n"
			+ query
		)

		return false


	return true


# ======================================================
# SELECT
# ======================================================

func select(query: String) -> Array:

	if not is_ready:

		push_error(
			"[Database] Database is not ready."
		)

		return []


	if not db.query(query):

		push_error(
			"[Database] SELECT query failed:\n"
			+ query
		)

		return []


	return db.query_result


# ======================================================
# INSERT
# ======================================================

func insert(
	table: String,
	data: Dictionary
) -> bool:

	if not is_ready:

		push_error(
			"[Database] Database is not ready."
		)

		return false


	if data.is_empty():

		push_error(
			"[Database] INSERT data is empty."
		)

		return false


	var columns: Array[String] = []
	var values: Array[String] = []


	for key in data.keys():

		columns.append(
			str(key)
		)

		values.append(
			_sql_value(data[key])
		)


	var query := """
		INSERT INTO %s (%s)
		VALUES (%s);
	""" % [
		table,
		", ".join(columns),
		", ".join(values)
	]


	return execute(query)


# ======================================================
# UPDATE
# ======================================================

func update(
	table: String,
	data: Dictionary,
	where_clause: String
) -> bool:

	if not is_ready:

		push_error(
			"[Database] Database is not ready."
		)

		return false


	if data.is_empty():

		push_error(
			"[Database] UPDATE data is empty."
		)

		return false


	if where_clause.strip_edges().is_empty():

		push_error(
			"[Database] UPDATE requires WHERE clause."
		)

		return false


	var assignments: Array[String] = []


	for key in data.keys():

		assignments.append(
			"%s = %s"
			% [
				str(key),
				_sql_value(data[key])
			]
		)


	var query := """
		UPDATE %s
		SET %s
		WHERE %s;
	""" % [
		table,
		", ".join(assignments),
		where_clause
	]


	return execute(query)


# ======================================================
# DELETE
# ======================================================

func delete(
	table: String,
	where_clause: String
) -> bool:

	if not is_ready:

		push_error(
			"[Database] Database is not ready."
		)

		return false


	if where_clause.strip_edges().is_empty():

		push_error(
			"[Database] DELETE requires WHERE clause."
		)

		return false


	var query := """
		DELETE FROM %s
		WHERE %s;
	""" % [
		table,
		where_clause
	]


	return execute(query)


# ======================================================
# Table Exists
# ======================================================

func table_exists(
	table_name: String
) -> bool:

	if not is_ready:

		return false


	var result := select(
		"""
		SELECT name
		FROM sqlite_master
		WHERE type = 'table'
		AND name = '%s';
		"""
		% _escape_string(table_name)
	)


	return not result.is_empty()


# ======================================================
# Transaction
# ======================================================

func begin_transaction() -> bool:

	return execute(
		"BEGIN TRANSACTION;"
	)


func commit_transaction() -> bool:

	return execute(
		"COMMIT;"
	)


func rollback_transaction() -> bool:

	return execute(
		"ROLLBACK;"
	)


# ======================================================
# SQL Value
# ======================================================

func _sql_value(
	value: Variant
) -> String:

	if value == null:

		return "NULL"


	if value is bool:

		return "1" if value else "0"


	if value is int or value is float:

		return str(value)


	if value is String:

		return "'%s'" % _escape_string(
			str(value)
		)


	return "'%s'" % _escape_string(
		str(value)
	)


# ======================================================
# SQL String Escape
# ======================================================

func _escape_string(
	value: String
) -> String:

	return value.replace(
		"'",
		"''"
	)
