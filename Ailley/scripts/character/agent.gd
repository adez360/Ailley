extends Character

## 由任務池 + 仲裁器驅動的角色。
## 這一版只有 schedule 來源的任務（從 npc_schedule.json 轉換），仲裁器本身
## 已經是通用的——LLM 決策迴圈接上後，只要把任務丟進 _tasks 就會跟 schedule
## 任務公平競爭，不用再改這個檔案的仲裁邏輯。設計見 [[行程佇列與任務仲裁]]。
##
## 這一版刻意不接 LLM：先確保任務池/仲裁器重構完，行為跟舊版 cron 完全一致，
## 之後接 LLM 若行為跑歪，才分得出是這次重構寫錯還是 LLM 給的決策爛。

## 初始行程模板，對應 npc_schedule.json 的鍵（例如 "npc001"）。
## 這是「用哪份資料」而不是「我是誰」，所以刻意不共用 character_id ——
## id 是全遊戲唯一的身分，不可能同時等於一個手寫的模板名。
##
## 這個 @export 是**後備值**，優先權低於 npc_schedule.json 的 assignments：
## 場景裡的預設值是所有 instance 共用的，只靠它的話同一份 agent.tscn 生出來的
## 每一隻 Agent 都會拿到同一份行程、在同一分鐘走去同一個地點。
## 誰用哪份行程是資料，寫在資料檔裡才有辦法逐隻不同。
@export var schedule_template := ""

## 看到陌生人之後愣住多久（現實秒）
const NOTICE_PAUSE := 2.0

## demo 用的手動開關：這隻 Agent 看到玩家時，要不要打 village_sim_client
## 問一次真實決策（見 VillageSimDecision）。刻意預設關閉、要逐隻手動開，
## 不是全體 Agent 一起開——[[LLM 串接與 AI 服務層]] 明講過「先從一隻角色
## 開始，不要一次對所有 Agent 開放」，這是那條原則的落實。
@export var village_ai_enabled := false

## village_ai_enabled 開啟時，這隻 Agent 對應到 poc_village_sim 的哪個內部
## id（alan/zhou/mei/tie/aji）。跟 village_ai_enabled 一樣，這是 demo 用的
## 暫時欄位，不是正式的角色身分對照方案。
@export var poc_character_id := ""

## schedule 任務給中間值，靠 time_bonus 拉開跟其他來源的差距，
## 不是靠 base priority 本身——見 [[行程佇列與任務仲裁]] 的「待決」那節
const SCHEDULE_BASE_PRIORITY := 10.0

## 窗內給的加成，要明顯大於任何 base priority，確保「到點的行程」
## 預設壓過「隨時可做的雜事」
const TIME_BONUS := 100.0

## 兩個任務分數接近時的防抖動閾值：新任務分數要贏過目前任務「這麼多」才切換。
## 跟 MIN_COMMIT 一樣是待實跑調的暫定值，不是理論算出來的
const HYSTERESIS := 5.0

## 最短承諾時間（遊戲分鐘）：任務至少要做滿這麼久才允許被非 reflex 任務搶走，
## 防止兩個分數接近的任務讓角色來回抖動
const MIN_COMMIT := 2.0

## 候選任務池。這一版只在 _load_schedule() 建立一次就不再變動——
## 「到點才可用」靠仲裁時的 window 過濾，不是把任務從池子裡搬進搬出
var _tasks: Array[Dictionary] = []

## 目前執行中的任務，空字典代表還沒選過任何任務
var _current_task: Dictionary = {}

## _current_task 是什麼時候開始執行的（遊戲分鐘，見 _now_minutes()），
## 給 MIN_COMMIT 判斷用
var _current_task_started_at := 0

var current_place := ""
var current_state := "idle"

# 這一場已經對誰驚訝過。Vision 只回報「看到誰」，要不要有反應是這裡決定的；
# 沒有這張表的話，走出視野再走回來就會再驚訝一次
var _noticed := {}

