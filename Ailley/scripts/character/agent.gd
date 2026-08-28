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
##
## @export 預設值維持 false，是場景／存檔沒有其他人設定時的後備值，不代表
## 「開場一定是排程模式」——main_scene.gd::_apply_startup_ai_state()（#357）
## 在開場依 AIService 就緒狀態，把場上每隻 Agent 各自實際會用的 provider
## 準備好了沒查過一輪，就緒就自動打開，不就緒才維持這裡的預設值退回排程模式。
## debug 主控台的 `ai_decision <name> on/off`（#282）仍然保留，開場批次判斷
## 錯誤或要單獨測試某隻角色時可以手動覆寫
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

## #381：墓碑四內容欄位其中兩個（《規格書 09》§4-2）。life_highlights 由引擎彙整
## L4 核心記憶產出，絕不讓 LLM 潤飾——彙整函式 `Memory.get_life_highlights()`
## 已實作（#384），但死亡流程（`Character._die()`）還沒有任何呼叫端把結果寫進
## 這個欄位，見 [[記憶與睡眠反思]]「墓碑欄位 life_highlights」。
## words_to_creator 是墓碑第三個欄位，已存在於上面（#164），不重複宣告。
## last_words（第二個欄位）改由 Character 基底宣告（#379，死亡狀態機落地時
## 才發現這裡本來就先開了欄位形狀——Godot 4.5 不允許子類別重新宣告父類別
## 成員，會直接讓這支腳本載入失敗，CodeRabbit review 抓到），寫入邏輯仍在
## 下面覆寫的 _request_last_words()。第四個欄位 epitaphs（一對多，SQLite）
## 不在這裡，見 #382
var life_highlights: Array[String] = []

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

## 長動作固定間隔檢查點（issue #336，《02》§3／《99》P-14）：任務進行到期前，
## 每隔這麼多遊戲分鐘額外問一次「繼續」或「放棄、改做別的事」，不是被引擎
## 強制打斷。跟 MIN_ACTION_DURATION 取同一個值——這個值本身就是引擎對「一次
## 動作」的最小時間顆粒，短於它的任務一律在完成時的那次決策順便收尾，沒有
## 機會落在任何一個中途檢查點上（見 _reevaluate_once() 的
## `elapsed < duration` 條件），不需要另外校準一個新量級。MVP 唯一兩個長動作
## `hunt_large`（40 分鐘）／`work`（進行時間待補，見 P-14）都還沒實際跑過，
## 這是首次落地的建議值，之後有真實遊玩數據再回頭調（跟 P-04 一樣的「先跑，
## 實測後調」做法）
const LONG_ACTION_CHECKPOINT_INTERVAL := 10

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

# 正在跟隨的角色 character_id，空字串代表沒在跟隨任何人（issue #576）。
# 跟 current_place／current_state 同一層——這屬於「這個角色在這個世界裡的
# 行程狀態」，見 WorldCharacterStateSchema.gd 的 following_npc_id 說明。
# 要不要停止跟隨完全交給跟隨者自己的 AI 下一次決策判斷，這裡只負責存放
# 狀態，不寫任何距離／逾時門檻
var following_id := ""

# 這一場已經對誰驚訝過。Vision 只回報「看到誰」，要不要有反應是這裡決定的；
# 沒有這張表的話，走出視野再走回來就會再驚訝一次
var _noticed := {}

# 這一輪表演已經問過要不要打賞的表演者（#575）。跟 _noticed 不同，這裡刻意
# 「對方不再表演就從表裡移除」（見 _scan_for_performers()）——同一個人下次
# 再表演，是新的一場演出，值得再問一次要不要打賞，不是終身只問一次
var _tip_prompted_performers := {}

# 目前這一輪 tip 決策問的是誰（#575）。_request_next_decision() 回應回來時
# 靠這個 id 找到打賞對象——跟 appointment 的 with 不同，tip 決策本身沒有
# target 欄位（模型只回 give／amount，「給誰」是引擎自己知道的事，不需要
# 模型再講一次），所以要由呼叫端（_scan_for_performers()）自己記住問的是誰
var _tip_target_id := ""

# 今天已經對誰觸發過跟丟反應（#405）。跟 _noticed（終身只驚訝一次）不同：
# 這是單純的量級控制，每天由 _on_day_changed() 清空，不分認不認識——同一人
# 一天內反覆進出視野（走近又走遠）不會每次都排事實句洗版、拖爆 LLM 呼叫量，
# 但隔天還是會再觸發，不會變成終身只通知一次
var _lost_reacted := {}

# 這一次遭遇（走進視野到走出視野）已經對誰觸發過 L3 語意檢索（issue #571，
# WU-YI-RU review）：_seen_in_l1() 只讀不寫，角色不在最近 8 條 L1 視窗時，
# 同一人站在視野裡不動，vision.gd 每次重新 emit spotted 都會再打一次
# search_l3()，把重複內容一直塞進 _pending_recalled（無去重、無上限），
# 累積到下一輪 prompt 會放大 token 成本，違反《03》§7「不是每 tick 檢索」。
# 跟 _noticed（終身只驚訝一次）、_lost_reacted（每天一次）都是不同的時間
# 尺度——這張表在 _on_lost() 清除對應項，同一次持續遭遇只觸發一次，走出
# 視野再走回來才會重新觸發
var _l3_recalled_for := {}

# 上一次真的呼叫 move_to()（或判定「已經到了」「走不到」）的地點。
# _pursue_current_task() 每個遊戲分鐘都會跑，靠這個分辨「還在處理同一個地點」
# 與「地點換了要重新起步」
var _pursued_place := ""

# _on_action_interrupted() 存的即時位置反查快照，給 _on_attacked() 讀
# （見那兩個函式的說明，#426）
var _place_before_interrupt := ""

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

# 用來判斷「這筆追逐是不是同一筆 buy 任務」——不能沿用 current_place 比對，
# 因為販賣機不是 place 錨點，兩筆不同的 buy 任務可能落在同一個 place
# 字串（例如都在餐酒館買不同品項），甚至上一筆非 buy 任務（例如剛做完
# work）留下的 _pursued_place 也可能剛好等於這筆的 place，導致誤判成
# 「已經處理過」而整個跳過 move_to()（CodeRabbit review 抓到）
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

# bury 任務用的卡住偵測（#380），跟 _attack_pursuit_* 同一套理由與收尾方式
var _bury_pursuit_stuck_ticks := 0
var _bury_pursuit_last_distance := INF

# follow 任務用的卡住偵測（issue #576），跟 _talk_pursuit_* 同一套理由——
# 目標每 tick 都在動，每次都要重新 move_to()。卡住只警告不放棄，跟 talk
# 同一種態度：目標是不是要繼續被跟隨完全交給跟隨者自己下一次決策判斷，
# 不該讓引擎自己的卡住偵測代為決定放棄
var _follow_pursuit_stuck_ticks := 0
var _follow_pursuit_last_distance := INF

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

# 一次性事件（看到陌生人、聽到聲音）排隊要送進下一次決策的事實句
# （#402／#407，《01-3》§3 事實句機制）。跟 _pending_persuade 不同：
# 這裡不需要模型回覆特定欄位表態，_fact_lines_summary() 讀到的當下
# 就直接消化清空，不留到下一輪、也不用等回應來解析
var _pending_reaction_lines: Array[String] = []

# 正在對陌生人做「！」反應。那 2 秒刻意站著不動，期間不重新起步——
# GameClock 一個遊戲分鐘就是 1 現實秒，不擋的話 1 秒後就被送回路上，
# 2 秒的愣住實際上只有 1 秒
var _reacting := false

# 目前有沒有一份決策請求還沒回來。_reevaluate() 靠它避免同一份請求還在飛時
# 又觸發第二份（同一個 LLM 任務完成的當下可能被重算好幾次），
# _consider_switch() 靠它決定要用 MIN_COMMIT 還是 LLM_WAIT_MIN_COMMIT
var _awaiting_decision := false

# 長動作檢查點決策請求還有沒有一份在飛（issue #336）。跟 _awaiting_decision
# 是兩個獨立的旗標，各自防各自的重疊呼叫——檢查點問的是「這筆任務要不要
# 繼續」，跟完整重新規劃是兩種不同的請求，_reevaluate_once() 觸發檢查點時
# 同時看這個旗標與 _awaiting_decision，避免跟一份還在飛的完整決策打架
var _checkpoint_decision_pending := false

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

## 給 game_manager.gd 的跨日自動存檔（#468）判斷要不要等這隻角色。回傳 false
## 代表反思還在飛（_sleep_reflection_in_flight），或雖然剛做完但撞期時記了一次
## 補跑（_sleep_reflection_pending，見 _finish_sleep_reflection_request()）——
## 兩種情況都代表這次反思的 personality_delta／today_plan 還沒真正套用完成，
## 現在存檔會存到反思之前的狀態
func is_sleep_reflection_settled() -> bool:
	return not _sleep_reflection_in_flight and not _sleep_reflection_pending

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

## 目前有效的約定（#479，《10》§5.5）。同時間只追蹤一筆，新宣告直接整筆
## 覆蓋舊的——跟 _apply_today_plan() 的「整份取代」語意一致，不是陣列累加。
## null 代表目前沒有約定。形狀：{with, location, game_time, game_time_minutes,
## reminder_sent, waiting_since}——後兩者是引擎自己記帳用的階段旗標
## （waiting_since = -1 代表還沒進入「時間到、自己在場、等對方出現」那個階段），
## 不是模型填的
var _appointment: Variant = null

## 約定前置提醒與逾時等待的分鐘數（《10》§5.5：「約定前 30 遊戲分鐘」提醒、
## 「等到 12:30」＝約定時間 +30 分鐘的等待期滿）
const APPOINTMENT_REMINDER_MINUTES_BEFORE := 30
const APPOINTMENT_WAIT_MINUTES := 30

## 爽約當下若自己在睡眠中，先記著、等 _on_time_changed() 偵測到睡醒轉換時
## 才補送（《10》§5.5「爽約方若當時處於睡眠或昏迷，改為醒來後首次決策時
## 給予」）——跟其餘系統通知一律走 _pending_fact_lines 是同一套做法，這裡
## 只是多一個「先別送，等醒了」的暫存點
var _appointment_broken_pending_line := ""

## 今天做過什麼（#172，《15》§2-5「新增機制」）：給玩家看的今日摘要面板下半段，
## 跟 _today_plan（自我回報的意圖）是兩回事——這裡是引擎寫的客觀執行紀錄。
## 也跟 _daily_events（agent.gd 另一處，睡前送給 LLM 評分用）不是同一份：
## 那份會被清空／評分消耗，這份只給 UI 顯示，不進 prompt（《15》§1-2）、
## 不進存檔（重開遊戲後「今天」這個概念本身就重新開始，見《15》§2-5 末）
## 50 筆，超過從最舊丟（issue #518／《99》P-38：一筆只是四欄位的小 Dictionary，
## 記憶體成本可忽略，太小丟掉早上的事比太大多佔一點記憶體嚴重，先抓寬鬆值）
const TODAY_LOG_CAP := 50
var _today_log: Array[Dictionary] = []		# 由新到舊 push 到陣列尾端，UI 端自己反轉顯示

## 上一輪決策回應有沒有問「下次能不能讓我改 today_plan」——見
## _request_next_decision() 開頭怎麼消費它。這是四個開放時機裡的「AI 主動
## 申請」：不是每次決策都能改，得先問過、下一輪才真的給
var _plan_update_requested := false

## load_save_data() 清除 _plan_update_requested 時遞增的 epoch，用於保護
## 載入流程不被過期的決策請求覆寫——見 _request_next_decision() 的 epoch 檢查
var _plan_update_epoch := 0

## 這次重算「進來的時候」current_state 是不是 sleep——用來偵測「剛睡醒」
## 那個轉換瞬間，見 _reevaluate() 怎麼用它
var _was_sleeping := false

## 睡醒自動存檔失敗時設 true，下一個遊戲分鐘的 _on_time_changed() 會補
## 重試一次——不額外養計時器，本來就有的每分鐘 tick 天然就是節流過的重試
## 間隔，同一次失敗不會被密集重試到成功為止（#427／CodeRabbit review 抓到：
## 原本 save_character() 回傳值被直接丟掉，失敗就整批資料悄悄遺失）
var _pending_save_retry := false

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

## 同一次最外層 _reevaluate() 呼叫內，已經被挑過又收尾的任務 id（#456
## CodeRabbit review 抓到）：schedule 來源的任務收尾後不移出 _tasks（見
## _pursue_eat_task() 等處註解），若收尾當下立刻呼叫的 _reevaluate() 在
## window 還沒結束時把同一筆分數最高的任務原地重選回來，會在這次呼叫的
## while 迴圈裡卡成同步無窮迴圈（例如沒食物時 eat 一直失敗、一直被選回來）。
## 只在最外層呼叫開頭清空（見 _reevaluate()），下一次真正的 tick 觸發時
## 自然重置，不影響「下個 tick 再試一次」的正常重試節奏
var _reevaluate_excluded_ids: Dictionary = {}

## 這隻角色的決策來源，出生時決定一次，之後所有決策/對話呼叫都透過它——
## 跟《06》「decision_source／model_name 投放後不可改」的規則一致，不做成每次呼叫
## 才判斷（#155）
var _provider: DecisionProvider

## 這隻角色實際會打的 provider 名字（給 #357 開場批次查 AIService.get_readiness()
## 用）。轉呼叫 DecisionProvider.provider_name()，不直接讓外部碰 _provider——
## 外部只需要知道「這個名字」，不需要整個 DecisionProvider 物件
func get_provider_name() -> String:
	return _provider.provider_name()

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
##
## related_npcs 是這件事牽涉到誰——客觀事實，在事件發生的當下記下來，睡前
## 反思寫回 Memory.add_candidate() 時原封不動帶過去（見
## request_sleep_reflection()），不是引擎替這段記憶加主觀定性（見《00》
## 原則二）。location_id 預設用 current_place——跟 get_state_snapshot() 送給
## LLM 的 "place" 欄位同一個來源，不另外定義一套「現在在哪」；指定
## location_override 時改用覆寫值，見下一段
##
## location_override 給 current_place 當下不可信或不適用的呼叫端用（#426：
## _on_attacked() 用 _place_before_interrupt 快照的即時位置反查、
## exit_conversation() 直接呼叫 _resolve_actual_place()——見那兩個函式的
## 說明）：非 null 時取代 current_place，其餘呼叫端不用管這個參數（省略即為
## null），維持原本「一律用 current_place」的行為（CodeRabbit review 抓到
## force_interrupt() 會搶先把 current_place 清空，直接讀會拿到空字串）。
##
## 一定要用 null 當「沒有指定」的哨兵，不能用空字串——`_place_before_interrupt`
## 快照下來的值本來就可能合法地是空字串（角色被攻擊當下 current_place 本來就
## 沒設過），空字串當「沒指定」處理的話，會誤用呼叫這裡當下已經被 _reevaluate()
## 重新指派的 current_place（可能是完全不相關的新地點），而不是「這件事發生
## 時真的沒有地點」這個事實（CodeRabbit review 抓到）
func _push_daily_event(
	content: String, related_npcs: Array[String] = [], location_override: Variant = null
) -> void:
	var location_id: String = current_place if location_override == null else str(location_override)
	_daily_events.append({
		"id": _next_daily_event_id,
		"content": content,
		"related_npcs": related_npcs,
		"location_id": location_id,
	})
	_next_daily_event_id += 1
	if _daily_events.size() > DAILY_EVENTS_CAP:
		_daily_events.pop_front()

## 加一筆今天做過的事（#172）。minute 取 GameClock，target 沒有對象的動作
## 傳空字串——UI 端顯示時整個省略，不印「無」（《15》§2-5）
func _push_today_log(action: String, target: String, ok: bool) -> void:
	_today_log.append({
		"minute": GameClock.hour * 60 + GameClock.minute,
		"action": action,
		"target": target,
		"ok": ok,
	})
	if _today_log.size() > TODAY_LOG_CAP:
		_today_log.pop_front()

## 給今日摘要面板讀（#172）。內部陣列是舊到新（append 順序），這裡反轉成
## 《15》§2-5 要求的「由新到舊」——最上面那筆就是這個角色現在／剛剛在做的事
func get_today_log() -> Array[Dictionary]:
	var reversed := _today_log.duplicate(true)
	reversed.reverse()
	return reversed

func _on_day_changed(_day: int) -> void:
	_today_log.clear()
	_lost_reacted.clear()

## 收尾清空 _current_task 前先記一筆 today_log（#172）。集中在這一個 helper
## 而不是在每個呼叫端各自 push，是因為 _current_task 被清空的地方分散在
## 至少 8 處（exit_conversation／_finish_task_and_request_next／
## _pursue_eat_task／_pursue_murmur_task／_reevaluate_once 兩條過期路徑／
## _evict_lowest_priority_llm_task／_on_action_interrupted），把「清空」跟
## 「記一筆做過的事」黏在同一個函式，才不會有路徑漏記。
##
## target_override 給沒辦法從 params 推出對象的呼叫端用（例如 eat 吃的是哪個
## item_id，任務本身的 params 沒有記這個）；預設從 params.target／params.place
## 推，涵蓋大多數動作（talk/give/attack/persuade 用 target，schedule 類地點式
## 任務用 place）
func _clear_current_task(ok: bool, target_override: String = "") -> void:
	_log_task_ended(_current_task, ok, target_override)
	if not _current_task.is_empty():
		_reevaluate_excluded_ids[_current_task.get("id", "")] = true
	_current_task = {}
	current_place = ""
	current_state = "idle"

## 實際寫 today_log 的地方。_clear_current_task() 用在「換成空」的收尾，
## _select() 用在「換成另一筆」——後者不會經過 _clear_current_task()（它
## 直接把 _current_task 覆寫成新任務，不會先變成 {}），但舊任務一樣算
## 「做過的事」，不能因為換任務的路徑不同就漏記（#172）
##
## 靠 task 自己身上的 "_logged" 記一次就夠：_reevaluate_once() 的 duration
## 到期分支現在會搶先在完成的當下記一筆（見那裡的註解），同一個 task 之後
## 若又流到 _select()／_clear_current_task()（例如決策遲遲不回，_current_task
## 撐到自己過期才被 _clear_current_task() 收尾），不能再記第二次
func _log_task_ended(task: Dictionary, ok: bool, target_override: String = "") -> void:
	if task.is_empty() or task.get("_logged", false):
		return
	task["_logged"] = true
	var params: Dictionary = task.get("params", {})
	var target := target_override if not target_override.is_empty() \
			else str(params.get("target", params.get("place", "")))
	_push_today_log(str(task.get("action", "")), target, ok)

## ---- 事實句機制（#338，《01-3》§3）----
##
## 1 tick = 10 遊戲分鐘（《02》§1-4／《01-3》§3 三處門檻互相驗證過），下面
## 門檻常數統一換算成遊戲分鐘，跟 _now_minutes() 同一個時間基準

const FACT_SOCIAL_SILENCE_3H_MIN := 180		# 18 tick
const FACT_SOCIAL_SILENCE_HALF_DAY_MIN := 360	# 36 tick
const FACT_SOCIAL_SILENCE_1_DAY_MIN := 1440	# 144 tick
const FACT_GOAL_STALE_MIN := 360				# 36 tick
const FACT_CONSECUTIVE_FAILURE_THRESHOLD := 3

## 上次「跟人講完話」的時間點，_ready() 時初始化成出生那一刻，不是 0——
## 不然剛出生的角色會立刻背著「已經一整天沒說話」的事實句
var _last_social_minute := 0

## current_goal 最後一次被模型「改成新內容」的時間點（不是每次原樣重申都
## 更新）。-1 代表還沒設過，事實句判斷時用這個排除掉「模型從沒填過
## current_goal」跟「填了但很久」這兩種狀況
var _goal_set_minute := -1

## 去過的地點，只記有沒有去過，不記次數——判斷「首次造訪」用
var _visited_places := {}

