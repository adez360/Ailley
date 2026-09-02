class_name Player
extends Character

## 玩家操作的角色。輸入優先於 A* 自動移動：一按方向鍵就中斷現有路徑。
## 對話中依然吃得到方向鍵 —— 走遠了由 conversation.gd 的距離判定自然散場，
## 不需要另外做「離開對話」的操作。

## chat_input.gd 在玩家對話中打字送出時發這個訊號。
## 不直接讓 chat_input.gd 呼叫 conversation 物件——玩家不知道、也不該知道
## 自己現在是不是在跟一場 Conversation 物件對話，只知道「我打字、我的角色講話」，
## 這個訊號是 Character 介面本來就有的東西（spoke 訊號同一種精神）
signal line_submitted(text: String)

## 玩家這一輪有結果了：打字送出（ok=true），或這一輪被取消（ok=false，
## 走遠散場／按 E 離開）。只在 next_line() 真的在等待時（_turn_waiting）才會發——
## 玩家提早打字的那些話改走 _pending_lines 緩衝，不直接 emit（見 _on_line_submitted()）。
##
## `next_line()` 等的是這個而**不是**直接等 `line_submitted`：後者只在玩家真的
## 打字時才發，玩家還沒打字就離開對話的話那個 await 永遠不會回來，
## `conversation.gd` 的 `_run()` 就永遠停在那裡——而它是唯一能安全釋放
## Conversation 節點的地方（見該檔 `_finish()` 的說明），節點因此永遠留在場景樹上
signal turn_resolved(text: String, ok: bool)


## 玩家頭上「休息中」的常駐提示符號（issue #926）——純符號、不走 L10n
const RESTING_TEXT := "💤"

## 玩家提早打字（還沒真的輪到自己）時暫存的話，見 _on_line_submitted()
## 與 next_line() 開頭的緩衝檢查（#207）。FIFO 佇列而不是單一欄位——
## 單一欄位在玩家提交兩次時，較晚的那句會直接覆蓋掉還沒被 next_line()
## 取用的前一句，前一句就這樣靜默消失（CodeRabbit review 抓到）
var _pending_lines: Array[String] = []

## _pending_lines 上限（issue #843）：原本無上限，玩家可以趁 NPC／LLM 還沒
## 回應時連續打好幾句排隊，體驗上會跟對話實際節奏脫節——打的話已經不是在
## 回應剛剛聽到的內容。滿了之後 chat_input.gd 鎖住輸入框，不讓玩家再開
## 新的一句，等 next_line() 消化掉排隊的句子、緩衝區空出位置才解鎖
const MAX_PENDING_LINES := 3

## chat_input.gd 開啟輸入框前呼叫，判斷要不要鎖住（issue #843）。真的輪到
## 玩家（_turn_waiting）時永遠放行——那是 next_line() 直接在等的那一句，
## 跟排隊無關；不是輪到玩家時才看緩衝區還有沒有位置
func can_queue_line() -> bool:
	return _turn_waiting or _pending_lines.size() < MAX_PENDING_LINES

## next_line() 正在 await turn_resolved 的期間才是 true——_on_line_submitted()
## 與 exit_conversation() 靠這個判斷「現在直接 emit 給正在等的 next_line()」
## 還是「還沒輪到，先緩衝」（#207）
var _turn_waiting := false

@onready var interact_area: Area2D = $Sensing/InteractArea

## InteractArea 目前偵測到的候選（工作站／販賣機，靠 collision layer "interactable"
## 篩選，見 project.godot 的 layer_3）。角色候選不走這裡——直接沿用
## vision.get_visible_characters()，見 _get_interact_candidates() 的說明
var _nearby_interactables: Array[Node2D] = []

## Player 的 character_id 跨場次持久化檔案，跟世界／角色存檔（user://saves_<hash>/
## characters|worlds/）分開放——這個檔案不屬於 SaveService 那套整包讀寫／
## 版本／鎖的機制，它從頭到尾只有一個值，寫一次之後只會被讀取（issue #399）
##
## user:// 只依 project.godot 的 project name 解析，不分 worktree/checkout，
## 跟 DatabaseManager.DATABASE_PATH（issue #334）同一個病根：用 CheckoutIsolation
## 算出的雜湊接在子目錄後，讓不同 checkout 落地成不同實體檔案，不會互相
## 覆寫（issue #769／#987）
var _PLAYER_ID_PATH := _compute_player_id_path()


static func _compute_player_id_path() -> String:
	return "user://saves_%s/player_id.txt" % CheckoutIsolation.compute_hash()

## 搭話診斷用的逐筆 print()（issue #654：兩個角色重疊時搭話完全沒反應）。
## 正常遊玩預設關閉；除錯時改成 true。與 Conversation.TALK_DEBUG（PR #723）
## 各自獨立，輸出前綴用 [talk_debug_654] 區分調查主題。問題查清楚後這段
## 要整段拿掉，不是永久留著的 log
const TALK_DEBUG := false


func _ready() -> void:
	# Character._ready() 會用 facing 播 idle 動畫（預設 "front"），玩家出生要面向
	# 後方，得在 super() 之前設好，不然 player.tscn 場景檔設的 idle_back 只是編輯器
	# 預覽用，實際一進遊戲就被蓋成 idle_front（CodeRabbit review on #587 抓到）
	facing = "back"
	super()
	add_to_group("player")
	line_submitted.connect(_on_line_submitted)
	noise_heard.connect(_on_noise_heard)

	# 半徑動態算 maxf(...)，不能寫死：WORK_RANGE／TALK_RANGE／BUY_RANGE 是三個
	# 故意保持獨立可調的常數（見 note/技術/販賣機.md），這裡只是先撈進一個
	# 夠大的候選集合，真正的門檻在 _nearest_facing() 用各自的 range 再篩一次
	var shape := interact_area.get_node("CollisionShape2D").shape as CircleShape2D
	shape.radius = maxf(WORK_RANGE, maxf(TALK_RANGE, BUY_RANGE))
	interact_area.body_entered.connect(_on_interact_area_body_entered)
	interact_area.body_exited.connect(_on_interact_area_body_exited)

