class_name DatabaseSchema
extends RefCounted


## =====================================================
## DatabaseSchema
##
## 職責：
## 1. 統一管理所有資料表 Schema
## 2. 決定資料表建立順序
## 3. 將 SQLite db 傳給各個 Schema
## 4. 用 PRAGMA user_version 追蹤 schema 版本，套用落後的 migration
## 5. 不直接撰寫資料表 SQL
##
## 注意：
## SQLite 的 CREATE TABLE 本身不要求父表先存在；
## 啟用 FK 後，真正要求父表存在的是 INSERT / UPDATE。
## 因此這裡仍依賴順序建立父表，但不把它描述成 SQLite
## 的 CREATE TABLE 強制規則。
##
## 版本控管：
## 全部 table 都用 CREATE TABLE IF NOT EXISTS，schema 改了
## 也不會補進已存在的舊資料庫。用 PRAGMA user_version 記錄
## 目前的 schema 版本；偵測到既有資料庫版本落後時，依序套用
## MIGRATIONS 補齊結構差異，全部套用成功才把版本寫成
## CURRENT_VERSION。版本比目前程式碼還新（例如同一 checkout 切回舊分支、
## 但 DATABASE_PATH 指向的 hashed database 被新分支開過）則直接拒絕啟動，
## 不嘗試往下相容。
## =====================================================


## schema 目前的版本。哪一支 *Schema.gd 的欄位／CHECK／FK／索引改了，
## 導致既有資料庫（DatabaseManager.DATABASE_PATH）建出來的 table 跟新版
## CREATE TABLE 對不上時，
## 這裡加一，並在 MIGRATIONS 補上對應 entry。純新增 table 不算——
## CREATE TABLE IF NOT EXISTS 自己會建，不需要 migration。
const CURRENT_VERSION := 10


## 版本落後時依序套用的變更，每個 entry：
##
##     { "version": <int>, "name": <String>, "apply": <Callable(db)->bool> }
##
## apply 只處理「既有 table 的結構變更」（ALTER TABLE／重建搬資料），
## 不要重複 CREATE TABLE——新表由 initialize() 裡的 schemas 陣列建立，
## 兩者跑在同一個 transaction 裡。
##
## 版本必須遞增排列。下次 schema 出現不相容變更時，在這裡按版本
## 加一項，同時把 CURRENT_VERSION 加一。
const MIGRATIONS: Array[Dictionary] = [
	{
		"version": 2,
		"name": "Backfill water.is_perishable and ale.decay_rate",
		"apply": Callable(DatabaseSchema, "_migrate_v2_backfill_decay")
	},
	{
		"version": 3,
		"name": "Rebuild memories/npc_appearance/npc_last_action/npc_occupation with NOT NULL primary keys",
		"apply": Callable(DatabaseSchema, "_migrate_v3_notnull_primary_keys")
	},
	{
		"version": 4,
		"name": "Add grave_epitaphs.content length CHECK (issue #382)",
		"apply": Callable(DatabaseSchema, "_migrate_v4_epitaph_length_check")
	},
	{
		"version": 5,
		"name": "Drop orphaned npc_death/grave_highlights tables (issue #512)",
		"apply": Callable(DatabaseSchema, "_migrate_v5_drop_death_grave_highlights")
	},
	{
		"version": 6,
		"name": "Rebuild idx_npc_action_history_npc as composite (npc_id, game_day, game_minute, id)",
		"apply": Callable(DatabaseSchema, "_migrate_v6_action_history_composite_index")
	},
	{
		"version": 7,
		"name": "Rebuild world/item/npc_state/npc_emotion/npc_goal with NOT NULL primary keys",
		"apply": Callable(DatabaseSchema, "_migrate_v7_notnull_primary_keys")
	},
	{
		"version": 8,
		"name": "Add world_character_state.following_npc_id (issue #576)",
		"apply": Callable(DatabaseSchema, "_migrate_v8_add_following_npc_id")
	},
	{
		"version": 9,
		"name": "Rebuild npc/location and all their dependent tables with NOT NULL primary keys",
		"apply": Callable(DatabaseSchema, "_migrate_v9_notnull_primary_keys")
	},
	{
		"version": 10,
		"name": "Drop npc_relations.relations_trust (issue #601)",
		"apply": Callable(DatabaseSchema, "_migrate_v10_drop_relations_trust")
	}
]


## Migration 2：修正先前 seed 遺漏的平衡數值——
## water.is_perishable 應為 0（不腐壞）、ale.decay_rate 應為 0.3。
## 只更新這兩個 item_id，不影響其他資料。獨立成具名函式而不是內嵌
## lambda：多陳述式的 block lambda 直接當 const 陣列/字典的值寫，
## GDScript parser 會在陣列結尾的 unindent 認錯縮排層級（實測 Parse Error），
## 獨立成函式沒有這個問題，也跟 _apply_migrations／_get_user_version 等既有
## static func 同一套寫法。
static func _migrate_v2_backfill_decay(db) -> bool:
	var water_sql := """
	UPDATE item
	SET is_perishable = 0
	WHERE item_id = 'water';
	"""

	var ale_sql := """
	UPDATE item
	SET decay_rate = 0.3
	WHERE item_id = 'ale';
	"""

	if not db.query(water_sql):
		push_error(
			"[DatabaseSchema] Migration 2: Failed to update water.is_perishable: "
			+ db.error_message
		)
		return false

	if not db.query(ale_sql):
		push_error(
			"[DatabaseSchema] Migration 2: Failed to update ale.decay_rate: "
			+ db.error_message
		)
		return false

	return true


## Migration 3：既有資料庫的 memories／npc_appearance／npc_last_action／
## npc_occupation 是在對應 *Schema.gd 補上 `NOT NULL PRIMARY KEY` 之前建的，
## SQLite 的 CREATE TABLE IF NOT EXISTS 不會回頭改這些舊 table 的欄位定義。
## 用標準 SQLite「舊表改名成暫存表 → 呼叫對應 *Schema.create(db) 建回原名
## 新結構 → 從暫存表複製資料 → 刪除暫存表」流程逐表重建，不在這裡重複
## CREATE TABLE SQL。
##
## 不在這段 transaction 內切換 PRAGMA foreign_keys——SQLite 交易中途不接受
## 切換，而且這裡的重建順序（子表先於父表 DROP）本來就不需要暫時關 FK。
static func _migrate_v3_notnull_primary_keys(db) -> bool:
	var single_table_schemas := [
		{"table": "npc_appearance", "schema": NPCAppearanceSchema},
		{"table": "npc_last_action", "schema": NPCLastActionSchema},
		{"table": "npc_occupation", "schema": NPCOccupationSchema}
	]

	for entry in single_table_schemas:
		if not _migrate_rebuild_single_table(db, entry["table"], entry["schema"]):
			return false

	return _migrate_v3_rebuild_memories(db)


