extends Character

## 由任務池 + 仲裁器驅動的角色。
## 任務有兩個來源：schedule（從 npc_schedule.json 轉換，開場建立一次不再變動）
## 跟 llm（`llm_decision_enabled` 開啟後，決策迴圈依《10》§5.1 事件驅動觸發，
## 見 _request_next_decision()），兩者用同一套仲裁邏輯公平競爭，不分軌處理。
## 設計見 [[行程佇列與任務仲裁]]。

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

## 決策迴圈開關（#88）：開啟後 LLM 任務完成時會觸發下一次決策請求，
## 經 AISchema 驗證後推進 _tasks，跟仲裁器裡其他來源的任務公平競爭。
## 刻意預設關閉、要逐隻手動開，不是全體 Agent 一起開——
## [[LLM 串接與 AI 服務層]] 明講過「先從一隻角色開始，不要一次對所有
## Agent 開放」，這是那條原則的落實
@export var llm_decision_enabled := false

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

## 等待決策回覆期間，蓋掉上面的 MIN_COMMIT 用這個值。本地 LLM 已知延遲
## 2.5-4 秒（見 note/技術/LLM 串接與 AI 服務層.md 的延遲章節），比一般
## MIN_COMMIT（2.0 秒）長——等待決策期間退回任務池的 fallback 任務如果只受
## 一般 MIN_COMMIT 保護，幾乎每個決策週期都會在 fallback 才做不到一半、
## LLM 決策準時抵達的那一刻被切掉，變成規律性抖動而不是偶發的。
## 起始值抓 5.0，跟 MIN_COMMIT／HYSTERESIS 一樣是待實跑校準的暫定值
const LLM_WAIT_MIN_COMMIT := 5.0

## LLM 任務的 duration 引擎端下限（遊戲分鐘）：不管模型回傳什麼，實際套用值
## 一律不低於這個下限，避免呼叫頻率沒有上界保護。起始值抓 10，在地端已知延遲
## 2.5-4 秒的前提下留有緩衝，實跑同機測試後再校準，不是理論算出來的定案值
const MIN_ACTION_DURATION := 10.0

## _tasks 池子的 LLM 來源總量上限（不含 schedule 來源，那批是開場建立一次
## 就不變的固定集合）。跟每遊戲日最多 20 次 AI 請求同量級——見
## [[行程佇列與任務仲裁]] 的「池子的守則」
const LLM_TASK_POOL_CAP := 20

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

# talk 任務用的卡住偵測（#90）。目標是會動的角色，每次重算都要重新
# move_to()，不能沿用上面 _pursued_place／_pursuit_done 那套「地點沒換就不
# 重下指令」的節流——但這也表示不能靠 Character._stuck_timer：那個計時器在
# move_to() 一開頭就會被歸零，每個遊戲分鐘重下一次指令等於它永遠沒機會累積
# 到 STUCK_TIME。這裡自己算：距離沒有明顯縮短就算一次沒有進展
var _talk_pursuit_stuck_ticks := 0
var _talk_pursuit_last_distance := INF

# 自己成功發起、目前正在進行中的 talk 任務 id。只在 talk_to() 真的成功那一刻
# 設值，exit_conversation() 靠這個而不是「當下的 _current_task」判斷對話結束
# 時該清掉哪一筆——理由見 exit_conversation() 自己的註解
var _active_talk_task_id := ""

# 正在對陌生人做「！」反應。那 2 秒刻意站著不動，期間不重新起步——
# GameClock 一個遊戲分鐘就是 1 現實秒，不擋的話 1 秒後就被送回路上，
# 2 秒的愣住實際上只有 1 秒
var _reacting := false

# 目前有沒有一份決策請求還沒回來。_reevaluate() 靠它避免同一份請求還在飛時
# 又觸發第二份（同一個 LLM 任務完成的當下可能被重算好幾次），
# _consider_switch() 靠它決定要用 MIN_COMMIT 還是 LLM_WAIT_MIN_COMMIT
var _awaiting_decision := false