# 上一次真的呼叫 move_to()（或判定「已經到了」「走不到」）的地點。
# _pursue_current_task() 每個遊戲分鐘都會跑，靠這個分辨「還在處理同一個地點」
# 與「地點換了要重新起步」
var _pursued_place := ""

# 這一趟移動已經有結論了（走到了，或 _check_stuck() 放棄了）。
# 少了它，放棄之後下一次重算又會對同一個走不到的目標重新 move_to()，
# 變成每秒一次的卡住／放棄迴圈
var _pursuit_done := false

# 正在對陌生人做「！」反應。那 2 秒刻意站著不動，期間不重新起步——
# GameClock 一個遊戲分鐘就是 1 現實秒，不擋的話 1 秒後就被送回路上，
# 2 秒的愣住實際上只有 1 秒
var _reacting := false


func _ready() -> void:
	super()
	add_to_group("agents")
	_load_schedule()

	if vision != null:
		vision.spotted.connect(_on_spotted)

	noise_heard.connect(_on_noise_heard)
	move_finished.connect(_on_move_finished)

	# NavGrid 開場是非同步建的，不等它建完就出發只會拿到空路徑
	var nav = get_tree().get_first_node_in_group("nav_grid")
	if nav != null and not nav.built:
		await nav.grid_built

	# time_changed 要在 await 之後才接：接在前面的話，NavGrid 還在建的期間就會
	# 開始重算，而重算現在每次都會嘗試 move_to()，對著空的 AStar 只會拿到空路徑
	# 並噴一則假的「走不到」。舊 cron 版接在前面沒事，是因為它只在時間字串剛好
	# 吻合某筆行程時才動作，await 這段期間幾乎命中不了
	GameClock.time_changed.connect(_on_time_changed)

	# 開場只是「第一次重算」，不是特例——沒有「套用目前這一筆」這種概念，
	# 每次重算都是仲裁器從候選裡挑分數最高的那個
	_reevaluate()

# 一趟移動有結論了：走到了，或 _check_stuck() 判定走不動而放棄。
# 兩種都代表「這個地點不必再起步一次」，_pursue_current_task() 靠它收斂。
#
# move_finished 不是只有仲裁器自己會觸發——debug 主控台的 goto 類指令、
# R&D 線的 village_sim_decision.gd 都會繞過仲裁器直接呼叫 character.move_to()，
# 完成時一樣會發這個訊號。只有這次完成的目標剛好是仲裁器自己現在要去的
# 地方（current_place 對應的錨點座標），才算數；不是的話代表這次完成的
# 是別人發的請求，不該影響仲裁器自己的追逐狀態
func _on_move_finished(_reached: bool) -> void:
	if not _is_own_pursuit_target(last_move_target):
		return
	_pursuit_done = true

# 判斷某個世界座標是不是仲裁器目前追的那個地點——ARRIVE_DISTANCE 當容許誤差，
# 跟 _has_arrived_at() 判定「站得夠近」用同一個標準
func _is_own_pursuit_target(world_position: Vector2) -> bool:
	if current_place.is_empty():
		return false
	var anchors := get_tree().get_first_node_in_group("place_anchors")
	if anchors == null or not anchors.has(current_place):
		return false
	return world_position.distance_to(anchors.resolve(current_place)) <= ARRIVE_DISTANCE