## ALTER TABLE ... RENAME TO 會把表上的索引一起搬到暫存表，索引名稱不變。
## SQLite 的索引名稱在資料庫層級唯一，所以暫存表還占著原本的索引名稱時，
## schema.create(db) 的 CREATE INDEX IF NOT EXISTS 會直接跳過；等暫存表
## 之後被 DROP，那個索引就跟著消失，新表反而變成沒有索引。schema.create(db)
## 之前要先把暫存表上的索引清掉，讓索引名稱空出來給新表用。
## sqlite_autoindex_* 是 PRIMARY KEY 隱含建立的，跟著表本身建立／刪除，
## 不能也不需要手動 DROP。
##
## 版本無關的共用工具——migration 3（#446）與 migration 6（#514）都靠這個
## 重建流程補 NOT NULL 主鍵，函式名不再綁死 v3。
static func _migrate_rebuild_drop_stale_indexes(db, old_table_name: String) -> bool:
	if not db.query(
		"""
		SELECT name FROM sqlite_master
		WHERE type = 'index' AND tbl_name = '%s'
			AND name NOT LIKE 'sqlite_autoindex_%%';
		""" % old_table_name
	):
		push_error(
			"[DatabaseSchema] Table rebuild: Failed to query indexes on %s: %s"
			% [old_table_name, db.error_message]
		)
		return false

	var index_names: Array = (db.query_result as Array).map(
		func(row): return row.get("name", "")
	).filter(func(name: String): return not name.is_empty())

	for index_name in index_names:
		if not db.query("DROP INDEX %s;" % index_name):
			push_error(
				"[DatabaseSchema] Table rebuild: Failed to drop stale index %s: %s"
				% [index_name, db.error_message]
			)
			return false

	return true


## INSERT INTO x SELECT * FROM x_old 按欄位順序（不是名稱）複製。這個
## migration 只保證修好「既有資料庫僅缺 NOT NULL、其餘欄位定義跟現在
## 的 *Schema.gd 一致」這種情形——如果暫存表的欄位數剛好跟新表一樣，
## 但順序或語意不同（例如更早期的 schema 版本），SELECT * 會靜默把
## 資料複製到錯的欄位，不會報錯。INSERT 之前比對兩邊 PRAGMA table_info
## 的欄位名稱與順序，兜不起來就直接中止（呼叫端 ROLLBACK），不嘗試猜
## 欄位怎麼對應——這種既有資料庫已經超出這個 migration 的範圍，需要另外
## 判斷怎麼處理。版本無關的共用工具，理由同上——migration 3 與 6 共用。
static func _migrate_rebuild_verify_column_shape(db, old_name: String, new_name: String) -> bool:
	if not db.query("PRAGMA table_info(%s);" % old_name):
		push_error(
			"[DatabaseSchema] Table rebuild: Failed to read columns of %s: %s"
			% [old_name, db.error_message]
		)
		return false

	var old_columns: Array = (db.query_result as Array).map(
		func(row): return row.get("name", "")
	)

	if not db.query("PRAGMA table_info(%s);" % new_name):
		push_error(
			"[DatabaseSchema] Table rebuild: Failed to read columns of %s: %s"
			% [new_name, db.error_message]
		)
		return false

	var new_columns: Array = (db.query_result as Array).map(
		func(row): return row.get("name", "")
	)

	if old_columns == new_columns:
		return true

	push_error(
		(
			"[DatabaseSchema] Table rebuild: %s column shape doesn't match current "
			+ "schema (old=%s, new=%s) — refusing to copy data positionally with "
			+ "SELECT *. This existing database predates a schema change beyond "
			+ "the NOT NULL primary key fix this migration handles."
		) % [old_name, old_columns, new_columns]
	)
	return false


## 查一張既有表目前是否帶某個欄位。給 migration 9 的 npc_relations entry
## 動態選要用哪個 create_fn（見上面 _migrate_v9_notnull_primary_keys() 的
## 說明），版本無關的共用工具，一樣可以給之後別的 migration 用。
static func _migrate_table_has_column(db, table_name: String, column_name: String) -> bool:
	if not db.query("PRAGMA table_info(%s);" % table_name):
		return false

	for row in (db.query_result as Array):
		if String(row.get("name", "")) == column_name:
			return true

	return false


## 產生 UUID v4。演算法跟 character.gd::generate_id() 相同，這裡獨立一份
## 而不是直接呼叫 Character.generate_id()——DatabaseSchema 是資料庫層，
## 不依賴 Character 這個場景層的類別，純函式邏輯重複一份比跨層依賴划算。
static func _migrate_rebuild_generate_uuid() -> String:
	var bytes := Crypto.new().generate_random_bytes(16)
	bytes[6] = (bytes[6] & 0x0F) | 0x40		# version 4
	bytes[8] = (bytes[8] & 0x3F) | 0x80		# variant 10
	var hex := bytes.hex_encode()
	return "%s-%s-%s-%s-%s" % [
		hex.substr(0, 8), hex.substr(8, 4), hex.substr(12, 4),
		hex.substr(16, 4), hex.substr(20, 12)
	]