# InteractArea 的 collision_mask 只認 "interactable" 層，工作站／販賣機以外的
# 東西（地形、其他角色）本來就進不來，不用像 vision.gd 那樣濾除自己——
# Player 自己的 collision_layer 是 "character"，不在這層上，偵測不到自己
func _on_interact_area_body_entered(body: Node2D) -> void:
	if not _nearby_interactables.has(body):
		_nearby_interactables.append(body)

func _on_interact_area_body_exited(body: Node2D) -> void:
	_nearby_interactables.erase(body)

## 範圍內有人 make_noise()／shout 時（issue #376），玩家跟 agent.gd 非 LLM
## 模式下的 fallback 走同一條路——冒 !?。玩家沒有 LLM 決策迴圈可以問「要不要
## 有反應」，這裡不是引擎替玩家決定了什麼感受，只是把「有事發生」這個感測
## 結果顯示出來，要不要理會是玩家自己的事（跟《00》原則二「引擎只給事件，
## 不給情緒」對到的是 AI 那一側，這裡對應的是把感測結果曝光給操作者本人）。
## 對話中不冒泡：跟 agent.gd 的 _on_noise_heard() 同一個理由，避免打斷正在
## 顯示的對話內容。死屍不反應（CodeRabbit review 抓到，同 agent.gd 的
## _on_noise_heard() 一致）——這是 character.gd::make_noise() 直接觸發的外部
## 事件回呼，不會自動被別處的死亡判斷擋掉。make_noise() 本身已經排除自己
## （見 Character.make_noise()），這裡不用再另外判斷來源是不是自己
func _on_noise_heard(_source: Character) -> void:
	if is_dead or is_in_conversation():
		return
	# broadcast=false：這是系統 fallback 泡泡，不是玩家真的說了什麼，不該被
	# 3 格內的 NPC 當成「聽到的對話」去反應、問一次決策——同 agent.gd 的理由，
	# 見 character.gd::say() 的說明（CodeRabbit review 抓到，PR #674）
	say(L10n.t("DLG_NOISE_ALERT"), false, false)

# 打字是「這一輪有結果了」的其中一種來源，另一種是對話結束（見 exit_conversation()）。
# 兩者收斂成同一個訊號，next_line() 才只要等一個東西。
#
# _turn_waiting 是 false 的話代表玩家打字時根本沒有 next_line() 在 await——
# 例如輪到 NPC 講話、NPC 還在等 LLM 回應——這時候直接 emit 會讓 turn_resolved
# 發進沒人接的地方，訊號就這樣憑空消失（issue #207 已重現的 bug）。改成先存進
# _pending_lines，等真正輪到玩家、next_line() 開頭檢查到緩衝區有內容就依序取用
func _on_line_submitted(text: String) -> void:
	if _turn_waiting:
		turn_resolved.emit(text, true)
	else:
		_pending_lines.append(text)

# 對話結束時取消還在等打字的那一輪。conversation.gd 的 _finish() 一定會對雙方
# 呼叫這個函式，所以不管是走遠散場、按 E 離開、還是對方結束，都會走到這裡。
# 只有真的有 next_line() 在等待時才需要 emit 取消——沒在等待時 emit 只會是
# 發進沒人接的訊號（跟上面 _on_line_submitted() 同一個理由），順便清掉任何
# 殘留的緩衝，不讓上一場對話沒送出的半句話流進下一場對話
func exit_conversation(reason: String = "") -> void:
	super(reason)
	_pending_lines.clear()
	if _turn_waiting:
		turn_resolved.emit("", false)

