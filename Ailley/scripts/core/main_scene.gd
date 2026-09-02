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
	# 進場重置：離開流程立起的 GameManager._world_unloading 不會自己消退
	# （GameManager 是 autoload），不收掉的話這次對局單一角色退場時，
	# CharacterStatePersistence._release_home_if_dynamic() 會誤跳過拆除
	GameManager._world_unloading = false
	# 動態家重建：level.tscn 裡沒有任何畫死的家（issue #825），DB 裡
	# is_active=1 的家每次進世界都要重新 instantiate——autoload 開機那次 deferred 呼叫
	# 撞的是主選單場景（沒有 place_anchors／world，_rebuild_dynamic_homes()
	# 會直接跳過），進世界後唯一的重建入口就是這裡，新遊戲／繼續／回選單
	# 再進都會跑到（CodeRabbit review on #825）。DatabaseManager 建這個子
	# 節點也是用 call_deferred()，deferred 一拍讓建立先跑完，這裡才拿得到它
	call_deferred("_rebuild_dynamic_homes_once")
	# 全畫面昏迷倒數警示（issue #803）：純程式建 UI（比照 OnboardingHint 的
	# 動態掛法），自己訂閱 GameClock.time_changed 掃場上角色，沒人在倒數時
	# 整層隱藏。掛在這裡而不是角色身上——它是每場一份的全域 HUD，不是角色的
	# 頭上配件
	add_child(IncapacitationAlert.new())


	var new_game := true

	if GameManager.continue_requested:
		GameManager.continue_requested = false
		if not _apply_continue():
			# 讀檔失敗已經 change_scene_to_file() 切去主選單——這個節點跟場上
			# 角色都要被換掉了，不該再繼續跑開場 AI 狀態套用（CodeRabbit review
			# 抓到：原本這裡沒有提前 return，_apply_startup_ai_state() 還是會
			# 對已經要被丟棄的場景做 get_nodes_in_group("agents") 之類的操作）
			return
		new_game = false

	# 操作說明面板一律掛著（F1 隨時叫得出來，見 onboarding_hint.gd）；只有新
	# 遊戲第一次開場才自動彈一次（issue #585／#1017），讀檔（繼續遊戲）不彈。
	# 節點建在提前 return 之後，讀檔失敗不會留一個沒掛進樹的孤兒節點
	var onboarding := OnboardingHint.new()
	onboarding.auto_show = new_game
	add_child(onboarding)

	_apply_startup_ai_state()


## 進場重建動態家（見 _ready() 的說明）
func _rebuild_dynamic_homes_once() -> void:
	var persistence := DatabaseManager.get_node_or_null("CharacterStatePersistence")
	if persistence != null:
		persistence._rebuild_dynamic_homes()