# 先問資料檔這隻角色被指派了哪份行程，沒有指派才用場景裡的 @export 後備值。
# 順序不能反過來：@export 一定有值（agent.tscn 的預設），反過來的話 assignments 永遠不生效
#
# 查表用的是**節點名**不是 character_id：id 是生成的 UUID，手寫不出來，
# 而 assignments 是人在編輯的資料檔
func _load_schedule() -> void:
	_warn_if_node_name_shared()

	var assigned := GameManager.get_schedule_template(name)
	if assigned.is_empty():
		# 退回 @export 是允許的，但那個預設值是所有 instance 共用的，靜默退回
		# 等於兩隻走同一份行程。漏寫 assignments 遠比刻意不指派常見，所以要講出來
		push_warning("Agent %s: assignments 裡沒有這個節點名，退回場景預設值 %s" % [
			name, schedule_template
		])
	else:
		schedule_template = assigned

	if schedule_template.is_empty():
		push_error("Agent %s: 沒有指定 schedule_template（可在 npc_schedule.json 的 assignments 指派）" % name)
		return

	var data = GameManager.get_npc(schedule_template)
	if data == null:
		push_error("Agent %s: npc_schedule.json 裡沒有模板 %s" % [name, schedule_template])
		return

	_tasks = _tasks_from_schedule_json(data["schedule"])

# 把 npc_schedule.json 的 {time, place, state} 陣列轉成 Task 結構（見
# [[行程佇列與任務仲裁]]）。window.end 由下一筆的 time 推出，最後一筆
# 補到隔日的第一筆時間（不寫死 08:00，跟著資料檔本身的開場時間走）。
# sleep 標記成不可中斷，其餘動作沿用舊版行為（可被打斷）
func _tasks_from_schedule_json(entries: Array) -> Array[Dictionary]:
	var tasks: Array[Dictionary] = []
	if entries.is_empty():
		return tasks

	var wrap_to: String = entries[0]["time"]

	for i in entries.size():
		var entry: Dictionary = entries[i]
		var end: String = entries[i + 1]["time"] if i + 1 < entries.size() else wrap_to

		# 只有一筆的行程表：window 從自己繞回自己，start == end，而 _in_window()
		# 對 start == end 一律回 false（now >= T and now < T 不可能同時成立）——
		# 唯一的候選永遠不在窗內，這隻角色會靜靜地站著不動、什麼都不 log。
		# 一筆的意思是「整天都做這件事」，所以不給 window：仲裁器本來就把
		# 沒有 window 的任務當成隨時可選（見 _in_window_or_unwindowed()）
		var window: Variant = null if entry["time"] == end else {"start": entry["time"], "end": end}

		tasks.append({
			"id": "schedule_%d" % i,
			"action": entry["state"],
			"params": {"place": entry["place"]},
			"priority": SCHEDULE_BASE_PRIORITY,
			"window": window,
			"duration": 0.0,
			"interruptible": entry["state"] != "sleep",
			"preconditions": [],
			"source": "schedule",
			"created_at": 0,
			"expires_at": 0,
			"retries": 0,
		})

	return tasks

# 節點名只在**同一層**唯一 —— 引擎只會把撞名的兄弟節點改名，不同父節點底下
# 兩隻都叫 Agent 是合法的。那樣它們會查到同一筆 assignment，靜默共用一份行程。
#
# 只有後進 group 的那隻掃得到先進的（_ready() 由上而下跑），所以撞名只印一則
func _warn_if_node_name_shared() -> void:
	for other in get_tree().get_nodes_in_group("agents"):
		if other != self and other.name == name:
			push_error("Agent %s: 節點名和 %s 撞了，assignments 分不出是哪一隻" % [
				get_path(), other.get_path()
			])
			return

# super() 顧「工作中不能被搭話」；`interruptible` 是任務層級的判斷，睡覺不可
# 被打斷就是靠 sleep 這筆任務的 interruptible = false 表達的。
#
# 這裡不另外比對 current_state == "sleep"：_select() 把 action 寫進 current_state，
# 而 interruptible 是從同一個 action 算出來的（見 _tasks_from_schedule_json()），
# 兩者恆等——多寫一項只會讓人以為 sleep 有額外的特例
func is_interruptible() -> bool:
	return super() and _current_task.get("interruptible", true)

