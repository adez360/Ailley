class_name Agent
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

## 佔位欄位：決策來源（《06》decision_source，正式資料結構見 #122）。
## 先用常數驗證 DecisionProvider 選取邏輯是對的，欄位落地後這裡改吃真正的角色資料。
@export var decision_source := "local"		# "local" / "cloud"
@export var model_name := ""				# decision_source == "cloud" 時，AIConfig 的 provider 名字

## #164：角色對「自己被設定成這種性格」想說的一句話，建角當下生成一次、之後唯讀
## （《99》P-10）。角色庫（尚未投放）那條路徑已經有了（game_manager.gd 的
## _generate_words_to_creator()）；場景固定 NPC 走的是 npc_schedule.json 這條，
## 完全沒有這欄，所以在這裡的 _ready() 補打一次同一種一次性 AI 呼叫
var words_to_creator := ""

## 是否已經對玩家說出過 words_to_creator，一生只說一次。骰中但 AI 選擇不說
## 不算數，機會不消耗，見 maybe_speak_to_creator()（《99》P-10 #3）
var _words_to_creator_spoken := false

## 判定是否要說出口的 AI 呼叫進行中（見 maybe_speak_to_creator() 的鎖）
var _words_to_creator_pending := false

## schedule 任務給中間值，靠 time_bonus 拉開跟其他來源的差距，
## 不是靠 base priority 本身——見 [[行程佇列與任務仲裁]] 的「待決」那節
const SCHEDULE_BASE_PRIORITY := 10.0

## 窗內給的加成，要明顯大於任何 base priority，確保「到點的行程」
## 預設壓過「隨時可做的雜事」
const TIME_BONUS := 100.0

## 兩個任務分數接近時的防抖動閾值：新任務分數要贏過目前任務「這麼多」才切換。
## #118 實跑校準（2026-08-17）：真實跑兩次決策，觀察到的分數只有兩種差距——
## schedule 任務間完全打平（同檔內都是 10 或都是 110）、LLM 任務間差距 <0.2
## （observed priority 集中在 0.4~0.6）。5.0 對這兩種情況都綽綽有餘，沒有
## 重現任何抖動，維持這個值。之後 LLM 任務的 priority 量級校準（見 #224）
## 落地後，分數分佈會改變，屆時要重新驗證這個值還夠不夠
const HYSTERESIS := 5.0

## 最短承諾時間（遊戲分鐘）：任務至少要做滿這麼久才允許被非 reflex 任務搶走，
## 防止兩個分數接近的任務讓角色來回抖動。#118：跟 HYSTERESIS 同一輪驗證，
## 目前場上沒有任何候選會逼近這個門檻（見 HYSTERESIS 註解），維持 2.0
const MIN_COMMIT := 2.0

## 等待決策回覆期間，蓋掉上面的 MIN_COMMIT 用這個值。#118 實跑校準
## （2026-08-17）：對現行 llama-server 拓樸（本機 SSH port-forward 到
## desktop-h9aniv5）實測 6 次 plan 決策延遲，596~1866ms（均值約 1024ms）；
## 舊註解引用的「同機測試 2.5-4 秒」不是這次量到的環境，但兩者都遠低於
## 5.0（換算現實秒＝遊戲分鐘）；對照最大值 1866ms，約有 2.7 倍緩衝
## （5.0 / 1.866 ≈ 2.68），不調整
const LLM_WAIT_MIN_COMMIT := 5.0

## LLM 任務的 duration 引擎端下限（遊戲分鐘）：不管模型回傳什麼，實際套用值
## 一律不低於這個下限。#118 實跑校準（2026-08-17）：兩次真實決策裡，LLM
## 回傳的 duration **一律是 0**——模型完全沒有被告知這個欄位的單位或合理
## 範圍（見 #224），目前這個下限不只是防禦性下限，是任務唯一的非零執行時間
## 來源。維持 10，等 #224 補上 prompt 說明、模型真的開始給出有意義的估計值
## 之後再重新校準
const MIN_ACTION_DURATION := 10.0

## _tasks 池子的 LLM 來源總量上限（不含 schedule 來源，那批是開場建立一次
## 就不變的固定集合）。跟 max_calls_per_game_day（每遊戲日最多幾次 AI 請求）
## 是兩個獨立的限制，只是數字剛好一樣——這個管的是池子裡累積、還沒被執行掉
## 的 LLM 任務筆數，那個管的是真的打出去的網路請求次數，見
## [[行程佇列與任務仲裁]] 的「池子的守則」。#118 實跑校準（2026-08-17）：
## 確認 max_calls_per_game_day 目前設定值就是 20，跟這個上限剛好對齊；
## 對同一隻角色實測 12 次連續真實決策（含觸發 dedup 的重複 action/place），
## _llm_task_count() 峰值穩定在 6，dedup 機制有效防止無上限累積，離上限還有
## 相當餘裕，維持 20
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

# buy 任務目前追的販賣機世界座標。_is_own_pursuit_target() 預設只認
# current_place 對應的錨點座標，販賣機是場景節點的 global_position、
# 不是任何一個 place 錨點——不額外記這個的話，_check_stuck() 卡住時發出的
# move_finished(false) 會被 _is_own_pursuit_target() 判定「不是我要的」而
# 吞掉，_pursuit_done 永遠設不成 true，變成每秒一次的卡住／重試迴圈
# （CodeRabbit review 抓到，跟 give／talk 目標不是 current_place 錨點時
# 同一類問題，見上面 _give_pursuit_stuck_ticks 的說明）
var _buy_pursuit_target := Vector2.ZERO

# buy 追逐守衛原本比對 current_place 是否等於 _pursued_place，但 place 只是
# 字串（例如 "tavern"），跟具體要不要重下 move_to() 無關——前一筆完全不同的
# 任務（例如在同一個 place 完成的 work）也可能留下同樣的 current_place／
# _pursued_place／_pursuit_done=true，讓新的 buy 任務被誤判成「已經追過、
# 不用再試」，直接跳過 move_to()，角色站著不動也買不到東西。改成比對任務
# 自己的 id，只有同一筆 buy 任務才共用收斂狀態（CodeRabbit review 抓到）
var _buy_pursuit_task_id := ""

# talk 任務用的卡住偵測（#90）。目標是會動的角色，每次重算都要重新
# move_to()，不能沿用上面 _pursued_place／_pursuit_done 那套「地點沒換就不
# 重下指令」的節流——但這也表示不能靠 Character._stuck_timer：那個計時器在
# move_to() 一開頭就會被歸零，每個遊戲分鐘重下一次指令等於它永遠沒機會累積
# 到 STUCK_TIME。這裡自己算：距離沒有明顯縮短就算一次沒有進展
var _talk_pursuit_stuck_ticks := 0
var _talk_pursuit_last_distance := INF

# give 任務用的卡住偵測，跟 _talk_pursuit_* 同一套理由：目標會動、每次重算
# 都要重新 move_to()，Character._stuck_timer 因此永遠沒機會累積到 STUCK_TIME
# ——CodeRabbit review 抓到，_on_move_finished() 的 _is_own_pursuit_target()
# 只認地點式任務的 current_place，give 沒有這個欄位，_check_stuck() 發出的
# move_finished(false) 對它等於被吞掉，卡住的話會原地無限重試。give 跟 talk
# 不同的是卡住偵測到之後要真的放棄，不是只警告——give 的設計就是做一次就結束
var _give_pursuit_stuck_ticks := 0
var _give_pursuit_last_distance := INF

# attack 任務用的卡住偵測，跟 _give_pursuit_* 同一套理由與同一套收尾方式
var _attack_pursuit_stuck_ticks := 0
var _attack_pursuit_last_distance := INF

# persuade 任務用的卡住偵測（#227），跟 _give_pursuit_* 同一套理由與收尾方式
# （卡住就真的放棄，不是只警告）——共用邏輯見 _pursuit_stuck_progress()（#266）
var _persuade_pursuit_stuck_ticks := 0
var _persuade_pursuit_last_distance := INF

# 送達（已對目標開口，不論對方是否忙碌拒絕）後設 true，擋掉 _pursue_persuade_task()
# 後續每個 tick 重複呼叫 try_record_pending_persuade()／move_to()（P-09，
# CodeRabbit review 抓到：persuade 原本送達當下就 _finish_task_and_request_next()，
# 沒有真正佔滿 duration）。跟 give／shout「送達就結束」不同，persuade 佔滿
# duration 走 gather／hunt_small 那套 _reevaluate_once() 通用收尾機制
var _persuade_delivered := false

# 自己成功發起、目前正在進行中的 talk 任務 id／來源。只在 talk_to() 真的成功
# 那一刻設值，exit_conversation() 靠這個而不是「當下的 _current_task」判斷對話
# 結束時該清掉哪一筆——理由見 exit_conversation() 自己的註解。
#
# source 額外存一份是因為任務從池子移除後就查不到它原本的 source 了——
# exit_conversation() 要知道這筆任務是不是 llm 來源，才能決定要不要在這裡
# 觸發下一次決策請求
var _active_talk_task_id := ""
var _active_talk_task_source := ""

# 待回應的說服嘗試（#227，《01-3》§3 事實句機制）。空字典代表沒有待回應；
# 有值時形狀為 {"persuader": String, "reason": String, "proposed_task":
# Dictionary}（"proposed_task" 只在行動說服時存在，純思想說服沒有這個 key）。
# 單一欄位不是佇列——已有待回應記錄時新的說服直接判定失敗（見
# try_record_pending_persuade()），不覆蓋、不排隊，避免舊記錄被靜默蓋掉、
# 發起者完全不知道自己的嘗試消失了
var _pending_persuade: Dictionary = {}

# 正在對陌生人做「！」反應。那 2 秒刻意站著不動，期間不重新起步——
# GameClock 一個遊戲分鐘就是 1 現實秒，不擋的話 1 秒後就被送回路上，
# 2 秒的愣住實際上只有 1 秒
var _reacting := false

# 目前有沒有一份決策請求還沒回來。_reevaluate() 靠它避免同一份請求還在飛時
# 又觸發第二份（同一個 LLM 任務完成的當下可能被重算好幾次），
# _consider_switch() 靠它決定要用 MIN_COMMIT 還是 LLM_WAIT_MIN_COMMIT
var _awaiting_decision := false

# 同一套道理用在 request_sleep_reflection()：睡眠事件觸發跟 debug_console.gd
# 的 `reflect` 指令都可能呼叫它，這通吃 await，沒有這個旗標擋，重疊呼叫會
# 讓兩個請求同時讀寫同一份 _daily_events（CodeRabbit review 抓到）
var _sleep_reflection_in_flight := false

# 撞期時記「還有一次要補跑」，不能就這樣把那次請求默默丟掉——它很可能是想
# 反思等待期間才新累積的事件（CodeRabbit review 抓到，見
# _finish_sleep_reflection_request()）
var _sleep_reflection_pending := false

## 給 debug_console.gd 判斷要不要印「正在問地端模型...」用——open 呼叫
## debug_set_llm_decision(true) 前先問一次，才不會在請求根本沒送出（已經有
## 一份在飛）的情況下印出誤導的等待訊息
func is_decision_in_flight() -> bool:
	return _awaiting_decision

# 決策請求的世代編號。debug_set_llm_decision() 每次改變 llm_decision_enabled
# 就遞增一次——單純檢查「回應抵達當下的旗標值」不夠：等待期間若先關閉、
# 回應抵達前又重新開啟，旗標值會跟請求剛送出時一樣是 true，但那份回應早就
# 過期了。_request_next_decision() 在送出請求前記下當時的世代，await 後比對
# 世代是否還一樣，不一樣就代表中途被停用過，這份回應要整包丟棄
var _decision_generation := 0

# LLM 任務 id 的流水號。不能拿 Time.get_ticks_msec() 當唯一值——一次回應最多
# 五筆是在同一個同步迴圈裡建的，同毫秒是常態不是例外，撞 id 之後
# _consider_switch() 的 best.id == _current_task.id 會把不同任務當成同一筆，
# 直接 return 不切換
var _next_llm_task_id := 0

## 今日計畫（#89，《10》§5.4）：「想做的事」，不是排定的行程，引擎不強制
## 執行，只當 prompt context 用。跟 Task 是不同語意的東西，不要跟 _tasks
## 混在一起——那是引擎真的會去執行的排程單位。
##
## 欄位形狀對齊 database/schemas/NPCDailyPlanSchema.gd 的 npc_daily_plan
## 表（npc_id 那份存的是 plan_id/text/is_done），這裡還沒接存檔（#21～#23），
## 先用同樣的形狀存在記憶體，之後接存檔不用改欄位名
var _today_plan: Array[Dictionary] = []		# [{id, text, is_done}]
var _next_plan_id := 0

## 上一輪決策回應有沒有問「下次能不能讓我改 today_plan」——見
## _request_next_decision() 開頭怎麼消費它。這是四個開放時機裡的「AI 主動
## 申請」：不是每次決策都能改，得先問過、下一輪才真的給
var _plan_update_requested := false

## 這次重算「進來的時候」current_state 是不是 sleep——用來偵測「剛睡醒」
## 那個轉換瞬間，見 _reevaluate() 怎麼用它
var _was_sleeping := false

## #265：_reevaluate() 的重入保護（trampoline）。_pursue_current_task()
## 選中 give/shout、或 talk 判定失敗時會呼叫 _finish_task_and_request_next()，
## 它又呼叫一次 _reevaluate()——如果任務池裡連續好幾筆都是「一叫就結束」的
## 任務，這條鏈會巢狀往下疊很多層函式呼叫（O(n) 呼叫堆疊深度、O(n²) 重複
## 仲裁工作）。不能單純拿掉那次呼叫：等回應期間 fallback 任務不會被馬上
## 接手，會空等到下一次 GameClock 分鐘變化（CodeRabbit review 抓到過的舊
## bug）。也不能單純偵測到重入就跳過不做事：那樣這一輪就沒有任何地方去挑
## 下一筆任務，一樣會退回空等的問題。改成迴圈：最外層呼叫真的執行
## _reevaluate_once()，巢狀呼叫只設 _reevaluate_pending 然後直接返回，把呼叫
## 堆疊收回最外層的 while 迴圈，迴圈再跑下一輪去挑下一筆任務——行為不變，
## 深度收斂成固定
var _reevaluating := false
var _reevaluate_pending := false

## 這隻角色的決策來源，出生時決定一次，之後所有決策/對話呼叫都透過它——
## 跟《06》「decision_source／model_name 投放後不可改」的規則一致，不做成每次呼叫
## 才判斷（#155）
var _provider: DecisionProvider

