class_name GraveHighlightSchema
extends RefCounted


static func create(db) -> bool:

	var sql := """
	CREATE TABLE IF NOT EXISTS grave_highlights (

		highlight_id INTEGER PRIMARY KEY AUTOINCREMENT,

		grave_id INTEGER NOT NULL,

		highlight_order INTEGER NOT NULL,

		content TEXT NOT NULL,


		FOREIGN KEY (grave_id)
			REFERENCES grave(grave_id)
			ON DELETE CASCADE,


		UNIQUE (
			grave_id,
			highlight_order
		)
	);

	-- grave_id 是 UNIQUE (grave_id, highlight_order) 的前綴，
	-- SQLite 為那個 UNIQUE 建的 index 已經涵蓋單獨查 grave_id。
	"""


	if not db.query(sql):

		push_error(
			"[GraveHighlightSchema] "
			+ "Failed to create grave_highlights."
		)

		return false


	return true