# 對話結束後重算一次「現在該做什麼」，而不是接續原本那條路 ——
# 對話期間可能已經跨過了行程的整點
func exit_conversation() -> void:
	super()
	_reevaluate()

## 對話中要開口，打 AIService 要一句台詞。requester_id 用 character_id，不是
## 節點名或別的字串——這是這隻角色自己的成本控管，換節點名/場景重擺都不該
## 讓額度重算。ok=false 涵蓋 AI 未啟用/逾時/驗證失敗全部情況，呼叫端
## （conversation.gd）一律轉去 fallback，不細分是哪一種——細分沒有意義，
## 三種都是「這次要不到台詞」，處理方式完全一樣
const AI_THINKING_TEXT := "…"

func next_line(listener: Character, turns: Array[Dictionary], max_turns: int) -> Dictionary:
	# 立刻蓋掉正在顯示的東西，讓玩家知道「這個角色在想」，不是卡住。
	# AIService.request() 還沒送出就已經先顯示——冷卻/配額檢查也算在等待時間裡，
	# 玩家看到「…」的時間可能比實際打網路的時間長，這是刻意的：早一點給回饋
	# 比精準對齊網路延遲更重要
	say(AI_THINKING_TEXT, true)

	var envelope := PromptBuilder.build_dialogue_envelope(self, listener, turns, max_turns)
	var result: Dictionary = await AIService.request(envelope, character_id, AIService.Policy.CONVERSATION)
	if not result["ok"]:
		return {"ok": false}

	var parsed := AISchema.parse_completion(result["data"])
	if not parsed["ok"]:
		return {"ok": false}

	var validated := AISchema.validate_dialogue(parsed["data"])
	if not validated["ok"]:
		return {"ok": false}

	return {
		"ok": true,
		"line": validated["data"]["line"],
		"end": validated["data"]["end"],
	}

# 工作結束後同理：那 5 個遊戲分鐘可能已經跨過行程的整點，而 work_at() 開頭的
# stop_moving() 把原本的路徑清掉了，不重算的話會一路站到下一個整點字串吻合為止
func _on_work_finished() -> void:
	_reevaluate()

# 基底的快照加上行程表這一段。schedule/current_place/current_state 宣告在這裡，
# 所以是這裡負責放進去 —— 基底不必去猜誰有行程表
func get_state_snapshot() -> Dictionary:
	var snapshot := super()
	snapshot["schedule"] = {
		"place": current_place,
		"state": current_state,
		"size": _tasks.size(),
	}
	return snapshot

# 第一次看到某個陌生人就停下來愣一下。
#
# 認識的人不算 —— 每天上班都會遇到的同事不會讓人「！」。
# 判斷放在這裡而不是 Vision 裡：感知回報「看到誰」，要不要有反應是人格與關係的事，
# 接 LLM 之後這整段會換成「把 visible 放進 context 讓模型決定」
func _on_spotted(other: Character) -> void:
	# 玩家靠近時觸發一次真的 AI 決策——跟下面「陌生人才會『！』」那段是獨立的
	# 兩件事：AI 觸發不看認不認識（老朋友走近一樣想問問 AI 現在會怎麼決策），
	# 只看是不是玩家、這隻 Agent 有沒有開這個開關。目前只支援玩家觸發，
	# Agent 對 Agent 互相觸發是後續才要處理的範圍（見 [[LLM 串接與 AI 服務層]]
	# 的斷點記錄）。
	#
	# 呼叫 _trigger_village_ai() 而不是直接 await decide_and_act()：這裡故意
	# 不擋住下面的「！」反應——網路呼叫可能要幾秒，「！」反應應該要即時，
	# 不該被 AI 呼叫拖慢
	if village_ai_enabled and other.is_in_group("player") and not is_in_conversation():
		_trigger_village_ai()

	if is_in_conversation() or _noticed.has(other.character_id):
		return

	_noticed[other.character_id] = true

	if relationships != null and relationships.has_met(other.character_id):
		return

	say(L10n.t("DLG_SURPRISE"))
	stop_moving()

	# _reacting 期間 _pursue_current_task() 不重新起步。少了它，1 秒後
	# GameClock 的重算就會把角色送回路上，NOTICE_PAUSE 訂 2 秒實際上只有 1 秒
	_reacting = true
	await get_tree().create_timer(NOTICE_PAUSE).timeout
	_reacting = false

	# 愣完重算行程而不是接回原本那條路：這 2 秒可能已經跨過行程的整點，
	# 與 exit_conversation() 同一個理由。剛剛的 stop_moving() 已經把路徑清掉，
	# 這次重算會重新起步
	if not is_in_conversation():
		_reevaluate()