## 上一次睡眠反思的當日摘要（《03》§5「當日摘要（一句話）」）。目前只給
## debug 用（reflect 指令印出來看），沒有其他呼叫端讀它——先留著這個欄位
## 而不是驗證完就丟掉，之後要做《15》UI 的 today_log／摘要面板時才有東西可接，
## 不用回頭重寫 validate_reflection() 那層（max 等級 code review 抓到：
## 原本驗證過的 summary 完全沒被讀取，白白花了 LLM 的輸出 token）
var last_reflection_summary := ""

## 今天發生的事，純客觀事實句，睡前反思（request_sleep_reflection()）一次
## 送給 LLM 評分後清空（#168，《03》§5）。跟 Memory.l1 不是同一回事——l1 是
## 固定 8 條的滾動視窗，這裡是「睡前都留著」的緩衝區，語意不同不共用。
## 每句只寫事實，不判斷正負面／重不重要，那是 LLM 在反思時的工作
## （《00》原則二：引擎只給事件，不給情緒）
##
## 每筆是 {id, content} 不是單純字串——反思是一趟真的打網路的非同步呼叫，
## await 期間角色照樣可能觸發新事件、LLM 也可能漏評某幾筆。用穩定的 id
## 讓 request_sleep_reflection() 只刪除「LLM 真的回傳評分結果」的那幾筆，
## 不是用送出時的筆數概略估計（max 等級 code review 抓到：概略估計法在
## LLM 漏評、或等待期間 FIFO 剛好把快照最前面幾筆擠掉時，還是可能誤刪
## 沒被評到分的事件）
const DAILY_EVENTS_CAP := 30
var _daily_events: Array[Dictionary] = []
var _next_daily_event_id := 0

## 加一筆今天發生的事。滿了就丟掉最舊的一筆，不是拒絕新的——今天最新發生的
## 事沒理由因為緩衝區滿了就進不去，跟 Memory.push_l1() 的 FIFO 取捨一樣
func _push_daily_event(content: String) -> void:
	_daily_events.append({"id": _next_daily_event_id, "content": content})
	_next_daily_event_id += 1
	if _daily_events.size() > DAILY_EVENTS_CAP:
		_daily_events.pop_front()

## #164：天神之石的話傳到範圍內的角色（world/god_stone_input.gd 逐一呼叫）。
## 記一筆事實句（跟 _on_spotted() 的 "你第一次注意到 %s" 同一種寫法，不經
## L10n——這是餵給 LLM 反思的內部事實句，不是玩家會看到的 UI 文字），
## 同時骰一次天神之石觸發判定
func hear_god_stone(line: String) -> void:
	_push_daily_event("你在天神之石附近聽到一個聲音，說：「%s」" % line)
	maybe_speak_to_creator(line)

## #164 + 《99》P-10：25% 機率觸發（情緒強度 ≥70 時 40%），中了才問 AI 要不要
## 真的說出口——中了但 AI 選擇不說一樣不消耗機會，下次再被叫到還能再骰
## （P-10 #3：「是否消耗機會？否」）。只有骰中且 AI 決定說，才會真的說一次、
## 這輩子不會再說第二次。
##
## heard_line 是玩家在天神之石說的那句話，傳給 AI 當判斷依據（不傳的話 AI
## 只知道「有人說話」，不知道說了什麼，沒什麼好「自然判斷」的——CodeRabbit
## review 抓到）
##
## _words_to_creator_pending 鎖住判定期間：AI 回應可能超過天神之石的 5 秒
## 冷卻，玩家能在同一個判定還沒回來時再說一次話，兩次呼叫若都只查
## _words_to_creator_spoken 會一起通過早退檢查，兩個回應都成立時就會說兩次
## ——CodeRabbit review 抓到的競態
func maybe_speak_to_creator(heard_line: String) -> void:
	if words_to_creator.is_empty() or _words_to_creator_spoken or _words_to_creator_pending:
		return

	var chance := 0.4 if int(emotion.get("intensity", 0)) >= 70 else 0.25
	if randf() >= chance:
		return

	_words_to_creator_pending = true
	var envelope := PromptBuilder.build_words_to_creator_envelope(self, heard_line)
	var validator := func(data: Dictionary) -> Dictionary:
		return AISchema.validate_words_to_creator_choice(data)
	var result := await _decide_with_retry(envelope, AIService.Policy.SCHEDULED, validator)
	_words_to_creator_pending = false

	if not result["ok"] or not result["data"]["say_it"]:
		return

	_words_to_creator_spoken = true
	say(words_to_creator)

## 場景固定 NPC 沒有預先生成好的 words_to_creator（見上方欄位註解），開機時
## fire-and-forget 補打一次——跟 game_manager.gd::_generate_words_to_creator()
## 同一種呼叫，慢到或失敗就是這輩子沒有這句話可觸發，不擋開機、不重試
## （P-10 的重試/備用句庫決議是角色庫那條路徑的範圍，這裡先對齊現有實作深度）。
## 請求前後都檢查空字串，避免非同步回應回來時蓋掉已經有內容的欄位——
## 角色庫投放的角色會由 game_manager.gd::spawn_character() 在 add_child()
## 觸發這裡的 _ready() 之前就先填好 words_to_creator，這裡的第一道檢查會
## 直接跳過、不浪費一次多餘的 AI 呼叫；只有場景固定 NPC（沒有這條預填路徑）
## 才會真的走到底（CodeRabbit review 抓到）
func _generate_words_to_creator() -> void:
	if not words_to_creator.is_empty():
		return
	var envelope := PromptBuilder.build_creation_envelope(system_prompt)
	var result: Dictionary = await AIService.request(envelope, character_id, AIService.Policy.SCHEDULED)
	if not result["ok"]:
		return
	var validated := AISchema.validate_creation(result["data"])
	if not validated["ok"]:
		return
	if not words_to_creator.is_empty():
		return
	words_to_creator = validated["data"]["words_to_creator"]


func _ready() -> void:
	super()
	add_to_group("agents")
	_provider = _make_provider()
	_load_schedule()
	_generate_words_to_creator()

## 公開版的「重建 provider」（#122，CodeRabbit review 抓到的時序 bug）。
## GameManager.deploy_from_library() 會在 add_child()（進而觸發這個節點的
## _ready()）之後才套用建角面板選的 decision_source／model_name——那時候
## _provider 已經照預設值（"local"）建好了，角色庫選的來源永遠不會生效。
## 呼叫端設完那兩個欄位要接著呼叫這個，才會用最終的值重建一次
func rebuild_provider() -> void:
	_provider = _make_provider()

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
	# LLM 來源任務時補這一次，避免重進場景（例如換場）時重複發起。
	# 允許附帶 update_plan：開場 _today_plan 一定是空的，跟「意圖全數完成」
	# 那個時機（#89 觸發 2）是同一種狀況——沒有計畫，需要一份新的
	if llm_decision_enabled and not _has_llm_task():
		_request_next_decision(true)

## 依 decision_source 建一次決策提供者（#155）。打錯字／空字串一律安靜退回 LocalLLMProvider，
## 但寫一行 push_warning 帶原因——跟 _load_schedule() 找不到 assignment 時的處理是同一種
## 「資料異常先警告、遊戲照跑」的慣例，不讓一個資料錯字讓角色整個決策啞掉
func _make_provider() -> DecisionProvider:
	# 兩種資料異常（cloud 沒填 model_name、model_name 指到不可用的 provider）
	# 跟未知的 decision_source 打錯字，處理方式完全一樣，所以只收集原因，
	# 警告與 fallback 各寫一次。"local" 是獨立分支直接 return——它不算異常，
	# 不需要走下面收集 reason 那條路
	var reason := ""
	if decision_source == "cloud":
		if model_name.is_empty():
			reason = "decision_source 'cloud' 但 model_name 是空的"
		else:
			# model_name（《06》）存的是給玩家看的型號字串（如
			# "qwen2.5-7b-instruct"），不是 AIConfig.providers 字典的 key
			# （如 "openrouter"）——那個 key 只是玩家自己取的代號，規格書
			# 刻意不讓它進 model_name。查表方向要反過來：拿型號去掃
			# providers 找 .model 相符的那個，再用那個 provider 真正的
			# 名字去打 AIService.request()（見 AIConfig.get_provider_by_model()）
			var provider := AIService.config.get_provider_by_model(model_name)
			if provider == null or not provider.valid:
				reason = "decision_source 'cloud' 但 model_name '%s' 沒有對應的可用 AIConfig provider（不存在或設定不全）" % model_name
			else:
				return RemoteLLMProvider.new(provider.name)
	elif decision_source == "local":
		# #288：local 來源比照 cloud 讀 model_name——建角面板 local 分頁的下拉
		# 選單選的型號要真正生效，不能無條件打字面值 "local"。model_name 是
		# 空字串（MVP 5 個排程 NPC 沒走建角面板）時，LocalLLMProvider 自己
		# 退回既有的字面值行為，這裡不用另外分支
		return LocalLLMProvider.new(model_name)
	else:
		reason = "decision_source '%s' 不是已知值" % decision_source

	push_warning("Agent %s: %s，退回 local" % [character_name, reason])
	return LocalLLMProvider.new()

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
# 跟 _has_arrived_at() 判定「站得夠近」用同一個標準。buy 的販賣機目標不是
# place 錨點，額外比對 _buy_pursuit_target（CodeRabbit review 抓到）
func _is_own_pursuit_target(world_position: Vector2) -> bool:
	if current_state == "buy" and world_position.distance_to(_buy_pursuit_target) <= ARRIVE_DISTANCE:
		return true
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
	# 事件事實句要在 super() 把 _conversation 清成 null 之前先讀——這裡只記
	# 客觀事實（跟誰講完話），不記對話內容好壞，那是睡前反思時 LLM 自己判斷的事
	if _conversation != null:
		var other: Character = _conversation.target if _conversation.initiator == self else _conversation.initiator
		if other != null:
			_push_daily_event("你跟 %s 講完話了" % other.character_name)

	super()

	if not _active_talk_task_id.is_empty():
		var was_llm := _active_talk_task_source == "llm"

		_remove_task(_active_talk_task_id)
		if _current_task.get("id", "") == _active_talk_task_id:
			_current_task = {}
			current_place = ""
			current_state = "idle"
		_active_talk_task_id = ""
		_active_talk_task_source = ""

		# 這筆任務「做完了」的訊號是對話結束，不是 _reevaluate() 那段替沒有
		# 天然結束訊號的動作（eat/rest 那類）準備的 duration 下限——talk 有
		# 更準確的訊號就該用它，不要等 duration 事後才補觸發下一次決策。
		# 對話期間 _reevaluate() 那段其實被下面的 _current_task.get("id","")
		# != _active_talk_task_id 這個新條件擋住了，不會搶先觸發，這裡才是
		# 唯一真正觸發的地方。
		#
		# 允許附帶 update_plan 的判斷方式要跟 _reevaluate() 那段一致（#89
		# 觸發 2：意圖全數完成）——這裡也是「一筆任務完成」的事件，talk
		# 剛好完成的這一刻如果 today_plan 已經全部做完，同樣該給重寫的機會，
		# 不用等到下一次 duration 到期或睡醒才補上
		if was_llm and llm_decision_enabled and not _awaiting_decision:
			_request_next_decision(_today_plan_needs_new_goal())

	_reevaluate()

## 對話中要開口，打 AIService 要一句台詞。requester_id 用 character_id，不是
## 節點名或別的字串——這是這隻角色自己的成本控管，換節點名/場景重擺都不該
## 讓額度重算。ok=false 涵蓋 AI 未啟用/逾時/驗證失敗全部情況，呼叫端
## （conversation.gd）一律轉去 fallback，不細分是哪一種——細分沒有意義，
## 三種都是「這次要不到台詞」，處理方式完全一樣
const AI_THINKING_TEXT := "…"

## 呼叫 provider 決策並驗證內容，失敗時依 provider.max_validation_retries() 重試（#152）。
## 只有「拿到回應但內容不合格式」才重試（parse_completion／validate 失敗）；AIService
## 層級的失敗（逾時、連線失敗、停用、額度）不重試，原樣回傳給呼叫端走 fallback——
## 那類是「這次問不到」，不是「問到了但答案壞掉」，是《12》§6.1 講的不同兩種情境。
##
## validator 是呼叫端包好的驗證函式：next_line() 傳 AISchema.validate_dialogue，
## _request_next_decision() 傳一個包住 allow_update_plan 的 lambda 呼叫 validate_tasks。
## 這裡不用管兩邊 schema 形狀不同，只管「驗證過不過」
##
## attempt > 0（第二次起）傳 is_retry=true 給 AIService.request()：SCHEDULED policy
## 沒有 CONVERSATION 那種豁免，重試間隔只有幾秒、遠低於預設 30 秒冷卻，不跳過
## 冷卻檢查的話重試永遠會被自己剛送出的上一次呼叫擋成 ERROR_RATE_LIMITED，
## 《12》§3.4 要求的重試在 SCHEDULED 路徑上會實際失效（PR #176 review 抓到）
func _decide_with_retry(envelope: Dictionary, policy: AIService.Policy, validator: Callable) -> Dictionary:
	var attempts := _provider.max_validation_retries() + 1
	# 記住最後一次的失敗原因，迴圈跑完直接回它——parse 與 validate 兩種失敗
	# 的處理一模一樣（還有次數就重試，沒有就把原因原樣回報），不必各寫一遍
	var last := AISchema._fail("no_attempt")
	for attempt in attempts:
		var context := DecisionContext.new()
		context.is_retry = attempt > 0
		var result: Dictionary = await _provider.decide(envelope, character_id, policy, context)
		if not result["ok"]:
			return result

		var parsed := AISchema.parse_completion(result["data"])
		if not parsed["ok"]:
			last = AISchema._fail(parsed["error"])
			continue

		var validated: Dictionary = validator.call(parsed["data"])
		if validated["ok"]:
			return validated
		last = validated

	return last

func next_line(listener: Character, turns: Array[Dictionary], max_turns: int) -> Dictionary:
	# 立刻蓋掉正在顯示的東西，讓玩家知道「這個角色在想」，不是卡住。
	# AIService.request() 還沒送出就已經先顯示——冷卻/配額檢查也算在等待時間裡，
	# 玩家看到「…」的時間可能比實際打網路的時間長，這是刻意的：早一點給回饋
	# 比精準對齊網路延遲更重要
	say(AI_THINKING_TEXT, true)

	var envelope := PromptBuilder.build_dialogue_envelope(self, listener, turns, max_turns)
	var result := await _decide_with_retry(envelope, AIService.Policy.CONVERSATION, AISchema.validate_dialogue)
	if not result["ok"]:
		return {"ok": false}

	return {
		"ok": true,
		"line": result["data"]["line"],
		"end": result["data"]["end"],
	}