# 用 _unhandled_input 而不是 _input：debug 主控台的輸入框拿到焦點時
# 打字不該觸發搭話
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("make_noise"):
		get_viewport().set_input_as_handled()
		make_noise()
		return

	# 用快捷欄目前選取格裡的東西（#611）。跟 make_noise 同一種優先序——不管
	# 對話中或選單開著都能觸發，不用擠進下面那條 interact 的攔截鏈
	if event.is_action_pressed("use_item"):
		get_viewport().set_input_as_handled()
		var use_reason := use_selected_item()
		if use_reason != USE_ITEM_OK:
			report_action_failure("use_item", use_reason)
		return

	if event.is_action_pressed("attack"):
		get_viewport().set_input_as_handled()
		var attack_target: Character = _get_interact_candidates()["other"]
		if attack_target != null and attack_target.is_dead:
			attack_target = null
		var attack_reason := attack(attack_target)
		if attack_reason != ATTACK_OK:
			report_action_failure("attack", attack_reason)
		return

	# 休息（issue #926）：獨立按鍵，跟 make_noise／use_item／attack／give 同一種
	# 「不擠進 interact 優先序鏈」的頂層檢查，不用先找互動候選。契約是「按住
	# 休息」（PR 描述與《玩家休息機制》都寫按住）：按住 Z 休息、放開就停，
	# 單點一下不會留下沒人按著還在回復的休息狀態（CodeRabbit review 抓到；
	# 按下時還在休息就收掉，是放開事件被別的 UI 吃掉時的保險）
	if event.is_action_pressed("rest"):
		get_viewport().set_input_as_handled()
		_toggle_resting()
		return
	if event.is_action_released("rest") and _is_resting:
		get_viewport().set_input_as_handled()
		_stop_resting()
		return

	# 送禮（issue #841）：獨立按鍵，不擠進 interact（E）那條已經很長的優先序鏈
	# （工作／商店／搬運／復活／打賞／搭話）——give 目標判定只看「面向且在
	# 範圍內」，跟 attack 同一套 _get_interact_candidates()["other"]，不需要
	# 額外分流。開的是選單（選物品），不像 attack 按下去立刻執行，所以目標
	# 找不到時直接回報失敗，找得到就交給 give_menu 自己接手後續
	if event.is_action_pressed("give"):
		get_viewport().set_input_as_handled()
		var give_menu := get_tree().get_first_node_in_group("give_menu")
		if give_menu != null and give_menu.is_open():
			return
		var give_target: Character = _get_interact_candidates()["other"]
		if give_target != null and give_target.is_dead:
			give_target = null
		if give_target == null:
			report_action_failure("give", Character.GIVE_TARGET_NOT_FOUND)
			return
		if give_menu != null:
			give_menu.open(give_target, self)
		return

	if not event.is_action_pressed("interact"):
		return

	# 兩個選單節點先在進入點 log 之前取得，log 才能把三道 guard 的判定
	# 一起印出來（取得順序不影響行為，guard 檢查本身維持原位）
	var vending_menu := get_tree().get_first_node_in_group("vending_menu")
	var tip_menu := get_tree().get_first_node_in_group("tip_menu")
	if TALK_DEBUG:
		print("[talk_debug_654] E 鍵進入互動：vending_menu.is_open()=%s | tip_menu.is_open()=%s | is_in_conversation()=%s" % [
			str(vending_menu != null and vending_menu.is_open()),
			str(tip_menu != null and tip_menu.is_open()),
			str(is_in_conversation()),
		])

	# 販賣機選單開著時，這個 E 是要給選單用來關閉／已經在選單裡點過商品了，
	# 不該在這裡又被當成「開始一個新的互動」——不 set_input_as_handled()，
	# 讓事件繼續往下傳給 vending_menu.gd 自己的 _unhandled_input 處理
	if vending_menu != null and vending_menu.is_open():
		return

	# tip_menu 開著時同理 vending_menu（CodeRabbit review 抓到）：漏了這道
	# guard 的話，Player 這裡會搶先吃掉 interact／ui_cancel 事件、呼叫
	# set_input_as_handled()，tip_menu.gd 自己的 _unhandled_input() 永遠輪
	# 不到、選單關不掉
	if tip_menu != null and tip_menu.is_open():
		return

	# corpse_menu 開著時同一個理由（issue #758）
	var corpse_menu := get_tree().get_first_node_in_group("corpse_menu")
	if corpse_menu != null and corpse_menu.is_open():
		return

	# give_menu 開著時同一個理由（issue #841）：give_menu.gd 自己接 interact
	# 當關閉鍵，這裡漏了 guard 的話，E 會被這裡搶先吃掉、選單關不掉
	var give_menu_open_check := get_tree().get_first_node_in_group("give_menu")
	if give_menu_open_check != null and give_menu_open_check.is_open():
		return

	get_viewport().set_input_as_handled()

	# 搬運中時 E 只做「安葬或放下」，不落入下面搭話／工作／商店的判斷——雙手
	# 抱著屍體沒道理還能開別的互動。bury() 本身已經檢查距離／是否在墓園／
	# 墓碑格數，這裡不用重複算：能安葬就安葬；只差墓園位置的話，直接當成
	# 玩家想放下（issue #826 建議 2：不強制走到墓園才能結束搬運），沒有專門
	# 另開一個按鍵；其餘失敗原因（墓碑滿了）才真的回報給玩家
	if is_hauling():
		var haul_target := get_hauling_target()
		# 昏迷但還活著的目標不是屍體，bury() 一定回傳 BURY_TARGET_NOT_DEAD——
		# 這種情況沒有「安葬」可言，直接當放下處理（issue #958）
		if not haul_target.is_dead:
			# 玩家主動放下，不冒「掙脫」假事實（原則二）：引擎側釋放應傳 notify_target=false
			stop_haul(false)
			return
		var bury_reason := bury(haul_target)
		if bury_reason == BURY_OK:
			return
		if bury_reason == BURY_NOT_AT_CEMETERY:
			stop_haul()
			return
		report_action_failure("bury", bury_reason)
		return

	if is_in_conversation():
		leave_conversation()
		return

	# 附近的可互動物件（工作站、販賣機）與可搭話的人，三邊都先找出來，誰近誰
	# 先試——但「近」先被「有沒有面向它」篩過一輪，見 _get_interact_candidates()
	# 的說明。失敗會用 report_action_failure() 統一顯示在自己頭上（issue #180），
	# 不再是純靜默——同時也還會印成 warning，方便開發時對著編輯器 Output/
	# Debugger 面板看，不用另外開主控台查
	var candidates := _get_interact_candidates()
	var workstation: Workstation = candidates["workstation"]
	var shop_place: String = candidates["shop_place"]
	var downed: Character = candidates["downed"]
	var other: Character = candidates["other"]
	var corpse: Character = candidates["corpse"]

	# 除錯用（issue #654：兩個角色重疊站在同一格時搭話完全沒反應，追不到
	# 原因，程式碼審查沒看出漏洞）。列出這一刻視野裡的每個角色跟距離／
	# 面向判定結果，重現時對照 Output/Debugger 面板看是卡在哪一步：
	# visible_characters 裡有沒有兩個都在、_is_facing() 有沒有兩個都過、
	# 最後選中的是哪一個（或 null）。問題查清楚、改完 talk_to() 之後這段
	# 要記得拿掉，不是永久留著的 log
	if TALK_DEBUG:
		var visible_for_debug: Array = vision.get_visible_characters() if vision != null else []
		print("[talk_debug_654] E 鍵按下，視野內角色數=%d" % visible_for_debug.size())
		for c in visible_for_debug:
			if not is_instance_valid(c):
				continue
			var pos: Vector2 = (c as Character).get_body_position()
			print("[talk_debug_654]   候選 %s | pos=%s | facing=%s | dist=%.1f" % [
				(c as Character).character_id,
				pos,
				_is_facing(pos),
				get_body_position().distance_to(pos),
			])
		print("[talk_debug_654] _nearest_facing() 選中 other=%s" % (other.character_id if other != null else "null"))

	# 失敗要往下掉到搭話，不是直接 return。工作站被別人佔用（WORK_OCCUPIED）
	# 或自己正在工作（WORK_BUSY）時直接 return 的話，E 整個沒反應 ——
	# 玩家連站在眼前那個正在工作的人都搭不了話
	if workstation != null and candidates["to_work"] <= candidates["to_shop"] \
			and candidates["to_work"] <= candidates["to_downed"] \
			and candidates["to_work"] <= candidates["to_other"]:
		var work_reason := work_at(workstation)
		if work_reason == WORK_OK:
			# 開工成功就立刻收掉休息——不等的話要到下一個遊戲分鐘
			# _on_game_minute() 才會靠 _is_resting_blocked()（含 is_working()）把
			# 休息收掉，這中間 💤 會跟工作進度條並存一段（CodeRabbit review 抓到）
			if _is_resting:
				_stop_resting()
			if TALK_DEBUG:
				print("[talk_debug_654] 走了 work_at 分支（成功），work_reason=%s" % work_reason)
			return
		if other == null:
			_report_work_failure(workstation, work_reason)
			return
		# 工作失敗但旁邊還有人可以互動——對方正在表演的話跟下面主路徑同一種
		# 判斷，開打賞選單而不是搭話（CodeRabbit review 抓到：這條 return
		# 分支原本會搶在下面的 tip_menu 判斷之前結束，讓表演中的人在這裡
		# 只能被搭話，開不了打賞選單）
		if other.is_performing() and tip_menu != null:
			if TALK_DEBUG:
				print("[talk_debug_654] 走了打賞選單分支（工作站 fallback 路徑）")
			tip_menu.open(other, self)
			return
		# 否則先試搭話，兩邊都失敗才回報，不然「工作站被佔用」跟「搭話失敗」
		# 會疊成兩則訊息一起蹦出來
		var fallback_talk_reason := talk_to(other)
		if TALK_DEBUG:
			print("[talk_debug_654] 走了工作站 fallback 搭話分支，reason=%s（顯示的是 work_reason=%s）" % [fallback_talk_reason, work_reason])
		if fallback_talk_reason != TALK_OK:
			_report_work_failure(workstation, work_reason)
		return
	# 商店不是立刻執行動作，是開商品選單——真正的購買發生在
	# vending_menu.gd 裡點下某一項的時候。vending_menu 理論上一定找得到
	# （場景裡固定掛著），這裡多防一手是避免場景漏掛的話直接炸掉
	elif not shop_place.is_empty() and candidates["to_shop"] <= candidates["to_downed"] \
			and candidates["to_shop"] <= candidates["to_other"] and vending_menu != null:
		if TALK_DEBUG:
			print("[talk_debug_654] 走了販賣機選單分支，shop_place=%s" % shop_place)
		vending_menu.open(shop_place, self)
		return
	# 昏迷角色跟可搭話對象互斥（見 _get_interact_candidates() 的說明），
	# 這裡不是比大小決優先序，純粹是「範圍內有沒有昏迷者」決定 E 是搬運
	# 還是搭話（issue #637）
	elif downed != null and candidates["to_downed"] <= candidates["to_other"]:
		if TALK_DEBUG:
			print("[talk_debug_654] 走了昏迷搬運分支（issue #637）")
		var haul_reason := start_haul(downed)
		if haul_reason != HAUL_OK:
			report_action_failure("start_haul", haul_reason)
		return

	# 對著石化的屍體按 E 開的是「復活／搬運」二選一選單（issue #758），不是
	# 直接跟他聊天。revive() 跟 start_haul() 對屍體都能成功執行，同一個 interact
	# 鍵沒辦法讓玩家表達要哪一種，所以跟 tip_menu 同一種「開小選單」寫法。
	# 屍體候選走 vision.get_corpses()（issue #986 把死者移出 _visible，issue
	# #1026 補上這條路），不是從 `other` 反推。corpse_menu 理論上一定找得到
	# （場景裡固定掛著），跟 vending_menu／tip_menu 同一種「多防一手」寫法——
	# 場景漏掛時退回原本「直接復活」的舊行為，不讓 E 整個沒反應。
	# 屍體比可搭話對象遠時讓位給搭話（跟 downed 對 other 同一種距離判斷）
	if corpse != null and candidates["to_corpse"] <= candidates["to_other"]:
		if corpse_menu != null:
			if TALK_DEBUG:
				print("[talk_debug_654] 走了屍體復活／搬運選單分支（issue #758）")
			corpse_menu.open(corpse, self)
			return
		var revive_reason := revive(corpse)
		if TALK_DEBUG:
			print("[talk_debug_654] 走了直接復活分支（corpse_menu 漏掛 fallback），reason=%s" % revive_reason)
		if revive_reason != REVIVE_OK:
			report_action_failure("revive", revive_reason)
		return

	# 對方正在表演時，E 開的是打賞選單而不是搭話——玩家（天神）主動打賞是
	# 全新的 UI 互動，直接呼叫 Inventory.add_money()，不走 AI 決策（#575 拍板）。
	# tip_menu 理論上一定找得到（場景裡固定掛著），跟 vending_menu 同一種
	# 「多防一手」寫法，避免場景漏掛時直接炸掉。變數在函式開頭已經宣告過
	# 一次（給上面關閉選單那道 guard 用），這裡直接沿用，不重複宣告
	if other != null and other.is_performing() and tip_menu != null:
		if TALK_DEBUG:
			print("[talk_debug_654] 走了打賞選單分支（主路徑）")
		tip_menu.open(other, self)
		return

	var talk_reason := talk_to(other)
	if TALK_DEBUG:
		print("[talk_debug_654] 走了主路徑 talk_to 分支，reason=%s" % ("(OK)" if talk_reason == TALK_OK else talk_reason))	# 除錯用，見上方 issue #654 說明
	if talk_reason != TALK_OK:
		report_action_failure("talk_to", talk_reason)

