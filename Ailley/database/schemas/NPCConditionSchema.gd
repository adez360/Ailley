class_name NPCConditionSchema
extends RefCounted


static func create(db) -> bool:

	var sql := """
	CREATE TABLE IF NOT EXISTS npc_condition (

		npc_id TEXT PRIMARY KEY,

		physical_condition INTEGER NOT NULL DEFAULT 100
			CHECK (
				physical_condition BETWEEN 0 AND 100
			),

		mental_condition INTEGER NOT NULL DEFAULT 100
			CHECK (
				mental_condition BETWEEN 0 AND 100
			),

		health_condition INTEGER NOT NULL DEFAULT 100
			CHECK (
				health_condition BETWEEN 0 AND 100
			),

		fatigue INTEGER NOT NULL DEFAULT 0
			CHECK (
				fatigue BETWEEN 0 AND 100
			),

		pain INTEGER NOT NULL DEFAULT 0
			CHECK (
				pain BETWEEN 0 AND 100
			),

		sick INTEGER NOT NULL DEFAULT 0
			CHECK (
				sick IN (0, 1)
			),

		condition_description TEXT DEFAULT '',

		updated_at TEXT NOT NULL
			DEFAULT CURRENT_TIMESTAMP,

		FOREIGN KEY (npc_id)
			REFERENCES npc(npc_id)
			ON DELETE CASCADE
	);
	"""

	if not db.query(sql):

		push_error(
			"[NPCConditionSchema] "
			+ "Failed to create npc_condition."
		)

		return false

	return true