## 睡眠反思（#168，《03》§5）：把今天的事實句丟給 LLM，換回摘要跟逐筆評分，
## 交給 memory 分級寫入。importance/valence 完全由 LLM 決定（見 validate_reflection()
## 的註解），這裡不重算或覆寫這兩個值。
##
## 回傳三種狀態：
## - {"ok": true, ...}：這次真的反思到，並套用了結果
## - {"ok": false}：真正沒反思到（未啟用/逾時/驗證失敗/沒有事件可反思），
##   last_reflection_summary 維持上一次成功的舊值不變——呼叫端不該把舊摘要
##   誤當成「這次」的結果來顯示（max 等級 code review 抓到）
## - {"ok": false, "queued": true}：撞到已經有一份請求在飛，這次已經記進
##   _sleep_reflection_pending，會在那份做完後自動補跑一次——不是失敗，呼叫端
##   不該印成錯誤訊息（見 _cmd_reflect 的處理，CodeRabbit review 抓到）
##
## 失敗時不清空 _daily_events——今天的事還沒被評過分，清空等於直接遺失，
## 留著等下次睡眠反思重試，最壞情況是被 DAILY_EVENTS_CAP 的 FIFO 擠掉，
## 不會比現在更糟
##
## 送出去反思的每筆事件都帶穩定 id（見 _push_daily_event()），不是單純比
## 送出時的筆數：LLM 可能漏評某幾筆（合法的部分回應），await 期間（真的打
## 網路，數百毫秒到數十秒都可能）角色也可能觸發新事件並 append 進
## _daily_events。只刪除「LLM 這次真的回傳評分結果」的那幾個 id，其餘
## （包含等待期間新增的、跟 LLM 沒評到的）留在 _daily_events 裡，
## 下次反思會再送一次（max 等級 code review 抓到：純用送出筆數 pop_front()
## 的近似法，在這兩種情況下都可能誤刪還沒被評到分的事件）
##
## 觸發時機有兩個：debug_console.gd 的 `reflect` 指令手動呼叫，以及
## _reevaluate_once() 偵測到角色進入睡眠狀態時自動呼叫（#112 落地後接上）
func request_sleep_reflection() -> Dictionary:
	# 同一時間只能有一個反思請求在飛（CodeRabbit review 抓到）：睡眠事件跟
	# debug_console.gd 的 `reflect` 指令都會呼叫這裡，這通吃 await，重疊呼叫
	# 會讓兩個請求同時讀寫同一份 _daily_events——後回來的那個 filter() 會用
	# 自己那批 scored_ids 蓋掉先回來那個已經處理過的結果，兩邊都可能重複計分
	# 或漏算。撞期的這次不能就這樣丟掉不管：疊加的那次很可能是想反思等待期間
	# 新累積的事件，直接吞掉會讓那批事件在 _daily_events 裡卡到下次才補評——
	# 記一個「還有一次補跑」的旗標，等目前這次真的做完（不管成敗）才補跑一次
	# （CodeRabbit review 抓到，見 _finish_sleep_reflection_request()）
	if _sleep_reflection_in_flight:
		_sleep_reflection_pending = true
		# 帶 queued=true 跟真正的失敗（驗證失敗、逾時等）區分開——呼叫端
		# （debug_console.gd 的 `reflect` 指令）不能把「已經排隊等補跑」當成
		# 「反思失敗」印出來，那會誤導使用者以為今天的事沒了，其實只是排到
		# 下一次補跑（CodeRabbit review 抓到）
		return {"ok": false, "queued": true}
	if memory == null or _daily_events.is_empty():
		return {"ok": false}
	_sleep_reflection_in_flight = true

	var events_sent := _daily_events.duplicate(true)

	# #210：validate_reflection() 只驗結構，不驗 id 是不是真的來自這次送出的
	# events_sent（唯一且存在）。這裡包一層閉包，讓 id 檢查跟結構驗證共用同一條
	# 「失敗就重試」路徑（_decide_with_retry），不用改動那個共用機制的簽名。
	var valid_ids := {}
	for e in events_sent:
		valid_ids[e["id"]] = true

	var validator := func(data: Dictionary) -> Dictionary:
		var validated: Dictionary = AISchema.validate_reflection(data)
		if not validated["ok"]:
			return validated
		var seen_ids := {}
		for event in validated["data"]["events"]:
			var event_id = event["id"]
			if not valid_ids.has(event_id) or seen_ids.has(event_id):
				return AISchema._fail(AISchema.ERROR_BAD_SHAPE)
			seen_ids[event_id] = true
		return validated

	var envelope := PromptBuilder.build_reflection_envelope(self, events_sent)
	var result := await _decide_with_retry(envelope, AIService.Policy.SCHEDULED, validator)
	if not result["ok"]:
		_finish_sleep_reflection_request()
		return {"ok": false}

	var data: Dictionary = result["data"]
	last_reflection_summary = data["summary"]

	var scored_ids := {}
	for event in data["events"]:
		memory.add_candidate(event["content"], event["importance"], event["valence"])
		scored_ids[event["id"]] = true

	_daily_events = _daily_events.filter(func(e): return not scored_ids.has(e["id"]))

	# personality_delta（#349，《03》§5 流程圖 ⑥）：validate_reflection() 已經
	# 夾制過每一項到 ±MAX_PERSONALITY_DELTA，這裡直接加總套用，不再二次判斷——
	# 「這個人今天該不該變得更記仇」是模型的判斷，引擎只做防止數值失控的夾制
	var personality_delta: Dictionary = data.get("personality_delta", {})
	for dim in personality_delta.keys():
		var current: float = float(personality.get(dim, 50.0))
		personality[dim] = clampf(current + float(personality_delta[dim]), 0.0, 100.0)

	# today_plan（#350，流程圖 ②）：反思產出的是「明天的新計畫」，跟決策中途
	# 的 update_plan 是同一個欄位、同一種整份取代語意，直接沿用 _apply_today_plan()
	var new_plan: Variant = data.get("today_plan")
	if new_plan != null:
		_apply_today_plan(new_plan)

	# L1 清空（流程圖⑤）已經在呼叫端（_reevaluate_once() 偵測到入睡轉換時）
	# 統一做過了，不管反思成不成功都會清——這裡不再重複清一次，見那邊的註解
	_finish_sleep_reflection_request()
	return {"ok": true}

# 收尾這次反思請求：解除在飛旗標，如果有撞期被記下的補跑需求就立刻補一次
# （CodeRabbit review 抓到）。不用 await 這次補跑的結果——呼叫端只在意自己
# 那次請求的成敗，撞期的那次本來就沒有呼叫端在等結果（原本被靜默丟棄，見
# request_sleep_reflection() 頂端的說明），讓它自己跑完就好。如果補跑當下
# _daily_events 已經被這次清空／filter() 到空了，request_sleep_reflection()
# 開頭的 is_empty() 檢查會自然讓它變成無事可做的空跑，不用另外判斷
func _finish_sleep_reflection_request() -> void:
	_sleep_reflection_in_flight = false
	if _sleep_reflection_pending:
		_sleep_reflection_pending = false
		request_sleep_reflection()

## 正式決策迴圈（#88）的請求端，模式照抄 next_line()——build envelope、await
## AIService、parse_completion、validate_*，任何一關失敗都靜默放棄，任務池
## fallback 頂著，下次任務完成再試。跟 next_line() 不一樣的是這裡失敗不用
## 特別回報給呼叫端：next_line() 的呼叫端（conversation.gd）當下就在等一句話
## 沒有就要走 fallback 台詞；這裡的呼叫端只是「該不該重算」，仲裁器本來就會
## 自己從池子挑 fallback，不需要一個回傳值告訴它失敗了
##
## allow_update_plan 是這次呼叫端自己判斷「現在是不是 #89 講的四個開放時機
## 之一」（呼叫端各自的理由見各呼叫處的註解）。這裡另外 or 上
## _plan_update_requested：上一輪模型如果申請過，這裡兌現、用完就消費掉——
## 不管呼叫端這次是為了什麼理由觸發，欠的那次都在這裡還
func _request_next_decision(allow_update_plan: bool = false) -> Dictionary:
	if _awaiting_decision:
		return {"ok": false, "triggered": false}
	_awaiting_decision = true
	var my_generation := _decision_generation

	# 記下消費前的值，等這次回應因世代不符被丟棄時原封不動還回去——
	# 「跟從沒問過模型一樣」不能只是不套用任務，連這個已經兌現掉的許可
	# 也要還原，不然角色會憑空少一次原本已經賺到的 update_plan 機會
	var had_plan_update_requested := _plan_update_requested
	var effective_allow_update_plan := allow_update_plan or _plan_update_requested
	_plan_update_requested = false

	# #268／#290：捕一次 now_minutes，給 validator 把模型填的 expires_in_minutes
	# （相對時長）換算成任務池實際用的絕對 expires_at。envelope 的 schema
	# 邊界（#290 拍板後）是固定常數，不再依賴這個時間點，但 validator 這裡
	# 還是要——這通吃 await，重試之間可能過了不少遊戲時間，用重新取得的
	# 「現在」換算的話，同一份回應在不同時間點驗證會算出不同的絕對值
	var now_minutes := _now_minutes()

	# #227：捕一次「這輪送出的信封裡有沒有問到待回應的說服事實句」，跟
	# envelope／schema 是同一個時間點。這通吃 await，等待期間可能有新的
	# persuade 送達（原本是空的才收得進來，見 try_record_pending_persuade()
	# 的忙碌拒絕）——但那份新記錄的事實句從沒進過這次送出去的 prompt，回應
	# 回來後不能拿它去讀一個模型根本沒被問過的欄位，也不能因此清掉它，
	# 所以下面只在 had_pending_persuade 為真時才碰 _pending_persuade
	var had_pending_persuade := not _pending_persuade.is_empty()

	var visible: Array[Character] = vision.get_visible_characters() if vision != null else []
	var envelope := PromptBuilder.build_plan_envelope(
		self, visible, _task_pool_summary(), _today_plan_summary(), effective_allow_update_plan,
		_fact_lines_summary(), had_pending_persuade
	)
	var validator := func(data: Dictionary) -> Dictionary:
		return AISchema.validate_tasks(data, effective_allow_update_plan, now_minutes)

	var result := await _decide_with_retry(envelope, AIService.Policy.SCHEDULED, validator)
	_awaiting_decision = false

	# 世代編號在 await 期間變了，代表 debug_set_llm_decision() 至少關過一次
	# 決策開關——不管回應抵達當下旗標是什麼值（就算又被重新打開），這份回應
	# 都屬於已經作廢的世代，整包淘汰，不套用任何任務或計畫更新
	if my_generation != _decision_generation:
		_plan_update_requested = had_plan_update_requested
		return {"ok": false, "triggered": true}

	if not result["ok"]:
		return {"ok": false, "triggered": true}

	var data: Dictionary = result["data"]

	# reasoning／inner_monologue 印出來給人排查，跟 _trigger_village_ai() 的
	# print() 除錯模式一致；不進遊戲內 UI。決策準不準沒有系統性驗證，
	# 目前只能肉眼看這兩個欄位判斷合不合理
	print("[llm_decision] %s reasoning: %s" % [character_name, data.get("reasoning", "")])
	print("[llm_decision] %s inner_monologue: %s" % [character_name, data.get("inner_monologue", "")])

	var tasks_added := _push_llm_tasks(data["tasks"], data)

	# 不管這輪有沒有拿到 update_plan 許可，模型都可能問「下次讓我改」——記
	# 下來，下一次不管是哪個理由觸發 _request_next_decision() 都會兌現
	if data.get("request_plan_update", false):
		_plan_update_requested = true

	# null 代表這次沒有 update_plan（不管是沒許可、還是有許可但模型選擇不用）；
	# 空陣列 [] 是模型明確給的合法值（today_plan 清空），兩者不可混淆，見
	# AISchema.validate_tasks() 用 null 分辨「沒提供」與「提供了空陣列」
	var update_plan: Variant = data.get("update_plan")
	if update_plan != null:
		_apply_today_plan(update_plan)

	if had_pending_persuade:
		_resolve_pending_persuade(data)

	_reevaluate()

	return {
		"ok": true,
		"triggered": true,
		"reasoning": data.get("reasoning", ""),
		"inner_monologue": data.get("inner_monologue", ""),
		"tasks_added": tasks_added,
	}

## update_plan 回應整份取代 _today_plan，不是逐筆增刪改——四個開放時機語意上
## 都是「重寫」，不需要模型追蹤既有項目的 id 才能局部編輯，形狀跟驗證都簡單
## 很多。id 是這裡自己重新配發的本機序號，跟
## database/schemas/NPCDailyPlanSchema.gd 的 plan_id（存檔接上之後才有意義）
## 是兩回事，不能拿模型回應裡的任何值當它
func _apply_today_plan(items: Array[Dictionary]) -> void:
	_today_plan.clear()
	for item in items:
		_next_plan_id += 1
		_today_plan.append({
			"id": _next_plan_id,
			"text": item.get("text", ""),
			"is_done": item.get("is_done", false),
		})

## today_plan 是不是「沒事可做，需要新目標」（#89 觸發時機之一）：一片空白
## 也算——開場或剛被清空過，跟「全部項目都做完了」是同一種狀況，都需要
## 一份新計畫
func _today_plan_needs_new_goal() -> bool:
	if _today_plan.is_empty():
		return true
	for item in _today_plan:
		if not item.get("is_done", false):
			return false
	return true

## 給 PromptBuilder 組 plan 信封用的精簡版——只給 text／is_done，內部的本機
## id 不出現在 prompt 裡，那是引擎自己記帳用的，模型不需要知道也不該回傳它
func _today_plan_summary() -> Array[Dictionary]:
	var summary: Array[Dictionary] = []
	for item in _today_plan:
		summary.append({"text": item.get("text", ""), "is_done": item.get("is_done", false)})
	return summary

## 把驗證過的 LLM 任務推進 _tasks，補上仲裁器需要、但 LLM 不用填的欄位。
## response 帶的是同一次決策回應的 reasoning／inner_monologue，複製一份到
## 這批裡的每一筆 Task，讓「這個任務是為什麼被排進來的」跟任務本身綁在一起，
## 供之後《12》規格書的記憶系統直接從 Task 讀，不用另外對照決策回應的歷史記錄
func _push_llm_tasks(tasks: Array[Dictionary], response: Dictionary) -> int:
	var now_minutes := _now_minutes()
	var accepted := 0

	for task in tasks:
		var params: Dictionary = task.get("params", {})
		var action: String = str(task.get("action", ""))
		var dedup_key: String = action + "|" + str(params.get("target", params.get("place", "")))
		# buy 同一個 place 可以買不同 item（例如 tavern 的 ale 跟 water），
		# 只用 action+place 去重的話兩筆會互相覆蓋，靜默丟掉其中一筆合法購買
		# 任務（CodeRabbit review 抓到）
		if action == "buy":
			dedup_key += "|" + str(params.get("item_id", ""))

		# dedup：同一個 action+target/place（buy 再加 item_id）新的覆蓋舊的，
		# 不並存兩筆——見 [[行程佇列與任務仲裁]]「池子的守則」，沒有這條的話
		# 被搭話幾次之後池子就會塞滿重複的「回訪某某」
		for i in range(_tasks.size() - 1, -1, -1):
			if _tasks[i].get("source", "") != "llm":
				continue
			var existing_params: Dictionary = _tasks[i].get("params", {})
			var existing_action: String = str(_tasks[i].get("action", ""))
			var existing_key: String = existing_action + "|" \
				+ str(existing_params.get("target", existing_params.get("place", "")))
			if existing_action == "buy":
				existing_key += "|" + str(existing_params.get("item_id", ""))
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
		accepted += 1

	return accepted