# 之前吃過虧：decide_and_act() 完全沒有可見的回饋，跑失敗或跑成功但
# 剛好沒事發生（沒話、動作不是 move_to）看起來一模一樣，使用者分不出來
# 「壞了」還是「這次剛好沒事」。這裡一律 print()——不進遊戲內 UI，
# 印到 Godot 的 Output 面板／終端機，跟 debug 主控台的 _cmd_village_ai_act
# 是兩個不同的可見管道，但至少有一個能看
func _trigger_village_ai() -> void:
	print("[village_ai] %s 看到玩家，觸發自動決策（poc_character_id=%s）" % [character_name, poc_character_id])
	var result: Dictionary = await VillageSimDecision.decide(self, poc_character_id)

	if not result["ok"]:
		print("[village_ai] %s 決策失敗：%s" % [character_name, result["error"]])
		return

	var data: Dictionary = result["data"]
	var output: Dictionary = data.get("output", {})
	print("[village_ai] %s 決策完成：action_en=%s speech=%s" % [
		character_name, data.get("action_en", ""), output.get("speech")
	])
	print("[village_ai]   reasoning: %s" % output.get("reasoning", ""))
	# 現在已經接上 physiology_override（見 VillageSimDecision._build_physiology_override()），
	# 這裡重印一次真實的 Stats.SPEC 數值，方便對照 reasoning 判斷這次決策
	# 合不合理——只轉得出 hunger/energy(stamina)/fun(boredom) 三項，
	# social/mood 沒有對應欄位，thirst/health/money 這三項 Godot 沒有資料
	# 來源，AI 那邊沿用 poc 角色檔案原本的值，不是這隻角色的真實狀態
	print("[village_ai]   godot stats（僅供對照，非全部都送出去了）: %s" % get_state_snapshot().get("stats", {}))

	# 執行動作/說話留在這裡自己呼叫，不讓 VillageSimDecision 幫忙做——
	# 副作用要留在角色自己的程式碼路徑，理由見 village_sim_decision.gd 的檔頭註解
	#
	# 這條路目前完全繞過任務池/仲裁器（不進 _tasks，也不動 _current_task），
	# 跟下面的仲裁器是兩個獨立機制，會互相覆蓋——見 [[行程佇列與任務仲裁]]
	# 的已知並存說明，這則重構不含把這條路接進仲裁器
	VillageSimDecision.apply(self, poc_character_id, result)

# 範圍內有人發出聲音（見 character.gd 的 make_noise()）。
# 跟 _on_spotted 不同，這裡不記錄「已經反應過」——聲音是一次性事件，
# 每次都該有反應，不是像陌生人那樣「見過一次就不再驚訝」
func _on_noise_heard(_source: Character) -> void:
	if is_in_conversation():
		return

	say(L10n.t("DLG_NOISE_ALERT"))

func _on_time_changed(_hour: int, _minute: int) -> void:
	_reevaluate()

