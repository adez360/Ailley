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
			CHECK (is_active IN (0, 1)),

		-- 動態生成的家（issue #751）專用，允許 NULL：座標的單一事實來源仍是
		-- 場景裡的 Marker2D（見 places.gd），靜態地點不寫這兩欄。動態生成的
		-- 家沒有隨場景檔存在的節點，讀檔重建時要靠這裡記住上次的位置
		pos_x REAL,
		pos_y REAL
	);
	"""

	if not db.query(sql):
		push_error("[LocationSchema] Failed to create location.")
		return false

	return true