# LLM 任務 id 的流水號。不能拿 Time.get_ticks_msec() 當唯一值——一次回應最多
# 五筆是在同一個同步迴圈裡建的，同毫秒是常態不是例外，撞 id 之後
# _consider_switch() 的 best.id == _current_task.id 會把不同任務當成同一筆，
# 直接 return 不切換
var _next_llm_task_id := 0


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

	# 《10》§5.1「世界開始時，所有角色依序發起決策請求」——只在還沒有任何
	# LLM 來源任務時補這一次，避免重進場景（例如換場）時重複發起
	if llm_decision_enabled and not _has_llm_task():
		_request_next_decision()

# 一趟移動有結論了：走到了，或 _check_stuck() 判定走不動而放棄。
# 兩種都代表「這個地點不必再起步一次」，_pursue_current_task() 靠它收斂。
#
# move_finished 不是只有仲裁器自己會觸發——debug 主控台的 goto 類指令也會繞過
# 仲裁器直接呼叫 character.move_to()，完成時一樣會發這個訊號。
# 只有這次完成的目標剛好是仲裁器自己現在要去的
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

# 能不能被搭話打斷。super() 顧「工作中不能被搭話」；`interruptible` 是任務層級
# 的判斷，睡覺不可被打斷就是靠 sleep 這筆任務的 interruptible = false 表達的。
#
# 這裡不另外比對 current_state == "sleep"：_select() 把 action 寫進 current_state，
# 而 interruptible 是從同一個 action 算出來的（見 _tasks_from_schedule_json()），
# 兩者恆等——多寫一項只會讓人以為 sleep 有額外的特例
#
# 只管「搭話」，不管仲裁器搶占——那是 _is_preemptible() 的事。兩者在現有的
# 任務類型上算出同一個公式是刻意維持，不是巧合（見 _is_preemptible() 的
# 註解），issue #113 把它們拆成兩個獨立函式之前，這裡曾經一函兩用
func is_talk_interruptible() -> bool:
	return super() and _current_task.get("interruptible", true)

# 仲裁器搶占檢查：目前任務能不能被更高分的候選換掉。跟上面的搭話中斷是兩個
# 不同的問題——這裡不呼叫 super()／is_talk_interruptible()，兩個判斷刻意各自
# 獨立算，不要再透過共用函式綁在一起（那正是 issue #113 要拆開的意外共用）。
#
# 公式跟 is_talk_interruptible() 現在剛好一樣（not _working and 任務的
# interruptible），這是刻意維持拆分前的合併結果，不是巧合——純重構不改變
# 現有任務類型的實際中斷/搶占行為。「工作該不該被攻擊強制打斷」「AI 能不能
# 為了緊急需求主動放棄工作」這類語意判斷留給《AI自主性審查清單》PM 拍板後
# 的後續 issue，屆時兩個判斷要各自往哪個方向改會很清楚，這裡不動它
func _is_preemptible() -> bool:
	return not _working and _current_task.get("interruptible", true)

# 對話結束後重算一次「現在該做什麼」，而不是接續原本那條路 ——
# 對話期間可能已經跨過了行程的整點
#
# 自己主動發起搭話成功時觸發的那筆 talk 任務，對話結束要連任務帶目前狀態
# 一起清掉——不清的話 id 沒變，_reevaluate() 會選到同一筆再打一次，變成
# 每次重算都重新搭話一次的無限迴圈（#90）。
#
# 靠 _active_talk_task_id 認，不是看「當下」的 _current_task：對話期間
# _reevaluate() 照樣會跑完整套選任務邏輯（只有移動被 is_in_conversation()
# 擋住，選任務本身沒被擋），_current_task 完全可能在對話進行中被換成別的
# 任務。憑當下的 _current_task 判斷會有兩種撲空：真正該清的那筆任務已經
# 不是 _current_task、清不到；或是被別人搭話時，自己另一筆不相干的待辦
# talk 任務剛好是 _current_task，被誤刪
func exit_conversation() -> void:
	super()

	if not _active_talk_task_id.is_empty():
		_remove_task(_active_talk_task_id)
		if _current_task.get("id", "") == _active_talk_task_id:
			_current_task = {}
			current_place = ""
			current_state = "idle"
		_active_talk_task_id = ""

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