## work_at() 失敗的回報——WORK_OCCUPIED 額外算出還要等幾分鐘（issue #663），
## 比通用的 FAIL_OCCUPIED 訊息更有用：玩家才知道該站在這裡等還是先去做別的
## 事。其餘原因碼（TOO_FAR／BUSY／TARGET_NOT_FOUND）沒有額外資訊可加，照走
## report_action_failure() 既有的通用路徑
func _report_work_failure(workstation: Workstation, reason: String) -> void:
	if reason != WORK_OCCUPIED:
		report_action_failure("work_at", reason)
		return
	var minutes := workstation.get_wait_minutes()
	push_warning("%s: work_at 失敗（%s，還要 %d 分鐘）" % [character_name, reason, minutes])
	say(L10n.tf("FAIL_OCCUPIED_WITH_TIME", {"minutes": minutes}))

# 面向判定的錐角容許值：跟面向方向的內積要 >= 這個值才算「面對著」。
# 0.5 大約是 ±60 度的錐角——夠寬容得下斜向靠近的誤差，又不會寬到整個
# 半圓都算數（那樣就跟沒篩選一樣）
const FACING_DOT_THRESHOLD := 0.5

# target 是不是落在玩家目前面向的方向上。target 就在腳下（距離 0，理論上
# 不會發生，但除以零要擋）視為面向著，避免這種邊界情況把候選判掉
func _is_facing(target: Vector2) -> bool:
	var to_target := target - get_body_position()
	if to_target == Vector2.ZERO:
		return true
	return get_facing_direction().dot(to_target.normalized()) >= FACING_DOT_THRESHOLD

