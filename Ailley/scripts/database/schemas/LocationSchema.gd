class_name LocationSchema
extends RefCounted


static func create(db) -> bool:

	var sql := """
	CREATE TABLE IF NOT EXISTS location (

		location_id TEXT NOT NULL PRIMARY KEY,

		name TEXT NOT NULL,

		-- 保留 main 現有欄位名；與規格的 desc 語意一致
		description TEXT DEFAULT '',

		location_type TEXT DEFAULT '',

		-- 滿員時不可進入
		capacity INTEGER NOT NULL DEFAULT 0
			CHECK (capacity >= 0),

		-- 0-100；用於扣減行為成功率
		danger INTEGER NOT NULL DEFAULT 0
			CHECK (danger BETWEEN 0 AND 100),

		is_active INTEGER NOT NULL DEFAULT 1
			CHECK (is_active IN (0, 1))
	);
	"""

	if not db.query(sql):
		push_error("[LocationSchema] Failed to create location.")
		return false

	return true