## 一次性事實句佇列。跟「距上次社交」那種可持續重算的條件不同，「第一次
## 來這裡」是事件觸發的瞬間才成立，只在真的被送出且回應成功套用後才消費
## （見 _request_next_decision() 的 fact_lines_sent_count 說明），不是
## _fact_lines_summary() 組信封當下就清掉——回應失敗或被世代淘汰的話，
## 這句事實句要留著下一輪再問，不能就這樣不見
var _pending_fact_lines: Array[String] = []

## L3 語意檢索（issue #571，《03》§7）排隊機制。跟 _pending_reaction_lines
## 同一種「讀完即清」做法，不是 _pending_fact_lines 那種「送出後等回應真的
## 套用才消費」——語意檢索結果是順便給模型看的線索，不是欠模型一次許可，
## 這一輪沒趕上送出就丟掉，不影響正確性，沒必要複製一份 fact_lines_sent_count
## 那樣的還原機制
var _pending_recalled: Array[String] = []

## 連續同一動作失敗的追蹤。由各 _pursue_*_task() 在真正的終局結果（前置檢查
## 沒過、或 talk_to()／give_to()／attack()／eat()／drink() 等實際執行完成）
## 呼叫 _track_action_result_for_facts() 記錄——不能包在 resolve() 裡自動記，
## 那樣追逐目標時每個遊戲分鐘的前置檢查通過都會被當一次「成功」洗掉真正的
## 連續失敗（CodeRabbit review 抓到，見 resolve() 的說明）
var _consecutive_failure_action := ""
var _consecutive_failure_count := 0

## 《03》§7 觸發時機表「抵達新地點」（issue #571）：只在第一次抵達某個地點時
## 觸發語意檢索，跟這個函式本身既有的「新地點」判斷（_visited_places 只記
## 第一次）用同一個條件，不另外開一個「每次抵達」的判斷——後者代表每個遊戲
## tick 只要角色待在同一地點就可能重複觸發，違背《03》§7「不是每 tick 都檢索」
## 的精神。call-and-forget（CodeRabbit review 抓到：先前誤加了 await，
## 會讓這裡真的等 embedding API 回應才往下走，等於拖慢了呼叫端本來的同步
## 流程）——不 await，_queue_recalled() 在背景完成，_pending_recalled
## 是排隊寫入，下一輪決策自然讀得到，不需要等它
func _note_place_visited(place: String) -> void:
	if place.is_empty() or _visited_places.has(place):
		return
	_visited_places[place] = true
	_pending_fact_lines.append("你以前沒有來過「%s」。" % place)
	_queue_recalled(place)

func _track_action_result_for_facts(action: String, success: bool) -> void:
	if success:
		_consecutive_failure_count = 0
		_consecutive_failure_action = ""
		return
	if action == _consecutive_failure_action:
		_consecutive_failure_count += 1
	else:
		_consecutive_failure_action = action
		_consecutive_failure_count = 1
## #164：天神之石的話傳到範圍內的角色（world/god_stone_input.gd 逐一呼叫）。
## 記一筆事實句（跟 _on_spotted() 的 "你第一次注意到 %s" 同一種寫法，不經
## L10n——這是餵給 LLM 反思的內部事實句，不是玩家會看到的 UI 文字），
## 同時骰一次天神之石觸發判定
func hear_god_stone(line: String) -> void:
	if is_dead:
		return
	_push_daily_event("你在天神之石附近聽到一個聲音，說：「%s」" % line)
	# 《03》§7 觸發時機表「天神之石事件」（issue #571）：以事件內容本身（玩家
	# 說的那句話）為查詢——call-and-forget（不 await，CodeRabbit review 抓到
	# 先前誤加的 await 會拖住這裡），不擋 maybe_speak_to_creator() 原本就有的
	# 機率骰與 AI 詢問流程
	_queue_recalled(line)
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
	var my_generation := _decision_generation
	var envelope := PromptBuilder.build_words_to_creator_envelope(self, heard_line)
	var validator := func(data: Dictionary) -> Dictionary:
		return AISchema.validate_words_to_creator_choice(data)
	var result := await _decide_with_retry(envelope, AIService.Policy.SCHEDULED, validator)
	_words_to_creator_pending = false

	if is_dead or my_generation != _decision_generation:
		return
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
	var parsed := AISchema.parse_completion(result["data"])
	if not parsed["ok"]:
		return
	var validated := AISchema.validate_creation(parsed["data"])
	if not validated["ok"]:
		return
	if not words_to_creator.is_empty():
		return
	words_to_creator = validated["data"]["words_to_creator"]


## #357：這段（訊號連接、第一次 _reevaluate()、世界開場決策請求）曾經意外地
## 只掛在 rebuild_provider() 底下——PR #280（#122）把 `_provider = _make_provider()`
## 抽出成獨立函式時，新的 func 宣告插進了原本 _ready() 的中間，副作用是把
## _ready() 剩下的內容全部劃給了新函式。rebuild_provider() 只給
## GameManager.deploy_from_library()／存檔還原這兩條動態生成角色的路徑呼叫，
## 場景裡固定寫死的 NPC（main.tscn 的 Agent 節點）從來不會呼叫它，等於這些
## NPC 從頭到尾沒有接上 vision.spotted／noise_heard／move_finished／
## GameClock.time_changed，也沒有觸發過世界開場的第一次決策請求——不是只有
## llm_decision_enabled 預設 false 這一層問題。修法是搬回 _ready()，讓所有
## Agent（不分場景固定或動態生成）出生時都走這一段；rebuild_provider() 縮回
## 它原本的單一職責（見它自己的說明），不重複連接一次訊號
func _ready() -> void:
	super()
	add_to_group("agents")
	_provider = _make_provider()
	_load_schedule()
	_generate_words_to_creator()
	GameClock.day_changed.connect(_on_day_changed)
	# 出生那一刻起算，不是 0——不然剛出生的角色會立刻背著「一整天沒說話」
	# 的事實句（#338）
	_last_social_minute = _now_minutes()

	if vision != null:
		vision.spotted.connect(_on_spotted)
		vision.lost.connect(_on_lost)

	noise_heard.connect(_on_noise_heard)
	speech_heard.connect(_on_speech_heard)
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
	#
	# 這裡讀到的 llm_decision_enabled 是場景／存檔裡的既有值，還沒被
	# main_scene.gd 的開場批次套用（那一段在全部角色的 _ready() 都跑完
	# 之後才執行，見 main_scene.gd::_apply_startup_ai_state()）——所以這一關
	# 對場景固定 NPC（預設 false）通常不會成立，第一次決策改由開場批次
	# 直接呼叫 debug_set_llm_decision(true) 觸發，兩邊用同一條路徑
	# （_request_next_decision()），不重複也不衝突
	if llm_decision_enabled and not _has_llm_task():
		_request_next_decision(true)

## 公開版的「重建 provider」（#122，CodeRabbit review 抓到的時序 bug）。
## GameManager.deploy_from_library() 會在 add_child()（進而觸發這個節點的
## _ready()）之後才套用建角面板選的 decision_source／model_name——那時候
## _provider 已經照預設值（"local"）建好了，角色庫選的來源永遠不會生效。
## 呼叫端設完那兩個欄位要接著呼叫這個，才會用最終的值重建一次。
##
## 只重建 provider，不重複 _ready() 已經做過的訊號連接／世界開場決策請求——
## 那些呼叫端呼叫這個函式之前，add_child() 觸發的 _ready() 早就做過一次了
## （#357，見 _ready() 上面的說明）
func rebuild_provider() -> void:
	_provider = _make_provider()

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

# 給事實句（_push_daily_event()）用的即時位置反查（issue #426）：current_place
# 是目前任務的目的地，不是即時座標——移動中會提早等於目的地，talk／追逐這類
# 無地點任務更是從頭到尾空字串，記事實句當下若直接沿用會記錯地點。半徑跟
# TALK_RANGE／WORK_RANGE 等既有互動距離門檻取同一個值（32px，2 格），都在
# 範圍外就回傳空字串——「在地點之間」是合法值，呼叫端（_push_daily_event()
# 的 location_override）直接把這個結果原樣傳下去即可
const ACTUAL_PLACE_RADIUS := 32.0

func _resolve_actual_place() -> String:
	return _actual_place_of(self)

# 跟 _resolve_actual_place() 同一套即時位置反查，但吃任意角色——約定機制
# （#479）判定「對方是否在場」時，對方可能是 Player（沒有 current_place
# 這個 Agent 專屬欄位，只有 Character 都有的 get_body_position()），不能沿用
# current_place（那是任務目的地，不是即時座標，見 _push_daily_event() 的
# 說明；同樣的理由，判定「自己在不在場」也改用這個而不是 current_place）
func _actual_place_of(character: Character) -> String:
	var anchors := get_tree().get_first_node_in_group("place_anchors")
	if anchors == null:
		return ""
	return anchors.resolve_from_position(character.get_body_position(), ACTUAL_PLACE_RADIUS)

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
	# 表演中同理 _working（CodeRabbit review 抓到）：_consider_switch() 原本
	# 只擋 _working，_performing 期間沒被擋住的話，_current_task 可能在
	# _run_perform() 協程還在跑的時候被換成別的任務——_on_perform_finished()
	# 收尾時清掉／記錄的就不是真正的表演任務，是搶占進來的那筆
	return not _working and not _performing and _current_task.get("interruptible", true)

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
			# #426：current_place 對指名對話（direct-target talk）從頭到尾是
			# 空字串（沒有 place 可言），這裡改用即時座標反查——對話結束當下
			# 兩人就站在彼此旁邊，位置是準的
			_push_daily_event(
				"你跟 %s 講完話了" % other.character_name, [other.character_id], _resolve_actual_place()
			)
			# 「多久沒說話」事實句的計時基準（#338）
			_last_social_minute = _now_minutes()

	super()

	if not _active_talk_task_id.is_empty():
		var was_llm := _active_talk_task_source == "llm"

		_remove_task(_active_talk_task_id)
		if _current_task.get("id", "") == _active_talk_task_id:
			_clear_current_task(true)
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
		#
		# allow_appointment=true（#479，《12》§2.4「對話情境中且在場有其他
		# 角色」）：這裡是唯一真正對應那個條件的觸發點——剛講完話，對方
		# 剛剛還在眼前，適合問「要不要跟這個人約下次見面」。super() 已經把
		# _conversation 清成 null，不能再靠 is_in_conversation() 現算，改由
		# 呼叫端（這裡）直接宣告，跟 allow_update_plan 同一種做法
		if was_llm and llm_decision_enabled and not _awaiting_decision:
			_request_next_decision(_today_plan_needs_new_goal(), true)

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
	# 比精準對齊網路延遲更重要。broadcast=false：這是「正在想」的內部狀態
	# 泡泡，不是角色真的說了什麼，不該觸發鄰近角色的 speech_heard（CodeRabbit
	# review 抓到，PR #674）
	say(AI_THINKING_TEXT, true, false)

	var envelope := PromptBuilder.build_dialogue_envelope(
		self, listener, turns, max_turns, current_place, _recalled_summary()
	)
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
	# 死屍不建立新的反思請求（CodeRabbit review 抓到）：debug_console.gd 的
	# `reflect` 指令可以對任何角色手動呼叫，不像睡眠轉換那條路徑已經被
	# force_interrupt()／is_dead 相關守衛擋住
	if is_dead:
		return {"ok": false}
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
	#
	# 用 id 查表存整筆事件，不是只記存不存在——LLM 回應只回 content／
	# importance／valence，related_npcs／location_id 是引擎自己記的客觀事實
	# （見 _push_daily_event()），LLM 不會也不該回傳，寫回 Memory.add_candidate()
	# 時要從這裡原封不動撈回來（#346）
	var events_by_id := {}
	for e in events_sent:
		events_by_id[e["id"]] = e

	var validator := func(data: Dictionary) -> Dictionary:
		var validated: Dictionary = AISchema.validate_reflection(data)
		if not validated["ok"]:
			return validated
		var seen_ids := {}
		for event in validated["data"]["events"]:
			var event_id = event["id"]
			if not events_by_id.has(event_id) or seen_ids.has(event_id):
				return AISchema._fail(AISchema.ERROR_BAD_SHAPE)
			seen_ids[event_id] = true
		return validated

	var my_generation := _decision_generation
	var envelope := PromptBuilder.build_reflection_envelope(self, events_sent)
	var result := await _decide_with_retry(envelope, AIService.Policy.SCHEDULED, validator)
	# 世代守衛＋is_dead（CodeRabbit review 抓到）：跟 _request_last_words() 同一個
	# 理由——等待期間角色可能死亡或被 load_save_data() 蓋過世代，回來時不能再把
	# 反思結果（memory／personality_delta／today_plan／last_reflection_summary）
	# 套用到已經作廢的角色狀態上
	if is_dead or my_generation != _decision_generation or not result["ok"]:
		_finish_sleep_reflection_request()
		return {"ok": false}

	var data: Dictionary = result["data"]
	last_reflection_summary = data["summary"]

	# 《03》§7 觸發時機表「睡眠反思」（issue #571）：以剛產出的當日摘要為查詢，
	# 排進 _pending_recalled 給角色醒來後的下一輪決策用——call-and-forget
	# （不 await，CodeRabbit review 抓到先前誤加的 await 會拖住這裡），
	# 不影響這裡剩下的評分/人格套用/today_plan 流程
	_queue_recalled(last_reflection_summary)

	var scored_ids := {}
	for event in data["events"]:
		var original: Dictionary = events_by_id.get(event["id"], {})
		# CodeRabbit review：original.get() 回傳型別是 Variant，靠宣告時賦值
		# 隱式轉成 Array[String] 依賴的是「來源值本身在 runtime 就已經是
		# Array[String]」這個不對外保證的假設（雖然目前資料流確實如此——
		# _push_daily_event() 存進 _daily_events 時就是型別化參數，
		# events_sent := _daily_events.duplicate(true) 深複製也保留 subtype）。
		# 改用 assign() 不依賴這個隱性假設，來源不管是 untyped 還是 typed
		# 陣列都能正確轉換，不會在未來資料流改變時悄悄壞掉
		var related_npcs: Array[String] = []
		related_npcs.assign(original.get("related_npcs", []))
		var location_id: String = original.get("location_id", "")
		memory.add_candidate(event["content"], event["importance"], event["valence"], related_npcs, location_id)
		scored_ids[event["id"]] = true

	_daily_events = _daily_events.filter(func(e): return not scored_ids.has(e["id"]))

	# personality_delta（#349，《03》§5 流程圖 ⑥）：validate_reflection() 已經
	# 夾制過每一項到 ±MAX_PERSONALITY_DELTA，這裡直接加總套用，不再二次判斷——
	# 「這個人今天該不該變得更記仇」是模型的判斷，引擎只做防止數值失控的夾制。
	# 套用公式跟物品效果共用 apply_personality_delta()（見 character.gd「人格」段）
	apply_personality_delta(data.get("personality_delta", {}))

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

