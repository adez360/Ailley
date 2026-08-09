##	開啟 game.db
##	關閉 game.db
##	執行 SQL
##	SELECT
##	INSERT
##	UPDATE
##	DELETE
##	Transaction

extends Node

## Ailley SQLite Database Manager
## 負責整個遊戲的 SQLite 資料庫連線與基本操作。

const DATABASE_PATH := "user://game.db"

var db: SQLite
var is_ready := false


func _ready() -> void:
	print("[Database] Initializing database...")

	db = SQLite.new()
	db.path = DATABASE_PATH

	if not db.open_db():
		push_error("[Database] Failed to open database: " + DATABASE_PATH)
		return

	is_ready = true

	print("[Database] Database opened successfully: ", DATABASE_PATH)

	var schema := DatabaseSchema.new()

	if not schema.initialize():
		push_error("[Database] Database schema initialization failed.")
		return

	print("[Database] Database initialization completed.")
	
	var seeder := DatabaseSeeder.new()

	if not seeder.initialize():
		push_error("[Database] Database seeding failed.")
		return

	print("[Database] Database initialization and seeding completed.")


func execute(query: String) -> bool:
	if not is_ready:
		push_error("[Database] Database is not ready.")
		return false

	var success := db.query(query)

	if not success:
		push_error("[Database] SQL query failed:\n" + query)
		return false

	return true


func select(query: String) -> Array:
	if not is_ready:
		push_error("[Database] Database is not ready.")
		return []

	if not db.query(query):
		push_error("[Database] SELECT query failed:\n" + query)
		return []

	return db.query_result


func insert(table: String, data: Dictionary) -> bool:
	if not is_ready:
		push_error("[Database] Database is not ready.")
		return false

	var columns: Array[String] = []
	var values: Array[String] = []

	for key in data.keys():
		columns.append(str(key))
		values.append(_sql_value(data[key]))

	var query := """
		INSERT INTO %s (%s)
		VALUES (%s)
	""" % [
		table,
		", ".join(columns),
		", ".join(values)
	]

	return execute(query)


func update(
	table: String,
	data: Dictionary,
	where_clause: String
) -> bool:
	if not is_ready:
		push_error("[Database] Database is not ready.")
		return false

	var assignments: Array[String] = []

	for key in data.keys():
		assignments.append(
			"%s = %s" % [
				key,
				_sql_value(data[key])
			]
		)

	var query := """
		UPDATE %s
		SET %s
		WHERE %s
	""" % [
		table,
		", ".join(assignments),
		where_clause
	]

	return execute(query)


func delete(
	table: String,
	where_clause: String
) -> bool:
	if not is_ready:
		push_error("[Database] Database is not ready.")
		return false

	var query := """
		DELETE FROM %s
		WHERE %s
	""" % [
		table,
		where_clause
	]

	return execute(query)


func table_exists(table_name: String) -> bool:
	var result := select(
		"""
		SELECT name
		FROM sqlite_master
		WHERE type = 'table'
		AND name = '%s'
		""" % table_name
	)

	return not result.is_empty()


func _sql_value(value: Variant) -> String:
	if value == null:
		return "NULL"

	if value is bool:
		return "1" if value else "0"

	if value is int or value is float:
		return str(value)

	if value is String:
		return "'%s'" % str(value).replace("'", "''")

	return "'%s'" % str(value).replace("'", "''")