# 仲裁器的核心：每次重算，不維護「目前是第幾筆」。
#
# 1. 過濾出還在時間窗內的候選（沒有 window 的一律算候選）
# 2. 每筆算分數，取最高的，決定要不要換（_consider_switch）
# 3. 不管有沒有換，都再嘗試一次「往目前任務的方向前進」（_pursue_current_task）
#
# 第 3 步不能省，也不能只在「真的換了」的時候才做：GameClock 每個遊戲分鐘
# 都會呼叫這裡（見 _on_time_changed），對話中也一樣會被呼叫到——任務完全可能
# 在對話期間就換掉，而 _pursue_current_task() 那時候會因為 is_in_conversation()
# 直接返回、沒有真的移動。等對話結束 exit_conversation() 再重算一次時，best
# 通常還是同一筆（沒有新的更高分候選），「是不是同一筆」這個判斷若直接 return
# 就沒有第二次機會補跑 move_to()——角色會卡在對話結束的地方不動，即使任務
# 早就換了。所以「選任務」跟「往任務移動」是兩個獨立步驟，每次重算都跑後者。
#
# 代價是 _pursue_current_task() 得自己認得「這個地點已經在處理了」，
# 見它自己的註解
func _reevaluate() -> void:
	if _tasks.is_empty():
		return

	var now := "%02d:%02d" % [GameClock.hour, GameClock.minute]
	var now_minutes := _now_minutes()

	var best: Dictionary = {}
	var best_score := -INF

	for task in _tasks:
		# 過期任務不進入候選——expires_at 是「這件事的機會已經徹底過了」，
		# 跟 window（「現在不是做這件事的時間，但之後還會再輪到」）是不同語意，
		# 過期的候選不該被選中，也不該影響分數比較
		if _is_expired(task, now_minutes):
			continue
		if not _in_window_or_unwindowed(task, now):
			continue

		var score := _score(task, now)
		if score > best_score:
			best_score = score
			best = task

	if not best.is_empty():
		_consider_switch(best, best_score, now, now_minutes)
	elif not _current_task.is_empty() \
			and (_is_expired(_current_task, now_minutes) or not _in_window_or_unwindowed(_current_task, now)):
		# 一個候選都沒有，而目前這筆自己已經過期或窗口過了：清掉，不要留著。
		# 留著的話 sleep（interruptible = false）會讓 is_interruptible() 永遠回
		# false，角色再也搭不了話——跟「窗口過期還被 interruptible 擋住」是同一
		# 個坑，只是從 best 為空這條路徑進來，走不到 _consider_switch() 那關。
		# schedule 任務的窗口由建構方式保證連續，碰不到；有間隔的任務才會
		_current_task = {}
		current_place = ""
		current_state = "idle"

	_pursue_current_task()

# 決定要不要把 _current_task 換成 best。只動狀態，不碰移動——
# 移動一律交給呼叫端之後統一補跑的 _pursue_current_task()
func _consider_switch(best: Dictionary, best_score: float, now: String, now_minutes: int) -> void:
	if _current_task.is_empty():
		_select(best, now_minutes)
		return

	if best.get("id", "") == _current_task.get("id", ""):
		return

	var current_still_valid := not _is_expired(_current_task, now_minutes) \
		and _in_window_or_unwindowed(_current_task, now)

	if current_still_valid:
		# 承諾檢查（含 interruptible）只保護「還沒過期、還在自己時間窗內」的
		# 目前任務。過期或窗口已經過期的任務不受保護，該讓位就讓位——否則
		# sleep（interruptible=false）會卡死，永遠醒不過來，因為每次重算都在
		# 「不可中斷」這關直接 return，連「自己早就該結束了」都沒機會判斷到。
		# interruptible 管的是「有沒有更高分的候選能搶」，不該管「自己是不是
		# 早就該結束了」，這是兩件事
		if not is_interruptible():
			return

		var current_score := _score(_current_task, now)
		if best_score < current_score + HYSTERESIS:
			return

		var committed_for: int = now_minutes - _current_task_started_at
		if _current_task.get("source", "") != "reflex" and committed_for < MIN_COMMIT:
			return

	_select(best, now_minutes)