func _llm_task_count() -> int:
	var count := 0
	for task in _tasks:
		if task.get("source", "") == "llm":
			count += 1
	return count

# 找出目前池子裡分數最低的 llm 來源任務並移除，讓一筆「一定要塞進去」的
# 任務有位置——目前唯一呼叫端是 _resolve_pending_persuade()（見那邊的
# 說明）。只挑 llm 來源，不動 schedule／debug 任務，跟 _push_llm_tasks()
# dedup 邏輯篩選的範圍一致；用跟 _reevaluate_once() 選 best 候選同一套
# _score()，被擠掉的一定是仲裁器接下來本來就最不會選中的那筆
func _evict_lowest_priority_llm_task() -> void:
	var now := "%02d:%02d" % [GameClock.hour, GameClock.minute]
	var worst_id := ""
	var worst_score := INF
	for task in _tasks:
		if task.get("source", "") != "llm":
			continue
		var score := _score(task, now)
		if score < worst_score:
			worst_score = score
			worst_id = task.get("id", "")
	if worst_id.is_empty():
		return
	_remove_task(worst_id)
	# 被擠掉的剛好是目前正在做的那筆——照 _reevaluate_once() 過期清除那條
	# 路徑同一套處理，不留著一個已經不在 _tasks 裡、卻還被 _current_task
	# 指著的殘影
	if _current_task.get("id", "") == worst_id:
		stop_moving()
		_pursued_place = ""
		_pursuit_done = false
		_current_task = {}
		current_place = ""
		current_state = "idle"

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
			"item_id": params.get("item_id", ""),
			"source": task.get("source", ""),
		})
	return summary

# 工作結束後同理：那 5 個遊戲分鐘可能已經跨過行程的整點，而 work_at() 開頭的
# stop_moving() 把原本的路徑清掉了，不重算的話會一路站到下一個整點字串吻合為止
func _on_work_finished() -> void:
	# 不寫「賺了多少錢」——_on_work_finished() 提早離開工作站（半途走開）也會
	# 觸發，那種情況沒有真的撥款（見 character.gd 的 _run_work()／_end_work()），
	# 寫死賺錢金額會變成一句不一定為真的事實句
	_push_daily_event("你剛結束了一段工作站的工作")
	_reevaluate()

# 被攻擊等外部事件強制中斷（《02》§3 中斷規則）時的收尾。跟
# _finish_task_and_request_next() 類似但刻意不 _remove_task()——這不是任務
# 做完或判定失敗，只是被打斷，還在池子裡的話下次重新仲裁時值得重新考慮要不要
# 繼續做（例如原本在走去做別的事，被打斷後可能還是想繼續走過去）
func _on_action_interrupted() -> void:
	_pursued_place = ""
	_pursuit_done = false
	_current_task = {}
	current_place = ""
	current_state = "idle"
	if llm_decision_enabled and not _awaiting_decision:
		_request_next_decision(_today_plan_needs_new_goal())
	_reevaluate()

# 被攻擊記成事實句（純客觀事件，不貼「這很可怕」之類的主觀標籤——見 CLAUDE.md
# 「遊戲機制規格：AI 自主性自檢」），讓下次決策／睡前反思能讀到發生過這件事
func _on_attacked(attacker: Character) -> void:
	_push_daily_event("你被 %s 攻擊了" % attacker.character_name)

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

	_push_daily_event("你第一次注意到 %s" % other.character_name)

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

## 回復類動作每遊戲分鐘回多少（目標欄位＋數量，#214）。《07》§2-3 只給相對
## 關係——sleep 回復量最大、nap「與睡覺同模組但較低」、rest「小幅回復」——
## 沒有給數字，所以這三個值是待實跑校準的暫定值，不是規格定案。#118 只校準了
## 仲裁常數（HYSTERESIS／MIN_COMMIT／LLM_WAIT_MIN_COMMIT／MIN_ACTION_DURATION／
## LLM_TASK_POOL_CAP，見上方各自的說明），沒有涵蓋這裡，這三個值還沒實測過。
##
## 對照基準：stamina 的自然衰減是每遊戲分鐘 1.0，但 Stats 漂移只在每 10 遊戲分鐘
## 執行一次，所以每 tick（10 遊戲分鐘）的淨變化是 amount * 10 - 1.0。_apply_action_recovery()
## 是每遊戲分鐘執行一次，所以 sleep/nap/rest/wash 的回復額在每 10 遊戲分鐘內累積
##
## 表的形狀是「動作 -> {stat, amount}」而不是單純「動作 -> 數字」：不同動作
## 要回復的欄位不見得相同（wash 回復的是 `hygiene` 不是 `stamina`），單純
## 數字表沒辦法表達這件事，#214 把表改成這個形狀就是為了讓 wash 能直接
## 多加一行接上（#241），不必重寫 _apply_action_recovery() 本體。idle 不列——
## 發呆本來就不回復任何東西，它的用途是「合法地什麼都不做」，讓 AI 逾時或
## 沒事可做時有一個不必假裝在忙的選項
##
## ACTION_RECOVERY 的數值原是針對舊的「漂移快 10 倍」情況設的（#361 修正前）。
## #361 修正後漂移改成每 tick（而非每現實秒），ACTION_RECOVERY 同步除以 10
## 以維持相對平衡（#361）。
const ACTION_RECOVERY := {
	"sleep": {"stat": "stamina", "amount": 0.6},
	"nap": {"stat": "stamina", "amount": 0.4},
	"rest": {"stat": "stamina", "amount": 0.2},
	"wash": {"stat": "hygiene", "amount": 0.3},
}

# 到了定點才開始回復——還在走去床邊的路上不算在睡覺。沒有指定地點的任務
# （LLM 完全可以只回 {"action": "rest"}）本來就原地做，is_moving() 一樣是 false，
# 不用另外分流
func _apply_action_recovery() -> void:
	if stats == null or is_moving():
		return
	var recovery: Dictionary = ACTION_RECOVERY.get(current_state, {})
	if recovery.is_empty():
		return
	stats.add(recovery["stat"], recovery["amount"])

func _on_time_changed(_hour: int, _minute: int) -> void:
	# 先結算這一分鐘的回復，再重算要做什麼：反過來的話，剛被換掉的那筆任務
	# 會用新任務的 current_state 結算最後一分鐘
	_apply_action_recovery()
	_reevaluate()

# 力竭時強制進入休息，直到 stamina 恢復
func _force_rest_until_recovered(now_minutes: int) -> void:
	# 只有 reflex rest 已存在時才直接沿用
	if _current_task.get("source", "") == "reflex" and current_state == "rest":
		stop_moving()
		return

	stop_moving()
	var rest_task: Dictionary = {
		"id": "reflex_rest_" + str(randi()),
		"action": "rest",
		"source": "reflex",
		"duration": 999999,
		"params": {},
		"interruptible": false,  # 力竭期間不可被打斷
	}
	_select(rest_task, now_minutes)

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
#
# #265：真正的重新仲裁邏輯搬進 _reevaluate_once()，這個函式只負責
# trampoline——見上面 _reevaluating／_reevaluate_pending 的宣告註解
func _reevaluate() -> void:
	if _reevaluating:
		_reevaluate_pending = true
		return

	_reevaluating = true
	_reevaluate_pending = true
	while _reevaluate_pending:
		_reevaluate_pending = false
		_reevaluate_once()
	_reevaluating = false

func _reevaluate_once() -> void:
	var now_minutes := _now_minutes()

	# 力竭時強制進入休息，優先於一般的任務仲裁
	var has_exhausted := conditions.any(func(c): return c.get("type") == "exhausted")
	if has_exhausted:
		_force_rest_until_recovered(now_minutes)
		_pursue_current_task()
		return

	# exhausted 清除時，移除 reflex rest 並恢復一般仲裁
	if _current_task.get("source", "") == "reflex":
		_current_task = {}
		current_state = "idle"
		current_place = ""
		# 重置各追逐狀態，以便正常仲裁能清楚地選擇下一個任務
		_talk_pursuit_stuck_ticks = 0
		_talk_pursuit_last_distance = INF
		_give_pursuit_stuck_ticks = 0
		_give_pursuit_last_distance = INF
		_attack_pursuit_stuck_ticks = 0
		_attack_pursuit_last_distance = INF
		_persuade_pursuit_stuck_ticks = 0
		_persuade_pursuit_last_distance = INF

	# 剛睡醒的偵測要在這裡的任何選任務邏輯跑之前先記下「進來的時候是不是
	# 在睡」——選任務邏輯本身就可能把 current_state 從 sleep 換掉，這個
	# 函式結尾要拿它跟「換完之後」比較，才抓得到真正的轉換瞬間
	_was_sleeping = current_state == "sleep"

	# 事件驅動觸發：LLM 來源的目前任務做滿引擎套用過下限的 duration 就算完成，
	# 發起下一次決策請求。等待期間不 return——照樣往下跑完整套仲裁流程，
	# 從池子（schedule 任務、上一輪還沒被選中的 llm 任務）挑 fallback 頂著，
	# 不空等、不卡頓，是《10》§5.1 講的「天然容錯」
	if llm_decision_enabled and not _awaiting_decision \
			and _current_task.get("source", "") == "llm" \
			and _current_task.get("id", "") != _active_talk_task_id \
			and now_minutes - _current_task_started_at >= int(_current_task.get("duration", 0.0)):
		# 做完的那筆要先離開池子。llm 任務沒有 window，不像 schedule 靠時間窗
		# 自然退場——留著的話它會用原本的分數繼續參加下一輪算分，被重新選中，
		# 變成同一件事做完又做。_current_task 是同一個 Dictionary 的參照，
		# 移出池子不影響它，等待決策回來的期間照樣可以繼續執行
		#
		# 上面 id != _active_talk_task_id 這條擋掉一種情況：talk 任務正在
		# 撐著一場對話時，套用過下限的 duration 可能比對話實際講完的時間短，
		# 這裡搶先把它從池子清掉、觸發下一次決策，會跟 exit_conversation()
		# 真正該做的事打架（見那裡的註解）——talk 任務的完成訊號是對話結束，
		# 不是這個給沒有天然結束訊號的動作用的 duration 下限
		_remove_task(_current_task.get("id", ""))
		# 允許附帶 update_plan：today_plan 沒事可做時，這正是「意圖全數完成」
		# 那個開放時機（#89 觸發 2）——這個事件驅動迴圈本來就是每個 llm 任務
		# 做完就重問一次，剛好是檢查這件事最自然的時間點
		_request_next_decision(_today_plan_needs_new_goal())

	if _tasks.is_empty():
		return

	var now := "%02d:%02d" % [GameClock.hour, GameClock.minute]

	# CodeRabbit review（#269）：過期任務先前只在下面的候選迴圈裡被 continue
	# 跳過，從沒真的從 _tasks 移除——沒被選中又過期的 llm 任務會永久卡在池子
	# 裡，持續佔用 LLM_TASK_POOL_CAP，直到角色重開機都清不掉；連 _current_task
	# 過期時那條「清掉，不要留著」的路徑（見下面 elif 分支）也只清空了
	# _current_task 這個變數本身，沒有把同一個 Dictionary 從 _tasks 裡拿掉。
	# 在候選評分之前先單獨掃一次、真的 remove_at()，不論該任務是不是目前
	# 正被 _current_task 指向。
	#
	# 被移除的剛好是 _current_task 本人時，這裡直接同步清空 _current_task／
	# current_place／current_state——不依賴下面 elif 分支（那個分支只在
	# best 沒找到候選、或 _consider_switch() 選中別的候選時才會處理到過期
	# 的 _current_task）補做，讓「這個 Dictionary 一旦被拿出池子，_current_task
	# 就同一時間點跟著清空」直接在移除的當下發生，不留給後續分支的邊界情況去對
	for i in range(_tasks.size() - 1, -1, -1):
		if _is_expired(_tasks[i], now_minutes):
			var expired_task := _tasks[i]
			_tasks.remove_at(i)
			if expired_task.get("id", "") == _current_task.get("id", ""):
				_current_task = {}
				current_place = ""
				current_state = "idle"

	var best: Dictionary = {}
	var best_score := -INF

	for task in _tasks:
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

	# 剛睡醒（#89 觸發時機之一，重寫整份 today_plan）：這次重算進來的時候
	# 在睡，選完任務之後不再是了，就是這個轉換瞬間。只在真正換出 sleep 的
	# 那一次觸發，不會每個遊戲分鐘都重問——_was_sleeping 是這次呼叫一開頭
	# 記的，只反映「這一次」的轉換，不是累積狀態
	if _was_sleeping and current_state != "sleep" and llm_decision_enabled and not _awaiting_decision:
		_request_next_decision(true)

	# 剛入睡（#348，《03》§5 流程圖）：跟上面「剛睡醒」對稱的鏡像判斷——
	# 這次重算進來的時候不在睡，選完任務後變成在睡，就是這個轉換瞬間，
	# 只在真正換進 sleep 的那一次觸發。不掛 llm_decision_enabled——反思是
	# 獨立的 LLM 呼叫，不是決策迴圈的一部分，跟 _generate_words_to_creator()
	# 同一個道理，排程模式的角色一樣要能睡前反思。不 await：fire-and-forget，
	# _reevaluate_once() 是同步函式，不該卡在一次網路往返上
	if not _was_sleeping and current_state == "sleep":
		# 清空 L1（流程圖⑤）在這裡做，不是等 request_sleep_reflection() 成功
		# 才清——不然沒有事件可反思（該函式一開頭就 return）或反思失敗
		# （LLM 逾時／驗證不過）時 L1 永遠不會清空。入睡本身就是「今天的
		# 短期記憶窗口該重置」的事件，跟反思成不成功是兩件事（CodeRabbit
		# review 抓到）
		if memory != null:
			memory.l1.clear()
		request_sleep_reflection()

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

