class_name GraveEpitaphSchema
extends RefCounted


static func create(db) -> bool:

	var sql := """
	CREATE TABLE IF NOT EXISTS grave_epitaphs (

		epitaph_id INTEGER PRIMARY KEY AUTOINCREMENT,

		grave_id INTEGER NOT NULL,

		npc_id TEXT NOT NULL,

		-- 字數上限 40（2026-08-20 拍板，見《規格書 09》§4-5／issue #368）
		content TEXT NOT NULL
			CHECK (LENGTH(content) <= 40),


		created_at TEXT NOT NULL
			DEFAULT CURRENT_TIMESTAMP,

		updated_at TEXT NOT NULL
			DEFAULT CURRENT_TIMESTAMP,


		FOREIGN KEY (grave_id)
			REFERENCES grave(grave_id)
			ON DELETE CASCADE,

		FOREIGN KEY (npc_id)
			REFERENCES npc(npc_id)
			ON DELETE CASCADE,


		-- 一個 NPC 對同一個墓碑只能有一條
		UNIQUE (
			grave_id,
			npc_id
		)
	);


	-- grave_id 是 UNIQUE (grave_id, npc_id) 的前綴，不用另外建。

	CREATE INDEX IF NOT EXISTS
	idx_grave_epitaphs_npc
	ON grave_epitaphs(npc_id);
	"""


	if not db.query(sql):

		push_error(
			"[GraveEpitaphSchema] "
			+ "Failed to create grave_epitaphs."
		)

		return false


	return true