## 檢查／修復暫存表裡主鍵欄位為 NULL 的舊資料列（issue #566／P-69）。既有
## 資料庫在補上 NOT NULL 之前，TEXT PRIMARY KEY 不會自動蘊含 NOT NULL，
## 理論上可能已經寫入過主鍵是 NULL 的髒資料列；這種列跑後面的
## INSERT INTO ... SELECT * 會撞新表的 NOT NULL 約束、讓整個 migration
## 失敗，這裡先處理掉，給出比 SQL constraint error 更明確的結果。
##
## repair_null_pk 決定怎麼處理：
## - true（只用在 world／item／memories 這類主鍵是這張表自己獨立身分、
##   不是外鍵的「根表」）：幫每一筆 NULL 主鍵的舊資料列補一個新 UUID，
##   保留列數與其他欄位資料——NULL 沒有丟失任何可辨識的語意，補一個新
##   身分沒有問題。
## - false（預設，用在 npc_state／npc_emotion／npc_goal／npc_appearance／
##   npc_last_action／npc_occupation／memory_related_npcs 這類主鍵同時也
##   是外鍵，例如 npc_state.npc_id 指向 npc(npc_id) 的表）：NULL 代表
##   「不知道這筆屬於哪個父表資料」，這個資訊已經遺失，補一個新 UUID
##   對不到任何真實父表資料，只會讓 FK 約束擋下來——不猜，直接中止
##   migration，交給既有 ROLLBACK 機制，錯誤訊息列出表名與筆數讓人工
##   介入。
static func _migrate_rebuild_handle_null_primary_keys(
	db, old_name: String, table_name: String, repair_null_pk: bool
) -> bool:
	if not db.query("PRAGMA table_info(%s);" % old_name):
		push_error(
			"[DatabaseSchema] Table rebuild: Failed to read columns of %s: %s"
			% [table_name, db.error_message]
		)
		return false

	var pk_columns: Array = (db.query_result as Array).filter(
		func(row): return int(row.get("pk", 0)) != 0
	).map(func(row): return String(row.get("name", "")))

	if pk_columns.is_empty():
		return true

	var null_check := " OR ".join(pk_columns.map(func(col): return "%s IS NULL" % col))

	if not db.query("SELECT rowid FROM %s WHERE %s;" % [old_name, null_check]):
		push_error(
			"[DatabaseSchema] Table rebuild: Failed to check NULL primary keys in %s: %s"
			% [table_name, db.error_message]
		)
		return false

	var null_rowids: Array = (db.query_result as Array).map(
		func(row): return row.get("rowid")
	)

	if null_rowids.is_empty():
		return true

	if not repair_null_pk:
		push_error(
			(
				"[DatabaseSchema] Table rebuild: %s has %d row(s) with NULL primary "
				+ "key (%s) — this legacy database predates the NOT NULL fix and "
				+ "these rows can't be safely repaired (a freshly generated id "
				+ "can't recover whatever identity or relationship the lost value "
				+ "encoded). Refusing to migrate — see issue #566."
			) % [table_name, null_rowids.size(), ", ".join(pk_columns)]
		)
		return false

	if pk_columns.size() != 1:
		push_error(
			(
				"[DatabaseSchema] Table rebuild: %s has a composite primary key (%s) "
				+ "but repair_null_pk=true only supports single-column primary keys."
			) % [table_name, ", ".join(pk_columns)]
		)
		return false

	var pk_column: String = pk_columns[0]

	for rowid in null_rowids:
		if not db.query(
			"UPDATE %s SET %s = '%s' WHERE rowid = %s;"
			% [old_name, pk_column, _migrate_rebuild_generate_uuid(), rowid]
		):
			push_error(
				"[DatabaseSchema] Table rebuild: Failed to repair NULL primary key in %s: %s"
				% [table_name, db.error_message]
			)
			return false

	print(
		"[DatabaseSchema] Table rebuild: repaired %d row(s) with NULL primary key in %s"
		% [null_rowids.size(), table_name]
	)

	return true


## 沒有其他表外鍵指向的單一表重建：改名成暫存表 → 用 schema.create(db)
## 建回原名的新結構 → 把資料從暫存表複製回來 → 刪掉暫存表。版本無關的
## 共用工具——migration 3 與 6 共用，暫存表名不再帶版本號。
##
## repair_null_pk 見 _migrate_rebuild_handle_null_primary_keys() 的說明——
## 只有主鍵是這張表自己獨立身分（不是外鍵）時才傳 true。
static func _migrate_rebuild_single_table(
	db, table_name: String, schema, repair_null_pk: bool = false
) -> bool:
	var old_name := table_name + "__migrate_rebuild_old"

	if not db.query("ALTER TABLE %s RENAME TO %s;" % [table_name, old_name]):
		push_error(
			"[DatabaseSchema] Table rebuild: Failed to rename %s: %s"
			% [table_name, db.error_message]
		)
		return false

	if not _migrate_rebuild_drop_stale_indexes(db, old_name):
		return false

	if not schema.create(db):
		push_error(
			"[DatabaseSchema] Table rebuild: Failed to recreate %s: %s"
			% [table_name, db.error_message]
		)
		return false

	if not _migrate_rebuild_verify_column_shape(db, old_name, table_name):
		return false

	if not _migrate_rebuild_handle_null_primary_keys(db, old_name, table_name, repair_null_pk):
		return false

	if not db.query("INSERT INTO %s SELECT * FROM %s;" % [table_name, old_name]):
		push_error(
			"[DatabaseSchema] Table rebuild: Failed to copy data into %s: %s"
			% [table_name, db.error_message]
		)
		return false

	if not db.query("DROP TABLE %s;" % old_name):
		push_error(
			"[DatabaseSchema] Table rebuild: Failed to drop %s: %s"
			% [old_name, db.error_message]
		)
		return false

	return true


## 一組互相依賴的表一起重建：`entries` 依「父表在前、子表在後」排列
## （例如 `[{"table": "item", ...}, {"table": "npc_inventory", ...}]`）。
## 子表若有外鍵指向這組裡的父表，改名父表時 SQLite 會把子表的外鍵定義
## 自動改指向父表的暫存表名（跟單表重建的原理一樣，只是這裡子表本身
## 也在重建名單裡），所以子表也要跟著重建，讓外鍵在刪暫存表之前先恢復
## 指向新的父表。
##
## 全部改名成暫存表 → 依「父表在前」的順序逐一 create(db) 建回新結構
## （父表要先存在，子表的 CREATE TABLE 外鍵才不會找不到參照對象）→
## 依同一順序把資料搬回去（父表先搬，子表的 FK 立即檢查才能通過）→
## 依反序（子表先、父表後）刪暫存表——這個順序本身就避免了 DROP 觸發
## FK cascade（CASCADE 子表）或 FK 違規（RESTRICT 子表）波及還沒刪的表，
## 不需要在 transaction 中途切換 PRAGMA foreign_keys。
##
## entry 可選帶 "repair_null_pk"（預設 false），見
## _migrate_rebuild_handle_null_primary_keys() 的說明。
##
## entry 也可選帶 "create_fn"（Callable(db)->bool，預設用 entry["schema"].create）：
## 讓某張表用「這個 migration 當時的舊形狀」重建，而不是「現在的 *Schema.gd」——
## 同一張表後續若被別的 migration 再改形狀（例如再拿掉一欄），這裡若還是呼叫
## 活的 schema class，_migrate_rebuild_verify_column_shape() 會因為形狀已經
## 對不上舊資料庫而中止，等於這個較舊的 migration 被後來的 schema 變更波及。
## 見 migration 9 的 npc_relations（issue #601 拿掉 relations_trust 之後）。
static func _migrate_rebuild_table_group(db, entries: Array) -> bool:
	var old_names := {}

	for entry in entries:
		var table_name: String = entry["table"]
		var old_name := table_name + "__migrate_rebuild_old"
		old_names[table_name] = old_name

		if not db.query("ALTER TABLE %s RENAME TO %s;" % [table_name, old_name]):
			push_error(
				"[DatabaseSchema] Table rebuild: Failed to rename %s: %s"
				% [table_name, db.error_message]
			)
			return false

		if not _migrate_rebuild_drop_stale_indexes(db, old_name):
			return false

	for entry in entries:
		var create_ok: bool = (
			entry["create_fn"].call(db) if entry.has("create_fn")
			else entry["schema"].create(db)
		)
		if not create_ok:
			push_error(
				"[DatabaseSchema] Table rebuild: Failed to recreate %s: %s"
				% [entry["table"], db.error_message]
			)
			return false

	for entry in entries:
		var table_name: String = entry["table"]
		var old_name: String = old_names[table_name]

		if not _migrate_rebuild_verify_column_shape(db, old_name, table_name):
			return false

		if not _migrate_rebuild_handle_null_primary_keys(
			db, old_name, table_name, entry.get("repair_null_pk", false)
		):
			return false

		if not db.query("INSERT INTO %s SELECT * FROM %s;" % [table_name, old_name]):
			push_error(
				"[DatabaseSchema] Table rebuild: Failed to copy data into %s: %s"
				% [table_name, db.error_message]
			)
			return false

	var reverse_entries := entries.duplicate()
	reverse_entries.reverse()

	for entry in reverse_entries:
		var old_name: String = old_names[entry["table"]]

		if not db.query("DROP TABLE %s;" % old_name):
			push_error(
				"[DatabaseSchema] Table rebuild: Failed to drop %s: %s"
				% [old_name, db.error_message]
			)
			return false

	return true