## 死亡當下的臨終遺言請求（#379，《規格書09》§2）。覆寫 Character 的 no-op
## 掛點——只有 Agent 有 LLM 決策，Player 沒有，維持 last_words = null。
## _die() 呼叫這裡時不 await（見該函式說明），跟 request_sleep_reflection() 一樣
## 「打不到就算了」：last_words 本來就可以合法地是 null（來不及開口），
## 不值得為了它讓死亡狀態機卡住或另外報錯給誰看
func _request_last_words(cause: String) -> void:
	# 世代守衛（CodeRabbit review 抓到）：跟 _request_next_decision() 同一個理由——
	# 這通吃 await，等待期間可能發生 load_save_data()（世代遞增，見該函式），回應
	# 回來時若世代已經不是發起請求那時的世代，代表這份 last_words 屬於已經作廢的
	# 死亡請求，不能寫回去蓋掉載入後的角色狀態（可能是活人存檔，也可能是另一個
	# 死亡角色自己的 last_words）
	var my_generation := _decision_generation
	var envelope := PromptBuilder.build_last_words_envelope(self, cause)
	var result := await _decide_with_retry(envelope, AIService.Policy.SCHEDULED, AISchema.validate_last_words)
	if my_generation != _decision_generation:
		return
	if not result["ok"]:
		return
	last_words = result["data"]["last_words"]

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
##
## allow_appointment（#479）一樣是呼叫端自己判斷、不是這裡讀 is_in_conversation()
## 現算——《12》§2.4「對話情境中且在場有其他角色」在這個仲裁器裡唯一真正成立
## 的時刻是 exit_conversation() 剛講完話那一刻，而那個呼叫點在 super() 把
## _conversation 清成 null 之後才觸發下一次決策（CodeRabbit review 抓到），
## 這裡現算 is_in_conversation() 永遠讀到 false。改成跟 allow_update_plan
## 同一種做法：呼叫端自己知道「這通是不是剛結束一場對話」，這裡只負責照做
func _request_next_decision(
	allow_update_plan: bool = false, allow_appointment: bool = false, allow_perform_tip: bool = false
) -> Dictionary:
	# 死屍不建立新的決策請求（CodeRabbit review 抓到）：跟下面 await 之後的
	# is_dead 判斷是兩件事——那道只擋「套用已經送出去的回應」，這裡擋在送出
	# 請求之前，避免死亡後還被 _pending_reaction_lines 補問邏輯（見本函式
	# 結尾）之類的呼叫端觸發一次白白浪費的 AI 請求
	if is_dead:
		return {"ok": false, "triggered": false}
	if _awaiting_decision:
		return {"ok": false, "triggered": false}
	_awaiting_decision = true
	var my_generation := _decision_generation

	# 記下消費前的值，等這次回應因世代不符被丟棄時原封不動還回去——
	# 「跟從沒問過模型一樣」不能只是不套用任務，連這個已經兌現掉的許可
	# 也要還原，不然角色會憑空少一次原本已經賺到的 update_plan 機會。
	# 但若是載入造成的世代不符，則不該還原：load_save_data() 清除許可的同時
	# 也遞增了 _plan_update_epoch，下面只在 epoch 不變時才還原
	var had_plan_update_requested := _plan_update_requested
	var my_plan_update_epoch := _plan_update_epoch
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

	# 同一輪快照一次性事實句要送出的數量（CodeRabbit review 抓到）：這通吃
	# await，等待期間可能有新的一次性事實句進來（例如剛好走到沒去過的地點）。
	# 舊寫法在組信封當下就把 _pending_fact_lines 清空，回應失敗或被世代淘汰時
	# 這些事實句就這樣不見了，下一輪決策問不到；也可能把等待期間新加入、
	# 這次根本沒送出去的事實句一起清掉。改成只記「送出了幾筆」，等這次回應
	# 真的被套用時，才從佇列前面移掉對應筆數——等待期間新增的一律留在後面
	var fact_lines_sent_count := _pending_fact_lines.size()

	var visible: Array[Character] = vision.get_visible_characters() if vision != null else []
	var envelope := PromptBuilder.build_plan_envelope(
		self, visible, _task_pool_summary(), _today_plan_summary(), effective_allow_update_plan,
		_fact_lines_summary(), had_pending_persuade, current_place, allow_appointment,
		allow_perform_tip, _recalled_summary()
	)
	var validator := func(data: Dictionary) -> Dictionary:
		return AISchema.validate_tasks(
			data, effective_allow_update_plan, now_minutes, allow_appointment, allow_perform_tip
		)

	var result := await _decide_with_retry(envelope, AIService.Policy.SCHEDULED, validator)
	_awaiting_decision = false

	var final_result: Dictionary

	# 世代編號在 await 期間變了，代表 debug_set_llm_decision() 至少關過一次
	# 決策開關——不管回應抵達當下旗標是什麼值（就算又被重新打開），這份回應
	# 都屬於已經作廢的世代，整包淘汰，不套用任何任務或計畫更新。
	# 還原 had_plan_update_requested 時同時檢查 epoch：若 load_save_data() 發生過
	# （epoch 已遞增），則保持清除狀態，不讓過期請求重新授予 update_plan 許可。
	# is_dead 額外把關（CodeRabbit review 抓到）：這通請求可能是死亡發生前那個
	# 遊戲分鐘（昏迷逾時倒數期間 _on_time_changed() 仍會照常重算）發出的，
	# 死亡發生在 await 期間、世代沒變——沒有這個判斷，回應回來時會照樣把新任務
	# 塞進死屍的任務池、幫死屍套上新情緒，跟死亡當下的石化收尾矛盾
	if my_generation != _decision_generation or is_dead:
		if my_plan_update_epoch == _plan_update_epoch:
			_plan_update_requested = had_plan_update_requested
		final_result = {"ok": false, "triggered": true}
	elif not result["ok"]:
		final_result = {"ok": false, "triggered": true}
	else:
		var data: Dictionary = result["data"]

		# 這輪回應真的通過驗證、確定會被套用，才消費快照下來的一次性事實句數量
		# ——只砍前面 fact_lines_sent_count 筆，等待期間新增的（在陣列後段）
		# 留著給下一輪
		if fact_lines_sent_count > 0:
			_pending_fact_lines = _pending_fact_lines.slice(fact_lines_sent_count)

		# reasoning／inner_monologue 印出來給人排查，跟 _trigger_village_ai() 的
		# print() 除錯模式一致；不進遊戲內 UI。決策準不準沒有系統性驗證，
		# 目前只能肉眼看這兩個欄位判斷合不合理
		print("[llm_decision] %s reasoning: %s" % [character_name, data.get("reasoning", "")])
		print("[llm_decision] %s inner_monologue: %s" % [character_name, data.get("inner_monologue", "")])

		var tasks_added := _push_llm_tasks(data["tasks"], data)

		# emotion（#351）：每次決策都必填，validate_tasks() 已經驗證過 type／
		# intensity 合法，這裡直接套用，不再二次判斷——AI 自己宣告的內在狀態，
		# 引擎不覆寫、不打折扣。stability／grudge 帶這隻角色自己的人格值——不帶
		# 的話 set_emotion() 會退回中性值 50.0，讓《02》§1-4 的持續時間公式對
		# 每個角色都算出同一個結果，人格再怎麼極端也不影響情緒撐多久
		# （CodeRabbit review 抓到）
		var emotion_data: Dictionary = data.get("emotion", {})
		set_emotion(
			emotion_data.get("type", "neutral"), emotion_data.get("intensity", 0), "",
			personality.get("stability", 50.0), personality.get("grudge", 50.0)
		)

		# current_goal（#352）：模型完全沒填這欄位（current_goal_provided=false）
		# 就維持原樣不動，跟 update_plan 的「整份取代」不同，這是「有意思表示才
		# 動」的單一標籤。有填的話分兩種：空字串代表模型明確判斷這個目標已完成
		# 或不再追蹤，清空並停止目標拖延事實句的計時；非空字串才是真的設定/換
		# 目標（CodeRabbit review 抓到：原本「沒填」跟「填空字串」都被當「沒
		# 更新」，目標永遠沒有清除路徑，拖延事實句會無限期一直觸發下去）
		if data.get("current_goal_provided", false):
			var new_goal: String = data.get("current_goal", "")
			if new_goal.is_empty():
				current_goal = ""
				_goal_set_minute = -1
			elif new_goal != current_goal:
				current_goal = new_goal
				# 目標拖延事實句的計時基準（#338）：只在目標真的換了內容才重新
				# 起算，模型原樣重申同一個目標不算「重新設定」，不然這句事實句
				# 永遠不會累積
				_goal_set_minute = _now_minutes()

		# 不管這輪有沒有拿到 update_plan 許可，模型都可能問「下次讓我改」——記
		# 下來，下一次不管是哪個理由觸發 _request_next_decision() 都會兌現
		if data.get("request_plan_update", false):
			_plan_update_requested = true

		# null 代表這次沒有 update_plan（不管是沒許可、還是有許可但模型選擇不
		# 用）；空陣列 [] 是模型明確給的合法值（today_plan 清空），兩者不可
		# 混淆，見 AISchema.validate_tasks() 用 null 分辨「沒提供」與「提供了
		# 空陣列」
		var update_plan: Variant = data.get("update_plan")
		if update_plan != null:
			_apply_today_plan(update_plan)

		# appointment（#479）：null 代表這次沒有新約定（不管是沒開放還是模型
		# 選擇不用），有值就整筆取代舊的——跟 update_plan 同一種「明確給了才動」
		# 判斷。驗證層（AISchema._validate_appointment()）用的是送出信封那一刻
		# 的 now_minutes（見上面 var now_minutes := _now_minutes() 那行），但
		# 這裡是 await 網路往返回來之後——重試、逾時都可能讓時間走到約定時刻
		# 之後，用當初那個時間點驗證仍會通過，套用後下一個 tick 立刻判定爽約
		# 這種一出生就過期的約定沒有意義（CodeRabbit review 抓到）。用現在
		# 重新查一次 _now_minutes() 把關，過期就整筆丟棄，不重試——跟這一整段
		# 「世代不符、驗證失敗都直接放棄這輪」的態度一致，不特別為這一個欄位
		# 開一條回頭路
		var new_appointment: Variant = data.get("appointment")
		if new_appointment != null and int(new_appointment.get("game_time_minutes", 0)) > _now_minutes():
			_apply_appointment(new_appointment)

		# tip（#575）：null 代表這次沒有打賞（不管是沒開放、模型選擇不給，還是
		# give=false）——跟 appointment 同一種「明確給了才動」判斷，引擎只執行
		# AI 已經決定好的金額，不自己另外骰一個數字出來
		var tip_data: Variant = data.get("tip")
		if allow_perform_tip and tip_data != null and bool(tip_data.get("give", false)):
			_apply_perform_tip(int(tip_data.get("amount", 0)))

		if had_pending_persuade:
			_resolve_pending_persuade(data)

		_reevaluate()

		final_result = {
			"ok": true,
			"triggered": true,
			"reasoning": data.get("reasoning", ""),
			"inner_monologue": data.get("inner_monologue", ""),
			"tasks_added": tasks_added,
		}

	# 這次送出的信封已經把 _fact_lines_summary() 讀到的事實句清空，但等待
	# 回應期間（真的打網路，數百毫秒到數十秒）可能有新事件（#402／#407 的
	# spotted／noise_heard）把新的一句排進 _pending_reaction_lines——不管
	# 這次回應本身是過期世代被丟棄、失敗、還是成功，只要佇列還有東西沒送出，
	# 就該立刻補問一次，不然這句事實句只能等下一次「剛好」有別的理由觸發
	# 決策才會被看到，等於這次事件實質上被吃掉。fire-and-forget，不 await：
	# 呼叫端不需要等這次補問完成才能拿到目前這輪的結果。
	#
	# 要放在這裡（所有分支都處理完、_resolve_pending_persuade() 也清空過
	# _pending_persuade 之後），不能放在 await 剛結束就立刻補——補發的請求
	# （fire-and-forget，會立刻同步執行到它自己的第一個 await 點）會在原本
	# 這輪還沒真正把 _pending_persuade 解析掉之前就搶先讀到同一筆記錄，兩輪
	# 各自認定「這輪有待回應的說服」、各自問一次模型，等原本這輪稍後才真的
	# 清空 _pending_persuade，補發那輪的回應到達時會讀到空字典，若那輪也判斷
	# persuaded=true，會用空白內容（reason 空字串等）誤寫一筆記憶（CodeRabbit
	# review，PR #433）
	#
	# 還要檢查 llm_decision_enabled：這一輪在途時如果被 debug_set_llm_decision(false)
	# 關掉，原本這輪的回應會因世代過期被丟棄（走 final_result 的過期分支），
	# 但 _pending_reaction_lines 不會因此變空——不額外檢查旗標的話，決策已經
	# 被關掉了還是會補送一次多餘的請求，白白消耗配額（CodeRabbit review，PR #433）
	if llm_decision_enabled and not _pending_reaction_lines.is_empty():
		_request_next_decision()

	return final_result

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

## 存檔還原用的形狀檢查（CodeRabbit review 抓到）：只接受包含
## with／location／game_time／game_time_minutes 且型別正確的 Dictionary，
## 其餘一律當作沒有約定——_process_appointment() 每分鐘都直接讀這幾個欄位，
## 一份形狀不對的存檔（例如空 Dictionary）會在讀檔後的下一個 tick 就出錯。
## reminder_sent／waiting_since／plan_id 不在這裡檢查：三者都是引擎自己
## 記帳用的階段旗標，_process_appointment()／_clear_appointment_plan_entry()
## 讀取時本來就用 .get() 給預設值，缺了也不會出錯
static func _is_valid_appointment_shape(data: Dictionary) -> bool:
	if not data.get("with") is String or (data["with"] as String).is_empty():
		return false
	if not data.get("location") is String or (data["location"] as String).is_empty():
		return false
	if not data.get("game_time") is String or (data["game_time"] as String).is_empty():
		return false
	var minutes: Variant = data.get("game_time_minutes")
	return minutes is int or minutes is float

## 移除目前 _appointment 對應的 _today_plan 摘要（CodeRabbit review 抓到）：
## 覆蓋、赴約成功、爽約、等待逾時都是「這筆約定結束了」，_apply_appointment()
## 產生的那筆摘要不該繼續留著顯示成一筆永遠沒做完的意圖，也不該讓
## _today_plan_needs_new_goal() 誤判「還有事沒做完」。呼叫端要在真的清掉／
## 換掉 _appointment 之前呼叫這個，用 plan_id 精準比對只移除那一筆——今日
## 計畫可能同時有別的、跟約定無關的項目，不能整批清
func _clear_appointment_plan_entry() -> void:
	if _appointment == null:
		return
	var plan_id: Variant = _appointment.get("plan_id")
	if plan_id == null:
		return
	for i in range(_today_plan.size() - 1, -1, -1):
		if _today_plan[i].get("id") == plan_id:
			_today_plan.remove_at(i)
			return

## 套用一筆新約定（#479，《10》§5.5）。整筆取代，不跟舊約定合併——跟
## _apply_today_plan() 同一種「重寫」語意，同時間只有一筆有效，換新的之前先
## 清掉舊約定留下的 today_plan 摘要（見 _clear_appointment_plan_entry()）。
## 同步把新約定併入 _today_plan 顯示（《10》§5.5「產生約定時，引擎自動將該筆
## 約定併入 today_plan 顯示，不另外詢問 AI」）——這裡直接 append 一筆，不透過
## update_plan 那套「整份取代」機制，兩件事各自獨立
func _apply_appointment(data: Dictionary) -> void:
	_clear_appointment_plan_entry()
	_next_plan_id += 1
	var plan_id := _next_plan_id
	_appointment = {
		"with": data.get("with", ""),
		"location": data.get("location", ""),
		"game_time": data.get("game_time", ""),
		"game_time_minutes": int(data.get("game_time_minutes", 0)),
		"reminder_sent": false,
		"waiting_since": -1,
		"plan_id": plan_id,
	}
	_today_plan.append({
		"id": plan_id,
		"text": "跟 %s 約在「%s」見面（%s）" % [
			_appointment["with"], _appointment["location"], _appointment["game_time"]
		],
		"is_done": false,
	})

## 絕對分鐘數轉「HH:MM」，跨日只留當天時分——爽約／等待事實句的措辭跟《10》
## §5.5 的範例（「等到 12:30」）同一種只講時分不講第幾天的簡短度
static func _format_clock(total_minutes: int) -> String:
	var minute_of_day := total_minutes % 1440
	return "%02d:%02d" % [minute_of_day / 60, minute_of_day % 60]

## 真的把打賞的錢從自己身上轉給表演者（#575）。引擎只執行 AI 已經決定好的
## amount，不自己另外算——但「錢夠不夠」是這個世界的物理限制，不是 AI 決策
## 的一部分，量到不夠付時夾成「有多少給多少」，不透支成負債（跟 buy_from()
## 「錢不夠就整筆拒絕」不同：打賞不是一手交錢一手交貨的交易，AI 已經表態
## 要給，量力而為比整包作廢更貼近「打賞」這個行為的精神）。金額 <= 0（含
## amount 驗證失敗被夾成 0 的 give=false 情形，理論上不會走到這裡，見呼叫端
## 的 give 判斷，這裡多一層防呆）直接不動作
func _apply_perform_tip(amount: int) -> void:
	if amount <= 0 or inventory == null:
		return

	var performer := _find_character_by_id(_tip_target_id)
	if performer == null or not is_instance_valid(performer) or not performer.is_performing():
		return
	if performer.inventory == null:
		return

	var affordable := mini(amount, inventory.get_money())
	if affordable <= 0:
		return
	if inventory.spend(affordable) != Inventory.MONEY_OK:
		return

	performer.inventory.add_money(affordable)
	_push_daily_event(
		"你打賞了 %s %d 元。" % [performer.character_name, affordable], [performer.character_id]
	)
	# 表演者這一側也要留一句事實句（CodeRabbit review 抓到）：不然表演者的
	# AI 完全不知道自己被打賞過，睡前反思／下一次決策都讀不到這件事。跟
	# give_to() 對收禮方的對稱記錄同一個道理。Player 不是 Agent，沒有
	# _push_daily_event()，只有對方是 Agent 才記
	if performer is Agent:
		(performer as Agent)._push_daily_event(
			"%s 打賞了你 %d 元。" % [character_name, affordable], [character_id]
		)

## 爽約通知（#479，《10》§5.5）。睡眠中先暫存，交給 _on_time_changed() 的
## 「剛睡醒」分支補送（見那裡的說明）——《10》§5.5 原文「爽約方若當時處於
## 睡眠或昏迷，改為醒來後首次決策時給予」，本版死亡／昏迷狀態機尚未接上
## （見 #379），先只處理睡眠這一種
func _notify_appointment_broken(now_minutes: int) -> void:
	var line := "現在是%s，你和 %s 約好在「%s」見面，但你人不在那裡。" % [
		_format_clock(now_minutes), _appointment["with"], _appointment["location"]
	]
	if current_state == "sleep":
		_appointment_broken_pending_line = line
	else:
		_pending_fact_lines.append(line)
	_clear_appointment_plan_entry()
	_appointment = null

## 約定機制的每分鐘檢查（#479，《10》§5.5）。跟 _apply_action_recovery() 一樣
## 掛在 GameClock.time_changed，在 _reevaluate() 之前跑。三個時點依序檢查：
##   1. 約定前 30 分鐘：提醒事實句（只給宣告方，見 _apply_appointment()）
##   2. 約定時間到：自己不在場＝爽約，立刻（或睡醒後）通知；在場則進入等待
##   3. 等待期滿（+30 分鐘）：對方仍沒出現才通知「等到」；出現了就悄悄結束，
##      不用另外通知——《10》§5.5 沒有規定「赴約成功」要給事實句
## 三種通知都走 _pending_fact_lines，跟《10》§5.2「暫存後於下一次決策一併
## 給予」同一套既有機制，不另開一條路。
##
## 「單方面宣告的約定」（《10》§5.5）不需要額外處理：這整個函式只讀
## self._appointment，未答應的一方從沒呼叫過 _apply_appointment()，自然
## 不會收到任何提醒——不對稱本來就是設計本身，不是這裡要補的邊界情況
func _process_appointment(now_minutes: int) -> void:
	if _appointment == null:
		return
	var appointment: Dictionary = _appointment
	var deadline := int(appointment["game_time_minutes"])
	var with_name := str(appointment["with"])
	var location := str(appointment["location"])

	# reminder_sent／waiting_since 一律用 .get() 讀，不用 []：這兩個是引擎自己
	# 記帳用的階段旗標，_apply_appointment() 產生的 Dictionary 一定有，但這裡
	# 不能假設——GDScript 對 Dictionary 缺 key 的 [] 存取是執行期錯誤，會直接
	# 中斷整個決策迴圈，親自用 game_eval 灌一份缺這兩個欄位的資料重現過
	# （不是理論上的疑慮）。跟 _is_valid_appointment_shape() 只驗證 AI 會填的
	# 那四個欄位是同一個立場：這兩個欄位缺席就當作「還沒開始」，不因此整包
	# 拒絕
	if not appointment.get("reminder_sent", false) and now_minutes >= deadline - APPOINTMENT_REMINDER_MINUTES_BEFORE:
		appointment["reminder_sent"] = true
		_pending_fact_lines.append("你和 %s 約好%s在「%s」見面。" % [
			with_name, str(appointment["game_time"]), location
		])

	if int(appointment.get("waiting_since", -1)) < 0:
		if now_minutes < deadline:
			return
		if _actual_place_of(self) != location:
			_notify_appointment_broken(now_minutes)
			return
		appointment["waiting_since"] = now_minutes
		return

	# 等待階段：對方出現在同一地點就算赴約成功，悄悄結束，不用另外通知
	var other := _find_character_by_name(with_name)
	if other != null and _actual_place_of(other) == location:
		_clear_appointment_plan_entry()
		_appointment = null
		return

	if now_minutes >= deadline + APPOINTMENT_WAIT_MINUTES:
		_pending_fact_lines.append("你在「%s」等到%s，%s 沒有出現。" % [
			location, _format_clock(deadline + APPOINTMENT_WAIT_MINUTES), with_name
		])
		_clear_appointment_plan_entry()
		_appointment = null

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
		var dedup_key: String = str(task.get("action", "")) + "|" \
			+ str(params.get("target", params.get("place", "")))
		if task.get("action", "") == "buy":
			dedup_key += "|" + str(params.get("item_id", ""))

		# dedup：同一個 action+target/place 新的覆蓋舊的，不並存兩筆——
		# 見 [[行程佇列與任務仲裁]]「池子的守則」，沒有這條的話被搭話幾次
		# 之後池子就會塞滿重複的「回訪某某」
		for i in range(_tasks.size() - 1, -1, -1):
			if _tasks[i].get("source", "") != "llm":
				continue
			var existing_params: Dictionary = _tasks[i].get("params", {})
			var existing_key: String = str(_tasks[i].get("action", "")) + "|" \
				+ str(existing_params.get("target", existing_params.get("place", "")))
			if _tasks[i].get("action", "") == "buy":
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
		_clear_current_task(false)

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

## 表演結束後同理（#575）：跟 eat／drink 這種「呼叫一次就完成」不同，perform
## 是長動作，_pursue_perform_task() 開始表演成功後就先返回，不清任務——這裡
## 才是真正的收尾點（_run_perform() 協程跑完 PERFORM_DURATION_MINUTES 後呼叫）。
## llm 來源才移除任務，跟 eat／drink 收尾同一套規則：schedule 來源的任務不能
## 被移除，得靠 window 自然退場。
##
## completed=false（被 force_interrupt() 打斷，CodeRabbit review 抓到）比照
## _on_work_finished() 對半途離開工作站的處理：只留輕量事實句，不重複清任務／
## 問下一次決策——force_interrupt() 呼叫完 _end_perform(false) 之後緊接著會
## 呼叫 _on_action_interrupted()，那邊已經統一做了 _clear_current_task()／
## _request_next_decision()／_reevaluate()，這裡若也做一次，_request_next_decision()
## 會在同一次中斷裡被觸發兩次
func _on_perform_finished(completed: bool) -> void:
	if not completed:
		_push_daily_event("你的表演被打斷了")
		return
	if _current_task.get("source", "") == "llm":
		_remove_task(_current_task.get("id", ""))
	# 表演結束前殘留的 place-pursuit 狀態要一起清（CodeRabbit review 抓到）：
	# 不清的話，下一筆真正的 place 任務會誤讀到這場表演之前留下的
	# _pursued_place／_pursuit_done，把還沒抵達新地點誤判成「已經到過了」
	_pursued_place = ""
	_pursuit_done = false
	_clear_current_task(true)
	_push_daily_event("你的表演結束了。")
	if llm_decision_enabled and not _awaiting_decision:
		_request_next_decision(_today_plan_needs_new_goal())
	_reevaluate()