## 正式決策迴圈（#88）的請求端，模式照抄 next_line()——build envelope、await
## AIService、parse_completion、validate_*，任何一關失敗都靜默放棄，任務池
## fallback 頂著，下次任務完成再試。跟 next_line() 不一樣的是這裡失敗不用
## 特別回報給呼叫端：next_line() 的呼叫端（conversation.gd）當下就在等一句話
## 沒有就要走 fallback 台詞；這裡的呼叫端只是「該不該重算」，仲裁器本來就會
## 自己從池子挑 fallback，不需要一個回傳值告訴它失敗了
func _request_next_decision() -> void:
	if _awaiting_decision:
		return
	_awaiting_decision = true

	var visible: Array[Character] = vision.get_visible_characters() if vision != null else []
	var envelope := PromptBuilder.build_plan_envelope(self, visible, _task_pool_summary())
	var result: Dictionary = await AIService.request(envelope, character_id, AIService.Policy.SCHEDULED)
	_awaiting_decision = false

	if not result["ok"]:
		return

	var parsed := AISchema.parse_completion(result["data"])
	if not parsed["ok"]:
		return

	var validated := AISchema.validate_tasks(parsed["data"])
	if not validated["ok"]:
		return

	# reasoning／inner_monologue 印出來給人排查，跟 _trigger_village_ai() 的
	# print() 除錯模式一致；不進遊戲內 UI。決策準不準沒有系統性驗證，
	# 目前只能肉眼看這兩個欄位判斷合不合理
	print("[llm_decision] %s reasoning: %s" % [character_name, validated["data"].get("reasoning", "")])
	print("[llm_decision] %s inner_monologue: %s" % [character_name, validated["data"].get("inner_monologue", "")])

	_push_llm_tasks(validated["data"]["tasks"], validated["data"])
	_reevaluate()

## 把驗證過的 LLM 任務推進 _tasks，補上仲裁器需要、但 LLM 不用填的欄位。
## response 帶的是同一次決策回應的 reasoning／inner_monologue，複製一份到
## 這批裡的每一筆 Task，讓「這個任務是為什麼被排進來的」跟任務本身綁在一起，
## 供之後《12》規格書的記憶系統直接從 Task 讀，不用另外對照決策回應的歷史記錄
func _push_llm_tasks(tasks: Array[Dictionary], response: Dictionary) -> void:
	var now_minutes := _now_minutes()

	for task in tasks:
		var params: Dictionary = task.get("params", {})
		var dedup_key: String = str(task.get("action", "")) + "|" \
			+ str(params.get("target", params.get("place", "")))

		# dedup：同一個 action+target/place 新的覆蓋舊的，不並存兩筆——
		# 見 [[行程佇列與任務仲裁]]「池子的守則」，沒有這條的話被搭話幾次
		# 之後池子就會塞滿重複的「回訪某某」
		for i in range(_tasks.size() - 1, -1, -1):
			if _tasks[i].get("source", "") != "llm":
				continue
			var existing_params: Dictionary = _tasks[i].get("params", {})
			var existing_key: String = str(_tasks[i].get("action", "")) + "|" \
				+ str(existing_params.get("target", existing_params.get("place", "")))
			if existing_key == dedup_key:
				_tasks.remove_at(i)

		if _llm_task_count() >= LLM_TASK_POOL_CAP:
			push_warning("Agent %s: LLM 任務池已滿（上限 %d），丟棄新任務 %s" % [
				character_name, LLM_TASK_POOL_CAP, task.get("action", "")
			])
			continue

		_next_llm_task_id += 1
		task["id"] = "llm_%d_%d" % [now_minutes, _next_llm_task_id]
		task["source"] = "llm"
		task["created_at"] = now_minutes
		task["duration"] = maxf(float(task.get("duration", 0.0)), MIN_ACTION_DURATION)
		task["reasoning"] = response.get("reasoning", "")
		task["inner_monologue"] = response.get("inner_monologue", "")
		_tasks.append(task)

