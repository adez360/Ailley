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

	# 依 npc_id 查詢、依時間排序是這張表唯一的讀取模式（分析重複率時逐角色
	# 抓出全部歷史再排序成序列 S，見《99》P-52「已拍板」的計算公式）。
	# game_day/game_minute 無法區分同一遊戲分鐘內的多次切換，複合索引尾端
	# 加 id（AUTOINCREMENT，插入順序＝真實時間順序）當同分鐘內的排序依據，
	# 不然同一分鐘的相鄰比較結果會依 SQL 執行計畫而不固定（CodeRabbit review 抓到）
	if not db.query(
		"CREATE INDEX IF NOT EXISTS idx_npc_action_history_npc ON npc_action_history(npc_id, game_day, game_minute, id);"
	):
		push_error("[NPCActionHistorySchema] Failed to create idx_npc_action_history_npc.")
		return false

	return true
