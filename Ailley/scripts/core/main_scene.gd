extends Node

## main.tscn 根節點腳本。issue #343：開場讀檔的實際套用時機。
##
## GameManager.continue_requested 由主選單「繼續遊戲」按鈕設定，這裡是唯一
## 讀取並清除它的地方。子節點（Player/Agent 等）的 _ready() 在這個節點的
## _ready() 之前就跑完（Godot 由下而上呼叫 _ready），所以這裡執行時
## get_tree().get_nodes_in_group("characters") 已經拿得到場上全部角色。
##
## 套用邏輯直接對齊 debug_console.gd 的 _cmd_load()（#21 驗證過的讀檔進出點），
## 差別是這裡額外用 SaveService.has_world()/has_character() 分辨「本來就沒有
## 存檔」（正常新角色，不是錯誤）跟「存過但讀不出來」（存檔損毀，要 push_error
## 讓人看得到，不能悄悄退回預設值卻不留痕跡）。


const MAIN_MENU_SCENE := "res://scenes/main_menu.tscn"


func _ready() -> void:
	if GameManager.continue_requested:
		GameManager.continue_requested = false
		_apply_continue()

	_apply_startup_ai_state()


## #357：開場依 AIService 就緒狀態決定要不要自動打開場上 Agent 的
## llm_decision_enabled，並在 HUD 上寫一次「AI 決策中」／「排程模式（原因：…）」
## 的常駐指示——排程村莊跟真的在跑決策的村莊畫面上很像，沒有這個指示要盯
## 很久才會發現兩者其實不一樣。
##
## 只在開場探測一次、套用一次，不做背景輪詢：provider 連線狀態中途改變
## （例如玩到一半才把 llama-server 開起來）不在這裡的範圍，那種情況的
## 既有救援手段是 debug 主控台的 `ai`（手動重測）／`ai_decision`（手動逐隻開）。
##
## 逐隻查 agent.get_provider_name() 各自的 readiness，不是隨便查一個全域值——
## 不同 Agent 的 decision_source／model_name 可能解析到不同的 provider，
## 一隻壞掉不該連累其他隻。
##
## 要開啟的 Agent 呼叫 debug_set_llm_decision(true) 但不逐隻 await——
## AIService 的節點池＋佇列（POOL_SIZE=3，FIFO）本來就會把超出池子的請求
## 排隊處理，這裡不用自己手動錯開；逐隻 await 反而會把 5 隻角色的第一次
## 決策強制序列化，開場等待時間從一次 3-4 秒的網路延遲被拖成 5 次疊加
func _apply_startup_ai_state() -> void:
	await AIService.await_readiness_settled()

	var agents := get_tree().get_nodes_in_group("agents")
	var ready_count := 0
	var fallback_reason := ""
	for node in agents:
		var agent := node as Agent
		if agent == null:
			continue
		var readiness := AIService.get_readiness(agent.get_provider_name())
		var agent_ready := bool(readiness.get("ready", false))
		if agent_ready:
			ready_count += 1
		else:
			fallback_reason = str(readiness.get("reason", ""))
		agent.debug_set_llm_decision(agent_ready)

	if agents.is_empty():
		return

	var status_label := get_node_or_null("PersistentUI/HUD/AIStatusLabel")
	if status_label == null:
		return

	if ready_count == agents.size():
		status_label.set_status(true, "")
	else:
		# 混合場面（例如某隻角色的 model_name 指到一個壞掉的 provider）沒有
		# 單一個「就緒與否」，指示牌走保守那邊——只要有一隻沒開，就整體標成
		# 排程模式，理由取第一個沒就緒的原因當代表
		status_label.set_status(false, fallback_reason)


func _apply_continue() -> void:
	if not SaveService.has_world(GameManager.DEFAULT_WORLD_ID):
		push_error("main_scene: continue_requested 但世界存檔 %s 不存在，返回主選單" % GameManager.DEFAULT_WORLD_ID)
		GameManager.continue_load_failed = true
		get_tree().change_scene_to_file(MAIN_MENU_SCENE)
		return

	var world_data := SaveService.get_world(GameManager.DEFAULT_WORLD_ID)
	if not SaveService.is_world_data_valid(world_data):
		push_error("main_scene: 世界存檔 %s 讀取失敗或格式不完整（可能已損毀），返回主選單" % GameManager.DEFAULT_WORLD_ID)
		GameManager.continue_load_failed = true
		get_tree().change_scene_to_file(MAIN_MENU_SCENE)
		return
	GameManager.apply_world_save_data(world_data)

	for node in get_tree().get_nodes_in_group("characters"):
		var character := node as Character
		if not SaveService.has_character(character.character_id):
			continue # 這個角色本身還沒存過（例如存檔當時場上沒有它），不是錯誤

		var data := SaveService.get_character(character.character_id)
		if data.is_empty():
			push_error("main_scene: 角色存檔 %s（%s）讀取失敗（存在但無法解析，可能已損毀），該角色維持預設狀態" % [character.character_id, character.character_name])
			continue

		# character_id 一定要存在、是 String、且跟查詢用的 id 對得上——
		# get_save_data() 永遠會寫入這個欄位，缺欄位／型別不對／對不上
		# 都代表存檔內容跟檔名認定的角色不是同一個（可能已損毀或被誤覆蓋），
		# 套用下去 load_save_data() 會直接把場上角色的 id 改掉，跟世界存檔
		# 已套用的位置／關係對不起來
		var stored_id: Variant = data.get("character_id")
		if not (stored_id is String and stored_id == character.character_id):
			push_error("main_scene: 角色存檔 %s（%s）內容缺少或 character_id 不符（%s），可能已損毀，該角色維持預設狀態" % [character.character_id, character.character_name, stored_id])
			continue

		character.load_save_data(data)