# 被攻擊等外部事件強制中斷（《02》§3 中斷規則）時的收尾。跟
# _finish_task_and_request_next() 類似但刻意不 _remove_task()——這不是任務
# 做完或判定失敗，只是被打斷，還在池子裡的話下次重新仲裁時值得重新考慮要不要
# 繼續做（例如原本在走去做別的事，被打斷後可能還是想繼續走過去）
func _on_action_interrupted() -> void:
	# 死屍不重新規劃（CodeRabbit review 抓到）：_die() 這次改呼叫
	# force_interrupt() 收尾在途的工作／對話，會連帶跑到這裡——沒有這個
	# return，下面的 _request_next_decision()／_reevaluate() 會立刻幫死屍
	# 問出新任務，等於繞過 _on_time_changed() 那道 is_dead 判斷。
	# 順便清掉目前任務與追逐狀態（CodeRabbit review 抓到）：長動作 checkpoint
	# 請求若剛好還在飛，_request_checkpoint_decision() 回來時只比對世代跟
	# task id，不清的話這兩者都還對得上，會讓 _abandon_task_from_checkpoint()
	# → _finish_task_and_request_next() 對死者發出新的決策請求；清空後
	# task id 對不上，過期回應會被正確丟棄，死亡角色的狀態快照也回到 idle
	if is_dead:
		_current_task = {}
		current_place = ""
		current_state = "idle"
		_pursued_place = ""
		_pursuit_done = false
		return

	# 清空前先存一份快照——character.gd::attack() 的呼叫順序是
	# force_interrupt()（跑到這裡，把 current_place 清空）先於 _on_attacked()
	# （記事實句），直接讀 current_place 的話 _on_attacked() 永遠拿到空字串
	# （CodeRabbit review 抓到）。#426：改存即時座標反查的結果，不是
	# current_place 本身——force_interrupt() 這裡 stop_moving() 剛執行完、
	# 位置還沒被任何東西改變，正是「事情發生當下人真正站在哪」，比
	# current_place（任務目的地，移動途中被攻擊時還沒走到）準確
	_place_before_interrupt = _resolve_actual_place()
	_pursued_place = ""
	_pursuit_done = false
	_clear_current_task(false)
	if llm_decision_enabled and not _awaiting_decision:
		_request_next_decision(_today_plan_needs_new_goal())
	_reevaluate()

# 被攻擊記成事實句（純客觀事件，不貼「這很可怕」之類的主觀標籤——見 CLAUDE.md
# 「遊戲機制規格：AI 自主性自檢」），讓下次決策／睡前反思能讀到發生過這件事。
# 地點用 _on_action_interrupted() 存的快照，不是這裡當下的 current_place——
# 見 _push_daily_event() 的 location_override 說明
func _on_attacked(attacker: Character) -> void:
	super._on_attacked(attacker)
	_push_daily_event(
		"你被 %s 攻擊了" % attacker.character_name, [attacker.character_id], _place_before_interrupt
	)

# 被救助記成事實句，跟 _on_attacked() 同一個理由（純客觀事件，不貼標籤，見
# CLAUDE.md「遊戲機制規格：AI 自主性自檢」）。搬運中角色不是自己在移動，
# 不需要比照 _on_attacked() 那樣取中斷前快照，直接用 current_place 就是對的
func _on_rescued(hauler: Character) -> void:
	_push_daily_event("你被 %s 救助了，脫離昏迷" % hauler.character_name, [hauler.character_id])

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


# ---- 存檔 ----

# #381：墓碑「一份墓一筆」欄位裡屬於 Agent 自己的那兩個
# （words_to_creator/life_highlights），比照 base 的欄位風格直接存讀，不建
# SPEC——兩個欄位型別互不相同（string/array），硬套 Stats.SPEC 那種同型別、
# 走訪產生數值的模式沒有意義；SPEC 那條規則要保的是「加一項不用到處改」，
# 這裡欄位數量固定且各自的存讀邏輯本來就不同。last_words 是 Character 自己的
# 欄位（#379，Player 也需要），存讀交給 super()，這裡不重複處理。
# epitaphs（第四個欄位，一對多）不在這裡，走 SQLite，見 #382
#
# today_plan（#350）是跨天的承諾——「今天打算做這幾件事」——跟 current_goal
# 那種瞬時念頭不同，重開遊戲不該讓它憑空消失（見 note/技術/存檔.md 的既有
# 拍板；current_goal 刻意不存，這裡不要一起加進去）。id 是本機重新配發的
# 序號（見 _apply_today_plan() 的說明），跟存檔格式無關，原樣存回沒有問題——
# 下一次 _apply_today_plan() 呼叫本來就會整份取代並重新配發
func get_save_data() -> Dictionary:
	var data := super()
	data["words_to_creator"] = words_to_creator
	data["life_highlights"] = life_highlights.duplicate()
	data["today_plan"] = _today_plan.duplicate(true)
	data["appointment"] = _appointment.duplicate(true) if _appointment is Dictionary else null
	return data


func load_save_data(data: Dictionary) -> void:
	super(data)
	if data.has("words_to_creator"):
		var raw_words_to_creator: Variant = data["words_to_creator"]
		words_to_creator = raw_words_to_creator if raw_words_to_creator is String else ""
	# last_words 已由 super(data) 呼叫的 Character.load_save_data() 處理完畢
	# ——is_dead=true 時從存檔還原、is_dead=false 時重設回 null（見該函式
	# if/else 兩個分支），這裡不重複讀取——之前重複讀取會把 super() 剛處理好的
	# null 又轉成空字串，蓋掉「來不及開口」跟「AI 決定不說」的語意區分
	var raw_highlights: Variant = data.get("life_highlights", [])
	life_highlights.clear()
	if raw_highlights is Array:
		for item in raw_highlights:
			if item is String:
				life_highlights.append(item)

	# 讀檔當下若有一份決策請求還在飛（debug 主控台 load 指令對執行中的角色
	# 呼叫這裡），那份回應是問著載入前的舊狀態，不能讓它晚到之後用
	# _apply_today_plan() 蓋掉剛載入的 today_plan——跳世代讓
	# _request_next_decision() 收到回應時自己認出這是過期世代整包丟棄，
	# 跟 debug_set_llm_decision() 的翻轉世代同一招。_plan_update_requested
	# 也一併清掉：那是舊決策留下的「下次讓我改」許可，不該帶進載入後的狀態。
	# 遞增 _plan_update_epoch 確保過期請求不會在還原 had_plan_update_requested 時
	# 重新授予已經被載入清除的許可
	_decision_generation += 1
	_plan_update_requested = false
	_plan_update_epoch += 1

	# 已經排隊但還沒被下一輪決策消費掉的語意檢索結果也要清（CodeRabbit
	# review 抓到）：_queue_recalled() 的世代比對只擋得住「讀檔當下還在飛」
	# 的查詢，擋不住「讀檔前就已經排進 _pending_recalled、但還沒被
	# _recalled_summary() 讀走」的舊結果——不清的話下一次 next_line()／
	# _request_next_decision() 照樣會把讀檔前的記憶內容送進讀檔後的提示詞
	_pending_recalled.clear()

	# 只在資料裡真的有 today_plan 這個 key 時才覆寫——跟 character.gd 的
	# personality 同一個「省略 key＝不動」語意。沒有這條防呆的話，讀一份
	# 沒有 today_plan 欄位的存檔（例如舊格式、或只想局部更新其他欄位的
	# 呼叫端）會把角色現有的今日計畫整包清空，不是「維持原樣」
	# （CodeRabbit review 抓到）
	if data.has("today_plan"):
		_today_plan.clear()
		var raw_plan: Variant = data.get("today_plan", [])
		if raw_plan is Array:
			for item in raw_plan:
				if item is Dictionary:
					_today_plan.append((item as Dictionary).duplicate(true))

	# appointment（#479）：跟 today_plan 同一個「省略 key＝不動」語意。存檔裡
	# 的 null（沒有約定）跟合法的 Dictionary 都要能還原，形狀不對（例如存檔
	# 損毀留下的 {}）一律當沒有約定，不是照單全收——_process_appointment()
	# 每分鐘都直接讀 game_time_minutes／with／location，形狀不對的資料撐不
	# 到下一個 tick 就會出錯（CodeRabbit review 抓到）
	if data.has("appointment"):
		var raw_appointment: Variant = data.get("appointment")
		if raw_appointment is Dictionary and _is_valid_appointment_shape(raw_appointment as Dictionary):
			_appointment = (raw_appointment as Dictionary).duplicate(true)
		else:
			_appointment = null
	_appointment_broken_pending_line = ""

# 第一次看到某個陌生人的反應。
#
# 認識的人不算 —— 每天上班都會遇到的同事不會讓人「！」。
# 判斷放在這裡而不是 Vision 裡：感知回報「看到誰」，要不要有反應是人格與關係的事。
#
# llm_decision_enabled 開著時（#402）：不寫死反應，把事件記成事實句排進
# 下一次決策的 fact_lines，並比照 _on_attacked()／_on_action_interrupted()
# 立刻問一次模型，讓角色幾乎即時反應——要不要停下來、停多久、要不要說話，
# 都交給模型的 tasks[] 決定，這裡不再自己 say()／stop_moving()。
#
# 但模型問不到結果時（逾時、驗證失敗、世代被作廢）不能讓角色完全沒反應——
# 退回寫死的「！」，跟 llm_decision_enabled 關著時同一套 fallback（CodeRabbit
# review 抓到：原本只看 llm_decision_enabled 決定路徑，問失敗時兩邊 fallback
# 都被跳過）。`_request_next_decision()` 回傳 `triggered=false` 代表這次只是
# 排進佇列（已經有一份決策在飛，見它自己的補問機制），不算失敗，不用退回
# 寫死反應——`triggered=true` 但 `ok=false` 才是真的問過但沒問到結果
func _on_spotted(other: Character) -> void:
	# 死屍不反應（CodeRabbit review 抓到）：_on_time_changed()／
	# _on_action_interrupted() 那道 is_dead 判斷擋不到這裡——這是 vision.gd
	# 訊號直接觸發的外部事件回呼，死屍仍會被場上其他角色「第一次注意到」，
	# 沒擋的話會 say() 台詞、甚至問一次 LLM 決策
	if is_dead or is_in_conversation():
		return

	# 《03》§7 觸發時機表「遇到未在 L1 出現過的角色」（issue #571）：故意放在
	# _noticed 的早退之前（CodeRabbit review 抓到：原本放在 _noticed 早退
	# 之後，導致這個檢查一輩子只會在「第一次見到這個人」那一次跑到——_noticed
	# 是終身只設一次、不會清除的表，跟這裡要問的「最近 8 條記憶視窗裡有沒有
	# 這個人」是完全不同的時間尺度：同一個人可能很久以前見過、_noticed 早就
	# 設過，但這幾天都沒再想起，理應每次符合這個條件都值得重新檢索，不是只有
	# 生涯第一次見面那次）。跟下面 has_met() 問的「這輩子見沒見過」是兩個
	# 不同的條件。call-and-forget（不 await，CodeRabbit review 抓到先前
	# 誤加的 await 會拖住這裡，延誤下面 has_met() 判斷與跟丟／反應流程）
	if not _seen_in_l1(other.character_name) and not _l3_recalled_for.has(other.character_id):
		_l3_recalled_for[other.character_id] = true
		_queue_recalled(other.character_name)

	if _noticed.has(other.character_id):
		return
	_noticed[other.character_id] = true

	if relationships != null and relationships.has_met(other.character_id):
		return

	_push_daily_event("你第一次注意到 %s" % other.character_name, [other.character_id])

	if llm_decision_enabled:
		_queue_reaction_fact_line(
			"你第一次注意到 %s，要不要停下來、要不要說些什麼，由你自己決定" % other.character_name
		)
		var result := await _request_next_decision()
		if is_dead:
			return
		if result.get("triggered", false) and not result.get("ok", false):
			await _react_to_spotted_fallback()
		return

	await _react_to_spotted_fallback()

# 陌生人反應的寫死版本，兩種情況共用：排程模式（沒有 LLM 可問）、以及
# llm_decision_enabled 開著但這次決策問不到結果
func _react_to_spotted_fallback() -> void:
	# broadcast=false：這是系統 fallback 泡泡，不是角色真的說了什麼，不該被
	# 3 格內的人當成「聽到的對話」——同 _on_noise_heard()／_on_speech_heard()
	# 的理由，見 character.gd::say() 的說明（CodeRabbit review 抓到，PR #674）
	say(L10n.t("DLG_SURPRISE"), false, false)
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

# 視野裡跟丟某個人（issue #405）。
#
# 不分認不認識都處理（2026-08-24 拿掉原本的 has_met() 篩選——CLAUDE.md
# 「AI 自主性自檢」認定那是引擎替 AI 判斷「這件事不重要」，AI 連表態機會
# 都沒有；「認識的人本來就常常走出視野」是頻率論證，不是重要性論證，兩者
# 不能互相替代，見該次全專案盤點的審查結論）。事實句一律排給模型，
# 要不要在意、在意多少交給 AI 自己判斷。
#
# _lost_reacted 是量級控制，不是相關性判斷：同一人一天只觸發一次跟丟反應，
# 避免頻繁進出視野的人（不論認不認識）洗版事實句、把 LLM 呼叫量拖爆。
# 每天由 _on_day_changed() 清空，不是永久只給一次——拿掉 has_met() 篩選後
# 若還維持終身只觸發一次，天天見面的熟人實質上會跟沒接這個訊號一樣。
# _noticed 不在這裡清除——見 note/技術/視覺感測.md 已驗證的「走出視野再走
# 回來不會重複驚訝」，跟丟不代表要重新觸發陌生人反應。
#
# 不像 _on_spotted／_on_noise_heard 有寫死的 fallback 台詞可退——「跟丟了」
# 沒有通用的驚呼可以套，schedule 模式（llm_decision_enabled 關著）就不處理，
# 只在有 LLM 可問時把事實句排進下一次決策，要不要有反應交給模型自己判斷
func _on_lost(other: Character) -> void:
	# 離開視野就重置這次遭遇的 L3 觸發記錄——走出去再走回來要能重新觸發，
	# 跟下面 llm_decision_enabled 關著時就 return 的邏輯無關，這裡不受那個
	# 旗標影響，永遠先清
	_l3_recalled_for.erase(other.character_id)

	if is_in_conversation():
		return
	if not llm_decision_enabled:
		return
	if _lost_reacted.has(other.character_id):
		return
	_lost_reacted[other.character_id] = true

	_queue_reaction_fact_line("你看不到 %s 了，要不要有反應由你自己決定" % other.character_name)
	await _request_next_decision()

# 範圍內有人發出聲音（見 character.gd 的 make_noise()）。
# 跟 _on_spotted 不同，這裡不記錄「已經反應過」——聲音是一次性事件，
# 每次都該有反應，不是像陌生人那樣「見過一次就不再驚訝」
#
# llm_decision_enabled 開著時（#407）：同 _on_spotted() 的做法，事實句
# 排隊＋立刻問一次模型，不寫死冒 !?——問不到結果時一樣退回寫死反應，
# 理由跟 _on_spotted() 的說明相同
func _on_noise_heard(_source: Character) -> void:
	# 死屍不反應（CodeRabbit review 抓到），同 _on_spotted() 的理由——這是
	# character.gd::make_noise() 直接觸發的外部事件回呼，_on_time_changed()
	# 那道 is_dead 判斷擋不到這裡
	if is_dead or is_in_conversation():
		return

	if llm_decision_enabled:
		_queue_reaction_fact_line("你聽到一個聲音，要不要有反應由你自己決定")
		var result := await _request_next_decision()
		if is_dead:
			return
		if result.get("triggered", false) and not result.get("ok", false):
			say(L10n.t("DLG_NOISE_ALERT"), false, false)
		return

	# fallback（排程模式，沒有 LLM 可問）：維持原本寫死的 !? 反應
	say(L10n.t("DLG_NOISE_ALERT"), false, false)

# 範圍內有人說話（一般聊天輸入框或 talk_to() 對話，見 character.gd::say()
# 的廣播，issue #669）。跟 _on_noise_heard() 同一種感測/反應分離，差別是
# 這裡帶了實際講的內容——《07》§3「聽覺（一般說話）3 格」定義的本來就是
# 「聽得到的對話」，內容是客觀事實，要不要反應交給模型自己判斷
#
# 排程模式（llm_decision_enabled 關著）刻意不冒 !?，跟 _on_noise_heard() 不同：
# 一般說話遠比 make_noise()／shout 頻繁（玩家聊天、talk_to() 每一句都算），
# 排程模式又沒有決策迴圈會消費 _pending_reaction_lines，硬套 noise 那套寫死
# 反應只會讓排程模式的 NPC 對著每一句路過的對話狂冒 !?。這只是排程模式下
# 沒有「決策者」時的視覺呈現選擇，不影響 llm_decision_enabled 開著時送給
# 模型的事實內容（下面完整保留），跟原則二要保護的「事件有沒有讓 AI 知道」
# 是兩回事；llm_decision_enabled 開著但這次問不到結果（逾時／驗證失敗）時，
# 仍比照 _on_noise_heard() 退回寫死反應，不能讓角色看起來完全沒反應
func _on_speech_heard(source: Character, line: String) -> void:
	if is_dead or is_in_conversation():
		return

	if llm_decision_enabled:
		_queue_reaction_fact_line("你聽到附近的 %s 說：『%s』，要不要有反應由你自己決定" % [source.character_name, line])
		var result := await _request_next_decision()
		# await 期間對方可能已經走 talk_to() 建立了新對話（見 character.gd
		# 該函式），這裡的 fallback 不能無條件冒 !?，會插進正在顯示的
		# 對話泡泡（CodeRabbit review 抓到，PR #674）
		if is_dead or is_in_conversation():
			return
		if result.get("triggered", false) and not result.get("ok", false):
			say(L10n.t("DLG_NOISE_ALERT"), false, false)

# 把一次性事件（看到陌生人、聽到聲音）排進下一次決策的事實句佇列
# （#402／#407）。見 _pending_reaction_lines 的欄位說明
func _queue_reaction_fact_line(line: String) -> void:
	_pending_reaction_lines.append(line)

## 掃視野內有沒有人正在表演（#575），每個遊戲分鐘跟其他 _on_time_changed()
## 收尾一起跑。跟 _on_spotted() 不一樣：後者只在「第一次看到這個人」那一刻
## 觸發一次，沒辦法涵蓋「早就認識、但現在剛好開始表演」這種情況，所以另外
## 開一輪獨立的偵測，不共用 _noticed 那張表。
##
## 每個人的表演只問一次（_tip_prompted_performers 記住已經問過的 id），問完
## 之後若對方還在表演，不會每分鐘重問一次——跟 _noticed 的「問過就不再問」
## 同一種態度，但這裡是「這一場表演問過就不再問」，對方一旦不再表演（結束、
## 或走出視野）就從表裡移除，讓下一場表演可以重新被注意到
func _scan_for_performers() -> void:
	if is_dead or not llm_decision_enabled or vision == null:
		# 整輪掃描都跳過時，_tip_prompted_performers 也要清空（CodeRabbit
		# review 抓到）：不清的話，某個表演者的舊標記會一直卡著——如果他
		# 這段跳過期間表演結束又重新開始一場新的，等掃描恢復時，下面
		# 「不再表演的對象從表裡移除」那段清理邏輯根本沒機會跑到，新的
		# 這場表演會被誤判成「已經問過」，永遠不會真的觸發打賞決策。這裡
		# 沒辦法在跳過時照常判斷誰還在表演（vision 可能是 null），乾脆全部
		# 清空，讓掃描恢復時當作全新一輪重新判斷。這三個跳過原因都是比較
		# 「終局」的狀態（死亡不會再掃、llm_decision_enabled 關掉短期內也不會
		# 再掃、vision 是 null 正常情況下不會發生），清空不會誤傷還在進行中的
		# 表演
		_tip_prompted_performers.clear()
		return

	if is_in_conversation():
		# 對話中不清空（CodeRabbit review 抓到）：跟上面三個不一樣，對話是
		# 暫時性狀態，不代表期間所有表演都結束了——清空的話，對方在對話期間
		# 仍在同一場表演，對話結束後下一次掃描會誤判成「還沒問過」，同一場
		# 表演重新觸發一次打賞決策，變成收到兩次打賞。標記留著，等對話結束、
		# 真正掃描恢復時，下面「不再表演的對象從表裡移除」那段清理邏輯自然會
		# 處理掉真的已經結束的表演
		return

	var visible := vision.get_visible_characters()
	var still_performing := {}
	for other in visible:
		if not is_instance_valid(other) or other == self:
			continue
		var performer := other as Character
		if performer == null or not performer.is_performing():
			continue

		still_performing[performer.character_id] = true
		if _tip_prompted_performers.has(performer.character_id):
			continue
		# 已經有一通決策在飛（CodeRabbit review 抓到）：_tip_target_id
		# 只有一個欄位，同一輪掃到多個表演者時，這裡若不擋，後面的表演者
		# 會在還沒真的送出請求前就搶先把 _tip_target_id 蓋掉，等第一通回應
		# 回來時 _apply_perform_tip() 就會把錢轉給搶跑的那個人，不是真正
		# 決策問的對象；標記成「問過」也要跟著延後，不然這個人這場表演
		# 永遠不會被真的問到，下個遊戲分鐘的 scan 會再試一次
		if _awaiting_decision:
			continue

		_tip_prompted_performers[performer.character_id] = true
		_tip_target_id = performer.character_id
		_queue_reaction_fact_line(
			"你看到 %s 正在表演，要不要打賞、打賞多少由你自己決定。" % performer.character_name
		)
		_request_next_decision(false, false, true)

	# 不再表演（或走出視野）的對象從表裡移除，讓下一場表演可以重新觸發詢問
	for id in _tip_prompted_performers.keys():
		if not still_performing.has(id):
			_tip_prompted_performers.erase(id)

