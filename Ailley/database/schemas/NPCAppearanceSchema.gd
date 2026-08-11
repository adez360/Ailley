class_name NPCAppearanceSchema
extends RefCounted


static func create(db) -> bool:

	var sql := """
	CREATE TABLE IF NOT EXISTS npc_appearance (

		npc_id TEXT PRIMARY KEY,

		height INTEGER NOT NULL DEFAULT 170
			CHECK (height > 0),

		weight INTEGER NOT NULL DEFAULT 60
			CHECK (weight > 0),

		hair_color TEXT DEFAULT '',

		hair_style TEXT DEFAULT '',

		eye_color TEXT DEFAULT '',

		skin_color TEXT DEFAULT '',

		body_type TEXT DEFAULT '',

		face_description TEXT DEFAULT '',

		clothing_description TEXT DEFAULT '',

		appearance_description TEXT DEFAULT '',

		updated_at TEXT NOT NULL
			DEFAULT CURRENT_TIMESTAMP,

		FOREIGN KEY (npc_id)
			REFERENCES npc(npc_id)
			ON DELETE CASCADE
	);
	"""

	if not db.query(sql):

		push_error(
			"[NPCAppearanceSchema] "
			+ "Failed to create npc_appearance."
		)

		return false

	return true