# 用 .get() 而不是硬取 key，跟計分那幾個函式同一種寫法——檔頭承諾「把任務丟進
# _tasks 就會公平競爭，不用再改這個檔案」，那新來源少填一個欄位就不該讓這裡崩掉
func _select(task: Dictionary, now_minutes: int) -> void:
	_current_task = task
	_current_task_started_at = now_minutes
	current_place = str(task.get("params", {}).get("place", ""))
	current_state = str(task.get("action", ""))

# 往 _current_task 的方向前進。無條件每次重算都跑一次，不管這次有沒有
# 剛選定新任務——對話中會在這裡先返回、不移動，等下一次重算（對話結束後
# 那次）才會真的呼叫 move_to()。
#
# 「每次都跑」的代價是這個函式必須自己分辨「該起步了」與「已經在處理了」，
# 靠 _pursued_place / _pursuit_done 這兩個欄位（見它們的宣告）。少了這層，
# 每個遊戲分鐘都會對同一個目標重下一次指令，而它裡面的 move_to()、push_error()
# 都是只該在狀態真的改變時做一次的事
func _pursue_current_task() -> void:
	if _current_task.is_empty():
		return

	# 對話中先記下該去哪但不動身，講完由 exit_conversation() 重算
	if is_in_conversation():
		return

	# 工作中不要把自己走離工作站：_run_work() 每個遊戲分鐘重驗距離，走開就中止
	# 而且不撥款（見 character.gd 的 _run_work()）。_consider_switch() 那邊已經
	# 靠 is_interruptible()（含 not _working）擋住換任務，移動這半邊也要一致
	if is_working():
		return

	# 對陌生人「！」的那 2 秒刻意站著不動
	if _reacting:
		return

	if current_place.is_empty():
		return

	var anchors := get_tree().get_first_node_in_group("place_anchors")
	if anchors == null or not anchors.has(current_place):
		# 地點打錯只報一次。這個函式每個遊戲分鐘跑一次，不擋的話一個 typo
		# 就是每小時三千多則 error 洗掉整個面板
		if current_place != _pursued_place:
			push_error("Agent %s: 沒有這個地點 %s" % [character_name, current_place])
			_pursued_place = current_place
			_pursuit_done = true
		return

	var target: Vector2 = anchors.resolve(current_place)

	# 已經在目的地就沒事要做。這一步不做的話，「早就到了」會被誤報成「走不到」：
	# move_to() 對「路徑不足兩點」一律回傳 false，而站在原地正好就是這種情形
	if _has_arrived_at(target):
		stop_moving()
		_pursued_place = current_place
		_pursuit_done = true
		return

	# 地點沒換的話，這一趟只起步一次：還在走就繼續走（重下指令會重設
	# Character 的 _stuck_timer，卡住偵測永遠累積不到閾值），已經有結論
	# 也不要再試（_check_stuck() 放棄之後再 move_to() 同一個走不到的目標，
	# 就是卡住／放棄每秒一輪的無限迴圈）。
	#
	# 地點換了就一定要重下——不然任務換了、角色還在走去上一筆的地點時，
	# 新目標永遠等不到 move_to()，要先走完舊路徑才會改道
	if current_place == _pursued_place and (is_moving() or _pursuit_done):
		return

	_pursued_place = current_place
	_pursuit_done = false

	if not move_to(target):
		push_warning("Agent %s: 走不到 %s" % [character_name, current_place])
		_pursuit_done = true

# 站得夠近，或者已經站在目標所在的那一格。
#
# 後者才是關鍵：ARRIVE_DISTANCE 是 2px，但尋徑是以 16px 的格為單位，
# 中間 2..11px 這一段是死角 —— 距離判定說「還沒到」，find_path() 卻因為
# 起點終點同格而只給得出一個點。少了格判定，Agent 每次重算行程
# （對話結束、看到人愣完）都會噴一次假的「走不到」
func _has_arrived_at(target: Vector2) -> bool:
	if get_body_position().distance_to(target) <= ARRIVE_DISTANCE:
		return true

	var nav = get_tree().get_first_node_in_group("nav_grid")
	if nav == null:
		return false

	return nav.world_to_cell(get_body_position()) == nav.world_to_cell(target)