## 《03》§7 語意檢索的四個觸發點（_on_spotted()／_note_place_visited()／
## hear_god_stone()／request_sleep_reflection()）共用這個函式：await
## Memory.search_l3()，把結果轉成字串排進 _pending_recalled。查無結果時放
## PromptBuilder.L3_RECALL_FALLBACK 兜底句，不是留空陣列——這樣下一輪
## envelope 的 context.memory.recalled 一律有內容可讀，不必讓 PromptBuilder
## 額外判斷「這次到底有沒有觸發過檢索」
func _queue_recalled(query: String) -> void:
	if memory == null:
		return
	# await 之前先記住世代（CodeRabbit review 抓到）：跟 _request_next_decision()
	# 等既有 my_generation 比對同一招——load_save_data() 讀檔時會遞增
	# _decision_generation，這裡如果不比對，讀檔前排出去、讀檔後才回來的
	# 語意檢索結果會混進讀檔後全新的狀態裡，變成一句跟目前記憶／人格對不上的
	# 過期內容。still_valid 傳給 search_l3()（CodeRabbit review 再抓到一次）：
	# 世代比對本身不夠，mark_retrieved() 這個改動 decay_value 的副作用發生在
	# search_l3() 內部（await 結束後、回傳文字之前），這裡才檢查世代已經
	# 太晚——still_valid 讓 search_l3() 在真的執行排序／mark_retrieved()
	# 之前先問一次，過期就直接跳過，不留副作用
	var my_generation := _decision_generation
	var still_valid := func() -> bool: return not is_dead and my_generation == _decision_generation
	var hits: Array[Dictionary] = await memory.search_l3(query, Memory.L3_SEARCH_MAX_RESULTS, still_valid)
	if is_dead or my_generation != _decision_generation:
		return
	if hits.is_empty():
		_pending_recalled.append(PromptBuilder.L3_RECALL_FALLBACK)
		return
	for hit in hits:
		_pending_recalled.append(str(hit.get("content", "")))

## 跟 _fact_lines_summary() 讀 _pending_reaction_lines 同一種「讀完即清」，
## 見 _pending_recalled 宣告處的說明
func _recalled_summary() -> Array[String]:
	var lines := _pending_recalled.duplicate()
	_pending_recalled.clear()
	return lines

## 《03》§7 觸發時機表「遇到未在 L1 出現過的角色」的判定：掃 memory.l1
## （固定 8 條的短期工作記憶視窗）每筆 content 字串裡有沒有出現這個角色的
## 顯示名字。跟 _noticed（本檔頂端，終身只驚訝一次的跟丟反應用途）是兩件
## 不同的事——_noticed 問的是「這輩子有沒有被嚇到過」，這裡問的是「最近 8 條
## 記憶視窗裡提過這個人嗎」。字面比對顯示名字是簡化判斷，《03》文件本身也把
## 整張觸發時機表標成「推測待確認」，不追求精準比對 character_id
func _seen_in_l1(character_display_name: String) -> bool:
	if memory == null:
		return false
	for entry in memory.l1:
		if str(entry.get("content", "")).contains(character_display_name):
			return true
	return false

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
## (#362) sleep 同時回復 stamina 與 wakefulness，資料結構改成陣列以支持多個 stat
const ACTION_RECOVERY := {
	"sleep": [
		{"stat": "stamina", "amount": 0.6},
		{"stat": "wakefulness", "amount": 50},
	],
	"nap": [
		{"stat": "stamina", "amount": 0.4},
		{"stat": "wakefulness", "amount": 20},
	],
	"rest": [
		{"stat": "stamina", "amount": 0.2},
	],
	"wash": [
		{"stat": "hygiene", "amount": 0.3},
	],
}

# 到了定點才開始回復——還在走去床邊的路上不算在睡覺。沒有指定地點的任務
# （LLM 完全可以只回 {"action": "rest"}）本來就原地做，is_moving() 一樣是 false，
# 不用另外分流
func _apply_action_recovery() -> void:
	if stats == null or is_moving():
		return
	var recovery_list: Array = ACTION_RECOVERY.get(current_state, [])
	if recovery_list.is_empty():
		return
	for recovery in recovery_list:
		stats.add(recovery["stat"], recovery["amount"])
		# 若是回復 stamina 的動作，立即同步 exhausted 狀態，避免延遲至下一個 tick
		if recovery.get("stat") == "stamina":
			_update_exhausted_condition()

func _on_time_changed(_hour: int, _minute: int) -> void:
	# 死屍不再仲裁新任務（CodeRabbit review 抓到）：is_dead 只擋得住
	# _decide_velocity() 的移動輸出（見 _is_movement_locked()），沒擋住這裡——
	# 沒有這個 return，死屍每個遊戲分鐘還是會被 _reevaluate_once() 重新仲裁，
	# 選中並執行不需要移動的任務（eat／drink／murmur／shout／attack／persuade），
	# 跟《規格書09》§1「石化・停留原地」的死亡定義矛盾。攻擊觸發死亡的唯一現行
	# 路徑已經在 attack()→force_interrupt() 那一刻收尾掉進行中的 work 協程
	# （見 force_interrupt() 說明），這裡不需要額外處理 work
	if is_dead:
		return

	# 先結算這一分鐘的回復，再重算要做什麼：反過來的話，剛被換掉的那筆任務
	# 會用新任務的 current_state 結算最後一分鐘
	_apply_action_recovery()
	if _pending_save_retry:
		_autosave_on_wake()
	_process_appointment(_now_minutes())
	_scan_for_performers()
	_reevaluate()

# 力竭時強制進入休息，直到 stamina 恢復
func _force_rest_until_recovered(now_minutes: int) -> void:
	# 如果已經在執行 exhaustion_rest synthetic task，繼續就好
	if not _current_task.is_empty() \
			and _current_task.get("id", "") == "exhaustion_rest" \
			and _current_task.get("source", "") == "reflex":
		return

	# 不是 exhaustion_rest 的話，強制切換成 rest。選中新任務前先停止移動、
	# 結束對話與工作，避免舊動作在強制休息期間繼續執行
	stop_moving()
	if is_in_conversation():
		leave_conversation()
	if is_working():
		_end_work(_current_workstation)
	# 表演中同理 is_working()（CodeRabbit review 抓到）：不結束的話 _performing
	# 會繼續是 true，_select() 換成 exhaustion_rest 之後，背景的 _run_perform()
	# 協程還在跑，跑完自然觸發 _on_perform_finished(true)，那時候 _current_task
	# 已經是 exhaustion_rest（不是真正的表演任務）——會誤把 exhaustion_rest
	# 收尾掉（_clear_current_task()），力竭恢復到一半被打斷，而且原本的
	# perform 任務還留在 _tasks 裡沒被清乾淨。_end_perform(false) 當作「被
	# 打斷」處理（不是正常表演完），呼叫端只會補一則事實句，不會動
	# _current_task，讓後面的 _select(rest_task) 接手一個乾淨的狀態
	if is_performing():
		_end_perform(false)

	var rest_task: Dictionary = {
		"id": "exhaustion_rest",
		"action": "rest",
		"params": {},
		"priority": 999,  # 最高優先級
		"window": null,  # 沒有時間窗限制
		"duration": 0.0,  # 由引擎決定何時結束（stamina 恢復時）
		"interruptible": false,  # 力竭期間不可被打斷
		"preconditions": [],
		"source": "reflex",  # 引擎強制執行，不是 LLM 決定
		"created_at": now_minutes,
		"expires_at": 0,
		"retries": 0,
	}

	_select(rest_task, now_minutes)

# 睡醒自動存檔（#427），失敗時記錄角色識別資訊並排一次下個遊戲分鐘的
# 補重試——原本 save_character() 的回傳值被直接丟掉，失敗就整批資料悄悄
# 遺失，跟 #427 本來要解決的問題是同一種事故（CodeRabbit review 抓到）
func _autosave_on_wake() -> void:
	if SaveService == null:
		return
	if SaveService.save_character(character_id, get_save_data()):
		_pending_save_retry = false
		return
	push_error("Agent %s（%s）睡醒自動存檔失敗，下個遊戲分鐘會補重試一次" % [
		character_name, character_id
	])
	_pending_save_retry = true

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
	# 死屍不重新仲裁（CodeRabbit review 抓到）：擋在 trampoline 這一層，一次
	# 涵蓋所有會走到這裡的路徑——_on_time_changed()、_on_action_interrupted()
	# 各自已經有 is_dead 判斷，但 _end_work() → Agent._on_work_finished() →
	# _reevaluate() 這條（work_at() 死亡當下同步被 force_interrupt() 收尾時
	# 觸發）沒有，漏了就會讓死屍立刻選中並執行新任務
	if is_dead:
		return

	if _reevaluating:
		_reevaluate_pending = true
		return

	_reevaluate_excluded_ids.clear()
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

	# 力竭解除後清理：角色不再具有 CONDITION_EXHAUSTED 且 _current_task 仍指向
	# exhaustion_rest synthetic task 時，清除 _current_task、current_place、
	# current_state 及相關追逐狀態，再繼續正常仲裁。這個 synthetic task 不在
	# _tasks 池子裡，不會被正常的過期掃描清掉，必須在這裡主動處理——條件比對
	# id 而不只是 source，避免以後其他 reflex 來源的任務被誤判成這個 synthetic
	# task 清掉
	if not _current_task.is_empty() \
			and _current_task.get("id", "") == "exhaustion_rest" \
			and _current_task.get("source", "") == "reflex":
		_current_task = {}
		current_place = ""
		current_state = "idle"
		_pursued_place = ""
		_pursuit_done = false
		# 重置各追逐狀態，以便正常仲裁能清楚地選擇下一個任務
		_talk_pursuit_stuck_ticks = 0
		_talk_pursuit_last_distance = INF
		_give_pursuit_stuck_ticks = 0
		_give_pursuit_last_distance = INF
		_attack_pursuit_stuck_ticks = 0
		_attack_pursuit_last_distance = INF
		_persuade_pursuit_stuck_ticks = 0
		_persuade_pursuit_last_distance = INF
		_bury_pursuit_stuck_ticks = 0
		_bury_pursuit_last_distance = INF

	# 剛睡醒的偵測要在這裡的任何選任務邏輯跑之前先記下「進來的時候是不是
	# 在睡」——選任務邏輯本身就可能把 current_state 從 sleep 換掉，這個
	# 函式結尾要拿它跟「換完之後」比較，才抓得到真正的轉換瞬間
	_was_sleeping = current_state == "sleep"

	# 長動作固定間隔檢查點（issue #336，《02》§3）：任務做到一半、每隔
	# LONG_ACTION_CHECKPOINT_INTERVAL 分鐘額外問一次「繼續」或「放棄」，跟下面
	# duration 到期的「做完了，問下一步」是兩個獨立的事件——這裡問的當下任務
	# 還沒做完，`elapsed < duration` 排除掉終點那一刻（那一刻交給下面那個分支
	# 處理，不重複問）。條件跟下面那個分支同一套（llm 來源、talk 任務排除），
	# 多加 _checkpoint_decision_pending 避免自己的請求還沒回來又觸發一次。
	# elapsed % INTERVAL == 0 不需要額外記「上次問過哪一分鐘」：_on_time_changed
	# 每個遊戲分鐘只呼叫一次，elapsed 每次重算剛好前進 1，同一個間隔倍數只會
	# 撞上一次
	# is_performing() 排除（CodeRabbit review 抓到）：perform 任務擲成功後
	# _current_task 會繼續留著（source 還是 "llm"），交給 Character._run_perform()
	# 背景協程跑滿 PERFORM_DURATION_MINUTES 後才由 _on_perform_finished() 收尾。
	# 這裡的檢查點／duration 完成判定是給「沒有自己收尾機制」的通用 llm 任務用的
	# 兜底邏輯，如果不排除表演中的任務，會在真正表演結束前就搶先問檢查點、甚至
	# 判定「做完了」觸發 _remove_task()／_request_next_decision()，跟
	# _on_perform_finished() 真正的收尾撞在一起
	if llm_decision_enabled and not _awaiting_decision and not _checkpoint_decision_pending \
			and _current_task.get("source", "") == "llm" \
			and _current_task.get("id", "") != _active_talk_task_id \
			and not is_performing():
		var elapsed := now_minutes - _current_task_started_at
		var duration := int(_current_task.get("duration", 0.0))
		if elapsed > 0 and elapsed < duration and elapsed % LONG_ACTION_CHECKPOINT_INTERVAL == 0:
			_request_checkpoint_decision(_current_task)
			# 檢查點不限於任務發起者（《02》§3 2026-08-16 擴充）：依附在這個長
			# 動作上的其他角色（目前唯一情形是被自己 haul 的目標，見
			# Character.get_checkpoint_dependents()）一併收到通知。問什麼選項、
			# 要不要因此發起自己的決策請求，是各自機制的責任（haul 的
			# struggle／shout／idle 見 #337），這裡只負責在檢查點時機把這件事
			# 通知到，不代問
			for dependent in get_checkpoint_dependents():
				if is_instance_valid(dependent):
					dependent.on_dependent_checkpoint(_current_task)

	# 事件驅動觸發：LLM 來源的目前任務做滿引擎套用過下限的 duration 就算完成，
	# 發起下一次決策請求。等待期間不 return——照樣往下跑完整套仲裁流程，
	# 從池子（schedule 任務、上一輪還沒被選中的 llm 任務）挑 fallback 頂著，
	# 不空等、不卡頓，是《10》§5.1 講的「天然容錯」
	if llm_decision_enabled and not _awaiting_decision \
			and _current_task.get("source", "") == "llm" \
			and _current_task.get("id", "") != _active_talk_task_id \
			and not is_performing() \
			and now_minutes - _current_task_started_at >= int(ceil(_effective_action_duration(_current_task.get("duration", 0.0)))):
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
		# CodeRabbit review（#366）：today_log 要記「動作執行結束」那一刻
		# （《15》§2-5），不是之後某次 _select() 換下一筆任務的時候才補記——
		# 中間那段等待決策回應的空檔可能拖很久，甚至決策失敗或沒有候選、
		# _current_task 從頭到尾沒被換掉，那樣 _select() 永遠不會跑到、這筆
		# 就漏記。這裡就地記錄，_log_task_ended() 靠 task 自己的 _logged
		# 旗標擋掉之後 _select()／_clear_current_task() 對同一筆再記一次
		_log_task_ended(_current_task, true)
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
			# 表演中的當前任務不能被這個過期清除迴圈動到（CodeRabbit review
			# 抓到）：expires_in_minutes 可以低到 1，但 PERFORM_DURATION_MINUTES
			# 是 10，任務過期不代表表演做完了。提早清空 _current_task 會讓下面
			# _consider_switch() 選中別的候選頂上來，_run_perform() 背景協程
			# 卻還在跑同一個 session，跑完呼叫 _on_perform_finished(true) 時
			# 會把「頂上來的那個任務」誤判成表演完成
			if is_performing() and expired_task.get("id", "") == _current_task.get("id", ""):
				continue
			_tasks.remove_at(i)
			if expired_task.get("id", "") == _current_task.get("id", ""):
				_clear_current_task(false)

	var best: Dictionary = {}
	var best_score := -INF

	for task in _tasks:
		if not _in_window_or_unwindowed(task, now):
			continue
		if _reevaluate_excluded_ids.has(task.get("id", "")):
			continue
		# 排程任務這個時間窗內已知會失敗，退避到窗期結束（issue #505，見
		# _mark_schedule_retry_backoff()）——不跳過的話同一個失敗的排程任務
		# 每個遊戲分鐘都會被選回來重試一次，是這則 issue 要修的洗版問題本身
		if now_minutes < int(task.get("_retry_blocked_until", -1)):
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
		_clear_current_task(true)

	# 剛睡醒（#89 觸發時機之一，重寫整份 today_plan）：這次重算進來的時候
	# 在睡，選完任務之後不再是了，就是這個轉換瞬間。只在真正換出 sleep 的
	# 那一次觸發，不會每個遊戲分鐘都重問——_was_sleeping 是這次呼叫一開頭
	# 記的，只反映「這一次」的轉換，不是累積狀態
	if _was_sleeping and current_state != "sleep":
		# 自動存檔（issue #427）：睡醒是「一天告一段落」的自然檢查點，大約
		# 一天一次，I/O 成本可以忽略。跟下面的決策請求分開判斷——存檔不該被
		# llm_decision_enabled／_awaiting_decision 這兩個只跟決策迴圈有關的
		# 旗標擋住，AI 決策關掉時角色一樣會睡醒，一樣該存。之前沒有任何自動
		# 存檔機制，長時間無人值守的驗證只要沒人記得手動下 `save` 指令，
		# 執行期資料在 stop 的當下就整批消失，這是實際發生過的事故
		_autosave_on_wake()
		# 爽約通知的延後補送（#479，《10》§5.5）：睡眠中爽約時 _notify_appointment_broken()
		# 只暫存文字，不直接進 _pending_fact_lines——這裡才是「醒來後」，補進佇列讓
		# 下面的 _request_next_decision(true) 一起帶上
		if not _appointment_broken_pending_line.is_empty():
			_pending_fact_lines.append(_appointment_broken_pending_line)
			_appointment_broken_pending_line = ""
		if llm_decision_enabled and not _awaiting_decision:
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

	# current_still_valid：舊任務還在自己視窗內、沒過期，卻在這裡被換掉，
	# 代表它是被 best 搶占的，not (自然結束)——today_log 記 ok=false（#366）
	_select(best, now_minutes, not current_still_valid)

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
	var wakefulness: float = character.stats.get_value("wakefulness")
	var sleepy_term := -maxf(0.0, 15.0 - wakefulness) * 0.012
	var chance: float = params["base"] \
		+ trait_value * float(params["coef"]) \
		+ stamina_term + injury_term + alcohol_term + sleepy_term - environment_risk
	chance = clampf(chance, 0.05, 0.95)

	var success := randf() < chance
	if success:
		return {"success": true, "reason": ""}
	return {"success": false, "reason": _failure_reason(injury_term, alcohol_term, stamina_term, sleepy_term, environment_risk)}

## 《01-2》§5：失敗原因要具體到 AI 能調整策略，不能給一句放諸四海皆準的
## 「運氣不好」——找出扣最多分的修正項，講出具體理由。四個修正項全部
## 是負值或 0（environment_risk 本身以正值代表風險，取負號比較），取最負
## 的那個當主因；都沒扣分時才是真的手氣不好
func _failure_reason(injury_term: float, alcohol_term: float, stamina_term: float, sleepy_term: float, environment_risk: float) -> String:
	var worst := "luck"
	var worst_value := 0.0
	for pair in [["injury", injury_term], ["alcohol", alcohol_term], ["stamina", stamina_term], ["sleepy", sleepy_term], ["environment", -environment_risk]]:
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
		"sleepy":
			return "太睏了，沒辦法集中精神"
		"environment":
			return "現場條件不利，沒能成功"
		_:
			return "手氣不好，這次沒抓到訣竅"