## 《01-2》§3 完整表格，數字照抄，含目前還沒接上執行邏輯的動作（等落地時
## 直接呼叫 _roll_success()，不用重寫一次成功率公式）。struggle 例外太多
## （不擲骰、搭 haul 檢查點），不套用這裡，見《01-2》§3 附註
##
## 刻意不含 attack：P-28 已拍板 MVP 必中、不做閃避／格擋，不是《01-2》§2
## 通用成功率公式的技能檢定，resolve() 的 "attack" 分支直接放行，不查這張表
##
## 刻意不含 persuade：《00》原則四拍板它是心智判斷類行為，成敗交給被說服者
## 自己的模型判斷，不是這裡的技能檢定（見 #227，resolve() 的 "persuade"
## 分支直接放行，不查這張表）——CodeRabbit review 抓到舊資料殘留在這張表
## 裡、resolve() 的 persuade 分支又漏了 return，兩個湊在一起會讓 persuade
## 真的落進 _roll_success() 擲骰，直接違反這條拍板
const SUCCESS_PARAMS := {
	"hunt_small": {"base": 0.60, "trait": "courage", "coef": 0.002},
	"hunt_large": {"base": 0.30, "trait": "courage", "coef": 0.003},
	"gather": {"base": 0.80, "trait": "diligence", "coef": 0.001},
	"fish": {"base": 0.55, "trait": "diligence", "coef": 0.0015},
	"steal": {"base": 0.35, "trait": "courage", "coef": 0.0025},
	"perform": {"base": 0.70, "trait": "romanticism", "coef": 0.003},
}

## 《01-2》§2 通用成功率公式，純數學，跟哪個動作無關——不在 SUCCESS_PARAMS
## 表上的動作（move_to/talk/sleep/nap/rest/wash/idle/eat 全部不在表上）不是
## 技能檢定，直接放行。
##
## stamina/injury/alcohol 現在不存在於 Stats.SPEC（#115 還沒落地）。injury／
## alcohol 兩項公式本來就是「從 0 起算才扣分」，缺欄位時 Stats.get_value()
## 回傳的 0.0 剛好是中性值，不用特別處理；stamina 公式基準點是 50，函式內部
## 有另外判斷 Stats.SPEC.has("stamina")，缺欄位時當中性值 50 用，不會吃到假的
## 懲罰。等 #115 把 stamina 加進 SPEC，這裡不用改，自動開始吃到真實數值
func _roll_success(action: String, character: Character, environment_risk: float) -> Dictionary:
	var params: Dictionary = SUCCESS_PARAMS.get(action, {})
	if params.is_empty():
		return {"success": true, "reason": ""}

	# 《01》§2 的 10 項 personality，由 Personality.hexaco_to_personality() 在
	# character.gd::_ready() 產出（#117）。缺欄位（沒有 hexaco 資料的角色）當 0：
	# 公式是 base + trait × coef，trait = 0 就是「這項人格完全不加分」，也就是
	# 《01-2》§3 那個 base 本身的基準點，不是一個額外的懲罰
	var trait_value: float = character.personality.get(params["trait"], 0.0)

	# injury/alcohol 兩項的公式本來就是「從 0 起算才扣分」，Stats.get_value()
	# 對不存在的 key 回傳的 0.0 剛好就是中性值，不用特別處理。stamina 不一樣——
	# 公式基準點是 50 不是 0，缺欄位時硬套 get_value() 的 0.0 會變成一個假的
	# -10% 懲罰（QA review 抓到）。改成：SPEC 裡真的有這個欄位才讀實際值，
	# 沒有就當作中性的 50，貢獻 0——等 #115 把 stamina 加進 SPEC，這裡不用改，
	# 自動開始吃到真實數值
	var stamina: float = character.stats.get_value("stamina") if Stats.SPEC.has("stamina") else 50.0
	var injury_term := -character.stats.get_value("injury") * 0.004
	var alcohol_term := -maxf(0.0, character.stats.get_value("alcohol") - 30.0) * 0.005
	var stamina_term := (stamina - 50.0) * 0.002
	var chance: float = params["base"] \
		+ trait_value * float(params["coef"]) \
		+ stamina_term + injury_term + alcohol_term - environment_risk
	chance = clampf(chance, 0.05, 0.95)

	var success := randf() < chance
	if success:
		return {"success": true, "reason": ""}
	return {"success": false, "reason": _failure_reason(injury_term, alcohol_term, stamina_term, environment_risk)}

## 《01-2》§5：失敗原因要具體到 AI 能調整策略，不能給一句放諸四海皆準的
## 「運氣不好」——找出扣最多分的修正項，講出具體理由。四個修正項全部
## 是負值或 0（environment_risk 本身以正值代表風險，取負號比較），取最負
## 的那個當主因；都沒扣分時才是真的手氣不好
func _failure_reason(injury_term: float, alcohol_term: float, stamina_term: float, environment_risk: float) -> String:
	var worst := "luck"
	var worst_value := 0.0
	for pair in [["injury", injury_term], ["alcohol", alcohol_term], ["stamina", stamina_term], ["environment", -environment_risk]]:
		if float(pair[1]) < worst_value:
			worst_value = pair[1]
			worst = pair[0]

	match worst:
		"injury":
			return "傷勢太重，這個動作做不利索"
		"alcohol":
			return "喝多了，手腳不聽使喚"
		"stamina":
			return "體力撐不住，中途沒了力氣"
		"environment":
			return "現場條件不利，沒能成功"
		_:
			return "手氣不好，這次沒抓到訣竅"

## 環境風險由呼叫端依動作/情境算好傳入（正值代表風險，數字越大成功率扣越多）。
## SUCCESS_PARAMS 目前沒有動作會走到這裡，之後接動作時（例如 steal 的目擊者
## 風險）再補實際算法
func _environment_risk(_action: String, _params: Dictionary) -> float:
	return 0.0

## 決策執行前的檢查層（#120，《00》原則一：LLM 決定想做什麼，引擎決定做不做得到）。
## 只管兩件事：目標/前提是不是真的存在（硬規則），以及擲不擲得過成功率——語意
## 驗證/白名單那些是 AISchema 的事，這裡假設 action/params 已經過白名單
func resolve(action: String, params: Dictionary) -> Dictionary:
	match action:
		"talk":
			var target_name: String = str(params.get("target", ""))
			var matches := _find_all_characters_by_name(target_name)
			if matches.is_empty():
				return {"success": false, "reason": "找不到這個人，可能已經離開了"}
			if matches.size() > 1:
				return {"success": false, "reason": "有多個人叫這個名字，無法確定要找誰"}
		"eat":
			if inventory == null or _find_food_slot().is_empty():
				return {"success": false, "reason": "背包裡沒有食物可以吃"}
		"drink":
			if inventory == null or _find_drink_slot().is_empty():
				return {"success": false, "reason": "背包裡沒有飲品可以喝"}
		"buy":
			# 檢查錢夠不夠（需要先找機器查價格）、商品存不存在、背包有沒有空間
			var place: String = str(params.get("place", ""))
			var machine := _find_vending_machine_at_place(place)
			if machine == null:
				return {"success": false, "reason": "找不到販賣機"}
			var item_id: String = str(params.get("item_id", ""))
			var price := machine.get_price(item_id)
			if price < 0:
				return {"success": false, "reason": "販賣機裡沒有這個商品"}
			if inventory == null:
				return {"success": false, "reason": "背包裡沒有地方放東西"}
			if inventory.get_money() < price:
				return {"success": false, "reason": "身上沒有夠的錢"}
			# 檢查是否有空位或是否可以堆疊（add_item 會幫我們檢查）
			# 這裡先用樂觀假設，真的失敗讓 buy_from() 退款並傳回原因碼
		"give":
			# 《01-2》§1 流程圖①前置檢查點名的例子就是「物品在身上？」——give
			# 不進②③擲骰（不在 SUCCESS_PARAMS 上），只有這一關硬規則
			var target_name: String = str(params.get("target", ""))
			var matches := _find_all_characters_by_name(target_name)
			if matches.is_empty():
				return {"success": false, "reason": "找不到這個人，可能已經離開了"}
			if matches.size() > 1:
				return {"success": false, "reason": "有多個人叫這個名字，無法確定要找誰"}

			# count 的格式檢查（拒絕 1.5 這種帶小數的數量）交給
			# AISchema.validate_tasks() 做——跟這裡的職責分工比照 talk：schema
			# 驗「格式對不對」，resolve() 驗「這個世界裡真的能不能做到」。這裡
			# 只用 int() 收，llm 來源的 count 在進入 resolve() 之前已經過 schema
			# 那關，不會是帶小數的值
			var item_id: String = str(params.get("item_id", ""))
			var count: int = int(params.get("count", 1))
			if inventory == null or not inventory.has_item(item_id, count):
				return {"success": false, "reason": "身上沒有這件東西，送不出去"}
		"attack":
			# 必中（《99》P-28），不落進下面的 _roll_success()——那張表刻意沒收
			# attack，這裡硬規則過了就直接放行，不擲骰
			var target_name: String = str(params.get("target", ""))
			var matches := _find_all_characters_by_name(target_name)
			if matches.is_empty():
				return {"success": false, "reason": "找不到這個人，可能已經離開了"}
			if matches.size() > 1:
				return {"success": false, "reason": "有多個人叫這個名字，無法確定要找誰"}
			return {"success": true, "reason": ""}
		"persuade":
			# 跟 attack 同一套「硬規則過了就直接放行，不落進下面的 _roll_success()」
			# ——persuade 不擲骰（見《00》原則四），成敗交給被說服者自己的模型
			# 判斷，不是這裡的硬規則。SUCCESS_PARAMS 本來就不該有 persuade 的
			# 條目（那是這個機制定案前殘留的舊資料，已經一併清掉），這裡少了
			# return 的話會直接落進 _roll_success()，變成真的在擲骰，跟整個
			# 設計互相矛盾
			var target_name: String = str(params.get("target", ""))
			var matches := _find_all_characters_by_name(target_name)
			if matches.is_empty():
				return {"success": false, "reason": "找不到這個人，可能已經離開了"}
			if matches.size() > 1:
				return {"success": false, "reason": "有多個人叫這個名字，無法確定要找誰"}
			return {"success": true, "reason": ""}
		# move_to/sleep/nap/rest/wash/idle/eat/shout 目前都沒有額外的硬規則要擋
		# （eat 落地後要在這裡加「宣稱吃了背包裡沒有的食物」的檢查，見 #114；
		# shout 沒有目標、沒有前提，天生沒有硬規則可擋）
		_:
			pass

	return _roll_success(action, self, _environment_risk(action, params))

# 用 .get() 而不是硬取 key，跟計分那幾個函式同一種寫法——檔頭承諾「把任務丟進
# _tasks 就會公平競爭，不用再改這個檔案」，那新來源少填一個欄位就不該讓這裡崩掉。
#
# llm 來源任務需通過可執行動作白名單檢查（IMPLEMENTED_ACTIONS）——不在白名單上的
# 動作直接不 commit 並移除，避免選到後靜默不執行或每分鐘重試的無限迴圈。
# SUCCESS_PARAMS 不能當白名單：_roll_success() 對不在表上的動作直接放行（見
# _roll_success() 自己的註解），那些動作缺少執行邏輯時會靜默不做事，不符合
# 「不被允許」與「還沒做」要分開失敗的設計原則
func _select(task: Dictionary, now_minutes: int) -> void:
	if task.get("source", "") == "llm":
		var action: String = str(task.get("action", ""))
		if not AISchema.is_implemented_action(action):
			last_action_result = "這個動作還沒有實作，暫時做不了"
			_remove_task(task.get("id", ""))
			return

	_current_task = task
	_current_task_started_at = now_minutes
	current_place = str(task.get("params", {}).get("place", ""))
	current_state = str(task.get("action", ""))
	# resolve() 現在只在 _pursue_talk_task() 裡對 talk 任務呼叫——換成別的
	# 動作（move_to/sleep 等）時沒有人會再寫入 last_action_result，舊任務
	# 留下的失敗原因會一直卡著，讓 LLM 看到跟目前任務無關的過期訊息。這裡
	# 統一歸零，talk 任務會在下一次 _pursue_talk_task() 立刻覆蓋成真正結果
	last_action_result = ""
	# 換了新任務就是換了新的追逐目標，talk 任務自己的卡住偵測要歸零重算——
	# 不歸零的話舊目標留下的「沒進展」次數會誤算進新目標的偵測
	_talk_pursuit_stuck_ticks = 0
	_talk_pursuit_last_distance = INF
	_give_pursuit_stuck_ticks = 0
	_give_pursuit_last_distance = INF
	_attack_pursuit_stuck_ticks = 0
	_attack_pursuit_last_distance = INF
	_persuade_pursuit_stuck_ticks = 0
	_persuade_pursuit_last_distance = INF
	_persuade_delivered = false
	# 排程任務的 id 是穩定的 schedule_%d，同一筆 buy 任務會在下一個遊戲日
	# 重用同一個 id——不歸零的話，前一天走不到販賣機留下的 _buy_pursuit_task_id
	# 與 _pursuit_done=true 會讓新一天同 id 的任務直接被守衛判定「已處理過」，
	# 整個跳過 move_to()（CodeRabbit review 抓到，#441 同一套邏輯的 sibling PR）
	_buy_pursuit_task_id = ""
	_buy_pursuit_target = Vector2.ZERO

# 力竭狀態下強制休息（#364）。exhausted 激活時選不了別的動作，只能 rest
# 直到 stamina 恢復到門檻為止。_reevaluate_once() 檢查到 exhausted 時呼叫
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

	# murmur 沒有目標、也不用移動——講給自己聽當下就結束，不屬於「走到某個
	# 地點」這件事，要另外分流，不能落進下面的地點判斷
	if current_state == "murmur":
		_pursue_murmur_task()
		return

	# give／shout 跟 talk 一樣要另外分流，不能落進下面的地點判斷：give 的目標是
	# 會動的角色（跟 talk 同理），shout 則完全沒有 place／target 可言——原地喊
	# 一聲就結束，不屬於「走到某個地點」這件事
	if current_state == "give":
		_pursue_give_task()
		return

	if current_state == "shout":
		_pursue_shout_task()
		return

	if current_state == "attack":
		_pursue_attack_task()
		return

	# talk 任務的目標是另一個角色，不是固定地點——current_place 對它一律是空的
	# （params 裝的是 target 不是 place），要另外分流，不能落進下面的地點判斷
	if current_state == "talk":
		_pursue_talk_task()
		return

	# eat 跟 talk 一樣是「呼叫一次就完成」的動作，不能落進下面的地點判斷——
	# 那條路徑只會讓角色走去 params.place 站著，沒有任何東西會真的呼叫 eat()
	if current_state == "eat":
		_pursue_eat_task()
		return

	# persuade（#227）跟 talk／give 同理：目標是會動的角色，不是固定地點
	if current_state == "persuade":
		_pursue_persuade_task()
		return

	# drink 跟 eat 同一種「呼叫一次就完成」（#163）
	if current_state == "drink":
		_pursue_drink_task()
		return

	# buy 跟 eat／drink 同理：呼叫一次就完成（#340）
	if current_state == "buy":
		_pursue_buy_task()
		return

	# work 是長動作，執行協程會自己跑 5 分鐘，只能呼叫一次（#358）
	if current_state == "work":
		_pursue_work_task()
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