func _llm_task_count() -> int:
	var count := 0
	for task in _tasks:
		if task.get("source", "") == "llm":
			count += 1
	return count

func _remove_task(id: String) -> void:
	if id.is_empty():
		return
	for i in range(_tasks.size() - 1, -1, -1):
		if _tasks[i].get("id", "") == id:
			_tasks.remove_at(i)
			return

func _has_llm_task() -> bool:
	return _llm_task_count() > 0

## 目前任務池的摘要，給 PromptBuilder 組 plan 信封用——只給 LLM 需要知道的
## 「排程本身在做什麼」，不是完整 Task 結構（分數拆項那些是給人 debug 看的，
## 不該佔掉 prompt 的 token）
func _task_pool_summary() -> Array[Dictionary]:
	var summary: Array[Dictionary] = []
	for task in _tasks:
		var params: Dictionary = task.get("params", {})
		summary.append({
			"action": task.get("action", ""),
			"place": params.get("place", ""),
			"target": params.get("target", ""),
			"source": task.get("source", ""),
		})
	return summary

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
	var now_minutes := _now_minutes()

	# 事件驅動觸發：LLM 來源的目前任務做滿引擎套用過下限的 duration 就算完成，
	# 發起下一次決策請求。等待期間不 return——照樣往下跑完整套仲裁流程，
	# 從池子（schedule 任務、上一輪還沒被選中的 llm 任務）挑 fallback 頂著，
	# 不空等、不卡頓，是《10》§5.1 講的「天然容錯」
	if llm_decision_enabled and not _awaiting_decision \
			and _current_task.get("source", "") == "llm" \
			and now_minutes - _current_task_started_at >= int(_current_task.get("duration", 0.0)):
		# 做完的那筆要先離開池子。llm 任務沒有 window，不像 schedule 靠時間窗
		# 自然退場——留著的話它會用原本的分數繼續參加下一輪算分，被重新選中，
		# 變成同一件事做完又做。_current_task 是同一個 Dictionary 的參照，
		# 移出池子不影響它，等待決策回來的期間照樣可以繼續執行
		_remove_task(_current_task.get("id", ""))
		_request_next_decision()

	if _tasks.is_empty():
		return

	var now := "%02d:%02d" % [GameClock.hour, GameClock.minute]

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
		# 留著的話 sleep（interruptible = false）會讓 is_talk_interruptible() 與
		# _is_preemptible() 都永遠回 false，角色再也搭不了話、任務也永遠搶不走
		# ——跟「窗口過期還被 interruptible 擋住」是同一個坑，只是從 best 為空
		# 這條路徑進來，走不到 _consider_switch() 那關。schedule 任務的窗口由
		# 建構方式保證連續，碰不到；有間隔的任務才會
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
		# 「不可搶占」這關直接 return，連「自己早就該結束了」都沒機會判斷到。
		# interruptible 管的是「有沒有更高分的候選能搶」，不該管「自己是不是
		# 早就該結束了」，這是兩件事
		if not _is_preemptible():
			return

		var current_score := _score(_current_task, now)
		if best_score < current_score + HYSTERESIS:
			return

		# 等待決策回覆期間，fallback 任務吃比較長的承諾期——見 LLM_WAIT_MIN_COMMIT
		# 自己的註解：一般 MIN_COMMIT 比本地 LLM 已知延遲短，撐不了到答案回來
		var committed_for: int = now_minutes - _current_task_started_at
		var min_commit := LLM_WAIT_MIN_COMMIT if _awaiting_decision else MIN_COMMIT
		if _current_task.get("source", "") != "reflex" and committed_for < min_commit:
			return

	_select(best, now_minutes)