## 找出目前附近的四種互動候選（工作站／商店地點／昏迷角色／可搭話的人）跟各自的距離。
## `_unhandled_input()`（按 E 真的觸發）跟 `_process()`（每幀更新高亮）共用
## 這個函式——兩邊要看到同一個答案，不然會出現「亮的是這個，按下去卻打到
## 另一個」的狀況，比原本沒有高亮更誤導人。
##
## 純比距離會撞到 issue #81：桌子等固定物件很容易落在某個地點錨點的互動
## 半徑內（`square` 那張距錨點 21px < WORK_RANGE 32），agent 的行程又正好把
## NPC 帶去那些錨點，NPC 幾乎必然比物件更近，物件因此永遠打不到。改成先用
## `_is_facing()` 把沒面向的候選直接排除，玩家沒面向任何東西時四個候選都是
## 空——這是刻意拍板的硬性門檻，不是「面向只影響排序」：站在物件正上方但
## 背對著，不該選得到它，玩家得自己轉身面對。
##
## 工作站候選來自 InteractArea（Area2D，見 _ready()），取代原本每次呼叫都
## 掃過整個 group 的寫法。商店候選（issue #572）不是場景物件，直接對
## `_nearest_shop_place()` 那兩個已知地點各檢查一次距離＋面向，數量固定
## 只有 2 個，不值得為此另開一個 Area2D。角色候選改用
## `vision.get_visible_characters()`，不另開 Area2D（issue #109 拍板，見
## note/技術/talk 動作設計.md）——反正 talk_to() 已經要做視線判定，搭話
## 候選跟著視線走沒理由重複維護兩份
##
## 昏迷角色（`downed`）跟可搭話對象（`other`）從同一份 vision 清單分流、互斥——
## 昏迷者不進 `other`：talk_to() 沒有擋昏迷目標（is_talk_interruptible() 只看
## _working／is_dead／is_offline_asleep），兩邊都收會讓同一個人同時是搭話候選
## 又是搬運候選，距離又剛好一樣（HAUL_RANGE == TALK_RANGE），還得另外決哪個優先。
## 分流後兩邊各自呼叫一次 _nearest_facing()，跟 workstation 同一種寫法（issue #637）
##
## 屍體（`corpse`）走 vision.get_corpses()、不在 get_visible_characters() 裡
## （issue #986 把死者移出 _visible），跟 downed／other 一樣各自 _nearest_facing()
## 一次。對屍體按 E 開「復活／搬運」選單（issue #758），見 _unhandled_input()
func _get_interact_candidates() -> Dictionary:
	var workstation := _nearest_facing(_nearby_group("workstations"), WORK_RANGE, func(n): return n.global_position) as Workstation
	var shop_place := _nearest_shop_place()
	var visible_characters: Array = vision.get_visible_characters() if vision != null else []
	var corpse_characters: Array = vision.get_corpses() if vision != null else []
	var downed_characters := visible_characters.filter(func(n): return (n as Character).has_condition(CONDITION_INCAPACITATED))
	var talkable_characters := visible_characters.filter(func(n): return not (n as Character).has_condition(CONDITION_INCAPACITATED) and not (n as Character).is_offline_asleep)
	var downed := _nearest_facing(downed_characters, HAUL_RANGE, func(n): return (n as Character).get_body_position()) as Character
	var other := _nearest_facing(talkable_characters, TALK_RANGE, func(n): return (n as Character).get_body_position()) as Character
	var corpse := _nearest_facing(corpse_characters, HAUL_RANGE, func(n): return (n as Character).get_body_position()) as Character

	# 不在範圍內／沒被面向的候選距離是 INF，直接輸掉比較，不用另外再寫一層
	# null／空字串判斷
	var anchors := get_tree().get_first_node_in_group("place_anchors")
	return {
		"workstation": workstation,
		"shop_place": shop_place,
		"downed": downed,
		"other": other,
		"corpse": corpse,
		"to_work": get_body_position().distance_to(workstation.global_position) if workstation != null else INF,
		"to_shop": get_body_position().distance_to(anchors.resolve(shop_place)) if not shop_place.is_empty() and anchors != null else INF,
		"to_downed": get_body_position().distance_to(downed.get_body_position()) if downed != null else INF,
		"to_other": get_body_position().distance_to(other.get_body_position()) if other != null else INF,
		"to_corpse": get_body_position().distance_to(corpse.get_body_position()) if corpse != null else INF,
	}

## 餐酒館／藥草鋪這兩個地點目前唯一還有 buy 這個交易入口（issue #572：拿掉
## 販賣機實體道具，改成直接跟地點互動）
const SHOP_PLACES := ["tavern", "herb_shop"]

## 站在商店地點旁邊、且面向該地點時，回傳地點名稱；都不符合回空字串。
## 跟 _nearest_facing() 同一套「面向＋距離」判斷，只是候選是固定的兩個
## PlaceAnchors 座標，不是場上的節點
func _nearest_shop_place() -> String:
	var anchors := get_tree().get_first_node_in_group("place_anchors")
	if anchors == null:
		return ""

	var best_place := ""
	var best_distance := INF

	for place in SHOP_PLACES:
		if not anchors.has(place):
			continue

		var target: Vector2 = anchors.resolve(place)
		if not _is_facing(target):
			continue

		var distance := get_body_position().distance_to(target)
		if distance > BUY_RANGE:
			continue

		if distance < best_distance:
			best_distance = distance
			best_place = place

	return best_place

## 同一類（工作站／販賣機／角色）裡，玩家面向著的、距離最近的那個。沒面向
## 的候選直接跳過，不進距離比較——即使範圍內只有這一個候選，沒面向就是
## 沒面向，不會因為沒有對手就選到它。
##
## **不是**用整個 group 下去掃——那是純比物理距離選一個，會讓較近但沒被
## 面向的候選在選取那一步就把較遠但被面向的候選擋掉，永遠沒機會進入距離比較
## （CodeRabbit review 抓到：兩隻 Agent 站在玩家前後時，背後 8px 沒被面向的
## 那隻會讓正前方 20px 被面向的那隻完全不參與比較）。candidates 現在是先經過
## InteractArea／Vision 篩過一輪的小集合，不是整個 group
func _nearest_facing(candidates: Array, max_distance: float, position_of: Callable) -> Node2D:
	var best: Node2D = null
	var best_distance := INF

	for node in candidates:
		if not is_instance_valid(node) or node == self:
			continue

		var target: Vector2 = position_of.call(node)
		if not _is_facing(target):
			continue

		var distance := get_body_position().distance_to(target)
		if distance > max_distance:
			continue

		if distance < best_distance:
			best_distance = distance
			best = node

	return best