## 計算動作的有效 duration，考慮 sleepy 狀態下的時長倍率
func _effective_action_duration(base_duration: float) -> float:
	var duration := base_duration
	if has_condition(CONDITION_SLEEPY):
		duration *= 1.15
	return duration

## 環境風險由呼叫端依動作/情境算好傳入（正值代表風險，數字越大成功率扣越多）。
## SUCCESS_PARAMS 目前沒有動作會走到這裡，之後接動作時（例如 steal 的目擊者
## 風險）再補實際算法
func _environment_risk(_action: String, _params: Dictionary) -> float:
	return 0.0

## 決策執行前的檢查層（#120，《00》原則一：LLM 決定想做什麼，引擎決定做不做得到）。
## 只管兩件事：目標/前提是不是真的存在（硬規則），以及擲不擲得過成功率——語意
## 驗證/白名單那些是 AISchema 的事，這裡假設 action/params 已經過白名單。
##
## 「連續同一動作失敗」（#338）不在這裡記——talk／give／attack／persuade 追逐
## 目標時，這個函式每個遊戲分鐘都會被呼叫一次做前置檢查，追逐中途每次通過都
## 算「成功」的話，連續失敗計數會被追逐過程本身洗掉，也量不到 talk_to()／
## give_to()／attack()／eat()／drink() 真正執行後才會出現的失敗（CodeRabbit
## review 抓到）。改成由各 _pursue_*_task() 自己在真正的終局結果（前置檢查
## 沒過、或實際執行完成）呼叫 _track_action_result_for_facts()，只在任務真的
## 結束的那一刻記一次
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
		"gather":
			# 硬規則：藥草叢是目前唯一的採集地點，place 對不上就直接判定
			# 失敗，不落進下面的 _roll_success()——跟 buy 的販賣機存在檢查
			# 同一種角色，只是這裡沒有場景物件可查，直接比對地點名稱字串。
			# 通過硬規則後不 return，落進下面統一的 _roll_success()：gather
			# 在 SUCCESS_PARAMS 上（見那張表），是真的需要擲骰的動作（#574）
			var gather_place: String = str(params.get("place", ""))
			if gather_place != "herb_field":
				return {"success": false, "reason": "這裡沒有藥草可以採"}
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
		"bury":
			# 跟 attack 同理：硬規則過了就直接放行，不落進下面的 _roll_success()——
			# 安葬本身不是一場需要擲骰決定成敗的互動（《00》原則四只管「涉及他人
			# 意願」的動作要不要擲骰，屍體沒有意願可言），距離／地點／墓碑格數
			# 這些「這個世界裡真的能不能做到」的檢查交給 Character.bury() 自己
			# 的檢查順序，這裡只確認目標存在且是名字唯一
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
		"follow":
			# 跟 persuade 同一套「硬規則過了就直接放行」——follow 沒有成敗
			# 可言（不是說服、不是攻擊骰命中率），純粹是「這個目標現在還
			# 找不找得到」的存在性檢查，每個 tick 由 _pursue_follow_task()
			# 重新問一次。查的是 following_id 不是 params.target 的顯示
			# 名字（CodeRabbit review 抓到）：名字在 _select() 那次解析完
			# following_id 之後可能改變（改名），繼續用名字查每 tick 都要
			# 重新過一次撞名檢查，改名的話會被誤判成「跟丟」，即使
			# following_id 其實還能找到同一個人。id 是唯一值，不會撞名，
			# 不需要另外的歧義檢查
			var follow_target := _find_character_by_id(following_id)
			if follow_target == null:
				return {"success": false, "reason": "找不到這個人，可能已經離開了"}
			return {"success": true, "reason": ""}
		"perform":
			# perform 在 SUCCESS_PARAMS 上（見那張表），會落進下面的 _roll_success()
			# 真的擲骰——這裡只做「這個世界裡真的能不能做到」的硬規則檢查，跟
			# eat／drink 檢查背包同一個道理：沒有 instrument 連嘗試的資格都沒有，
			# 不該讓它有機會擲出成功。stats == null 也要在這裡擋（CodeRabbit
			# review 抓到）：不擋的話會落進 _roll_success() 讀 character.stats.get_value()，
			# 對 null 呼叫方法直接崩潰，Character.perform() 本來就有的
			# PERFORM_NO_STATS 防呆永遠沒有機會被回報，因為根本走不到那裡
			if inventory == null or not inventory.has_item("instrument"):
				return {"success": false, "reason": "身上沒有樂器，沒辦法表演"}
			if stats == null:
				return {"success": false, "reason": "沒有身體狀態資料，沒辦法表演"}
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
## outgoing_ok：舊任務（換掉前的 _current_task）today_log 要記 ok=true 還是
## false。呼叫端負責判斷——_consider_switch() 分得出「舊任務自己視窗已過／
## 已過期，換下一筆是它自然結束」（true）跟「舊任務還在有效期內，被更高分
## 的候選搶走」（false，CodeRabbit review #366：搶占時動作沒真的做完，不該
## 算成功）；_current_task 是空的那個呼叫（沒有舊任務可記）傳什麼都無所謂，
## 下面 _log_task_ended() 自己的 is_empty() 檢查會擋掉
func _select(task: Dictionary, now_minutes: int, outgoing_ok: bool = true) -> void:
	if task.get("source", "") == "llm":
		var action: String = str(task.get("action", ""))
		if not AISchema.is_implemented_action(action):
			last_action_result = "這個動作還沒有實作，暫時做不了"
			_remove_task(task.get("id", ""))
			return

	# 換成別筆任務時舊任務不會經過 _clear_current_task()（下面直接覆寫，不會
	# 先變成 {}），但一樣算「做過的事」，這裡補記一筆（#172）
	_log_task_ended(_current_task, outgoing_ok)

	_current_task = task
	# CodeRabbit review（#366）：schedule 任務的 Dictionary 跨時間窗、跨日重用，
	# 不像 llm 任務每次決策都是新的 Dictionary——"_logged" 記在上一次執行留下
	# 沒清，這次真的執行完會被當成「已經記過」而漏記。這裡是任務「開始執行」
	# 唯一的進入點，起跑時清乾淨，讓旗標只管「這一次執行」有沒有記過
	_current_task.erase("_logged")
	_current_task_started_at = now_minutes
	current_place = str(task.get("params", {}).get("place", ""))
	current_state = str(task.get("action", ""))

	# following_id 的生命週期跟著這裡收斂（issue #576）：新任務不是 follow
	# 就清掉——「要不要停止跟隨」交給跟隨者自己的下一次決策，只要那次決策
	# 選了別的動作（或壓根沒有 follow），這裡就是它被「執行」的那一刻，
	# 順勢清掉狀態，不用另外在別處輪詢判斷。新任務是 follow 的話，跟
	# talk／persuade 同一種做法在這裡先用名字找一次目標存 id——找不到／
	# 撞名的情形留給 _pursue_follow_task() 第一個 tick 呼叫 resolve() 時
	# 用同一套 target 存在性／歧義檢查收尾，這裡不重複判斷
	if current_state == "follow":
		# 任務起跑這一刻要做撞名檢查（CodeRabbit review 抓到）：
		# _find_character_by_name() 撞名時回傳「隨便找到的第一個」，跟
		# talk／attack／bury／persuade 在 resolve() 用 _find_all_characters_by_name()
		# 擋撞名的規則不一致，會讓 follow 悄悄跟錯人。之後每個 tick 的
		# resolve() 已經改用 following_id 查（不會再撞名，id 唯一），
		# 撞名檢查只需要在這裡、任務剛起跑、還只有顯示名字可查的這一刻做
		var follow_matches := _find_all_characters_by_name(str(task.get("params", {}).get("target", "")))
		following_id = follow_matches[0].character_id if follow_matches.size() == 1 else ""
	elif not following_id.is_empty():
		following_id = ""

	# #428：只記 llm 來源的動作切換，給 #418 重複率量測用——schedule 來源
	# 本來就設計成會重複（例如每天固定去上班），混進去會稀釋掉真正想量的東西
	# （已拍板）。_select() 是仲裁器唯一真正把 _current_task 換成新任務的地方
	# （_consider_switch() 所有分支最終都收斂到這裡才呼叫，且已經在呼叫端
	# 排除掉 best.id == _current_task.id 的情況），呼叫到這裡就代表真的換了
	# 一筆不同的任務，不用再另外判斷「是不是真的換了」
	if task.get("source", "") == "llm":
		_record_action_history(current_state)
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
	_bury_pursuit_stuck_ticks = 0
	_bury_pursuit_last_distance = INF
	_follow_pursuit_stuck_ticks = 0
	_follow_pursuit_last_distance = INF
	# 排程任務的 id 是穩定的 schedule_%d，同一筆 buy 任務會在下一個遊戲日
	# 重用同一個 id——不歸零的話，前一天走不到販賣機留下的 _buy_pursuit_task_id
	# 與 _pursuit_done=true 會讓新一天同 id 的任務直接被守衛判定「已處理過」，
	# 整個跳過 move_to()（CodeRabbit review 抓到）
	_buy_pursuit_task_id = ""
	_buy_pursuit_target = Vector2.ZERO

# 記一筆 llm 來源的動作切換（#428）。append-only，失敗不影響遊戲進行——
# 這是給之後分析用的資料，不是遊戲狀態，寫不進去只印警告，不擋仲裁器
# 換任務。game_minute 跟 _push_today_log() 的 "minute" 欄位同一個換算方式，
# 兩處都是「當天第幾分鐘」，方便之後對照
func _record_action_history(action: String) -> void:
	var inserted := DatabaseManager.insert("npc_action_history", {
		"npc_id": character_id,
		"game_day": GameClock.day,
		"game_minute": GameClock.hour * 60 + GameClock.minute,
		"action": action,
	})
	if not inserted:
		push_warning("Agent %s: npc_action_history 寫入失敗，這筆動作切換記錄遺失" % character_name)

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

	# 表演中同理：_run_perform() 自己跑完 PERFORM_DURATION_MINUTES 才收尾，
	# 這裡不該在協程進行中又重新選一次任務把它打斷
	if is_performing():
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

	# bury（#380）跟 attack／give 同理：目標是另一個角色（屍體），不是固定地點
	if current_state == "bury":
		_pursue_bury_task()
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

	# follow（issue #576）跟 talk／persuade 同理：目標是會動的角色，而且
	# 移動目標要每個 tick 重新算——不能落進下面的地點判斷，那條路徑只會
	# 走一次固定座標，追不上會動的跟隨對象
	if current_state == "follow":
		_pursue_follow_task()
		return

	# drink 跟 eat 同一種「呼叫一次就完成」（#163）
	if current_state == "drink":
		_pursue_drink_task()
		return

	# buy 跟 eat／drink 同理：呼叫一次就完成（#340）
	if current_state == "buy":
		_pursue_buy_task()
		return

	# gather 跟 buy 同理：要先走到藥草叢，抵達後呼叫一次就完成（#574）
	if current_state == "gather":
		_pursue_gather_task()
		return

	# work 是長動作，執行協程會自己跑 5 分鐘，只能呼叫一次（#358）
	if current_state == "work":
		_pursue_work_task()
		return

	# perform 跟 work 同理，是長動作、只能呼叫一次（#575）；不像 work 要先走到
	# 工作站，任意地點皆可，不落進下面的地點判斷
	if current_state == "perform":
		_pursue_perform_task()
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
		# 首次造訪事實句（#338）。_note_place_visited() 自己用 _visited_places
		# 判斷是不是真的第一次，這裡不用管——之後每輪重算都會重進這個分支
		# （已到達的地點沒換，仍然會命中 _has_arrived_at），呼叫端沒有節流
		# 責任
		_note_place_visited(current_place)
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
			# 同樣失敗的無限迴圈。跟 give／shout「做一次就結束」共用同一套收尾。
			# 任務在這裡就終結，不會有下一個 tick 重算，記一次不會被追逐過程
			# 本身重複洗掉（見 resolve() 的說明）
			_track_action_result_for_facts("talk", false)
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
		# 首次造訪事實句（#338）：排程觸發的 talk 也是一種「移動到地點」的
		# 抵達分支，跟 _pursue_current_task() 的一般移動分支同樣要記
		# （CodeRabbit review 抓到：這裡原本漏了）
		_note_place_visited(current_place)

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
			_track_action_result_for_facts("talk", true)
		else:
			# 失敗不放棄任務，下個遊戲分鐘再試——對方可能只是暫時忙碌（TARGET_BUSY
			# 等），跟 move_to() 走不到只 push_warning 不整筆放棄是同一種態度。
			# 這裡是 talk_to() 真正執行後的結果，不是追逐中的前置檢查，每次
			# 重試都是一次真實的失敗，該算進連續失敗計數
			push_warning("Agent %s: 搭話 %s 失敗（%s）" % [
				character_name, target.character_name, failure
			])
			_track_action_result_for_facts("talk", false)
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
		if not proceed:
			_track_action_result_for_facts("eat", false)

	# today_log 要記「吃了哪個 item_id」，但 eat() 本身只回傳成功/失敗原因碼，
	# 不回傳吃的是哪個——得在它把東西吃掉、格子清空之前先偷看一眼（#172）
	var food_item := ""
	if proceed:
		food_item = str(_find_food_slot().get("item_id", ""))
		var reason := eat()
		last_action_result = reason
		if reason != Character.EAT_OK:
			push_warning("Agent %s: eat 失敗（%s）" % [character_name, reason])
			_mark_schedule_retry_backoff(_current_task)
		else:
			var food_name := ItemDatabase.get_display_name(food_item)
			_push_daily_event("你吃了%s。" % food_name)
		# 連續失敗事實句涵蓋所有實際執行的動作，不分來源——跟 talk 的既有規則
		# 一致（CodeRabbit review 抓到：原本只計 llm 來源，talk 卻不分來源，
		# 兩套契約不一致，schedule／llm 交錯時計數會被錯誤重設或漏算）
		_track_action_result_for_facts("eat", reason == Character.EAT_OK)

	# 不管成功失敗都收尾：跟 _pursue_talk_task() 的 resolve() 失敗分支一樣，
	# 這筆任務不留在池子裡繼續佔位（吃不到就是吃不到，不會下一分鐘自己變出食物），
	# 立刻交還決策權給下一輪。schedule 來源的任務不移出池子——它是時間的函數，
	# 靠 window 自然退場，跟 _reevaluate() 事件驅動觸發那段的收尾邏輯同一套規則
	# （見 [[行程佇列與任務仲裁]]「中斷之後怎麼辦」），移掉的話明天同一個 window
	# 不會再被選中
	if _current_task.get("source", "") == "llm":
		_remove_task(_current_task.get("id", ""))
	_clear_current_task(last_action_result == Character.EAT_OK, food_item)
	if llm_decision_enabled and not _awaiting_decision:
		_request_next_decision(_today_plan_needs_new_goal())
	# CodeRabbit review：_request_next_decision() 只有在非同步回應回來後才會
	# 重新仲裁，不立刻補一次 _reevaluate() 的話，等回應期間排程或 fallback
	# 任務不會被馬上接手，得空等到下一次 GameClock time_changed（跟 drink／
	# murmur 同一個問題）
	_reevaluate()

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
		if not proceed:
			_track_action_result_for_facts("drink", false)

	var drink_item := ""
	if proceed:
		drink_item = str(_find_drink_slot().get("item_id", ""))
		var reason := drink()
		last_action_result = reason
		if reason != Character.DRINK_OK:
			push_warning("Agent %s: drink 失敗（%s）" % [character_name, reason])
			_mark_schedule_retry_backoff(_current_task)
		else:
			var drink_name := ItemDatabase.get_display_name(drink_item)
			_push_daily_event("你喝了%s。" % drink_name)
		# 不分來源都記——理由同 _pursue_eat_task()
		_track_action_result_for_facts("drink", reason == Character.DRINK_OK)

	if _current_task.get("source", "") == "llm":
		_remove_task(_current_task.get("id", ""))
	# #456 CodeRabbit review：改用跟 _pursue_eat_task() 一樣的共用收尾 helper——
	# 手動清空漏記 today_log（drink 做完的事不會出現在每日摘要），也漏了
	# _reevaluate_excluded_ids 之外沒問題但重複造輪子。_clear_current_task()
	# 已經把兩件事都做了（見它的宣告與 _reevaluate_excluded_ids 宣告註解）
	_clear_current_task(last_action_result == Character.DRINK_OK)
	if llm_decision_enabled and not _awaiting_decision:
		_request_next_decision(_today_plan_needs_new_goal())
	# CodeRabbit review：_request_next_decision() 只有在非同步回應回來後才會
	# 重新仲裁，不立刻補一次 _reevaluate() 的話，等回應期間排程或 fallback
	# 任務不會被馬上接手，得空等到下一次 GameClock time_changed（跟 murmur
	# 那條同一個問題）
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
		# 誤判成已經處理過（CodeRabbit review 抓到）
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
		# move_to() 失敗）也不要再試——原本的守衛條件反過來寫，move_to()
		# 失敗、is_moving() 仍是 false 時下一輪又會重複呼叫、重複噴警告
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
		# 工作站已被佔用：保留目前的 schedule work 任務，不清掉也不呼叫 _reevaluate()。
		# 讓下一個時間事件觸發重試，避免頻繁的同步重評估導致遊戲無回應
		push_warning("Agent %s: work_at 失敗（工作站被佔用）" % [character_name])
		return

	if reason != Character.WORK_OK:
		push_warning("Agent %s: work_at 失敗（%s）" % [character_name, reason])
		# 其他失敗原因：清掉任務、重置 pursuit state 並等待決策
		_pursued_place = ""
		_pursuit_done = false
		_current_task = {}
		current_place = ""
		current_state = "idle"
		if llm_decision_enabled and not _awaiting_decision:
			_request_next_decision(_today_plan_needs_new_goal())

# perform 任務的執行（#575）：跟 eat／drink 一樣先用 resolve() 判定（perform
# 在 SUCCESS_PARAMS 上，這裡才是真正擲骰的那一刻，只呼叫一次，不是每個
# 遊戲分鐘都重骰——理由見 resolve() 開頭那段對「一次決策一次骰」的說明）。
# 擲成功才呼叫 Character.perform()，跟 work 一樣是長動作：perform() 立刻
# 回傳 OK、協程在背景跑完 PERFORM_DURATION_MINUTES，任務要留在 _current_task
# 上（不在這裡清掉），收尾交給 _on_perform_finished()（_run_perform() 結束時
# 呼叫）
func _pursue_perform_task() -> void:
	stop_moving()
	var proceed := true
	if _current_task.get("source", "") == "llm":
		var result := resolve(str(_current_task.get("action", "")), _current_task.get("params", {}))
		last_action_result = result["reason"]
		proceed = result["success"]
		if not proceed:
			_track_action_result_for_facts("perform", false)

	if proceed:
		var reason := perform()
		last_action_result = reason
		_track_action_result_for_facts("perform", reason == Character.PERFORM_OK)
		if reason == Character.PERFORM_OK:
			_push_daily_event("你開始表演。")
			return
		push_warning("Agent %s: perform 失敗（%s）" % [character_name, reason])
		_mark_schedule_retry_backoff(_current_task)

	if _current_task.get("source", "") == "llm":
		_remove_task(_current_task.get("id", ""))
	_clear_current_task(false)
	if llm_decision_enabled and not _awaiting_decision:
		_request_next_decision(_today_plan_needs_new_goal())
	_reevaluate()