## memories／memory_related_npcs 兩張表要一起重建：memory_related_npcs
## 外鍵指向 memories(memory_id)，改名 memories 時 SQLite 會把這個外鍵定義
## 自動改指向暫存表名，所以 memory_related_npcs 也要同步重建，
## 讓它的外鍵在刪暫存表之前先恢復指向新的 memories。
## 兩個暫存表都建好、資料複製完，才依「子表先、父表後」的順序 DROP——
## 這個順序本身就避免了 DROP 觸發 FK cascade 波及對方。
static func _migrate_v3_rebuild_memories(db) -> bool:
	if not db.query("ALTER TABLE memories RENAME TO memories__migrate_v3_old;"):
		push_error(
			"[DatabaseSchema] Migration 3: Failed to rename memories: "
			+ db.error_message
		)
		return false

	if not db.query(
		"ALTER TABLE memory_related_npcs RENAME TO memory_related_npcs__migrate_v3_old;"
	):
		push_error(
			"[DatabaseSchema] Migration 3: Failed to rename memory_related_npcs: "
			+ db.error_message
		)
		return false

	if not _migrate_rebuild_drop_stale_indexes(db, "memories__migrate_v3_old"):
		return false

	if not _migrate_rebuild_drop_stale_indexes(db, "memory_related_npcs__migrate_v3_old"):
		return false

	if not MemorySchema.create(db):
		push_error(
			"[DatabaseSchema] Migration 3: Failed to recreate memories/memory_related_npcs: "
			+ db.error_message
		)
		return false

	if not _migrate_rebuild_verify_column_shape(db, "memories__migrate_v3_old", "memories"):
		return false

	# memory_id 是 memories 自己的獨立身分（不是外鍵），NULL 主鍵可以安全補新
	# UUID——見 _migrate_rebuild_handle_null_primary_keys() 的說明。
	if not _migrate_rebuild_handle_null_primary_keys(
		db, "memories__migrate_v3_old", "memories", true
	):
		return false

	if not db.query("INSERT INTO memories SELECT * FROM memories__migrate_v3_old;"):
		push_error(
			"[DatabaseSchema] Migration 3: Failed to copy data into memories: "
			+ db.error_message
		)
		return false

	if not _migrate_rebuild_verify_column_shape(
		db, "memory_related_npcs__migrate_v3_old", "memory_related_npcs"
	):
		return false

	# memory_id／npc_id 兩欄都是外鍵，NULL 代表不知道這筆屬於哪個 memories／
	# npc，不能補新 ID——維持預設 false（不修復，撞到就中止 migration）。
	if not _migrate_rebuild_handle_null_primary_keys(
		db, "memory_related_npcs__migrate_v3_old", "memory_related_npcs", false
	):
		return false

	if not db.query(
		"INSERT INTO memory_related_npcs SELECT * FROM memory_related_npcs__migrate_v3_old;"
	):
		push_error(
			"[DatabaseSchema] Migration 3: Failed to copy data into memory_related_npcs: "
			+ db.error_message
		)
		return false

	if not db.query("DROP TABLE memory_related_npcs__migrate_v3_old;"):
		push_error(
			"[DatabaseSchema] Migration 3: Failed to drop memory_related_npcs__migrate_v3_old: "
			+ db.error_message
		)
		return false

	if not db.query("DROP TABLE memories__migrate_v3_old;"):
		push_error(
			"[DatabaseSchema] Migration 3: Failed to drop memories__migrate_v3_old: "
			+ db.error_message
		)
		return false

	return true


## Migration 4：`grave_epitaphs.content` 補上 `CHECK (LENGTH(content) <= 40)`
## （issue #368／#382 拍板悼詞字數上限）。SQLite 不支援用 ALTER TABLE 補
## CHECK 約束，只能整張表重建；`grave_epitaphs` 目前沒有任何呼叫端在寫
## （死亡系統還沒實作，見 note/技術/存檔.md「墓碑欄位」一節），DROP 後直接
## 用 GraveEpitaphSchema.create() 照最新定義重建即可，不需要搬既有資料。
static func _migrate_v4_epitaph_length_check(db) -> bool:
	if not db.query("DROP TABLE IF EXISTS grave_epitaphs;"):
		push_error(
			"[DatabaseSchema] Migration 4: Failed to drop grave_epitaphs: "
			+ db.error_message
		)
		return false

	return GraveEpitaphSchema.create(db)


## Migration 5：`npc_death`／`grave_highlights` 隨 NPCDeathSchema.gd／
## GraveHighlightSchema.gd 一起移除（issue #512）——死亡狀態與
## life_highlights 都決定走 JSON，這兩張表從 #124 骨架階段就沒有任何
## 呼叫端讀寫過（整份 git 歷史查無 INSERT INTO npc_death／grave_highlights），
## 不需要搬資料，既有資料庫上的孤兒空表直接砍掉即可。DATABASE_PATH 只依
## res:// 路徑雜湊、不依 schema 版本，既有資料庫不會自己重建，CREATE TABLE
## IF NOT EXISTS 也不會反向清除已移除 schema 對應的舊表，所以仍要走正式
## migration，不能只當「純新增/移除 table 不算」處理
static func _migrate_v5_drop_death_grave_highlights(db) -> bool:
	if not db.query("DROP TABLE IF EXISTS npc_death;"):
		push_error(
			"[DatabaseSchema] Migration 5: Failed to drop npc_death: "
			+ db.error_message
		)
		return false

	if not db.query("DROP TABLE IF EXISTS grave_highlights;"):
		push_error(
			"[DatabaseSchema] Migration 5: Failed to drop grave_highlights: "
			+ db.error_message
		)
		return false

	return true