# InteractArea 偵測到的候選裡，篩出屬於某個 group 的那些（目前只有工作站
# 還在用——商店改成地點導向後不再靠這個找，見 _nearest_shop_place()）
func _nearby_group(group: String) -> Array:
	return _nearby_interactables.filter(func(n): return is_instance_valid(n) and n.is_in_group(group))

# 每幀重算一次「E 現在會打到誰」並更新高亮，跟 selection.gd::_update_hover()
# 同一種寫法——目標沒變就不重複呼叫 set_highlighted()。對話中不顯示任何
# 互動高亮：這時候按 E 是離開對話，不是觸發工作站/商店/搭話。商店（issue
# #572 起）不是場景物件，沒有節點可以掛描邊高亮，這裡只算優先序、不畫
# 任何東西——玩家走進 BUY_RANGE 面向地點就能按 E，沒有額外的視覺提示
var _highlighted_workstation: Workstation = null
var _highlighted_other: Character = null

func _process(_delta: float) -> void:
	var vending_menu := get_tree().get_first_node_in_group("vending_menu")
	var tip_menu := get_tree().get_first_node_in_group("tip_menu")
	var corpse_menu := get_tree().get_first_node_in_group("corpse_menu")

	# 選單開著時 E 是關閉選單（見 vending_menu.gd／tip_menu.gd／corpse_menu.gd
	# 自己的 _unhandled_input），不是這幾個候選裡的任何一個——選單不擋移動，玩家
	# 開著選單照樣能走位/轉向，這裡不擋的話高亮會跟著跳來跳去，暗示 E 現在
	# 會搭話/工作，實際上按下去只會關掉選單，跟對話中不顯示互動高亮是同一個
	# 理由。tip_menu 漏了這道 guard 會讓表演者在選單開著時還被畫成「可以互動」
	# （CodeRabbit review 抓到）
	if is_in_conversation() or (vending_menu != null and vending_menu.is_open()) \
			or (tip_menu != null and tip_menu.is_open()) \
			or (corpse_menu != null and corpse_menu.is_open()):
		_set_highlighted_workstation(null)
		_set_highlighted_other(null)
		return

	var candidates := _get_interact_candidates()
	var workstation: Workstation = candidates["workstation"]
	var downed: Character = candidates["downed"]
	var other: Character = candidates["other"]
	var corpse: Character = candidates["corpse"]

	var target_workstation: Workstation = null
	var target_other: Character = null

	# 跟 _unhandled_input() 判斷「E 會打到誰」用同一套優先序，只是不含失敗
	# 重試那段——重試只在真的按下 E、真的失敗時才有意義，高亮只回答
	# 「等一下按下去會先試誰」。商店分支沒有對應的高亮目標可設，這裡只是
	# 為了正確跳過下面的搭話高亮——vending_menu != null 這道防呆也要跟
	# _unhandled_input() 對齊，場景漏掛選單節點時那邊會直接退回搭話，這裡
	# 不跟著退的話會亮著一個按下去其實打不到商店的高亮。
	# downed 併進 target_other（沿用同一個高亮 setter）——玩家看到的只是
	# 「這個人會被 E 打到」，會搬運還是搭話由 _unhandled_input() 決定，
	# 高亮視覺不用另外分兩種（issue #637）
	if workstation != null and candidates["to_work"] <= candidates["to_shop"] \
			and candidates["to_work"] <= candidates["to_downed"] \
			and candidates["to_work"] <= candidates["to_other"]:
		target_workstation = workstation
	elif not String(candidates["shop_place"]).is_empty() and candidates["to_shop"] <= candidates["to_downed"] \
			and candidates["to_shop"] <= candidates["to_other"] \
			and vending_menu != null:
		pass		# 商店贏了，但沒有節點可高亮
	elif downed != null and candidates["to_downed"] <= candidates["to_other"]:
		target_other = downed
	elif corpse != null and candidates["to_corpse"] <= candidates["to_other"]:
		# 屍體優先於搭話：_unhandled_input() 的屍體分支排在 talk_to() 之前
		target_other = corpse
	elif other != null:
		target_other = other

	_set_highlighted_workstation(target_workstation)
	_set_highlighted_other(target_other)

func _set_highlighted_workstation(target: Workstation) -> void:
	if target == _highlighted_workstation:
		return
	if is_instance_valid(_highlighted_workstation):
		_highlighted_workstation.set_highlighted(false)
	_highlighted_workstation = target
	if _highlighted_workstation != null:
		_highlighted_workstation.set_highlighted(true)

func _set_highlighted_other(target: Character) -> void:
	if target == _highlighted_other:
		return
	# 用 set_interact_highlighted() 不是 set_highlighted()：後者是滑鼠 hover
	# （selection.gd）在用的欄位，兩邊合用會互相蓋掉對方還想要的高亮狀態
	if is_instance_valid(_highlighted_other):
		_highlighted_other.set_interact_highlighted(false)
	_highlighted_other = target
	if _highlighted_other != null:
		_highlighted_other.set_interact_highlighted(true)

# 讀取 WASD 輸入，回傳正規化後的方向（斜向不會加速）
func get_input_direction() -> Vector2:
	# 有文字輸入框拿到焦點時（例如 debug 輸入框）不吃移動鍵，
	# 因為 Input.get_axis() 讀的是全域輸入狀態，不會被 LineEdit 攔下來。
	# 只認 LineEdit/TextEdit，不是任意拿到焦點的 Control——Button 預設
	# focus_mode 就是 FOCUS_ALL，點過場上任何一顆按鈕（esc 選單、工具列……）
	# 之後只要沒人主動 release_focus()，焦點會一直留著，用「有沒有 Control
	# 拿焦點」當條件會讓玩家點過一次按鈕後就永久走不動
	var focus_owner := get_viewport().gui_get_focus_owner()
	if focus_owner is LineEdit or focus_owner is TextEdit:
		return Vector2.ZERO

	return Vector2(
		Input.get_axis("move_left", "move_right"),
		Input.get_axis("move_up", "move_down")
	).normalized()