# give／talk 追逐移動目標時共用的卡住判定門檻（#266）：連續幾次「距離沒有
# 明顯縮短」才算真的卡住，不是量測誤差。兩邊原本各自寫死 3，抽成常數，
# 改一次兩邊一起改，不會漂移
const PURSUIT_STUCK_THRESHOLD := 3

# give／talk 任務追逐移動目標時的卡住偵測共用邏輯（#266，取代原本兩份幾乎
# 一樣的重複實作，同樣的 -1.0 誤差容許值、同樣連續 3 次判定卡住）。
# 只回傳「卡住幾次了」跟「這一次是不是剛好達到門檻」，達到門檻之後要做
# 什麼由呼叫端自己決定——talk 只警告不放棄、give 真的放棄，兩邊反應不同，
# 不該塞進這個共用函式。用「剛好等於門檻」而不是「大於等於」，是要保留
# 原本「只在跨過門檻那一次通知一次」的行為，不會每個 tick 都重複觸發
static func _pursuit_stuck_progress(distance: float, last_distance: float, stuck_ticks: int) -> Dictionary:
	var new_ticks := stuck_ticks + 1 if distance >= last_distance - 1.0 else 0
	return {
		"stuck_ticks": new_ticks,
		"threshold_reached": new_ticks == PURSUIT_STUCK_THRESHOLD,
	}

# talk 任務的執行（#90）：目標是會動的角色，不是靜止的地點錨點，所以不能沿用
# 上面那套「走一次、_pursued_place／_pursuit_done 收斂」的節流——每次重算都
# 要重新問一次「他現在在哪」，距離內就直接搭話，不是只起步一次
func _pursue_talk_task() -> void:
	# resolve() 判定前置檢查：只針對 llm 來源任務，在即將產生副作用（talk_to）
	# 前執行，避免移動期間提前消耗 _roll_success() 或使用過期狀態。
	# ⚠ _pursue_current_task() 每個遊戲分鐘都會跑到這裡，talk 現在能這樣寫
	# 是因為它不在 SUCCESS_PARAMS 上、resolve() 對它只會走硬規則檢查（純函式、
	# 沒有隨機性），每分鐘重算結果都一樣，等同只是重新確認前置條件沒變。
	# 之後如果哪個會擲骰的 SUCCESS_PARAMS 動作也要做成「追逐中執行」，不能照抄
	# 這個寫法——resolve() 裡的 _roll_success() 每呼叫一次就重骰一次，搬進這種
	# 每分鐘都跑的函式會變成「重骰到成功為止」，跟《01-2》§2「一次決策一次骰」
	# 的公式前提不符。那種情況要另外做「這個任務實例只骰一次」的保護（例如
	# 記一個 _resolved_task_id，骰過就不再骰，只重驗真的需要每次重查的部分）
	if _current_task.get("source", "") == "llm":
		var result := resolve(str(_current_task.get("action", "")), _current_task.get("params", {}))
		last_action_result = result["reason"]
		if not result["success"]:
			# resolve() 判定失敗的任務不留在池子裡繼續佔位——不移除的話
			# 下次重算分數不變，會馬上又選到同一筆，變成每分鐘重試一次
			# 同樣失敗的無限迴圈。跟 give／shout「做一次就結束」共用同一套收尾
			_finish_task_and_request_next()
			return

	var target_name: String = str(_current_task.get("params", {}).get("target", ""))

	# schedule talk（target_name 為空）需要先到達指定地點再找人聊。
	# LLM talk（target_name 非空）維持現有行為：直接追蹤目標角色。
	if target_name.is_empty() and not current_place.is_empty():
		var anchors := get_tree().get_first_node_in_group("place_anchors")
		if anchors == null or not anchors.has(current_place):
			if current_place != _pursued_place:
				push_error("Agent %s: 沒有這個地點 %s" % [character_name, current_place])
				_pursued_place = current_place
			return

		var place_pos: Vector2 = anchors.resolve(current_place)
		if not _has_arrived_at(place_pos):
			# 還沒到——跟 _pursue_current_task() 的節流邏輯一樣：
			# 同一個地點只起步一次，還在走就繼續走
			if current_place == _pursued_place and (is_moving() or _pursuit_done):
				return
			_pursued_place = current_place
			_pursuit_done = false
			if not move_to(place_pos):
				push_warning("Agent %s: 走不到搭話地點 %s" % [character_name, current_place])
				_pursuit_done = true
			return
		# 到了——停下、標記，繼續往下找人
		stop_moving()
		_pursued_place = current_place
		_pursuit_done = true

	# #281：排程觸發的 talk（target_name 為空）沒有指定對象——查證過
	# npc_schedule.json，這類排程本來就沒有 target 欄位，涼亭這類地點的
	# 定位是「聚集」，不是排定好的一對一見面點；《技術/talk 動作設計》
	# 也只列了 debug 主控台／agent.gd 的 LLM 決策會明確指名對象，排程不在
	# 這份清單裡。原本直接拿空字串去 _find_character_by_name() 找，保證
	# 找不到、每次都報 TARGET_NOT_FOUND，等於這類排程永遠講不了話。改成
	# 在抵達地點後，找同地點內離自己最近的人——沒有指定對象時退回「找人
	# 聊」而不是「找某個人聊」，跟涼亭的地點設計語意一致
	var target: Character
	if target_name.is_empty():
		target = _find_nearest_character_within(TALK_RANGE)
		if target == null:
			# 還沒人到齊，不算錯誤——地點本來就會有人先到、人後到的時間差，
			# 跟找不到指名對象（那是設定錯誤）性質不同，不用 push_error 洗
			# log，安靜等下一個遊戲分鐘再找
			return
	else:
		target = _find_character_by_name(target_name)

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
			_active_talk_task_source = _current_task.get("source", "")
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

	# 距離沒有明顯縮短就算一次沒進展；連續幾次才報一次，不是每次都報——
	# 偶爾一次量測誤差不該洗警告（#266：共用邏輯見 _pursuit_stuck_progress()）
	var progress := _pursuit_stuck_progress(distance, _talk_pursuit_last_distance, _talk_pursuit_stuck_ticks)
	_talk_pursuit_stuck_ticks = progress["stuck_ticks"]
	_talk_pursuit_last_distance = distance

	if progress["threshold_reached"]:
		push_warning("Agent %s: 追不上搭話對象 %s，可能被卡住" % [character_name, target.character_name])

# eat 任務的執行（#114）：跟 talk 一樣是「呼叫一次就完成」，不是靠 duration
# 逐分鐘回復的動作，所以不走通用的地點追逐路徑，做完立刻收尾。
# resolve() 呼叫的理由跟 _pursue_talk_task() 一樣：eat 不在 SUCCESS_PARAMS 上，
# resolve() 對它只走硬規則檢查（背包裡有沒有食物），沒有隨機性，每分鐘重算
# 結果都一樣，這裡只是重新確認前置條件沒變。不能直接沿用 _finish_task_and_request_next()：
# 那個共用收尾無條件 _remove_task()，schedule 來源的 eat 任務不能被移除（見下方）
func _pursue_eat_task() -> void:
	stop_moving()
	var proceed := true
	if _current_task.get("source", "") == "llm":
		var result := resolve(str(_current_task.get("action", "")), _current_task.get("params", {}))
		last_action_result = result["reason"]
		proceed = result["success"]

	if proceed:
		var reason := eat()
		last_action_result = reason
		if reason != Character.EAT_OK:
			push_warning("Agent %s: eat 失敗（%s）" % [character_name, reason])

	# 不管成功失敗都收尾：跟 _pursue_talk_task() 的 resolve() 失敗分支一樣，
	# 這筆任務不留在池子裡繼續佔位（吃不到就是吃不到，不會下一分鐘自己變出食物），
	# 立刻交還決策權給下一輪。schedule 來源的任務不移出池子——它是時間的函數，
	# 靠 window 自然退場，跟 _reevaluate() 事件驅動觸發那段的收尾邏輯同一套規則
	# （見 [[行程佇列與任務仲裁]]「中斷之後怎麼辦」），移掉的話明天同一個 window
	# 不會再被選中
	if _current_task.get("source", "") == "llm":
		_remove_task(_current_task.get("id", ""))
	_current_task = {}
	current_place = ""
	current_state = "idle"
	if llm_decision_enabled and not _awaiting_decision:
		_request_next_decision(_today_plan_needs_new_goal())

# drink 任務的執行（#163）：跟 _pursue_eat_task() 完全同一種形狀，只是換
# 呼叫 drink() 而不是 eat()。沒有共用一份程式碼是因為兩者要各自轉傳不同的
# reason 常數（Character.DRINK_OK vs Character.EAT_OK）與不同的收尾文字，
# 硬抽共用反而要傳一堆函式參數進去換兩行判斷式，不划算
func _pursue_drink_task() -> void:
	stop_moving()
	var proceed := true
	if _current_task.get("source", "") == "llm":
		var result := resolve(str(_current_task.get("action", "")), _current_task.get("params", {}))
		last_action_result = result["reason"]
		proceed = result["success"]

	if proceed:
		var reason := drink()
		last_action_result = reason
		if reason != Character.DRINK_OK:
			push_warning("Agent %s: drink 失敗（%s）" % [character_name, reason])

	if _current_task.get("source", "") == "llm":
		_remove_task(_current_task.get("id", ""))
	_current_task = {}
	current_place = ""
	current_state = "idle"
	if llm_decision_enabled and not _awaiting_decision:
		_request_next_decision(_today_plan_needs_new_goal())
	# CodeRabbit review：_request_next_decision() 只有在非同步回應回來後才會
	# 重新仲裁，不立刻補一次 _reevaluate() 的話，等回應期間排程或 fallback
	# 任務不會被馬上接手，得空等到下一次 GameClock time_changed 才會被接手
	_reevaluate()

# 根據地點找到對應的販賣機。場景中每台機器都有一個對應的地點：
# - "tavern" → VendingMachine
# - "herb_shop" → VendingMachineHerbShop
# 靠節點名稱來區分，更新日期 2026-08-20
func _find_vending_machine_at_place(place: String) -> VendingMachine:
	var machines := get_tree().get_nodes_in_group("vending_machines")

	for machine in machines:
		if not machine is VendingMachine:
			continue

		var machine_name: String = machine.name.to_lower()
		# VendingMachineHerbShop → "herb_shop"，VendingMachine → "tavern"
		if place == "herb_shop" and machine_name.contains("herb"):
			return machine
		elif place == "tavern" and not machine_name.contains("herb"):
			return machine

	return null

# buy 任務的執行（#340）：跟 work 一樣要先走到定點才能執行——販賣機有
# BUY_RANGE 距離限制（Character.buy_from()），跟 eat／drink 那種背包裡
# 直接生效的動作不同，不先移動的話站太遠一定回傳 BUY_TOO_FAR，
# params.place 就形同虛設（CodeRabbit review 抓到）。移動收斂邏輯跟
# _pursue_work_task() 同一套
func _pursue_buy_task() -> void:
	var buy_task_id: String = str(_current_task.get("id", ""))
	var place: String = str(_current_task.get("params", {}).get("place", ""))
	var machine := _find_vending_machine_at_place(place)

	# 找不到販賣機：立即返回失敗，跟 _pursue_work_task() 找不到地點同一套處理
	if not machine:
		push_warning("Agent %s: 找不到販賣機 %s" % [character_name, place])
		last_action_result = Character.BUY_TARGET_NOT_FOUND
		# 清掉任務前先停下——不然角色若正走去先前目標，會帶著已失效的
		# 路徑繼續走（CodeRabbit review 抓到）
		stop_moving()
		_pursued_place = ""
		_pursuit_done = false
		# 要先讀 source／id 再清空 _current_task，不然兩個 get() 只會讀到
		# 空字典的預設值，llm 來源的任務移除不掉（同一類問題見 #441 review）
		var failed_task_source: String = str(_current_task.get("source", ""))
		var failed_task_id: String = str(_current_task.get("id", ""))
		_current_task = {}
		current_place = ""
		current_state = "idle"
		if failed_task_source == "llm":
			_remove_task(failed_task_id)
		if llm_decision_enabled and not _awaiting_decision:
			_request_next_decision(_today_plan_needs_new_goal())
		_reevaluate()
		return

	# 還沒到達就先走過去
	if not _has_arrived_at(machine.global_position):
		if _buy_pursuit_task_id == buy_task_id and (is_moving() or _pursuit_done):
			# _pursuit_done 除了 move_to() 立即失敗會設，_on_move_finished(false)
			# 這個非同步的尋徑失敗回呼也會設——原本這裡直接 return，llm 任務會
			# 卡在這個守衛出不去，永遠記錄不到失敗結果、也不會請求下一次決策
			# （CodeRabbit review 抓到，sibling PR #441 同一套邏輯）
			if _pursuit_done and _current_task.get("source", "") == "llm":
				last_action_result = "走不到販賣機，無法購買"
				_finish_task_and_request_next()
			return
		_buy_pursuit_task_id = buy_task_id
		_pursued_place = current_place
		_pursuit_done = false
		_buy_pursuit_target = machine.global_position
		if not move_to(machine.global_position):
			push_warning("Agent %s: 走不到販賣機 %s" % [character_name, place])
			# schedule 任務維持原本的停止重試行為，靠 window 自然退場；
			# llm 任務沒有 window 這條退路，只設 _pursuit_done 的話會一直卡在
			# buy 狀態，等不到失敗結果、也不會請求下一個決策（CodeRabbit review 抓到）
			if _current_task.get("source", "") == "llm":
				last_action_result = "走不到販賣機，無法購買"
				_finish_task_and_request_next()
			else:
				_pursuit_done = true
		return

	# 已到達，執行購買
	stop_moving()
	_pursued_place = current_place
	_pursuit_done = true

	var proceed := true
	if _current_task.get("source", "") == "llm":
		var result := resolve(str(_current_task.get("action", "")), _current_task.get("params", {}))
		last_action_result = result["reason"]
		proceed = result["success"]

	if proceed:
		var item_id: String = str(_current_task.get("params", {}).get("item_id", ""))
		var reason := buy_from(machine, item_id)
		last_action_result = reason
		if reason != Character.BUY_OK:
			push_warning("Agent %s: buy 失敗（%s）" % [character_name, reason])

	if _current_task.get("source", "") == "llm":
		_remove_task(_current_task.get("id", ""))
	_current_task = {}
	current_place = ""
	current_state = "idle"
	if llm_decision_enabled and not _awaiting_decision:
		_request_next_decision(_today_plan_needs_new_goal())
	_reevaluate()

