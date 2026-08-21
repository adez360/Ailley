class_name NPCActionHistorySchema
extends RefCounted

## 只新增、不更新的動作切換歷史（issue #428）：仲裁器（agent.gd::_select()）
## 真正把 _current_task 換成 llm 來源新任務的那一刻各記一筆，給之後分析
## 「連續兩次選同一動作」的重複率用。不即時算重複率，收集完資料後用 SQL
## 查詢（同一個 npc_id 依時間排序，比較相鄰兩筆 action）——見
## [[LLM 串接與 AI 服務層]]。


static func create(db) -> bool:

	var sql := """
	CREATE TABLE IF NOT EXISTS npc_action_history (

		id INTEGER PRIMARY KEY AUTOINCREMENT,

		npc_id TEXT NOT NULL,

		game_day INTEGER NOT NULL,

		-- 當天第幾分鐘（0-1439），跟 agent.gd::_push_today_log() 的
		-- "minute" 欄位同一個換算方式：GameClock.hour * 60 + GameClock.minute
		game_minute INTEGER NOT NULL,

		action TEXT NOT NULL,

		created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,

		FOREIGN KEY (npc_id)
			REFERENCES npc(npc_id)
			ON DELETE CASCADE
	);
	"""

	if not db.query(sql):
		push_error("[NPCActionHistorySchema] Failed to create npc_action_history.")
		return false

	# 依 npc_id 查詢是這張表唯一的讀取模式（分析重複率時逐角色抓出全部
	# 歷史再依時間排序），比照其餘 schema 的索引慣例補一個
	if not db.query(
		"CREATE INDEX IF NOT EXISTS idx_npc_action_history_npc ON npc_action_history(npc_id);"
	):
		push_error("[NPCActionHistorySchema] Failed to create idx_npc_action_history_npc.")
		return false

	return true