# 用 .get() 而不是硬取 key，跟計分那幾個函式同一種寫法——檔頭承諾「把任務丟進
# _tasks 就會公平競爭，不用再改這個檔案」，那新來源少填一個欄位就不該讓這裡崩掉
func _select(task: Dictionary, now_minutes: int) -> void:
	_current_task = task
	_current_task_started_at = now_minutes
	current_place = str(task.get("params", {}).get("place", ""))
	current_state = str(task.get("action", ""))
	# 換了新任務就是換了新的追逐目標，talk 任務自己的卡住偵測要歸零重算——
	# 不歸零的話舊目標留下的「沒進展」次數會誤算進新目標的偵測
	_talk_pursuit_stuck_ticks = 0
	_talk_pursuit_last_distance = INF

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
	# 靠 _is_preemptible()（含 not _working）擋住換任務，移動這半邊也要一致
	if is_working():
		return

	# 對陌生人「！」的那 2 秒刻意站著不動
	if _reacting:
		return

	# talk 任務的目標是另一個角色，不是固定地點——current_place 對它一律是空的
	# （params 裝的是 target 不是 place），要另外分流，不能落進下面的地點判斷
	if current_state == "talk":
		_pursue_talk_task()
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

# talk 任務的執行（#90）：目標是會動的角色，不是靜止的地點錨點，所以不能沿用
# 上面那套「走一次、_pursued_place／_pursuit_done 收斂」的節流——每次重算都
# 要重新問一次「他現在在哪」，距離內就直接搭話，不是只起步一次
func _pursue_talk_task() -> void:
	var target_name: String = str(_current_task.get("params", {}).get("target", ""))
	var target := _find_character_by_name(target_name)

	if target == null:
		# 找不到人只報一次，理由跟「地點打錯只報一次」一樣——這個函式每個
		# 遊戲分鐘跑一次，目標一直不存在的話不能每分鐘洗一次錯誤。借用
		# _pursued_place 當去重鍵：talk 任務跟 place 任務不會同時是目前任務，
		# 語意上不衝突，不用另外開欄位
		if target_name != _pursued_place:
			push_error("Agent %s: 找不到搭話對象 %s" % [character_name, target_name])
			_pursued_place = target_name
		return

	var distance := get_body_position().distance_to(target.get_body_position())

	if distance <= TALK_RANGE:
		stop_moving()
		var failure := talk_to(target)
		if failure == Character.TALK_OK:
			# 記住是這筆任務讓對話成立的——exit_conversation() 靠這個 id 清任務，
			# 不能靠「對話結束當下的 _current_task」，因為對話期間 _reevaluate()
			# 照樣可能把 _current_task 換成別的（見 exit_conversation() 的註解）
			_active_talk_task_id = _current_task.get("id", "")
		else:
			# 失敗不放棄任務，下個遊戲分鐘再試——對方可能只是暫時忙碌（TARGET_BUSY
			# 等），跟 move_to() 走不到只 push_warning 不整筆放棄是同一種態度
			push_warning("Agent %s: 搭話 %s 失敗（%s）" % [
				character_name, target.character_name, failure
			])
		return

	# 找不到路徑要講出來——跟地點式任務一樣，不然「永遠追不到人」在 log 裡
	# 完全沒有線索，只看得到角色站著不動
	if not move_to(target.get_body_position()):
		push_warning("Agent %s: 走不到搭話對象 %s" % [character_name, target.character_name])
		_talk_pursuit_stuck_ticks = 0
		return

	# 距離沒有明顯縮短（容許一點量測誤差）就算一次沒進展；連續幾次才報一次，
	# 不是每次都報——偶爾一次量測誤差不該洗警告
	if distance >= _talk_pursuit_last_distance - 1.0:
		_talk_pursuit_stuck_ticks += 1
	else:
		_talk_pursuit_stuck_ticks = 0
	_talk_pursuit_last_distance = distance

	if _talk_pursuit_stuck_ticks == 3:
		push_warning("Agent %s: 追不上搭話對象 %s，可能被卡住" % [character_name, target.character_name])

# 按顯示名找角色，不分大小寫的規則跟 debug_console.gd::_get_character() 不同——
# 那裡要處理玩家手打、可能撞名的情形；這裡的 target 是 LLM 從 context.visible
# 抄回來的名字，來源單一，先用最單純的完全比對，真的撞名再處理
func _find_character_by_name(target_name: String) -> Character:
	if target_name.is_empty():
		return null
	for node in get_tree().get_nodes_in_group("characters"):
		if node != self and node.character_name == target_name:
			return node as Character
	return null

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