# buy 任務的執行（#340）：先找到販賣機並移動到其位置，再呼叫 buy_from()。
# 販賣機透過 params.place 指定（餐酒館或藥草鋪）
#
# 導航目標刻意不是 machine.global_position（#670）：販賣機是 NavGrid 上的
# 障礙格（見 vending_machine.gd 開頭註解），終點格永遠不可走，尋徑只會把
# 路徑收斂到鄰近可走格，跟 _has_arrived_at() 的判定（2px 或同一格）永遠對不上，
# 是結構性死結，不是機率問題。改跟 _pursue_work_task() 同一套，用 PlaceAnchors
# 預先擺在可走格上的錨點當導航目標；買東西那一刻的距離判定（buy_from()，
# character.gd）維持看 machine.global_position，不受影響，四個方向一樣能買
func _pursue_buy_task() -> void:
	var buy_task_id: String = str(_current_task.get("id", ""))
	var place: String = str(_current_task.get("params", {}).get("place", ""))
	var machine := _find_vending_machine_at_place(place)
	var anchors := get_tree().get_first_node_in_group("place_anchors")

	# 找不到販賣機，或販賣機所在地點沒有對應的可走錨點：立即返回失敗
	if not machine or anchors == null or not anchors.has(place):
		# 要先讀 source／id 再清空 _current_task——清空之後兩個 get() 都只會
		# 讀到空字典的預設值，llm 任務永遠判斷不是 llm、也移除不掉，會卡在
		# 池子裡讓 _reevaluate() 重複選到同一筆（CodeRabbit review 抓到）
		var failed_task_source: String = str(_current_task.get("source", ""))
		var failed_task_id: String = str(_current_task.get("id", ""))
		push_warning("Agent %s: 找不到販賣機 %s" % [character_name, place])
		# 清掉任務前先停下——不然角色若正走去先前目標，會帶著已失效的
		# 路徑繼續走（CodeRabbit review 抓到）
		stop_moving()
		_pursued_place = ""
		_pursuit_done = false
		last_action_result = Character.BUY_TARGET_NOT_FOUND
		if failed_task_source == "llm":
			_remove_task(failed_task_id)
		else:
			# schedule 任務不會被移出池子，靠 window 自然退場——不加退避的話
			# 下面 _reevaluate() 會在同一輪 trampoline 裡立刻重選到同一筆、
			# 立刻再失敗一次，卡進無法跳出的同步迴圈（CodeRabbit review 抓到）
			_mark_schedule_retry_backoff(_current_task)
		# 用 _clear_current_task() 而不是手動清四個欄位：它會把這筆任務 id 記進
		# _reevaluate_excluded_ids，這輪 trampoline 才不會又選回同一筆
		# （CodeRabbit review 抓到，跟上面的退避是同一個問題的兩面）
		_clear_current_task(false)
		if llm_decision_enabled and not _awaiting_decision:
			_request_next_decision(_today_plan_needs_new_goal())
		_reevaluate()
		return

	var approach_target: Vector2 = anchors.resolve(place)

	# 還沒到達就先走過去
	if not _has_arrived_at(approach_target):
		# 同 _pursue_work_task() 的收斂邏輯：已有結論就不要重試——但這裡要比對
		# 任務 id 而不是 current_place，理由見 _buy_pursuit_task_id 的說明
		# （CodeRabbit review 抓到）
		if _buy_pursuit_task_id == buy_task_id and (is_moving() or _pursuit_done):
			# _pursuit_done 除了 move_to() 立即失敗會設，_on_move_finished(false)
			# 這個非同步的尋徑失敗回呼也會設——原本這裡直接 return，llm 任務會
			# 卡在這個守衛出不去，永遠記錄不到失敗結果、也不會請求下一次決策
			# （CodeRabbit review 抓到）
			if _pursuit_done and _current_task.get("source", "") == "llm":
				last_action_result = "走不到販賣機，無法購買"
				_finish_task_and_request_next()
			return
		_buy_pursuit_task_id = buy_task_id
		_pursued_place = current_place
		_pursuit_done = false
		_buy_pursuit_target = approach_target
		if not move_to(approach_target):
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

	# 已到達販賣機位置，執行購買
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
	_pursued_place = ""
	_pursuit_done = false
	_current_task = {}
	current_place = ""
	current_state = "idle"
	if llm_decision_enabled and not _awaiting_decision:
		_request_next_decision(_today_plan_needs_new_goal())
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

# gather 任務的執行（#574）：跟 _pursue_work_task() 同理，先走到地點錨點，
# 抵達後才執行；跟 eat／drink／buy 同理，呼叫一次就完成，不像 nap 那樣佔滿
# 整段 duration。⚠ gather 在 SUCCESS_PARAMS 上（見 _roll_success()），
# resolve() 對它是真的擲骰——這裡只能在抵達後呼叫一次 resolve()，不能放進
# 每個遊戲分鐘都會重算的路徑（《99》issue #216 已警告過這個陷阱：那張表上的
# 動作接執行層時，_roll_success() 每呼叫一次就重骰一次，不是「重驗前置條件」
# 那種可以每分鐘重跑的純函式）。寫法照抄 _pursue_buy_task() 的「先走、
# 到了才骰」結構，只是用地點錨點取代販賣機節點
func _pursue_gather_task() -> void:
	var place: String = str(_current_task.get("params", {}).get("place", ""))
	var anchors := get_tree().get_first_node_in_group("place_anchors")

	# 藥草叢是目前唯一的採集地點：place 不是 herb_field，或場景根本沒建這個
	# 錨點，都直接判定失敗，不用先走過去才發現——跟 _pursue_buy_task() 同一套
	# 「先驗證地點合不合理，再決定要不要走過去」的順序（CodeRabbit review 抓到：
	# 原本只檢查「這個名字有沒有對應到任何錨點」，place 給一個真實存在但不是
	# herb_field 的地點（例如 tavern）時會先走過去，抵達後才靠 resolve() 判定
	# 失敗，等於明知走錯地方還是先走過去，浪費遊戲時間）
	if place != "herb_field" or anchors == null or not anchors.has(place):
		var failed_task_source: String = str(_current_task.get("source", ""))
		var failed_task_id: String = str(_current_task.get("id", ""))
		push_warning("Agent %s: 沒有這個採集地點 %s" % [character_name, place])
		# 排程來源的 place 打錯字是靜態資料，每個遊戲分鐘重算都會撞上同一個
		# 失敗，不退避就是《99》issue #505 修過的「排程失敗每分鐘瘋狂重試」
		# 重演（原案例是 eat 排程沒食物），這裡要在 _current_task 被清空、
		# 拿不到任務物件之前先標記
		_mark_schedule_retry_backoff(_current_task)
		stop_moving()
		_pursued_place = ""
		_pursuit_done = false
		last_action_result = "這裡沒有藥草可以採"
		# 用 _clear_current_task() 取代手動重設三個欄位——手動寫法漏呼叫
		# _log_task_ended()，這筆失敗的 gather 不會出現在 today_log／每日摘要
		# 裡（CodeRabbit review 抓到，跟 eat／drink／buy 的收尾方式看齊）
		_clear_current_task(false)
		if failed_task_source == "llm":
			_remove_task(failed_task_id)
		if llm_decision_enabled and not _awaiting_decision:
			_request_next_decision(_today_plan_needs_new_goal())
		_reevaluate()
		return

	var target: Vector2 = anchors.resolve(place)

	# 還沒到達就先走過去——跟 _pursue_work_task()／_pursue_buy_task() 同一套
	# 收斂邏輯：地點沒換就只起步一次，已有結論（含 move_to() 失敗）不重試
	if not _has_arrived_at(target):
		if current_place == _pursued_place and (is_moving() or _pursuit_done):
			return
		_pursued_place = current_place
		_pursuit_done = false
		if not move_to(target):
			push_warning("Agent %s: 走不到 %s" % [character_name, place])
			# 跟 _pursue_buy_task() 同一套：llm 任務沒有 window 這條退路，只設
			# _pursuit_done 的話會一直卡在 gather 狀態，永遠等不到失敗結果、
			# 也不會請求下一個決策（CodeRabbit review 抓到）
			if _current_task.get("source", "") == "llm":
				last_action_result = "走不到藥草叢，無法採集"
				_finish_task_and_request_next()
			else:
				_pursuit_done = true
		return

	# 已到達藥草叢，執行採集
	stop_moving()
	_pursued_place = current_place
	_pursuit_done = true

	# resolve() 不分來源都要呼叫——跟 eat／drink／buy
	# 不同的是，gather 在 SUCCESS_PARAMS 上，resolve() 對它是真的擲骰，不是
	# 「重驗前置條件」的純函式；只在 llm 來源才骰的話，schedule 來源的 gather
	# （目前 npc_schedule.json 沒有，但介面上合法）會完全跳過擲骰、直接必中，
	# 違反《01-2》§2 的成功率公式（CodeRabbit review 抓到）
	var result := resolve(str(_current_task.get("action", "")), _current_task.get("params", {}))
	last_action_result = result["reason"]
	var proceed: bool = result["success"]
	if not proceed:
		_track_action_result_for_facts("gather", false)

	if proceed:
		var reason := gather()
		last_action_result = reason
		if reason != Character.GATHER_OK:
			push_warning("Agent %s: gather 失敗（%s）" % [character_name, reason])
		else:
			_push_daily_event("你採集到了一份%s。" % ItemDatabase.get_display_name("herb"))
		_track_action_result_for_facts("gather", reason == Character.GATHER_OK)

	# 排程來源不論擲骰失敗、gather() 失敗、還是成功，都要退避到窗期結束——
	# 跟 eat／drink 只在失敗時退避的理由不同：eat／drink 有 satiety 這種會隨
	# 動作完成自然下降的分數，吃飽了下一輪自然選不到；gather 沒有這種內建
	# 抑制，同一個排程窗期內每個遊戲分鐘都可能被 _reevaluate() 立即重選中，
	# 擲骰成功也一樣會無限重跑、每分鐘多產一份 herb（CodeRabbit review 抓到）
	_mark_schedule_retry_backoff(_current_task)

	if _current_task.get("source", "") == "llm":
		_remove_task(_current_task.get("id", ""))
	_pursued_place = ""
	_pursuit_done = false
	# 同上：用 _clear_current_task() 取代手動重設，補上 today_log 紀錄
	# （CodeRabbit review 抓到）
	_clear_current_task(last_action_result == Character.GATHER_OK)
	if llm_decision_enabled and not _awaiting_decision:
		_request_next_decision(_today_plan_needs_new_goal())
	_reevaluate()

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
		# murmur 沒有追逐、每筆任務只跑這裡一次，resolve() 的結果就是終局結果
		# （不像 talk／give／attack 之後還有一次真正執行可能失敗）

	# 內容層跟 talk 同一套「模板先頂著，LLM 版之後再換」的分工（見
	# note/技術/talk 動作設計.md）：murmur 沒有聽者，講的是給自己聽的話，
	# 不能沿用 DialogueLines.reply() 那組面向對話對象的句子
	if should_speak and stats != null:
		say(DialogueLines.murmur(stats))

	# 連續失敗事實句涵蓋所有實際執行的動作，不分來源——跟 eat/drink/talk
	# 既有規則一致（CodeRabbit review 抓到：原本只計 llm 來源，schedule 來源
	# 的 murmur 成功時不會重設計數，先前的失敗事實句會卡住不消失，後續失敗
	# 也會被錯誤累計）
	_track_action_result_for_facts("murmur", should_speak)

	_remove_task(_current_task.get("id", ""))
	_clear_current_task(last_action_result.is_empty())
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
	_clear_current_task(last_action_result.is_empty())
	if llm_decision_enabled and not _awaiting_decision:
		_request_next_decision(_today_plan_needs_new_goal())
	# _request_next_decision() 只有在非同步回應回來後才會重新仲裁，不立刻補
	# 一次 _reevaluate() 的話，等回應期間排程或 fallback 任務不會被馬上接手，
	# 得空等到下一次 GameClock time_changed（跟 murmur 那條 PR 同一個
	# CodeRabbit review 抓到的問題，這裡是共用的收尾，一次修就對三個呼叫端都生效）
	_reevaluate()

## 長動作固定間隔檢查點的決策請求本體（issue #336，《02》§3）。跟
## maybe_speak_to_creator() 同一種輕量是非題信封——問「要不要繼續」不需要
## visible／pool／today_plan／memory 這些完整重新規劃才要看的資料，不走
## _request_next_decision() 那整套 tasks schema。
##
## task_id 記下呼叫當下這筆任務的 id：這通吃 await，等待期間任務可能已經
## 自然做完、被外部事件中斷、或被另一個檢查點處理過，_current_task 早就
## 不是當初問的那一筆了——回應回來後只比對 id，id 對不上就整包丟棄，不套用
## 到一筆不相干的新任務上（跟 _request_next_decision() 的世代比對同一種
## 「回應可能已經過期」的處理方式）
func _request_checkpoint_decision(task: Dictionary) -> void:
	_checkpoint_decision_pending = true
	var task_id: String = task.get("id", "")
	var my_generation := _decision_generation
	var elapsed := _now_minutes() - _current_task_started_at

	var envelope := PromptBuilder.build_checkpoint_envelope(self, task, elapsed)
	var validator := func(data: Dictionary) -> Dictionary:
		return AISchema.validate_checkpoint(data)
	var result := await _decide_with_retry(envelope, AIService.Policy.SCHEDULED, validator)
	_checkpoint_decision_pending = false

	if my_generation != _decision_generation or _current_task.get("id", "") != task_id:
		return
	if not result["ok"]:
		return
	if not result["data"]["continue"]:
		_abandon_task_from_checkpoint(task)

## 檢查點問到「放棄」時的收尾。跟 _finish_task_and_request_next() 共用同一套
## 退出任務池／清空目前任務／補下一次決策的邏輯——差別只在這是 AI 自己主動
## 決定放棄，不是任務天然做完，所以先寫一個非空的 last_action_result 讓
## _clear_current_task() 判定為不成功（中止不撥款這類逐動作的代價，由各動作
## 自己的執行邏輯根據「這筆任務沒有成功」這個事實去決定怎麼處理，不是這裡的
## 責任——見 issue #336 範圍界線）
func _abandon_task_from_checkpoint(task: Dictionary) -> void:
	last_action_result = "你自己決定中途放棄，沒有完成"
	_push_daily_event("你放棄了正在做的「%s」，改做別的事" % str(task.get("action", "")))
	_finish_task_and_request_next()

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
			_track_action_result_for_facts("give", false)
			_finish_task_and_request_next()
			return

	var params: Dictionary = _current_task.get("params", {})
	var target_name: String = str(params.get("target", ""))
	var target := _find_character_by_name(target_name)

	if target == null:
		last_action_result = "找不到這個人，可能已經離開了"
		# 連續失敗事實句涵蓋所有實際執行的動作，不分來源（CodeRabbit review
		# 抓到：原本只計 llm 來源，talk 卻不分來源，兩套契約不一致，統一成
		# 都不分來源）
		_track_action_result_for_facts("give", false)
		_finish_task_and_request_next()
		return

	var distance := get_body_position().distance_to(target.get_body_position())
	if distance > GIVE_RANGE:
		# 走不到跟 talk 一樣只警告不放棄——但 give 沒有「對方暫時忙碌」這種
		# 值得下個遊戲分鐘重試的情境，走不到就是走不到，直接結束這筆任務
		if not move_to(target.get_body_position()):
			push_warning("Agent %s: 走不到送禮對象 %s" % [character_name, target.character_name])
			last_action_result = "靠近不了對方，禮物送不出去"
			_track_action_result_for_facts("give", false)
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
			_track_action_result_for_facts("give", false)
			_finish_task_and_request_next()
		return

	stop_moving()
	var item_id: String = str(params.get("item_id", ""))
	var count: int = int(params.get("count", 1))
	var give_failure := give_to(target, item_id, count)
	last_action_result = _give_failure_message(give_failure)
	_track_action_result_for_facts("give", give_failure == Character.GIVE_OK)

	if give_failure == Character.GIVE_OK:
		var item_name := ItemDatabase.get_display_name(item_id)
		_push_daily_event("你把%s給了%s。" % [item_name, target.character_name], [target.character_id])
		if target.is_in_group("agents"):
			(target as Agent)._push_daily_event("你收到了%s的%s。" % [character_name, item_name], [character_id])

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
			_track_action_result_for_facts("attack", false)
			_finish_task_and_request_next()
			return

	var params: Dictionary = _current_task.get("params", {})
	var target_name: String = str(params.get("target", ""))
	var target := _find_character_by_name(target_name)

	if target == null:
		last_action_result = "找不到這個人，可能已經離開了"
		_track_action_result_for_facts("attack", false)
		_finish_task_and_request_next()
		return

	var distance := get_body_position().distance_to(target.get_body_position())
	if distance > ATTACK_RANGE:
		if not move_to(target.get_body_position()):
			push_warning("Agent %s: 走不到攻擊對象 %s" % [character_name, target.character_name])
			last_action_result = "靠近不了對方，攻擊不到"
			_track_action_result_for_facts("attack", false)
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
			_track_action_result_for_facts("attack", false)
			_finish_task_and_request_next()
		return

	stop_moving()
	var attack_failure := attack(target)
	last_action_result = _attack_failure_message(attack_failure)
	_track_action_result_for_facts("attack", attack_failure == Character.ATTACK_OK)
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

# bury 任務的執行（#380）：目標跟 attack 一樣是另一個角色（要安葬的屍體），
# 沿用同一套「走一次、卡住偵測、卡住就真的放棄」節流。跟 attack 不同的是
# 距離門檻用 Character.BURY_RANGE，而且 Character.bury() 自己還會再檢查
# 屍體是否死亡、是否已安葬、是否在墓園範圍內、墓碑格數滿不滿——這裡只負責
# 把安葬者移動到屍體旁邊，真正的規則判斷交給 bury() 本身
func _pursue_bury_task() -> void:
	if _current_task.get("source", "") == "llm":
		var result := resolve(str(_current_task.get("action", "")), _current_task.get("params", {}))
		last_action_result = result["reason"]
		if not result["success"]:
			_track_action_result_for_facts("bury", false)
			_finish_task_and_request_next()
			return

	var params: Dictionary = _current_task.get("params", {})
	var target_name: String = str(params.get("target", ""))
	var target := _find_character_by_name(target_name)

	if target == null:
		last_action_result = "找不到這個人，可能已經離開了"
		_track_action_result_for_facts("bury", false)
		_finish_task_and_request_next()
		return

	var distance := get_body_position().distance_to(target.get_body_position())
	if distance > Character.BURY_RANGE:
		if not move_to(target.get_body_position()):
			push_warning("Agent %s: 走不到安葬對象 %s" % [character_name, target.character_name])
			last_action_result = "靠近不了屍體，安葬不了"
			_track_action_result_for_facts("bury", false)
			_finish_task_and_request_next()
			return

		if distance >= _bury_pursuit_last_distance - 1.0:
			_bury_pursuit_stuck_ticks += 1
		else:
			_bury_pursuit_stuck_ticks = 0
		_bury_pursuit_last_distance = distance

		if _bury_pursuit_stuck_ticks >= 3:
			push_warning("Agent %s: 安葬對象 %s 卡住走不到，放棄" % [character_name, target.character_name])
			last_action_result = "靠近不了屍體，安葬不了"
			_track_action_result_for_facts("bury", false)
			_finish_task_and_request_next()
		return

	stop_moving()
	var bury_failure := bury(target)
	last_action_result = _bury_failure_message(bury_failure)
	_track_action_result_for_facts("bury", bury_failure == Character.BURY_OK)

	if bury_failure == Character.BURY_OK:
		_push_daily_event("你把%s安葬了。" % target.character_name, [target.character_id])

	_finish_task_and_request_next()

