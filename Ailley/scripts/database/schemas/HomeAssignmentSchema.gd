class_name HomeAssignmentSchema
extends RefCounted

## loc_home_* round-robin 分配游標的唯一持久化位置（issue #391，
## 《規格書07_地點/家》）。issue #825 後家的供給完全動態、數量會變，游標的
## 上界收斂交給 CharacterStatePersistence._assign_next_home_location()（用當下
## 真正的 active 家數量取 %）。獨立成單一表，不掛在 world 底下——world 目前有
## JsonSaveService／SqliteSaveService 兩套並存，world_id 的權威來源不在
## 這個 issue 範圍內；這裡只需要跟 npc/location 同一份 SQLite 檔案裡、
## 存讀檔都不變的一個整數游標。永遠只有 id=1 這一列。


static func create(db) -> bool:

	var sql := """
	CREATE TABLE IF NOT EXISTS home_assignment (

		id INTEGER NOT NULL PRIMARY KEY
			CHECK (id = 1),

		-- 下一次分配要從 active 家清單（依編號排序）的第幾個（0-based）開始找
		next_index INTEGER NOT NULL DEFAULT 0
			CHECK (next_index >= 0)
	);
	"""

	if not db.query(sql):
		push_error("[HomeAssignmentSchema] Failed to create home_assignment.")
		return false

	return true