## Migration 7：既有資料庫的 world／item／npc_state／npc_emotion／npc_goal
## 跟 migration 3（#446）處理的 4 張表同一個病根——`TEXT PRIMARY KEY` 補
## `NOT NULL` 只對全新建立的資料庫生效。版號原訂 6，rebase 到 main 時發現
## 6 已被 npc_action_history 複合索引（#511）佔用，改編為 7。
##
## npc_state／npc_emotion／npc_goal 沒有任何其他表外鍵指向它們（它們反過來
## 外鍵指向 npc／location，但那是「這 3 張表依賴別人」，不是「別人依賴
## 這 3 張表」，重建時不會觸發別的表跟著改），用 _migrate_rebuild_single_table()
## 逐表重建即可。
##
## world／item 不是這種情形——world_character_state 外鍵指向
## world(world_id) ON DELETE CASCADE；npc_inventory／npc_home_storage／
## item_transaction 外鍵指向 item(item_id) ON DELETE RESTRICT。改名
## world／item 時 SQLite 會把這些子表的外鍵定義自動改指向暫存表名，
## 子表沒有跟著重建的話，最後 DROP 舊 world／item 時：CASCADE 的
## world_character_state 會被隱含 DELETE 連鎖清空（悄悄丟資料）；
## RESTRICT 的 3 張子表則會擋下 DROP、讓整個 migration 失敗（只要
## 那 3 張表任一張有資料）。兩種都要用 _migrate_rebuild_table_group()
## 連同子表一起重建，讓子表的外鍵在刪暫存表之前先恢復指向新的
## world／item。
##
## `npc`（近 20 張依附表）與 `npc`／`location` 之間的重建順序問題不在這次
## 範圍內，見《99》P-55、issue #561、migration 9。
## Migration 7 當年重建 world_character_state 時的表結構凍結版（CodeRabbit
## review 抓到）：不能直接傳目前的 WorldCharacterStateSchema 進
## _migrate_rebuild_table_group()——那個 schema 後來（issue #576）加了
## following_npc_id 欄位，用「現在的形狀」去對「user_version<=6、根本還沒
## 有這個欄位」的舊資料庫做 _migrate_rebuild_verify_column_shape()，新舊
## 欄位數對不上，驗證直接判定失敗、整個 migration 7 中止，migration 8
## 永遠跑不到。這裡凍結 migration 7 完成當下（issue #576 之前）真正的表
## 形狀，讓 migration 7 對舊資料庫還是能重建成功；之後 migration 8 的
## ALTER TABLE ADD COLUMN following_npc_id（已經有查 PRAGMA table_info 擋
## 重複欄位）才是唯一負責把這個新欄位補上去的地方
class _WorldCharacterStateSchemaV7RebuildShape:
	extends RefCounted

	static func create(db) -> bool:
		var sql := """
		CREATE TABLE IF NOT EXISTS world_character_state (

			world_id TEXT NOT NULL,
			npc_id TEXT NOT NULL,

			pos_x REAL NOT NULL DEFAULT 0.0,
			pos_y REAL NOT NULL DEFAULT 0.0,

			current_place TEXT,
			current_state TEXT,

			updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,

			PRIMARY KEY (world_id, npc_id),

			FOREIGN KEY (world_id)
				REFERENCES world(world_id)
				ON DELETE CASCADE,

			FOREIGN KEY (npc_id)
				REFERENCES npc(npc_id)
				ON DELETE CASCADE
		);

		CREATE INDEX IF NOT EXISTS
		idx_world_character_state_npc
		ON world_character_state(npc_id);
		"""

		if not db.query(sql):
			push_error(
				"[DatabaseSchema] Migration 7: Failed to recreate world_character_state (v7 shape)."
			)
			return false

		return true


static func _migrate_v7_notnull_primary_keys(db) -> bool:
	var single_table_schemas := [
		{"table": "npc_state", "schema": NPCStateSchema},
		{"table": "npc_emotion", "schema": NPCEmotionSchema},
		{"table": "npc_goal", "schema": NPCGoalSchema}
	]

	for entry in single_table_schemas:
		if not _migrate_rebuild_single_table(db, entry["table"], entry["schema"]):
			return false

	# world／item 是自己獨立身分（不是外鍵），NULL 主鍵可以安全補新 UUID；
	# world_character_state／npc_inventory／npc_home_storage／item_transaction
	# 這幾張子表維持預設 false——它們的主鍵本來就不在原本 11 個缺 NOT NULL
	# 的欄位裡（見 P-55 背景），這裡的檢查對它們只是防禦性的。
	# world_character_state 傳的是上面凍結的 v7 形狀，不是目前的
	# WorldCharacterStateSchema（原因見那個類別的註解）
	if not _migrate_rebuild_table_group(db, [
		{"table": "world", "schema": WorldSchema, "repair_null_pk": true},
		{"table": "world_character_state", "schema": _WorldCharacterStateSchemaV7RebuildShape}
	]):
		return false

	return _migrate_rebuild_table_group(db, [
		{"table": "item", "schema": ItemSchema, "repair_null_pk": true},
		{"table": "npc_inventory", "schema": NPCInventorySchema},
		{"table": "npc_home_storage", "schema": NPCHomeStorageSchema},
		{"table": "item_transaction", "schema": ItemTransactionSchema}
	])


## Migration 10：拿掉 npc_relations.relations_trust（issue #601）。`trust` 全庫零
## 引擎消費者（persuade 走模型判斷不擲骰、僅存的三個固定公式加減已改事實句
## 陳述），不符合《00》原則三的留存門檻，比照 affinity/familiarity/debt 整條移除。
## SQLite 不支援移除帶 CHECK 的欄位，要整張表重建；npc_relations 沒有任何其他
## 表外鍵指向它（它自己外鍵指向 npc），單表重建即可。不能沿用
## _migrate_rebuild_single_table()——那個走 INSERT ... SELECT * 並比對欄位形狀，
## 是為「只補 NOT NULL、欄位不變」設計的，這裡欄位數變了會被形狀檢查擋下。
## 改成明確列出保留欄位複製。
##
## 原本開發時跟 PR #607（npc/location NOT NULL 重建）撞號取 8，#607 先合併，
## rebase 時重編為 9；之後合併 main 又發現 9 已被同一條 NOT NULL 重建佔走
## （8 被 world_character_state.following_npc_id／issue #576 插隊，重建順延為
## 9，見上面 Migration 9 的說明），再順延為 10——跟這個檔案先前 v6（原 4）、
## v7（原 6）撞號重編同一套處理。
static func _migrate_v10_drop_relations_trust(db) -> bool:
	var old_name := "npc_relations__migrate_v10_old"

	if not db.query("ALTER TABLE npc_relations RENAME TO %s;" % old_name):
		push_error(
			"[DatabaseSchema] Migration 10: Failed to rename npc_relations: "
			+ db.error_message
		)
		return false

	if not _migrate_rebuild_drop_stale_indexes(db, old_name):
		return false

	if not NPCRelationsSchema.create(db):
		push_error(
			"[DatabaseSchema] Migration 10: Failed to recreate npc_relations: "
			+ db.error_message
		)
		return false

	if not db.query(
		"""
		INSERT INTO npc_relations
			(relation_id, character_id, target_id, relations_appearance_cache, updated_at)
		SELECT
			relation_id, character_id, target_id, relations_appearance_cache, updated_at
		FROM %s;
		""" % old_name
	):
		push_error(
			"[DatabaseSchema] Migration 10: Failed to copy data into npc_relations: "
			+ db.error_message
		)
		return false

	if not db.query("DROP TABLE %s;" % old_name):
		push_error(
			"[DatabaseSchema] Migration 10: Failed to drop %s: " % old_name
			+ db.error_message
		)
		return false

	return true