func _decide_velocity() -> Vector2:
	# 被搬運時交給基底的 _follow_hauler()，玩家輸入不該蓋過（見 Character._decide_velocity()）
	if is_being_hauled():
		return super()

	# 昏迷或治療中無法移動（即使有輸入也不回應）
	if _is_movement_locked():
		return Vector2.ZERO

	var input_dir := get_input_direction()

	# 手動操作優先，直接中斷自動移動。乘 effective_speed() 而非 SPEED——
	# 搬運屍體時要吃到 _speed_multiplier 減速，跟 _follow_hauler() 用的
	# 是同一個倍率，玩家跟被搬運目標才會同速（issue #822）
	if input_dir != Vector2.ZERO:
		# 移動輸入立即取消休息——玩家按方向鍵顯然是想走了，不用另外按一次休息鍵
		# 才能離開這個狀態（issue #926）
		if _is_resting:
			_stop_resting()
		if is_moving():
			stop_moving()
		return input_dir * effective_speed()

	return super()

## 玩家專屬體力／清醒度回復機制（issue #926）。玩家沒有 Agent 的 LLM 決策
## 迴圈，沒辦法比照 NPC 那樣「先講好要睡多久」再一次套用整段回復量，改成
## 「按住休息鍵、依累積已休息的時長重新分級」——每經過一個遊戲分鐘依
## Agent.SLEEP_TIER_NAP_MIN_MINUTES／SLEEP_TIER_SLEEP_MIN_MINUTES 兩個門檻
## 重新分級一次、查 Agent.ACTION_RECOVERY 套用對應那格的回復量。三者都是
## Agent 的公開成員（class_name 靜態存取，不需要繼承關係），跟 NPC 共用
## 同一張已校調過的表，不重複一份數字；分級判斷本身很單純，直接在這裡
## 重寫兩行，不去呼叫 Agent 命名帶底線、語意上屬於內部實作的
## _classify_sleep_tier()（見 note/技術/進食與飲用.md）
var _is_resting := false
var _rest_elapsed_minutes := 0

## 開始休息前擋掉的狀態，跟 NPC 那邊「入眠中不能再入眠」同一類防呆：死亡／
## 昏迷／治療中／被天神召喚中（_is_movement_locked() 涵蓋後三者）、對話中、
## 工作中、搬運屍體、被搬運中，這些狀態下休息沒有意義或會跟既有機制衝突。
## is_working() 也擋住反方向：休息中被要求開工（work_at() 不查休息狀態）時，
## _on_game_minute() 靠同一個檢查把休息狀態收掉，兩邊不能並行
func _is_resting_blocked() -> bool:
	return is_dead or _is_movement_locked() or is_in_conversation() or is_working() or is_hauling() or is_being_hauled()

## 按下休息鍵：已經在休息就結束，否則檢查能不能開始。失敗原因統一用共用
## 詞彙表的 "BUSY"（FAILURE_MESSAGE_KEYS 已有對應），不用為這個動作另開新碼
func _toggle_resting() -> void:
	if _is_resting:
		_stop_resting()
		return
	if _is_resting_blocked():
		report_action_failure("rest", "BUSY")
		return
	_is_resting = true
	_rest_elapsed_minutes = 0
	if bubble != null:
		bubble.hold(RESTING_TEXT)

func _stop_resting() -> void:
	if not _is_resting:
		return
	_is_resting = false
	if bubble != null:
		bubble.release_hold()

## 休息中的每幀重查：被擋狀態（對話開始、開工、被搬運、昏迷……）出現的當下
## 就把休息收掉，不等下一個遊戲分鐘 `_on_game_minute()` 的重查——中途進出
## 一場對話再回來，回復不該在沒有重新按住 Z 的情況下續攤（CodeRabbit review
## 抓到）。`_is_resting_blocked()` 的每個條件都是持續性狀態，休息中不會一幀
## 真一幀假，每幀檢查不會誤殺正常休息
func _physics_process(delta: float) -> void:
	if _is_resting and _is_resting_blocked():
		_stop_resting()
	super(delta)

## Character._ready() 已經把 GameClock.time_changed 接到這個函式（見該檔
## _ready()），這裡覆寫並呼叫 super() 保留昏迷／治療／exhausted 檢查，不是
## 另開一條獨立連線——跟 agent.gd 的 _apply_action_recovery() 同一種「掛在
## 既有的每遊戲分鐘訊號上」的作法
func _on_game_minute(hour: int, minute: int) -> void:
	super(hour, minute)
	if not _is_resting:
		return
	if stats == null or _is_resting_blocked():
		_stop_resting()
		return
	_rest_elapsed_minutes += 1
	var tier := "rest"
	if _rest_elapsed_minutes >= Agent.SLEEP_TIER_SLEEP_MIN_MINUTES:
		tier = "sleep"
	elif _rest_elapsed_minutes >= Agent.SLEEP_TIER_NAP_MIN_MINUTES:
		tier = "nap"
	for recovery in Agent.ACTION_RECOVERY.get(tier, []):
		stats.add(recovery["stat"], recovery["amount"])
		# stamina 回來了要即時同步 exhausted——super() 開頭的
		# _update_exhausted_condition() 跑在回復「之前」，這裡不同步的話，
		# exhausted 會多掛一個遊戲分鐘才解除（比照 agent.gd
		# ::_apply_action_recovery() 的即時同步做法，CodeRabbit review 抓到）
		if recovery.get("stat") == "stamina":
			_update_exhausted_condition()

