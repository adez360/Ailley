class_name GraveHighlightSchema
extends RefCounted


static func create(db) -> bool:

	var sql := """
	CREATE TABLE IF NOT EXISTS grave_highlights (

		highlight_id INTEGER PRIMARY KEY AUTOINCREMENT,

		grave_id INTEGER NOT NULL,

		highlight_order INTEGER NOT NULL DEFAULT 0,

		content TEXT NOT NULL,


		FOREIGN KEY (grave_id)
			REFERENCES grave(grave_id)
			ON DELETE CASCADE,


		UNIQUE (
			grave_id,
			highlight_order
		)
	);


	CREATE INDEX IF NOT EXISTS
	idx_grave_highlights_grave
	ON grave_highlights(grave_id);
	"""


	if not db.query(sql):

		push_error(
			"[GraveHighlightSchema] "
			+ "Failed to create grave_highlights."
		)

		return false


	return true