# work 任務的執行（#358）：長動作，執行協程會自己跑 5 遊戲分鐘。
# 跟 eat／drink 的差異是需要先走到工作地點，到達後才呼叫 work_at()。
# 工作開始後 `_working = true`，後續 _pursue_current_task() 會因 is_working()
# 直接返回，協程會自己監控 5 分鐘、完成時自動收尾（或中途異常中止）。
# 成功或失敗都不在這裡結束任務——schedule 任務靠 window 自然退場，
# 失敗時 resolve() 層級也會記錄原因（未來若開放 LLM 選 work 時）
func _pursue_work_task() -> void:
	# 檢查是否已到達工作地點
	var anchors := get_tree().get_first_node_in_group("place_anchors")
	if anchors == null or current_place.is_empty() or not anchors.has(current_place):
		last_action_result = Character.WORK_TARGET_NOT_FOUND
		push_warning("Agent %s: work 失敗（無法解析地點 %s）" % [character_name, current_place])
		# 完整重設追逐狀態，不然下一筆任務可能沿用舊路徑，或被追逐節流
		# 誤判成已經處理過；current_place 沒清空也會讓下一輪仲裁跟 prompt
		# context 誤以為角色還在一個查無此地的地點（CodeRabbit review 抓到）
		stop_moving()
		_pursued_place = ""
		_pursuit_done = false
		_current_task = {}
		current_place = ""
		current_state = "idle"
		return

	var target: Vector2 = anchors.resolve(current_place)

	# 還沒到達就先走過去
	if not _has_arrived_at(target):
		# 地點沒換的話這一趟只起步一次：還在走就繼續走，已經有結論（含
		# move_to() 失敗）也不要再試——原本的守衛條件反過來寫，導致
		# move_to() 失敗、is_moving() 仍是 false 時，下一輪重算又會再呼叫
		# 一次 move_to()，卡住的角色會每個 tick 重複噴同一則警告
		# （CodeRabbit review 抓到）。跟 _pursue_buy_task() 同一套收斂邏輯
		if current_place == _pursued_place and (is_moving() or _pursuit_done):
			return
		_pursued_place = current_place
		_pursuit_done = false
		if not move_to(target):
			push_warning("Agent %s: 走不到工作地點 %s" % [character_name, current_place])
			_pursuit_done = true
		return

	# 已到達工作地點，找工作站並執行 work_at()
	stop_moving()
	_pursued_place = current_place
	_pursuit_done = true

	# 找最近的工作站（MVP 只有一個，但用最近的方式向前相容）
	var workstations: Array = get_tree().get_nodes_in_group("workstations")
	var nearest_workstation: Workstation = null
	var nearest_distance := INF

	for ws in workstations:
		var distance := get_body_position().distance_to(ws.global_position)
		if distance < nearest_distance:
			nearest_distance = distance
			nearest_workstation = ws

	# 呼叫 work_at() 並記錄結果
	var reason := work_at(nearest_workstation)
	last_action_result = reason

	if reason == Character.WORK_OCCUPIED:
		# 工作站被佔用：保留目前的 schedule work 任務、不清掉也不呼叫
		# _reevaluate()。清掉的話 _reevaluate() 會在同一輪立刻重選到同一筆
		# schedule 任務（_tasks 裡的參照沒被移除），work_at() 再次回
		# WORK_OCCUPIED，形成同步無限迴圈（CodeRabbit review 抓到，實測
		# passes=8 warnings=8 不收斂）。讓下一次 GameClock time_changed
		# 自然觸發重試，工作站空出來後就能接得上
		push_warning("Agent %s: work_at 失敗（工作站被佔用）" % [character_name])
		return

	if reason != Character.WORK_OK:
		push_warning("Agent %s: work_at 失敗（%s）" % [character_name, reason])
		# 工作失敗就收尾任務；成功的話協程會自己管理、完成後呼叫 _on_work_finished()。
		# 跟 WORK_OCCUPIED 同一個理由：schedule 任務還在 _tasks 池子裡，立刻
		# 呼叫 _reevaluate() 會在同一輪重選到同一筆，work_at() 再次遇到同樣
		# 走不到／忙碌的狀態，形成同步無限迴圈（CodeRabbit review 抓到）。
		# 不呼叫 _reevaluate()，讓下一次 time_changed 自然重試
		_current_task = {}
		current_place = ""
		current_state = "idle"

# murmur 任務的執行（#162）：沒有目標、不用移動，講給自己聽當下就結束——不像
# talk 要追著會動的目標走，也不像 nap／rest 那類要佔滿整段 duration。resolve()
# 一過（murmur 沒有硬規則、不擲骰，恆成功）就講一句、立刻退出任務池
func _pursue_murmur_task() -> void:
	# CodeRabbit review：murmur 可能是從移動中的任務切換過來，不清掉舊路徑
	# 的話角色會一邊沿用上一筆任務的移動、一邊講自語
	if is_moving():
		stop_moving()

	var should_speak := true
	if _current_task.get("source", "") == "llm":
		var result := resolve(str(_current_task.get("action", "")), _current_task.get("params", {}))
		last_action_result = result["reason"]
		should_speak = result["success"]

	# 內容層跟 talk 同一套「模板先頂著，LLM 版之後再換」的分工（見
	# note/技術/talk 動作設計.md）：murmur 沒有聽者，講的是給自己聽的話，
	# 不能沿用 DialogueLines.reply() 那組面向對話對象的句子
	if should_speak and stats != null:
		say(DialogueLines.murmur(stats))

	_remove_task(_current_task.get("id", ""))
	_current_task = {}
	current_place = ""
	current_state = "idle"
	if llm_decision_enabled and not _awaiting_decision:
		_request_next_decision(_today_plan_needs_new_goal())
	# CodeRabbit review：_request_next_decision() 只有在非同步回應回來後才會
	# 重新仲裁，不立刻補一次 _reevaluate() 的話，等回應期間排程或 fallback
	# 任務不會被馬上接手，得空等到下一次 GameClock time_changed
	_reevaluate()

# 任務「做完了」的共同收尾：talk 判定失敗、give／shout 這種一次性動作執行完畢
# 都要退出任務池、清掉目前任務狀態、主動補一次決策請求。
#
# 主動補請求是必要的：這筆若是最後一筆 llm 任務，它在這裡被移除，不是被
# _reevaluate() 的 duration 完成分支判定完成的，那個分支不會再被觸發——
# 不主動補的話 Agent 會乾等到某個不相干的事件才重新決策（跟 exit_conversation()
# 對「llm 任務因為別的理由結束」的處理一致，是 max 等級 code review 抓到的坑）
#
# stop_moving() 與清 _pursued_place／_pursuit_done 也是必要的（CodeRabbit
# review 抓到，#158）：give 會追著會動的目標走，走到一半才被更高分的任務
# 打斷時，這裡若不重設，之後仲裁器選回同一個 place（跟 give 之前那筆地點式
# 任務剛好同名）會被 _pursue_current_task() 的「地點沒換、已有結論」節流誤判
# 成「已經到過了」而不重新 move_to()——但角色實際位置早就被 give 帶去別處，
# 不是真的站在那個地點上
func _finish_task_and_request_next() -> void:
	stop_moving()
	_pursued_place = ""
	_pursuit_done = false
	_remove_task(_current_task.get("id", ""))
	_current_task = {}
	current_place = ""
	current_state = "idle"
	if llm_decision_enabled and not _awaiting_decision:
		_request_next_decision(_today_plan_needs_new_goal())
	# _request_next_decision() 只有在非同步回應回來後才會重新仲裁，不立刻補
	# 一次 _reevaluate() 的話，等回應期間排程或 fallback 任務不會被馬上接手，
	# 得空等到下一次 GameClock time_changed（跟 murmur 那條 PR 同一個
	# CodeRabbit review 抓到的問題，這裡是共用的收尾，一次修就對三個呼叫端都生效）
	_reevaluate()

# give 任務的執行（#158）：目標跟 talk 一樣是會動的角色，不能沿用地點式的
# 「走一次、_pursued_place／_pursuit_done 收斂」節流，每次重算都要重新問一次
# 「他現在在哪」。跟 talk 不同的是東西送到就結束了，不會像對話一樣持續佔用
# 很多個遊戲分鐘——真正執行過一次（不管成功失敗）就立刻退出任務池，不會每個
# 遊戲分鐘重送一次
func _pursue_give_task() -> void:
	if _current_task.get("source", "") == "llm":
		var result := resolve(str(_current_task.get("action", "")), _current_task.get("params", {}))
		last_action_result = result["reason"]
		if not result["success"]:
			_finish_task_and_request_next()
			return

	var params: Dictionary = _current_task.get("params", {})
	var target_name: String = str(params.get("target", ""))
	var target := _find_character_by_name(target_name)

	if target == null:
		last_action_result = "找不到這個人，可能已經離開了"
		_finish_task_and_request_next()
		return

	var distance := get_body_position().distance_to(target.get_body_position())
	if distance > GIVE_RANGE:
		# 走不到跟 talk 一樣只警告不放棄——但 give 沒有「對方暫時忙碌」這種
		# 值得下個遊戲分鐘重試的情境，走不到就是走不到，直接結束這筆任務
		if not move_to(target.get_body_position()):
			push_warning("Agent %s: 走不到送禮對象 %s" % [character_name, target.character_name])
			last_action_result = "靠近不了對方，禮物送不出去"
			_finish_task_and_request_next()
			return

		# 找得到路徑但卡住（障礙物、對方站在走不進去的位置）：距離沒有明顯
		# 縮短就算一次沒進展，連續卡住才真的放棄（#266：共用邏輯見
		# _pursuit_stuck_progress()）
		var progress := _pursuit_stuck_progress(distance, _give_pursuit_last_distance, _give_pursuit_stuck_ticks)
		_give_pursuit_stuck_ticks = progress["stuck_ticks"]
		_give_pursuit_last_distance = distance

		if progress["threshold_reached"]:
			push_warning("Agent %s: 送禮對象 %s 卡住走不到，放棄" % [character_name, target.character_name])
			last_action_result = "靠近不了對方，禮物送不出去"
			_finish_task_and_request_next()
		return

	stop_moving()
	var item_id: String = str(params.get("item_id", ""))
	var count: int = int(params.get("count", 1))
	last_action_result = _give_failure_message(give_to(target, item_id, count))
	_finish_task_and_request_next()

# give_to() 失敗原因碼轉中文，格式跟 _failure_reason() 一致——《01-2》§5
# 要求失敗原因要具體到 AI 能調整策略，不能只回錯誤碼
func _give_failure_message(failure: String) -> String:
	match failure:
		Character.GIVE_OK:
			return ""
		Character.GIVE_TARGET_NOT_FOUND:
			return "找不到這個人，可能已經離開了"
		Character.GIVE_TARGET_IS_SELF:
			return "不能把東西送給自己"
		Character.GIVE_NO_INVENTORY:
			return "沒有背包，沒辦法送禮"
		Character.GIVE_TOO_FAR:
			return "距離太遠，禮物送不到"
		Inventory.REMOVE_NOT_FOUND:
			return "身上沒有這件東西，送不出去"
		Inventory.REMOVE_INVALID_COUNT:
			return "送禮的數量不對"
		Inventory.ADD_NO_SPACE:
			return "對方身上放不下了，禮物送不出去"
		_:
			return "禮物沒有送成功"

# attack 任務的執行（#159）：目標跟 give 一樣是會動的角色，沿用同一套「走一次、
# 卡住偵測」節流，跟 give 不同的只有終點呼叫的是 attack() 不是 give_to()——
# 必中，resolve() 已經在硬規則那關保證這裡不會再失敗
func _pursue_attack_task() -> void:
	if _current_task.get("source", "") == "llm":
		var result := resolve(str(_current_task.get("action", "")), _current_task.get("params", {}))
		last_action_result = result["reason"]
		if not result["success"]:
			_finish_task_and_request_next()
			return

	var params: Dictionary = _current_task.get("params", {})
	var target_name: String = str(params.get("target", ""))
	var target := _find_character_by_name(target_name)

	if target == null:
		last_action_result = "找不到這個人，可能已經離開了"
		_finish_task_and_request_next()
		return

	var distance := get_body_position().distance_to(target.get_body_position())
	if distance > ATTACK_RANGE:
		if not move_to(target.get_body_position()):
			push_warning("Agent %s: 走不到攻擊對象 %s" % [character_name, target.character_name])
			last_action_result = "靠近不了對方，攻擊不到"
			_finish_task_and_request_next()
			return

		if distance >= _attack_pursuit_last_distance - 1.0:
			_attack_pursuit_stuck_ticks += 1
		else:
			_attack_pursuit_stuck_ticks = 0
		_attack_pursuit_last_distance = distance

		if _attack_pursuit_stuck_ticks >= 3:
			push_warning("Agent %s: 攻擊對象 %s 卡住走不到，放棄" % [character_name, target.character_name])
			last_action_result = "靠近不了對方，攻擊不到"
			_finish_task_and_request_next()
		return

	stop_moving()
	last_action_result = _attack_failure_message(attack(target))
	_finish_task_and_request_next()

# attack() 失敗原因碼轉中文，格式跟 _give_failure_message() 一致
func _attack_failure_message(failure: String) -> String:
	match failure:
		Character.ATTACK_OK:
			return ""
		Character.ATTACK_TARGET_NOT_FOUND:
			return "找不到這個人，可能已經離開了"
		Character.ATTACK_TARGET_IS_SELF:
			return "不能攻擊自己"
		Character.ATTACK_TOO_FAR:
			return "距離太遠，攻擊不到"
		_:
			return "攻擊沒有成功"