## Migration 6：npc_action_history 是同一輪開發（#428）才新增的表，
## NPCActionHistorySchema.gd 最初把 idx_npc_action_history_npc 只建在
## (npc_id)，後來（#511 CodeRabbit review）才發現重複率分析需要
## (npc_id, game_day, game_minute, id) 複合索引才能穩定排序。任何在這兩次
## 提交之間跑過 initialize() 的既有資料庫，索引名稱已經被舊定義占走——
## CREATE INDEX IF NOT EXISTS 撞到同名索引會直接跳過，不會自動變成新形狀，
## 所以仍要走正式 migration 補齊，不能只當「純新增 table 不算」處理。
## 版號原訂 4，rebase 到 main 時發現 4／5 已被 grave_epitaphs（#382）與
## npc_death 清理（#512）佔用，改編為 6。
static func _migrate_v6_action_history_composite_index(db) -> bool:
	if not db.query("DROP INDEX IF EXISTS idx_npc_action_history_npc;"):
		push_error(
			"[DatabaseSchema] Migration 6: Failed to drop idx_npc_action_history_npc: "
			+ db.error_message
		)
		return false

	if not db.query(
		"CREATE INDEX IF NOT EXISTS idx_npc_action_history_npc ON npc_action_history(npc_id, game_day, game_minute, id);"
	):
		push_error(
			"[DatabaseSchema] Migration 6: Failed to recreate idx_npc_action_history_npc: "
			+ db.error_message
		)
		return false

	return true


## Migration 8：world_character_state 新增 following_npc_id（issue #576，
## 「跟隨誰」的持續狀態，見 WorldCharacterStateSchema.gd 檔頭說明）。純新增
## 一個允許 NULL、預設值也是 NULL 的欄位，不像 migration 3／6／7 那樣涉及
## NOT NULL／索引形狀變更，不需要整張表重建——SQLite 的 ALTER TABLE ADD
## COLUMN 本身就支援帶 REFERENCES 的欄位，只要沒有非 NULL 的預設值就不會
## 卡既有資料列，直接 ALTER TABLE 就夠。
## 先查欄位存不存在才 ALTER TABLE（CodeRabbit review 抓到）：user_version <= 6
## 的既有資料庫，initialize() 會先跑 migration 7（整表重建 world_character_state），
## 這次改動後 WorldCharacterStateSchema.create() 的 CREATE TABLE 本身就帶
## following_npc_id，重建出來的新表已經有這個欄位——接著跑到 migration 8 若
## 不查就直接 ALTER TABLE ADD COLUMN，會撞 duplicate column 錯誤，整個
## migration rollback。user_version 剛好是 7（還沒跑過 migration 7 重建、
## 或本來就在這個版位）的資料庫才需要真的 ALTER TABLE
static func _migrate_v8_add_following_npc_id(db) -> bool:
	if not db.query("PRAGMA table_info(world_character_state);"):
		push_error(
			"[DatabaseSchema] Migration 8: Failed to read columns of world_character_state: "
			+ db.error_message
		)
		return false

	var existing_columns: Array = (db.query_result as Array).map(
		func(row): return row.get("name", "")
	)
	if existing_columns.has("following_npc_id"):
		return true

	if not db.query(
		"ALTER TABLE world_character_state ADD COLUMN following_npc_id TEXT REFERENCES npc(npc_id) ON DELETE SET NULL;"
	):
		push_error(
			"[DatabaseSchema] Migration 8: Failed to add following_npc_id: "
			+ db.error_message
		)
		return false

	return true