# score(task, now) = priority + time_bonus + need_bonus + age_bonus，
# 見 [[行程佇列與任務仲裁]]。這一版只有 schedule 來源，need_bonus／
# age_bonus 先固定回 0——兩者要等 LLM 任務接進來、真的有「等待中的任務」
# 才有意義，不是這則重構的範圍
func _score(task: Dictionary, now: String) -> float:
	return float(task.get("priority", 0.0)) \
		+ _time_bonus(task, now) \
		+ _need_bonus(task) \
		+ _age_bonus(task)

func _time_bonus(task: Dictionary, now: String) -> float:
	var window = task.get("window")
	if window == null:
		return 0.0
	return TIME_BONUS if _in_window(window, now) else 0.0

# 這一版恆為 0——schedule 任務不看角色需求，等 LLM 依 Stats 產生任務時才會用到
func _need_bonus(_task: Dictionary) -> float:
	return 0.0

# 這一版恆為 0——schedule 任務是「到點就可用」的固定候選，不是排隊等執行、
# 需要防餓死的任務。LLM 任務有真的 created_at 時間戳之後才有意義
func _age_bonus(_task: Dictionary) -> float:
	return 0.0

# expires_at 是絕對遊戲分鐘數（見 _now_minutes()），0 或負值代表不會過期。
# schedule 來源的任務目前一律填 0（見 _tasks_from_schedule_json()），碰不到
# 這條路徑；LLM 推進池子的任務才會真的帶非零值
func _is_expired(task: Dictionary, now_minutes: int) -> bool:
	var expires_at: int = task.get("expires_at", 0)
	return expires_at > 0 and expires_at < now_minutes

func _in_window_or_unwindowed(task: Dictionary, now: String) -> bool:
	var window = task.get("window")
	if window == null:
		return true
	return _in_window(window, now)

# "HH:MM" 字串比較。start <= end 是同一天內的一般窗口；start > end 代表
# 跨過午夜（例如 18:00~08:00 的 sleep），要用「在 start 之後 或 在 end 之前」
func _in_window(window: Dictionary, now: String) -> bool:
	var start: String = window["start"]
	var end: String = window["end"]
	if start <= end:
		return now >= start and now < end
	return now >= start or now < end

func _now_minutes() -> int:
	return GameClock.day * 1440 + GameClock.hour * 60 + GameClock.minute

## Debug 用：回傳候選池每一筆的分數拆項跟目前有沒有在窗內／是不是執行中——
## debug_console.gd 的 tasks 指令用這個顯示。不直接碰底線開頭的內部欄位，
## 保持仲裁邏輯本身是這個檔案唯一能動 _tasks/_current_task 的地方
func get_task_debug_info() -> Array[Dictionary]:
	var now := "%02d:%02d" % [GameClock.hour, GameClock.minute]
	var result: Array[Dictionary] = []

	for task in _tasks:
		result.append({
			"task": task,
			"is_current": not _current_task.is_empty() and task["id"] == _current_task["id"],
			"in_window": _in_window_or_unwindowed(task, now),
			"score": {
				"base": float(task.get("priority", 0.0)),
				"time": _time_bonus(task, now),
				"need": _need_bonus(task),
				"age": _age_bonus(task),
				"total": _score(task, now),
			},
		})

	return result

## Debug 用：目前這筆任務已經執行幾個遊戲分鐘，給 tasks 指令顯示
func get_current_task_elapsed_minutes() -> int:
	if _current_task.is_empty():
		return 0
	return _now_minutes() - _current_task_started_at