## #357：開場依 AIService 就緒狀態決定要不要自動打開場上 Agent 的
## llm_decision_enabled，並在 HUD 上寫一次「AI 決策中」／「排程模式（原因：…）」
## 的常駐指示——排程村莊跟真的在跑決策的村莊畫面上很像，沒有這個指示要盯
## 很久才會發現兩者其實不一樣。
##
## 只在開機探測、套用一次，不做背景輪詢：開機那批快照若有「沒 ready」的，
## 這裡會像 game_manager.gd::activate_llm_decision_if_ready() 一樣事件觸發
## 補打一次 reload_config_and_wait() 再判定（issue #728），除此之外不做
## 第二次探測——provider 連線狀態玩到一半才改變（例如才把 llama-server
## 開起來）不在這裡的範圍，那種情況的既有救援手段是 debug 主控台的
## `ai`（手動重測）／`ai_decision`（手動逐隻開）。
##
## 逐隻查 agent.get_provider_name() 各自的 readiness，不是隨便查一個全域值——
## 不同 Agent 的 decision_source／model_name 可能解析到不同的 provider，
## 一隻壞掉不該連累其他隻。
##
## 要開啟的 Agent 呼叫 debug_set_llm_decision(true) 但不逐隻 await——
## AIService 的節點池＋佇列（池子大小見 AIConfig.pool_size，預設 3，CONVERSATION 優先於 SCHEDULED、
## 同優先權內維持進場順序，見《10》§5.1）本來就會把超出池子的請求
## 排隊處理，這裡不用自己手動錯開；逐隻 await 反而會把 5 隻角色的第一次
## 決策強制序列化，開場等待時間從一次 3-4 秒的網路延遲被拖成 5 次疊加
func _apply_startup_ai_state() -> void:
	await AIService.await_readiness_settled()

	# await 期間場景可能已被換掉（例如讀檔失敗改跳主選單）——這個節點連同
	# 場上 Agent 都不再有效，get_tree() 這時候會回傳 null，繼續往下會直接
	# 噴 null 存取錯誤（CodeRabbit review 抓到，PR #467）
	if not is_inside_tree():
		return

	var agents := get_tree().get_nodes_in_group("agents")
	var ready_count := 0
	# 用字典去重收集所有「沒就緒」的原因，不是只留最後一隻的——不同 Agent
	# 可能因為不同原因沒就緒（例如一隻 provider 查無此名、另一隻是連線逾時），
	# 開發期指示器要能一次看出全部原因，不能只看到最後蓋掉前面的那個
	# （CodeRabbit review 抓到，PR #467）
	var fallback_reasons := {}
	var ready_agents: Array[Agent] = []
	var not_ready_agents: Array[Agent] = []
	for node in agents:
		var agent := node as Agent
		if agent == null:
			continue
		var readiness := AIService.get_readiness(agent.get_provider_name())
		if bool(readiness.get("ready", false)):
			ready_count += 1
			ready_agents.append(agent)
		else:
			fallback_reasons[str(readiness.get("reason", ""))] = true
			agent.debug_set_llm_decision(false)
			not_ready_agents.append(agent)

	# 開機那批探測的「沒 ready」可能是過期快照（探測剛好撞上暫時性網路問題，
	# 之後連線已恢復，快照卻不會自己變好）——跟
	# game_manager.gd::activate_llm_decision_if_ready() 用同一個補打入口
	# reload_config_and_wait() 再判定一次（issue #728），不讓場景固定 NPC
	# 走另一道靜默關卡。整批沒就緒的 Agent 共用一次補打，不是逐隻各補打
	# 一次（世代編號機制保證結果不會互相污染）；仍是事件觸發的一次性補打，
	# 不是 tick 輪詢。
	if not not_ready_agents.is_empty():
		await AIService.reload_config_and_wait()
		# await 期間場景可能已被換掉（同上面 await_readiness_settled() 的防呆，
		# CodeRabbit review 抓到，PR #467）——這個節點連同場上 Agent 都不再
		# 有效，繼續往下會直接噴 null 存取錯誤
		if not is_inside_tree():
			return
		for agent in not_ready_agents:
			if not is_instance_valid(agent):
				continue
			var readiness := AIService.get_readiness(agent.get_provider_name())
			if bool(readiness.get("ready", false)):
				ready_count += 1
				ready_agents.append(agent)
			else:
				fallback_reasons[str(readiness.get("reason", ""))] = true

	# 場景固定 NPC 若沒有預先生成好 words_to_creator，Agent._ready() 開場會
	# fire-and-forget 補打一次（見 agent.gd::_generate_words_to_creator()）——
	# 上面補打的 await 期間場上角色可能被移除（debug 主控台 despawn 之類），
	# 已收集的 ready_agents 要逐隻防呆，對已 freed 的節點呼叫方法會直接噴錯
	for agent in ready_agents:
		if not is_instance_valid(agent):
			continue
		agent.debug_set_llm_decision(true)

	if agents.is_empty():
		return

	var status_label := get_node_or_null("PersistentUI/HUD/AIStatusLabel")
	if status_label == null:
		return

	status_label.set_status(ready_count, agents.size(), "、".join(fallback_reasons.keys()))


## 回傳這次讀檔是否成功套用。false 時已經呼叫 change_scene_to_file() 切去
## 主選單——呼叫端（_ready()）要跟著提前 return，不能繼續對正要被換掉的場景
## 做任何操作（CodeRabbit review 抓到，PR #467）
func _apply_continue() -> bool:
	if not SaveService.has_world(GameManager.DEFAULT_WORLD_ID):
		push_error("main_scene: continue_requested 但世界存檔 %s 不存在，返回主選單" % GameManager.DEFAULT_WORLD_ID)
		GameManager.continue_load_failed = true
		get_tree().change_scene_to_file(MAIN_MENU_SCENE)
		return false

	var world_data := SaveService.get_world(GameManager.DEFAULT_WORLD_ID)
	if not SaveService.is_world_data_valid(world_data):
		push_error("main_scene: 世界存檔 %s 讀取失敗或格式不完整（可能已損毀），返回主選單" % GameManager.DEFAULT_WORLD_ID)
		GameManager.continue_load_failed = true
		get_tree().change_scene_to_file(MAIN_MENU_SCENE)
		return false
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

	return true