# bury() 失敗原因碼轉中文，格式跟 _attack_failure_message() 一致
func _bury_failure_message(failure: String) -> String:
	match failure:
		Character.BURY_OK:
			return ""
		Character.BURY_TARGET_NOT_FOUND:
			return "找不到這個人，可能已經離開了"
		Character.BURY_TARGET_NOT_DEAD:
			return "這個人還活著，不能安葬"
		Character.BURY_ALREADY_BURIED:
			return "已經安葬過了"
		Character.BURY_TOO_FAR:
			return "距離太遠，安葬不了"
		Character.BURY_NOT_AT_CEMETERY:
			return "這裡不是墓園，沒辦法安葬"
		Character.BURY_CEMETERY_FULL:
			return "墓園的墓碑格滿了，安葬不了"
		_:
			return "安葬沒有成功"

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
			_track_action_result_for_facts("persuade", false)
			_finish_task_and_request_next()
			return

	var params: Dictionary = _current_task.get("params", {})
	var target_name: String = str(params.get("target", ""))
	var target := _find_character_by_name(target_name)

	if target == null:
		last_action_result = "找不到這個人，可能已經離開了"
		_track_action_result_for_facts("persuade", false)
		_finish_task_and_request_next()
		return

	# 玩家目標永遠可以嘗試說服（Y/N 彈窗，#305），不像 Agent 目標需要
	# llm_decision_enabled 這種能力門檻——那個門檻只對 Agent 目標有意義，玩家
	# 沒有「決策迴圈關著」這種狀態。llm_decision_enabled 關著的 Agent 走不通：
	# _ready() 一律 add_to_group("agents")，不管這個旗標開不開（預設就是關），
	# 只檢查有沒有在 agents 群組擋不住——若放行，_pending_persuade 寫上去之後
	# 永遠沒有 _request_next_decision() 會被觸發去清掉它（見 llm_decision_enabled
	# 關閉時「沒有任務做完就重新決策那條路徑」的既有說明），這筆待回應記錄會
	# 卡死，之後任何人都說服不了這個目標（忙碌拒絕永遠擋著）
	var target_is_player := target.is_in_group("player")
	if not target_is_player and not (target.is_in_group("agents") and (target as Agent).llm_decision_enabled):
		last_action_result = "這個人好像沒辦法被說服"
		_track_action_result_for_facts("persuade", false)
		_finish_task_and_request_next()
		return

	# 距離判定跟 Agent 目標共用同一套——玩家目標一樣要先走到範圍內才算送達
	# （CodeRabbit review 抓到：原本玩家分支在這之前就直接開彈窗，NPC 隔著
	# 半張地圖也能對玩家彈窗，沒有真的「靠近才能說話」）
	var distance := get_body_position().distance_to(target.get_body_position())
	if distance > TALK_RANGE:
		# 走不到跟 give 一樣只警告不放棄——但沒有「對方暫時忙碌」這種值得
		# 下個遊戲分鐘重試的情境，走不到就是走不到，直接結束這筆任務
		if not move_to(target.get_body_position()):
			push_warning("Agent %s: 走不到說服對象 %s" % [character_name, target.character_name])
			last_action_result = "靠近不了對方，話說不出口"
			_track_action_result_for_facts("persuade", false)
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
			_track_action_result_for_facts("persuade", false)
			_finish_task_and_request_next()
		return

	stop_moving()
	var reason: String = str(params.get("reason", ""))
	var proposed_task: Dictionary = params.get("proposed_task", {})

	# 玩家目標：範圍判定通過，改走 Y/N 彈窗（#305），不寫入 _pending_persuade
	# 走 LLM 決策迴圈（玩家沒有）。fire-and-forget：不 await，讓這筆任務照
	# 固定 duration 收尾，彈窗的結果晚點才回來，兩者互不卡住
	if target_is_player:
		last_action_result = "你試著說服 %s，等他自己想清楚" % target.character_name
		_track_action_result_for_facts("persuade", true)
		_persuade_delivered = true
		_ask_player_persuade(target as Player, reason, proposed_task)
		return

	var recorded: bool = (target as Agent).try_record_pending_persuade(character_name, character_id, reason, proposed_task)
	if recorded:
		last_action_result = "你試著說服 %s，等他自己想清楚" % target.character_name
	else:
		last_action_result = "%s 好像還在想別人剛才說的話，你的話插不進去" % target.character_name
	_track_action_result_for_facts("persuade", recorded)
	_persuade_delivered = true
	# 不在這裡呼叫 _finish_task_and_request_next()：P-09 拍板 persuade 佔用
	# 固定時長（模型填的建議值 10 分鐘），跟 gather／hunt_small 同一套用法——
	# _reevaluate_once() 的通用事件驅動迴圈會在 duration 走完時自動移除
	# 這筆任務、觸發下一次決策，不是 give／shout 那種送達就立刻結束的
	# 一次性動作（CodeRabbit review 抓到：原本送達當下就呼叫
	# _finish_task_and_request_next()，等於忽略了 duration，任務在抵達的
	# 那一分鐘就結束）。_persuade_delivered 擋掉 duration 還沒走完前，
	# 後續每個 tick 重複呼叫 try_record_pending_persuade()

# follow 任務的執行（issue #576）：目標是會動的角色，移動目標動態改成
# 跟隨對象目前的位置——每個 tick 都重新問一次「他現在在哪」再重下
# move_to()，不是只算一次路徑就不管（跟 _pursue_talk_task() 同一種「目標
# 會動」的追逐節奏，但 talk 到範圍內就停下開口，follow 沒有這種終點，
# 只要還在 follow 狀態就持續逼近）。
#
# 要不要停止跟隨完全交給跟隨者自己的 AI 模型在下一次決策時判斷——這裡
# 不寫任何距離／逾時門檻，following_id 只在下面兩種情況清除：目標透過
# resolve() 判定不存在／撞名，或是 _select() 換上了別的任務（見 _select()
# 的 following_id 收斂邏輯）
func _pursue_follow_task() -> void:
	if _current_task.get("source", "") == "llm":
		var result := resolve(str(_current_task.get("action", "")), _current_task.get("params", {}))
		last_action_result = result["reason"]
		if not result["success"]:
			_track_action_result_for_facts("follow", false)
			following_id = ""
			_finish_task_and_request_next()
			return

	var target := _find_character_by_id(following_id)
	if target == null:
		last_action_result = "找不到要跟隨的人，可能已經離開了"
		_track_action_result_for_facts("follow", false)
		following_id = ""
		_finish_task_and_request_next()
		return

	var target_pos: Vector2 = target.get_body_position()

	# 已經走到跟隨對象身邊——停下來，不用每個 tick 都重新起步一次 A*
	# 尋徑；對方下一步移動時距離會再拉開，下個 tick 自然會離開這個分支
	if _has_arrived_at(target_pos):
		stop_moving()
		_follow_pursuit_stuck_ticks = 0
		_follow_pursuit_last_distance = INF
		return

	var move_ok := move_to(target_pos)
	if not move_ok:
		push_warning("Agent %s: 走不到跟隨對象 %s" % [character_name, target.character_name])

	# move_to() 失敗也要算進卡住偵測（CodeRabbit review 抓到）：原本失敗時
	# 提早 return，_follow_pursuit_stuck_ticks 永遠不會累積，導致下面「追不上，
	# 可能被卡住」這個門檻警告永遠不會在這個情境觸發，只有每個 tick 都印一次
	# 「走不到」的雜訊，沒有真正的卡住偵測
	var distance := get_body_position().distance_to(target_pos)
	var progress := _pursuit_stuck_progress(distance, _follow_pursuit_last_distance, _follow_pursuit_stuck_ticks)
	_follow_pursuit_stuck_ticks = progress["stuck_ticks"]
	_follow_pursuit_last_distance = distance

	if progress["threshold_reached"]:
		push_warning("Agent %s: 追不上跟隨對象 %s，可能被卡住" % [character_name, target.character_name])

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

# 事實句摘要（《01-3》§3）。九條裡本則（#227＋#338）接了七條：persuade
# 待回應（#227）、社交沉默三級距、目標拖延、首次造訪、連續同一動作失敗。
# 剩下兩條是搬運相關（正被搬運中／醒來發現位置變了），依賴 haul 執行層，
# 見 #338 範圍界線。
#
# _pending_reaction_lines（#402／#407，看到陌生人／聽到聲音的反應）不在
# 《01-3》§3 那九條清單內，是額外獨立的一次性事件通知——跟下面的
# _pending_fact_lines 不同，讀到就直接清空，不用等 _request_next_decision()
# 驗證通過才清：這類事件沒有「這次沒送成功要保留重送」的語意，錯過這次
# 通知不影響角色狀態，不是必須被看到才行的東西
func _fact_lines_summary() -> Array[String]:
	var lines: Array[String] = _pending_reaction_lines.duplicate()
	_pending_reaction_lines.clear()

	# 一次性事件（首次造訪等）。這裡只讀不清——真的被這輪回應消費掉才清，
	# 由 _request_next_decision() 在回應通過驗證後處理（見那邊
	# fact_lines_sent_count 的說明），這裡單純組信封用的內容，不能假設
	# 這次一定會送成功
	lines.append_array(_pending_fact_lines)

	if not _pending_persuade.is_empty():
		var persuader: String = str(_pending_persuade.get("persuader", ""))
		var reason: String = str(_pending_persuade.get("reason", ""))
		var proposed_task: Dictionary = _pending_persuade.get("proposed_task", {})

		if proposed_task.is_empty():
			lines.append("剛才 %s 試著說服你：%s，你被說動了嗎？" % [persuader, reason])
		else:
			lines.append("剛才 %s 試著說服你（%s），希望你能去做「%s」，你被說動了嗎？" % [
				persuader, reason, _describe_task_intent(proposed_task)
			])

	# 社交沉默：三級距取最長那條符合的，不三句一起塞（#338 建議做法）
	var since_social := _now_minutes() - _last_social_minute
	if since_social >= FACT_SOCIAL_SILENCE_1_DAY_MIN:
		lines.append("你整整一天沒有和任何人說過話。")
	elif since_social >= FACT_SOCIAL_SILENCE_HALF_DAY_MIN:
		lines.append("你已經大半天沒和任何人說過話了。")
	elif since_social >= FACT_SOCIAL_SILENCE_3H_MIN:
		lines.append("你已經三個小時沒和任何人說過話了。")

	# 目標拖延：只有真的設過 current_goal（_goal_set_minute >= 0）才判斷，
	# 沒設過目標不該無中生有講「你想做的那件事拖很久」
	if _goal_set_minute >= 0 and _now_minutes() - _goal_set_minute >= FACT_GOAL_STALE_MIN:
		lines.append("你想做的那件事已經拖了很久還沒完成。")

	# 連續同一動作失敗。次數用實際值帶入，不要寫死「三次」——
	# _consecutive_failure_count 沒有上限，角色可能卡在同一動作連續失敗
	# 10 次、20 次，寫死的話這句話從第 4 次開始就是假話，還會每次決策
	# 都重複注入同一句過期文字（code review 抓到，跟社交沉默/目標拖延
	# 那幾條「條件持續成立就持續注入」是同一種行為，不是新增的問題；
	# 問題只在文字內容沒有跟著次數更新）
	if _consecutive_failure_count >= FACT_CONSECUTIVE_FAILURE_THRESHOLD:
		lines.append("你已經連續 %d 次沒能完成「%s」。" % [_consecutive_failure_count, _consecutive_failure_action])

	# 跟隨狀態（issue #576）：只要 following_id 還設著就每次決策都注入，
	# 跟社交沉默／目標拖延同一種「條件持續成立就持續提醒」寫法——引擎不會
	# 自己決定停止跟隨，模型要靠這句話才知道自己正在跟著誰、對方目前在
	# 哪裡，才有材料判斷這一輪要不要繼續 follow
	if not following_id.is_empty():
		var follow_target := _find_character_by_id(following_id)
		if follow_target != null:
			# 用即時位置反查，不是 current_place（CodeRabbit review 抓到）：
			# current_place 是任務目的地，跟隨對象還在半路走過去時，這個欄位
			# 已經先變成目的地了，模型會被告知一個對方根本還沒到的地方。
			# _actual_place_of() 是既有的「反查真實座標對應到哪個地點錨點」
			# 工具（見 _resolve_actual_place()／約定機制同一套），Player 沒有
			# 地點錨點覆蓋範圍時一樣回傳空字串，跟原本的空字串 fallback 行為一致
			var follow_place := _actual_place_of(follow_target)
			if follow_place.is_empty():
				lines.append("你正在跟著 %s。" % follow_target.character_name)
			else:
				lines.append("你正在跟著 %s，他現在在「%s」。" % [follow_target.character_name, follow_place])

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

# 對玩家發起的 persuade（#305）：不寫入 _pending_persuade 走 LLM 決策迴圈，
# 直接跳玩家自己的 Y/N 彈窗。文案比照 _fact_lines_summary() 對 Agent 目標用的
# 同一種事實句措辭（「說服者是誰、理由是什麼」），只是這裡是主動彈窗不是
# 被動注入下一輪 prompt。fire-and-forget：呼叫端（_pursue_persuade_task()）
# 不 await 這個函式，跟 persuade 本身「送達」與「被不被說動」是兩個時間點
# 分開的既有設計一致——送達當下就讓任務照 duration 收尾，彈窗的結果晚點
# 才會回來，兩者不互相卡
func _ask_player_persuade(player: Player, reason: String, proposed_task: Dictionary) -> void:
	var text: String
	if proposed_task.is_empty():
		text = "%s 試著說服你：%s，你被說動了嗎？" % [character_name, reason]
	else:
		text = "%s 試著說服你（%s），希望你能去做「%s」，你被說動了嗎？" % [
			character_name, reason, _describe_task_intent(proposed_task)
		]

	var accepted: bool = await player.request_persuade_response(text)
	if not accepted:
		return

	# 行動說服：帶地點就用 #415 的 waypoint 導引玩家過去，純粹導引不代替玩家
	# 行動——玩家沒有任務池，不會被自動執行動作，去不去、中途放不放棄都是
	# 玩家自己決定。proposed_task 沒有地點（純文字任務）時沒有座標可以導引，
	# 靜默略過，不是漏做
	if not proposed_task.is_empty():
		var place: String = str(proposed_task.get("params", {}).get("place", ""))
		if place.is_empty():
			return
		var anchors := get_tree().get_first_node_in_group("place_anchors")
		if anchors == null or not anchors.has(place) or player.waypoint_indicator == null:
			return
		player.waypoint_indicator.show_waypoint(anchors.resolve(place), Callable(), Callable())
		return

	# 純思想說服：沿用 #227 對 Agent 目標的效果，寫進被說服者（這裡是玩家）
	# 的記憶。玩家沒有 LLM 可以像 Agent 那樣自己評 importance／valence
	# （見 _resolve_pending_persuade() 對應分支），這裡用固定的中等重要度、
	# 正面傾向頂：玩家已經主動選了「Y」，代表這件事對他來說值得記住、
	# 感受傾向正面，不是無中生有替他判斷
	if player.memory != null:
		player.memory.add_candidate(reason, 50, "positive", [character_id] as Array[String])

# 消化這輪待回應的說服結果（#227）。只在 _request_next_decision() 確認這輪
# envelope 真的問過模型（見那邊 had_pending_persuade 的說明）才會被呼叫——
# 不驗證、不二次判定 persuaded 本身，只決定「接受了要做什麼」：行動說服
# （帶 proposed_task）機械式推進任務池，跟一般 LLM 任務同一套驗證與仲裁；
# 純思想說服（沒有 proposed_task）寫進記憶。不接受什麼都不做。不論結果都
# 清掉待回應記錄，不重複注入同一句事實句
func _resolve_pending_persuade(data: Dictionary) -> void:
	var pending := _pending_persuade
	_pending_persuade = {}

	var persuader: String = str(pending.get("persuader", ""))
	var persuaded: bool = data.get("persuaded", false)
	var persuader_related: Array[String] = []
	var persuader_id_for_event: String = str(pending.get("persuader_id", ""))
	if not persuader_id_for_event.is_empty():
		persuader_related.append(persuader_id_for_event)

	if persuaded:
		_push_daily_event("你被%s說服了。" % persuader, persuader_related)
	else:
		_push_daily_event("你拒絕了%s的勸說。" % persuader, persuader_related)

	if not persuaded:
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
			_track_action_result_for_facts("shout", false)
			_finish_task_and_request_next()
			return
		# shout 沒有追逐、每筆任務只跑這裡一次，resolve() 通過後 make_noise()
		# 不會再失敗，這裡就是終局結果

	# 半徑沿用 make_noise() 的預設值 NOISE_RADIUS——《07》§3 已定案「聽覺
	# （shout）8 格」，跟 make_noise() 原本給玩家按鍵用的廣播半徑是同一個數字，
	# 不用另外定義一個常數
	make_noise()

	# 連續失敗事實句涵蓋所有實際執行的動作，不分來源——跟 eat/drink/talk
	# 既有規則一致（CodeRabbit review 抓到：原本只計 llm 來源，schedule 來源
	# 的 shout 成功時不會重設計數，先前的失敗事實句會卡住不消失，後續失敗
	# 也會被錯誤累計）
	_track_action_result_for_facts("shout", true)
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

# 按 character_id 找角色：following_id（#576）存的是身分而不是顯示名字，
# 才不會在跟隨對象改名／撞名時追丟；打賞轉帳（#575）也要精準指到當初排隊
# 事實句的那個 performer，不能像 talk 那樣憑顯示名找——顯示名可能撞名，
# id 不會。跟 _find_character_by_name() 用同一個 "characters" 群組，
# 不分玩家／Agent
func _find_character_by_id(target_id: String) -> Character:
	if target_id.is_empty():
		return null
	for node in get_tree().get_nodes_in_group("characters"):
		if node != self and (node as Character).character_id == target_id:
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

# 排程任務失敗退避（issue #505）：算出這個 window 下一次結束的絕對分鐘數
# （跟 _now_minutes() 同一個基準：day * 1440 + hour * 60 + minute）。用「今天
# 開始」＋window.end 的時分算出候選值，已經過了（跨午夜的 window，或現在
# 剛好卡在結束那一分鐘）就再加一天——保證回傳的是「現在之後最近一次的
# window 結束時刻」，不是任意一個過去的結束時刻
func _window_end_minutes(window: Dictionary, now_minutes: int) -> int:
	var end_parts: PackedStringArray = str(window.get("end", "")).split(":")
	var end_of_day := int(end_parts[0]) * 60 + int(end_parts[1])
	var today_start := (now_minutes / 1440) * 1440
	var end_minutes := today_start + end_of_day
	if end_minutes <= now_minutes:
		end_minutes += 1440
	return end_minutes

# 排程來源的任務這個時間窗內已知會失敗（issue #505）：記下窗期結束的絕對
# 分鐘數，掛在 task 這個 Dictionary 物件本身（跟 _tasks 池子裡是同一個參照，
# 不是複本）。eat／drink 這類「呼叫一次就完成」的動作每次執行完不管成敗都
# 會 _clear_current_task()，所以真正擋下「每個遊戲分鐘重試」的是
# _reevaluate_once() 選任務時看到這個標記就跳過該候選——task 這個 Dictionary
# 還在 _tasks 池子裡、標記還留著，不會在下一分鐘又被選回來，交給次高分的
# 候選或乾脆沒有候選（角色站著不動，直到窗期結束）。下一個時間窗（例如明天
# 同一個 window）now_minutes 自然超過這個值，不用另外清除標記。
#
# 只對 schedule 來源、且有 window 的任務生效——llm 來源失敗直接 _remove_task()
# 離開池子，不需要退避；沒有 window 的排程任務（目前 npc_schedule.json 沒有
# 這種案例，見 _tasks_from_schedule_json() 的說明）沒有窗期終點可以退避到，
# 先不處理，等真的出現這種案例再補
func _mark_schedule_retry_backoff(task: Dictionary) -> void:
	if task.get("source", "") != "schedule":
		return
	var window: Variant = task.get("window")
	if window == null:
		return
	task["_retry_blocked_until"] = _window_end_minutes(window, _now_minutes())

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
	# expires_at 是安全網，不能比完成判定（_reevaluate_once() 用
	# _effective_action_duration() 算的有效時長）先到期——不然 sleepy 狀態
	# 下這筆任務會在真正做完前就被過期清除迴圈提前拿掉（CodeRabbit review 抓到）
	var tasks: Array[Dictionary] = [{
		"action": action,
		"params": params,
		"priority": DEBUG_TASK_PRIORITY,
		"duration": duration,
		"expires_at": _now_minutes() + int(ceil(_effective_action_duration(duration))),
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