## Migration 9：既有資料庫的 npc／location 補 NOT NULL 主鍵——P-55 最後
## 剩下的 2 張表，issue #561。原訂版號 8，rebase 到 main 時發現 8 已被
## world_character_state.following_npc_id（issue #576）佔用；following_npc_id
## 那個 migration 改成 ALTER TABLE ADD COLUMN，必須排在這裡的
## world_character_state 整表重建之前——重建時 world_character_state 用的是
## 目前（已含 following_npc_id）的 WorldCharacterStateSchema，若這裡先跑，
## 舊資料庫的 world_character_state 還沒有這個欄位，
## _migrate_rebuild_verify_column_shape() 新舊欄位數對不上會直接判定失敗。
##
## 這兩張比 migration 7 處理過的 world／item 複雜得多：location 有 7 張表
## 外鍵指向它（npc 本身也是其中一張，透過 home_location_id），npc 則有
## 近 20 張表外鍵指向它。改名 location／npc 時，SQLite 會把「全部」指向
## 它們的外鍵定義自動改指向暫存表名——不是只有 migration 7 那種 1-2 層，
## 這裡有 grave → grave_epitaphs、memories → memory_related_npcs 這種
## 兩層鏈，這些子表的子表也要跟著重建，否則它們的外鍵會停留在暫存表名，
## 最後 DROP 暫存表時 CASCADE 子表被隱含清空、RESTRICT 子表擋下 DROP。
##
## 所以這裡不是「npc／location 各自一組」，而是把 location／npc 與全部
## 直接或間接依附它們的表全部放進同一個 _migrate_rebuild_table_group()，
## 依「父表在前」拓樸排序：
##   location → npc（npc.home_location_id 依附 location，location 要先）
##   → grave（依附 npc／location）→ memories（依附 npc／location）
##   → grave_epitaphs（依附 grave／npc，要在 grave 之後）
##   → memory_related_npcs（依附 memories／npc，要在 memories 之後）
##   → 其餘只依附 npc（部分也依附 location）的表，彼此順序無關
## _migrate_rebuild_table_group() 會依反序（子表先、父表後）DROP 暫存表，
## 不需要另外處理。
##
## npc_action_history（#428／migration 6 才新增，ON DELETE CASCADE 指向
## npc）在原始設計之後才出現，一併掃進「只依附 npc」的那組，理由跟其他
## 同組表一樣——不掃進來的話，npc 改名時它的外鍵會停在暫存表名，最後
## DROP 暫存 npc 時被隱含 CASCADE 清空，悄悄丟光整張表的資料。
##
## repair_null_pk 只給 location／npc——兩者的主鍵是這張表自己的獨立身分
## （不是外鍵），NULL 可以安全補新 UUID，跟 migration 7 的 world／item
## 同一套判斷。其餘表要嘛主鍵是 INTEGER PRIMARY KEY AUTOINCREMENT（SQLite
## 不會真的存 NULL 進去，不會踩到這個問題），要嘛主鍵已經在 migration 3／7
## 補過 NOT NULL（npc_appearance／npc_last_action／npc_occupation／
## npc_state／npc_emotion／npc_goal）——這裡被掃進同一組重建純粹是因為
## 它們的外鍵指向 npc／location，不是因為它們自己的主鍵有缺口，維持預設
## false（找到 NULL 主鍵列才會中止，正常情況下不會發生）。
##
## npc_inventory／npc_home_storage／item_transaction／world_character_state
## 這 4 張在 migration 7 已經因為 world／item 重建過一輪，這裡因為 npc
## 重建又要再重建一次——不是重複勞動，是因為兩次重建各自針對不同的父表
## （item／world vs. npc），沒有先後可以合併的空間。
##
## npc_relations 的 entry 額外判斷：issue #601 在這個 migration 上線後才把
## relations_trust 從 NPCRelationsSchema 拿掉，migration 10 才是正式移除它的
## 地方。這裡若一律呼叫活的 NPCRelationsSchema.create() 重建，會在「舊資料庫
## 真的帶著 relations_trust」時跟舊表形狀對不上而中止（_migrate_rebuild_table_group()
## 的欄位形狀比對抓到）。在 _migrate_rebuild_table_group() 改名「之前」先查活表
## npc_relations 有沒有 relations_trust 欄位動態判斷該用哪個 create：有 → 用凍結的 _migrate_v8_create_npc_relations_with_trust()
## 原樣重建、留給 migration 10 拿掉；沒有（新資料庫從沒真的存過這欄，或已經是
## #601 之後的形狀）→ 用現行 NPCRelationsSchema，跟其餘表的預設行為一致。
static func _migrate_v9_notnull_primary_keys(db) -> bool:
	var npc_relations_entry := {"table": "npc_relations", "schema": NPCRelationsSchema}
	if _migrate_table_has_column(db, "npc_relations", "relations_trust"):
		npc_relations_entry["create_fn"] = Callable(
			DatabaseSchema, "_migrate_v8_create_npc_relations_with_trust"
		)

	return _migrate_rebuild_table_group(db, [
		{"table": "location", "schema": LocationSchema, "repair_null_pk": true},
		{"table": "npc", "schema": NPCSchema, "repair_null_pk": true},
		{"table": "grave", "schema": GraveSchema},
		{"table": "memories", "schema": MemorySchema},
		{"table": "grave_epitaphs", "schema": GraveEpitaphSchema},
		# MemorySchema.create() 一次建 memories 與 memory_related_npcs，
		# 這裡再列一次是為了讓 memory_related_npcs 也走 rename／copy／drop
		# 三個階段；重複的 create() 靠 CREATE TABLE IF NOT EXISTS 變成 no-op。
		{"table": "memory_related_npcs", "schema": MemorySchema},
		{"table": "money_transaction", "schema": MoneyTransactionSchema},
		{"table": "item_transaction", "schema": ItemTransactionSchema},
		{"table": "npc_action_history", "schema": NPCActionHistorySchema},
		{"table": "npc_appearance", "schema": NPCAppearanceSchema},
		{"table": "npc_condition", "schema": NPCConditionSchema},
		{"table": "npc_daily_plan", "schema": NPCDailyPlanSchema},
		{"table": "npc_emotion", "schema": NPCEmotionSchema},
		{"table": "npc_goal", "schema": NPCGoalSchema},
		{"table": "npc_home_storage", "schema": NPCHomeStorageSchema},
		{"table": "npc_inventory", "schema": NPCInventorySchema},
		{"table": "npc_last_action", "schema": NPCLastActionSchema},
		{"table": "npc_occupation", "schema": NPCOccupationSchema},
		{"table": "npc_personality", "schema": NPCPersonalitySchema},
		npc_relations_entry,
		{"table": "npc_schedule", "schema": NPCScheduleSchema},
		{"table": "npc_state", "schema": NPCStateSchema},
		{"table": "npc_taboo", "schema": NPCTabooSchema},
		{"table": "npc_wallet", "schema": NPCWalletSchema},
		{"table": "world_character_state", "schema": WorldCharacterStateSchema}
	])


## npc_relations 在 migration 9 當下（issue #561；原訂版號 8，見上面 Migration 9
## 的說明）的形狀，帶 relations_trust——凍結成獨立函式而不是呼叫
## NPCRelationsSchema.create()，是因為 issue #601
## 把 relations_trust 從那個活的 schema class 移除了。migration 9 的職責只是
## 幫舊資料庫補 NOT NULL 主鍵，真的帶著 relations_trust 資料的舊資料庫不該因為
## 之後別的 migration 又改了這張表的欄位，就連帶讓自己失敗（
## _migrate_rebuild_table_group() 的欄位形狀比對會抓到：舊表有 relations_trust、
## 新表沒有，直接中止整個 initialize()）。只在 _migrate_v9_notnull_primary_keys()
## 動態判斷出舊表確實還帶 relations_trust 時才會被指定成 create_fn 呼叫；
## 這裡凍結的 CREATE TABLE 就是 #601 之前 NPCRelationsSchema.gd 的內容，
## trust 欄位由 migration 10 負責拿掉。
static func _migrate_v8_create_npc_relations_with_trust(db) -> bool:
	var sql := """
	CREATE TABLE IF NOT EXISTS npc_relations (

		relation_id INTEGER PRIMARY KEY AUTOINCREMENT,

		character_id TEXT NOT NULL,

		target_id TEXT NOT NULL,

		relations_trust INTEGER NOT NULL DEFAULT 20
			CHECK (
				relations_trust BETWEEN 0 AND 100
			),

		relations_appearance_cache TEXT NOT NULL DEFAULT ''
			CHECK (
				length(relations_appearance_cache) <= 20
			),

		updated_at TEXT NOT NULL
			DEFAULT CURRENT_TIMESTAMP,

		FOREIGN KEY (character_id)
			REFERENCES npc(npc_id)
			ON DELETE CASCADE,

		FOREIGN KEY (target_id)
			REFERENCES npc(npc_id)
			ON DELETE CASCADE,

		UNIQUE (character_id, target_id),

		CHECK (character_id <> target_id)
	);

	CREATE INDEX IF NOT EXISTS
	idx_npc_relations_character
	ON npc_relations(character_id);

	CREATE INDEX IF NOT EXISTS
	idx_npc_relations_target
	ON npc_relations(target_id);
	"""

	if not db.query(sql):
		push_error(
			"[DatabaseSchema] Migration 8: Failed to recreate npc_relations (frozen with-trust shape): "
			+ db.error_message
		)
		return false

	return true