# 玩家的下一句話就是玩家打的字。
#
# 先檢查 _pending_lines：玩家提早打字時 _on_line_submitted() 已經把話存起來，
# 有的話取最早那句直接用掉、不用再等一次訊號（#207 的緩衝修法，見那邊的說明）。
#
# 沒有緩衝才真的開始等 turn_resolved 而不是 line_submitted——這個 await
# 一定要有辦法在「玩家沒打字就離開對話」時收場，理由見 turn_resolved 的宣告。
# ok=false 代表這一輪被取消，呼叫端（conversation.gd 的 _run()）緊接著的
# _bail_if_finished() 會看到 _finished 已經是 true 並釋放節點，不會走到
# fallback，也不會把空字串當台詞講出去。
#
# listener 頭上的「？」常駐提示只在真的要等待時才顯示（緩衝命中就立刻回傳，
# 不需要提示）；is_instance_valid() 包一層跟 conversation.gd::_finish_with_fallback()
# 同一種顧慮——await 讓出控制權的這段期間，listener 理論上可能已經離開場景
#
# 沒有 end 這個概念——玩家不是靠一個結構化欄位收尾，是靠實際走開或
# leave_conversation()（_unhandled_input 的 interact 分支），所以這裡固定 false
func next_line(listener: Character, _turns: Array[Dictionary], _max_turns: int) -> Dictionary:
	if not _pending_lines.is_empty():
		# 型別標註不能省：Array[String].pop_front() 的靜態分析器認不出元素型別，
		# := 推論會得到 Variant，這台編輯器把「從 Variant 推論」警告當錯誤看，
		# 導致這個檔案編譯失敗、連帶讓依賴它的腳本（同繼承 Character 的 Agent）
		# 一起被判定「depended script 編譯失敗」——跟 #477 無關，是解除驗證阻塞
		# 順手修的既有問題
		var line: String = _pending_lines.pop_front()
		return {"ok": true, "line": line, "end": false}

	# NPC 頭上顯示「思考中」指示，讓玩家知道對方在等自己打字（issue #207／
	# #949 B 類）。跟 AI 思考共用同一個動畫圖示——都是「系統正在等」，不是台詞
	if is_instance_valid(listener) and listener.thinking_indicator != null:
		listener.thinking_indicator.show_indicator()

	_turn_waiting = true
	var resolved: Array = await turn_resolved
	_turn_waiting = false

	if is_instance_valid(listener) and listener.thinking_indicator != null:
		listener.thinking_indicator.hide_indicator()

	return {"ok": resolved[1], "line": resolved[0], "end": false}

## NPC 對玩家發起 persuade 時（#305）跳出的 Y/N 彈窗結果。彈窗是
## scenes/persuade_dialog.tscn 的單一實例（persuade_dialog 群組，跟
## vending_menu／god_stone_input 同一種「場景裡固定掛一個、用 group 找」
## 的既有寫法），這裡只負責找到它、把文案丟過去、把結果轉交回呼叫端
## （agent.gd 的 _ask_player_persuade()）——跟 next_line()／turn_resolved
## 同一種「玩家的回應來自 UI 事件不是 LLM」的介面設計，呼叫端不用知道
## 彈窗怎麼畫、怎麼收使用者輸入
func request_persuade_response(text: String) -> bool:
	var dialog := get_tree().get_first_node_in_group("persuade_dialog")
	if dialog == null:
		push_error("player.gd: 場景裡找不到 persuade_dialog 群組的節點")
		return false
	return await dialog.ask(text)

## Player 沒有 npc_schedule.json 的 identities 項目可查（那份表本來就只給場景裡
## 固定的 NPC 用），每次開遊戲都會走到 Character._ready() 的第三層。這裡覆寫
## 掉那層預設的「即用即棄」：第一次生成後把 id 存進獨立檔案，之後開遊戲沿用
## 同一組——不然 relationships／存檔都拿 character_id 當 key，id 每次重開都變
## 等於玩家每次都是「新來的陌生人」，世界／角色存檔也永遠查不到自己（#399）
func _resolve_generated_id() -> String:
	if FileAccess.file_exists(_PLAYER_ID_PATH):
		var read_file := FileAccess.open(_PLAYER_ID_PATH, FileAccess.READ)
		if read_file == null:
			# 讀取失敗不等於檔案是空的（可能是暫時性的權限／鎖定問題），
			# 不能落到下面的寫入流程去覆蓋掉可能還是好的正式檔案。
			push_error("player.gd: 無法讀取 %s（%s），這次改用新生成的 character_id（不寫回檔案）" % [
				_PLAYER_ID_PATH, error_string(FileAccess.get_open_error())
			])
			return generate_id()
		else:
			var existing := read_file.get_as_text().strip_edges()
			read_file.close()
			if not existing.is_empty():
				return existing

	var id := generate_id()
	_write_player_id_file(id)
	return id

## character_id 被 _ensure_unique_id() 換掉時（讀進壞掉的存檔、撞到場上已有
## 的角色）同步呼叫，把新 id 寫回同一份持久化檔案——不然下次 _resolve_generated_id()
## 還是讀到那組已經被撞掉的舊 id，若造成碰撞的狀態沒消失，會在下次開遊戲時
## 再次判定碰撞、再次換新 id，等於每次重開都變（issue #438，違反 #399 想保證的
## 「跨場次同一組 id」）
func _on_id_changed(new_id: String) -> void:
	_write_player_id_file(new_id)

# 寫入 _PLAYER_ID_PATH 的共用邏輯：_resolve_generated_id() 首次生成、
# _on_id_changed() 撞號換掉後都呼叫這個。失敗只 push_error 不擋呼叫端——
# 兩個呼叫端都已經拿到可用的 character_id，寫檔只是儘量做到跨場次持久化，
# 寫不成不影響這一場正常運作
func _write_player_id_file(id: String) -> void:
	var dir := _PLAYER_ID_PATH.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	# 先寫暫存檔再 rename 蓋過去，避免 FileAccess.WRITE 直接截斷正式檔案時
	# 中途中斷（當機／強制關閉），讓 player_id.txt 留下空檔或半截 id。
	var tmp_path := _PLAYER_ID_PATH + ".tmp"
	var file := FileAccess.open(tmp_path, FileAccess.WRITE)
	if file == null:
		push_error("player.gd: 無法寫入 %s（%s），character_id 這次不會跨場次持久化" % [
			tmp_path, error_string(FileAccess.get_open_error())
		])
		return
	file.store_string(id)
	file.flush()
	var write_error := file.get_error()
	file.close()
	if write_error != OK:
		push_error("player.gd: 寫入 %s 失敗（%s），character_id 這次不會跨場次持久化" % [
			tmp_path, error_string(write_error)
		])
		DirAccess.remove_absolute(tmp_path)
		return
	var rename_error := DirAccess.rename_absolute(tmp_path, _PLAYER_ID_PATH)
	if rename_error != OK:
		push_error("player.gd: 替換 %s 失敗（%s），character_id 這次不會跨場次持久化" % [
			_PLAYER_ID_PATH, error_string(rename_error)
		])
		DirAccess.remove_absolute(tmp_path)