# persuade 任務的執行（#227）：目標跟 talk／give 一樣是會動的角色，走到範圍
# 內才生效，不擲骰、恆送達——「送不送達」（有沒有走到、對方在不在）跟
# 「被不被說動」是兩件事，這裡只管前者。後者交給目標角色自己下一輪決策時
# 的 persuaded 欄位，見 _resolve_pending_persuade()。
#
# 跟 give／shout 不同：P-09 拍板 persuade 佔用固定 duration（模型填的
# 建議值 10 分鐘），送達後不立刻退出任務池，改用 gather／hunt_small 那套
# _reevaluate_once() 通用事件驅動機制在 duration 走完時收尾
func _pursue_persuade_task() -> void:
	# 已送達、正在佔用 duration 等 _reevaluate_once() 的通用機制收尾——
	# 不用每個 tick 重跑 resolve()／找目標／追逐那一整套
	if _persuade_delivered:
		return

	if _current_task.get("source", "") == "llm":
		var result := resolve(str(_current_task.get("action", "")), _current_task.get("params", {}))
		last_action_result = result["reason"]
		if not result["success"]:
			_finish_task_and_request_next()
			return

	var params: Dictionary = _current_task.get("params", {})
	var target_name: String = str(params.get("target", ""))
	var target := _find_character_by_name(target_name)

	if target == null:
		last_action_result = "找不到這個人，可能已經離開了"
		_finish_task_and_request_next()
		return

	# 玩家沒有 LLM 決策迴圈，persuaded 這條路徑走不通——見 issue #305。
	# llm_decision_enabled 關著的 Agent 也一樣走不通：_ready() 一律
	# add_to_group("agents")，不管這個旗標開不開（預設就是關），只檢查
	# 有沒有在 agents 群組擋不住——若放行，_pending_persuade 寫上去之後
	# 永遠沒有 _request_next_decision() 會被觸發去清掉它（見 llm_decision_enabled
	# 關閉時「沒有任務做完就重新決策那條路徑」的既有說明），這筆待回應記錄會
	# 卡死，之後任何人都說服不了這個目標（忙碌拒絕永遠擋著）
	if not (target.is_in_group("agents") and (target as Agent).llm_decision_enabled):
		last_action_result = "這個人好像沒辦法被說服"
		_finish_task_and_request_next()
		return

	var distance := get_body_position().distance_to(target.get_body_position())
	if distance > TALK_RANGE:
		# 走不到跟 give 一樣只警告不放棄——但沒有「對方暫時忙碌」這種值得
		# 下個遊戲分鐘重試的情境，走不到就是走不到，直接結束這筆任務
		if not move_to(target.get_body_position()):
			push_warning("Agent %s: 走不到說服對象 %s" % [character_name, target.character_name])
			last_action_result = "靠近不了對方，話說不出口"
			_finish_task_and_request_next()
			return

		var progress := _pursuit_stuck_progress(
			distance, _persuade_pursuit_last_distance, _persuade_pursuit_stuck_ticks
		)
		_persuade_pursuit_stuck_ticks = progress["stuck_ticks"]
		_persuade_pursuit_last_distance = distance

		if progress["threshold_reached"]:
			push_warning("Agent %s: 說服對象 %s 卡住走不到，放棄" % [character_name, target.character_name])
			last_action_result = "靠近不了對方，話說不出口"
			_finish_task_and_request_next()
		return

	stop_moving()
	var reason: String = str(params.get("reason", ""))
	var proposed_task: Dictionary = params.get("proposed_task", {})
	var recorded: bool = (target as Agent).try_record_pending_persuade(character_name, character_id, reason, proposed_task)
	if recorded:
		last_action_result = "你試著說服 %s，等他自己想清楚" % target.character_name
	else:
		last_action_result = "%s 好像還在想別人剛才說的話，你的話插不進去" % target.character_name
	_persuade_delivered = true
	# 不在這裡呼叫 _finish_task_and_request_next()：P-09 拍板 persuade 佔用
	# 固定時長（模型填的建議值 10 分鐘），跟 gather／hunt_small 同一套用法——
	# _reevaluate_once() 的通用事件驅動迴圈會在 duration 走完時自動移除
	# 這筆任務、觸發下一次決策，不是 give／shout 那種送達就立刻結束的
	# 一次性動作（CodeRabbit review 抓到：原本送達當下就呼叫
	# _finish_task_and_request_next()，等於忽略了 duration，任務在抵達的
	# 那一分鐘就結束）。_persuade_delivered 擋掉 duration 還沒走完前，
	# 後續每個 tick 重複呼叫 try_record_pending_persuade()

# 給發起者呼叫，把說服嘗試寫進自己的待回應記錄（#227）。已有待回應記錄時
# 直接拒絕（忙碌拒絕，比照 talk_to() 的 TALK_TARGET_BUSY），不覆蓋、不排隊
# ——避免舊記錄被靜默蓋掉，讓第一個說服者的嘗試無聲消失、自己完全不知道
func try_record_pending_persuade(persuader: String, persuader_id: String, reason: String, proposed_task: Dictionary) -> bool:
	if not _pending_persuade.is_empty():
		return false

	var pending := {"persuader": persuader, "persuader_id": persuader_id, "reason": reason}
	if not proposed_task.is_empty():
		pending["proposed_task"] = proposed_task
	_pending_persuade = pending
	return true

# 待回應事實句摘要（#227，《01-3》§3）。目前唯一來源是 persuade——其他
# 《01-3》§3 列的觸發條件（多久沒說話、地點首次造訪等）還沒接進來，不在
# 這次範圍內
func _fact_lines_summary() -> Array[String]:
	var lines: Array[String] = []
	if _pending_persuade.is_empty():
		return lines

	var persuader: String = str(_pending_persuade.get("persuader", ""))
	var reason: String = str(_pending_persuade.get("reason", ""))
	var proposed_task: Dictionary = _pending_persuade.get("proposed_task", {})

	if proposed_task.is_empty():
		lines.append("剛才 %s 試著說服你：%s，你被說動了嗎？" % [persuader, reason])
	else:
		lines.append("剛才 %s 試著說服你（%s），希望你能去做「%s」，你被說動了嗎？" % [
			persuader, reason, _describe_task_intent(proposed_task)
		])
	return lines

# 把 proposed_task 的 action／params 組成一句人看得懂的意圖描述，給
# _fact_lines_summary() 用（#227，CodeRabbit review 抓到只給英文 action
# 代號資訊不足——模型判斷要不要被說動時看不到具體內容）。沒有現成的
# action→中文對照表可用，這裡只補目標／地點，不翻譯動作本身——跟
# debug_console.gd 的 tasks 指令顯示一致，動作代號本來就是直接秀出來，
# 不是這個機制特有的取捨
func _describe_task_intent(task: Dictionary) -> String:
	var action: String = str(task.get("action", ""))
	var params: Dictionary = task.get("params", {})
	var target: String = str(params.get("target", ""))
	var place: String = str(params.get("place", ""))
	if not target.is_empty():
		return "%s（對象：%s）" % [action, target]
	if not place.is_empty():
		return "%s（地點：%s）" % [action, place]
	return action

# 消化這輪待回應的說服結果（#227）。只在 _request_next_decision() 確認這輪
# envelope 真的問過模型（見那邊 had_pending_persuade 的說明）才會被呼叫——
# 不驗證、不二次判定 persuaded 本身，只決定「接受了要做什麼」：行動說服
# （帶 proposed_task）機械式推進任務池，跟一般 LLM 任務同一套驗證與仲裁；
# 純思想說服（沒有 proposed_task）寫進記憶。不接受什麼都不做。不論結果都
# 清掉待回應記錄，不重複注入同一句事實句
func _resolve_pending_persuade(data: Dictionary) -> void:
	var pending := _pending_persuade
	_pending_persuade = {}

	if not data.get("persuaded", false):
		return

	var proposed_task: Dictionary = pending.get("proposed_task", {})
	if not proposed_task.is_empty():
		# proposed_task 的 expires_at 是發起者「決策當下」給的絕對遊戲分鐘，
		# 不是「被接受這一刻」的——中間隔著發起者追上目標、等目標下一輪自然
		# 決策這兩段可能耗掉數十遊戲分鐘的過程，原始 expires_at 這時很可能
		# 已經過期。照原樣推進的話，_is_expired() 會把它濾掉，說服判定成功
		# 卻什麼都不會發生、也不會有任何訊息。
		#
		# 不能清成 0：_is_expired()（見下方說明）把 expires_at <= 0 當「永不
		# 過期」，這筆任務選不上時會永久佔住 LLM_TASK_POOL_CAP 一格，直到
		# 角色重開機（CodeRabbit review 抓到，跟一般 LLM 任務的處理方式不
		# 一致——_validate_task_shape() 一律填 now_minutes + MAX_EXPIRES_IN_MINUTES，
		# 沒有無限期的路徑）。改成以接受當下重新換算存續時間，跟一般 LLM
		# 任務省略 expires_in_minutes 時的預設值同一套
		var accepted := proposed_task.duplicate()
		accepted["expires_at"] = _now_minutes() + AISchema.MAX_EXPIRES_IN_MINUTES

		# _push_llm_tasks() 池滿時只 push_warning 就靜默丟棄新任務（見它自己
		# 的說明）——對一般 LLM 任務來說「模型這輪的意圖沒排進去，下一輪再問
		# 一次」還好；但這裡是已經答應目標「你被說動了」之後的承諾，answer
		# 已經定案、_pending_persuade 也已經在上面清空，沒有「下一輪再問」
		# 這條路，池滿會讓這個承諾憑空消失、無聲無息（CodeRabbit review 抓
		# 到）。用先騰出一格再推進的方式保證塞得進去，代價是犧牲池子裡分數
		# 最低的既有 llm 任務——跟仲裁器本來就會用分數決定誰該留下是同一套
		# 邏輯，只是這裡改成事後、非比較式地騰位置
		if _llm_task_count() >= LLM_TASK_POOL_CAP:
			_evict_lowest_priority_llm_task()
		_push_llm_tasks([accepted], {})
		return

	if memory == null:
		return

	var reason: String = str(pending.get("reason", ""))
	var importance: int = int(data.get("importance", 50))
	var valence: String = str(data.get("valence", "neutral"))
	# related_npcs 存的是 character_id，不是顯示名——跟 memory.gd 的欄位定義
	# 一致，才能靠這個欄位正確連結到發起說服的那個角色（CodeRabbit review 抓到
	# 這裡原本傳的是 persuader 顯示名，會讓記憶連不回角色）
	var persuader_id: String = str(pending.get("persuader_id", ""))
	memory.add_candidate(reason, importance, valence, [persuader_id] as Array[String])

# shout 任務的執行（#158）：不像 give／talk 有會動的目標要追，原地喊一聲當下
# 就結束，不需要追逐或等待抵達——resolve() 一過就廣播，立刻退出任務池
func _pursue_shout_task() -> void:
	if _current_task.get("source", "") == "llm":
		var result := resolve(str(_current_task.get("action", "")), _current_task.get("params", {}))
		last_action_result = result["reason"]
		if not result["success"]:
			_finish_task_and_request_next()
			return

	# 半徑沿用 make_noise() 的預設值 NOISE_RADIUS——《07》§3 已定案「聽覺
	# （shout）8 格」，跟 make_noise() 原本給玩家按鍵用的廣播半徑是同一個數字，
	# 不用另外定義一個常數
	make_noise()
	_finish_task_and_request_next()

# 按顯示名找所有符合的角色，用於偵測撞名（resolve() 的歧義檢查）
func _find_all_characters_by_name(target_name: String) -> Array[Character]:
	var matches: Array[Character] = []
	if target_name.is_empty():
		return matches
	for node in get_tree().get_nodes_in_group("characters"):
		if node != self and node.character_name == target_name:
			matches.append(node as Character)
	return matches

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

# 找範圍內離自己最近的角色，不指定名字（#281，排程觸發的 talk 沒有指定
# 對象時用）。跟 _find_character_by_name() 用同一個 "characters" 群組，
# 不分玩家／Agent——涼亭這類聚集地點誰都可能在場
func _find_nearest_character_within(range_px: float) -> Character:
	var nearest: Character = null
	var nearest_distance := INF
	for node in get_tree().get_nodes_in_group("characters"):
		if node == self:
			continue
		var candidate := node as Character
		var distance := get_body_position().distance_to(candidate.get_body_position())
		if distance <= range_px and distance < nearest_distance:
			nearest_distance = distance
			nearest = candidate
	return nearest

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
	return expires_at > 0 and expires_at <= now_minutes

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

## Debug 用：直接推一筆任務進池子（debug_console.gd 的 act 指令，#112 驗證用）。
## 走 _push_llm_tasks() 這條跟 LLM 決策回應完全一樣的路徑，不另開執行捷徑——
## 另開一條的話，驗到的就不是真正會跑的那條。
##
## priority 給得比「schedule 任務 + 時間窗加成」（10 + 100）還高：指令下了就要
## 看得到效果，不是跟到點的行程比分數。expires_at 一定要填，這筆任務才會自己
## 退場——llm_decision_enabled 關著的角色沒有「任務做完就重新決策」那條路徑，
## 不填的話這筆最高分任務會永遠留在池子裡，把角色卡在原地
const DEBUG_TASK_PRIORITY := 999.0

func debug_push_task(action: String, params: Dictionary, duration: float) -> void:
	var tasks: Array[Dictionary] = [{
		"action": action,
		"params": params,
		"priority": DEBUG_TASK_PRIORITY,
		"duration": duration,
		"expires_at": _now_minutes() + int(duration),
	}]
	_push_llm_tasks(tasks, {})
	_reevaluate()

## Debug 用：切換 llm_decision_enabled（issue #282，debug_console.gd 的
## ai_decision 指令）。開啟時立刻等待一次真正的 _request_next_decision()，
## 不等自然觸發條件（任務做完、剛睡醒）——組員下指令當下就要看得到效果。
## 走跟正式路徑完全一樣的 _request_next_decision()，不另開捷徑，理由跟
## debug_push_task() 一樣：驗到的才是真正會跑的那條。
##
## 回傳值給 debug_console.gd 印出來當「這次真的問過模型」的可視覺驗證：
## reasoning／inner_monologue 是模型當次回應的自由文字，不是寫死的字串，
## 印得出這兩項就代表這趟真的打了地端模型，不是接了個假資料
func debug_set_llm_decision(enabled: bool) -> Dictionary:
	var state_changed := llm_decision_enabled != enabled
	llm_decision_enabled = enabled

	# 只有旗標真的翻轉時才跳世代——不然重複下 ai_decision X on（旗標本來就
	# 是 true）會白白作廢掉一份可能正由自然觸發路徑（非這個 debug 指令）
	# 送出、無關的在途請求。真的翻轉時，讓任何一份還在飛的舊回應——不管它
	# 抵達時旗標又被切回什麼值——一律被 _request_next_decision() 認成過期
	# 世代淘汰掉，見它自己的註解
	if state_changed:
		_decision_generation += 1

	if not enabled or _awaiting_decision:
		return {"triggered": false}

	# _request_next_decision() 回傳這次請求實際的驗證結果，不是靠任務池
	# 前後淨變動去猜——_push_llm_tasks() 會先淘汰同 key 的舊任務再新增，
	# 換舊為新時池子淨變動是 0，但這次請求其實成功了
	return await _request_next_decision(_today_plan_needs_new_goal())

## Debug 用：今天累積了哪些事件，給 reflect 指令在呼叫 request_sleep_reflection()
## 前先印出來看。只回 content——debug 顯示不需要知道內部的 id
func get_daily_events() -> Array[String]:
	var contents: Array[String] = []
	for event in _daily_events:
		contents.append(event["content"])
	return contents