static func initialize(db) -> bool:
	if db == null:
		push_error("[DatabaseSchema] Database object is null.")
		return false

	var schemas := [

		# -------------------------------------------------
		# 01. World
		# -------------------------------------------------

		WorldSchema,
		LocationSchema,

		# NPC Core
		NPCSchema,
		NPCStateSchema,
		NPCScheduleSchema,

		# NPC Profile
		NPCPersonalitySchema,
		NPCAppearanceSchema,
		NPCOccupationSchema,
		NPCTabooSchema,

		# NPC AI
		NPCEmotionSchema,
		NPCConditionSchema,
		NPCGoalSchema,
		NPCDailyPlanSchema,
		NPCLastActionSchema,
		NPCActionHistorySchema,

		# NPC Memory
		MemorySchema,

		# NPC Death
		# 死亡狀態（is_dead/death_cause/last_words 等）與 grave_highlights
		# 已拍板走 JSON（見 note/技術/存檔.md「墓碑欄位」），對應的
		# NPCDeathSchema／GraveHighlightSchema 是 #124 骨架階段留下、沒有
		# 任何呼叫端讀寫的死碼，見《99》P-50，已移除。GraveSchema 仍保留——
		# grave_epitaphs 的 grave_id 外鍵指向 grave(grave_id)，epitaphs
		# 這張表需要一個父表才能寫入資料，不是死碼
		GraveSchema,
		GraveEpitaphSchema,

		# Item
		ItemSchema,

		# Inventory / Storage
		NPCInventorySchema,
		NPCHomeStorageSchema,

		# Relations
		NPCRelationsSchema,

		# Economy
		NPCWalletSchema,
		MoneyTransactionSchema,
		ItemTransactionSchema,


		# -------------------------------------------------
		# 11. World Character State
		# -------------------------------------------------

		WorldCharacterStateSchema
	]

	var stored_version := _get_user_version(db)

	# 資料庫版本比目前程式碼認得的還新——大概是同一 checkout 切回舊分支、
	# 但 DATABASE_PATH 指向的 hashed database 被新分支開過（跨 checkout
	# 已靠雜湊隔開，不會撞到別的 worktree）。
	# 不能往下走：schemas 陣列建的是舊分支自己認得的欄位，MIGRATIONS
	# 也不含新分支已經套用過的項目，繼續執行會把 user_version 誤降回
	# CURRENT_VERSION、讓新分支的 migration 之後被重複套用。
	if stored_version > CURRENT_VERSION:
		push_error(
			"[DatabaseSchema] Database version %d is newer than this build supports (%d). Refusing to open."
			% [stored_version, CURRENT_VERSION]
		)
		return false


	# 全新資料庫（sqlite_master 裡一張 table 都沒有）跟「已經有 table、
	# 只是從沒記錄過版本」的既有資料庫（同樣 stored_version == 0）要分開
	# 處理：下面 schemas 陣列的 CREATE TABLE 建的一律是目前最新欄位，
	# 全新資料庫建完就已經是 CURRENT_VERSION 的形狀，不該再套用歷史
	# MIGRATIONS 的 ALTER TABLE——那是為了把舊表結構補到新形狀，
	# 套在剛用最新定義建出來的表上只會撞欄位已存在而失敗。
	var is_fresh_database := stored_version == 0 and not _has_existing_tables(db)


	# =================================================
	# 整批包在一個 transaction 裡。
	#
	# SQLite 的 DDL 可以進 transaction，所以中間任何一張表失敗
	# 就整個回滾。否則會留下一個建到一半的資料庫，而且因為用的是
	# CREATE TABLE IF NOT EXISTS，下次開機也不會自己修好。
	#
	# PRAGMA user_version 的寫入也在同一個 transaction 裡——
	# migration 沒套完就不該讓版本號提前跳到新的。
	# =================================================

	if not db.query("BEGIN TRANSACTION;"):
		push_error(
			"[DatabaseSchema] BEGIN failed: "
			+ db.error_message
		)
		return false

	for schema in schemas:
		if schema.create(db):
			continue

		push_error(
			"[DatabaseSchema] Failed to create %s: %s"
			% [_schema_name(schema), db.error_message]
		)

		db.query("ROLLBACK;")
		return false

	if not is_fresh_database and not _apply_migrations(db, stored_version, MIGRATIONS):
		db.query("ROLLBACK;")
		return false


	if not _set_user_version(db, CURRENT_VERSION):
		push_error(
			"[DatabaseSchema] Failed to set user_version to %d: %s"
			% [CURRENT_VERSION, db.error_message]
		)

		db.query("ROLLBACK;")
		return false


	if not db.query("COMMIT;"):
		push_error(
			"[DatabaseSchema] COMMIT failed: "
			+ db.error_message
		)

		db.query("ROLLBACK;")
		return false

	print(
		"[DatabaseSchema] %d schemas created, schema version %d."
		% [schemas.size(), CURRENT_VERSION]
	)

	return true


## 依序套用版本 > from_version 的 migration，任何一個失敗就中止
## （呼叫端負責 ROLLBACK）。migrations 走參數傳入而不是直接讀
## MIGRATIONS 常數，是為了讓測試可以餵一份假清單進來驗證套用順序／
## 失敗中止的邏輯，不需要真的改動 schema。
static func _apply_migrations(
	db,
	from_version: int,
	migrations: Array[Dictionary]
) -> bool:
	var pending := migrations.filter(
		func(m): return m["version"] > from_version
	)

	pending.sort_custom(func(a, b): return a["version"] < b["version"])

	for migration in pending:
		if migration["apply"].call(db):
			print(
				"[DatabaseSchema] Migration %d (%s) applied."
				% [migration["version"], migration["name"]]
			)
			continue

		push_error(
			"[DatabaseSchema] Migration %d (%s) failed: %s"
			% [migration["version"], migration["name"], db.error_message]
		)
		return false

	return true


## 查 sqlite_master 有沒有任何應用程式 table，用來分辨「全新資料庫」跟
## 「已經有 table、只是沒記錄過版本」的既有資料庫（兩者 user_version
## 都是 0）。查詢本身失敗時保守回傳 true（當作有既有 table）——
## 誤判成既有資料庫頂多多套用不需要的 migration，誤判成全新資料庫則會
## 漏掉真正需要的 migration，後者的後果更嚴重。
static func _has_existing_tables(db) -> bool:
	if not db.query(
		"SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' LIMIT 1;"
	):
		push_error(
			"[DatabaseSchema] Failed to query sqlite_master: "
			+ db.error_message
		)
		return true

	return not db.query_result.is_empty()


## PRAGMA user_version 是存在資料庫檔頭的整數，新資料庫預設是 0。
static func _get_user_version(db) -> int:
	if not db.query("PRAGMA user_version;"):
		push_error(
			"[DatabaseSchema] Failed to read user_version: "
			+ db.error_message
		)
		return 0

	var result: Array = db.query_result

	if result.is_empty():
		return 0

	return int(result[0].values()[0])


static func _set_user_version(db, version: int) -> bool:
	return db.query("PRAGMA user_version = %d;" % version)


## schema 是 GDScript class，直接 str() 出來會是 <GDScript#...>，
## 看不出是哪張表。
static func _schema_name(schema) -> String:
	return str(schema.resource_path).get_file().get_basename()
