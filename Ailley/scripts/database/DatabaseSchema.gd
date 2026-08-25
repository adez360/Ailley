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
const CURRENT_VERSION := 6


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
		"name": "Rebuild world/item/npc_state/npc_emotion/npc_goal with NOT NULL primary keys",
		"apply": Callable(DatabaseSchema, "_migrate_v6_notnull_primary_keys")
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
		if not entry["schema"].create(db):
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


## Migration 6：既有資料庫的 world／item／npc_state／npc_emotion／npc_goal
## 跟 migration 3（#446）處理的 4 張表同一個病根——`TEXT PRIMARY KEY` 補
## `NOT NULL` 只對全新建立的資料庫生效。
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
## 範圍內，見《99》P-55、issue #561。
static func _migrate_v6_notnull_primary_keys(db) -> bool:
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
	if not _migrate_rebuild_table_group(db, [
		{"table": "world", "schema": WorldSchema, "repair_null_pk": true},
		{"table": "world_character_state", "schema": WorldCharacterStateSchema}
	]):
		return false

	return _migrate_rebuild_table_group(db, [
		{"table": "item", "schema": ItemSchema, "repair_null_pk": true},
		{"table": "npc_inventory", "schema": NPCInventorySchema},
		{"table": "npc_home_storage", "schema": NPCHomeStorageSchema},
		{"table": "item_transaction", "schema": ItemTransactionSchema}
	])


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
