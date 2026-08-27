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

## NPC 頭上「輪到你了」的常駐提示符號（issue #207）。純符號不是語言內容，
## 跟 agent.gd::AI_THINKING_TEXT（"…"）同一種處理，不走 L10n
const WAITING_FOR_PLAYER_TEXT := "？"

## 玩家提早打字（還沒真的輪到自己）時暫存的話，見 _on_line_submitted()
## 與 next_line() 開頭的緩衝檢查（#207）。FIFO 佇列而不是單一欄位——
## 單一欄位在玩家提交兩次時，較晚的那句會直接覆蓋掉還沒被 next_line()
## 取用的前一句，前一句就這樣靜默消失（CodeRabbit review 抓到）
var _pending_lines: Array[String] = []

## next_line() 正在 await turn_resolved 的期間才是 true——_on_line_submitted()
## 與 exit_conversation() 靠這個判斷「現在直接 emit 給正在等的 next_line()」
## 還是「還沒輪到，先緩衝」（#207）
var _turn_waiting := false

@onready var interact_area: Area2D = $Sensing/InteractArea

## InteractArea 目前偵測到的候選（工作站／販賣機，靠 collision layer "interactable"
## 篩選，見 project.godot 的 layer_3）。角色候選不走這裡——直接沿用
## vision.get_visible_characters()，見 _get_interact_candidates() 的說明
var _nearby_interactables: Array[Node2D] = []

## Player 的 character_id 跨場次持久化檔案，跟世界／角色存檔（user://saves/
## characters|worlds/）分開放——這個檔案不屬於 SaveService 那套整包讀寫／
## 版本／鎖的機制，它從頭到尾只有一個值，寫一次之後只會被讀取（issue #399）
const _PLAYER_ID_PATH := "user://saves/player_id.txt"


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
	say(L10n.t("DLG_NOISE_ALERT"))

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
func exit_conversation() -> void:
	super()
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

	if not event.is_action_pressed("interact"):
		return

	# 販賣機選單開著時，這個 E 是要給選單用來關閉／已經在選單裡點過商品了，
	# 不該在這裡又被當成「開始一個新的互動」——不 set_input_as_handled()，
	# 讓事件繼續往下傳給 vending_menu.gd 自己的 _unhandled_input 處理
	var vending_menu := get_tree().get_first_node_in_group("vending_menu")
	if vending_menu != null and vending_menu.is_open():
		return

	get_viewport().set_input_as_handled()

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
	var machine: VendingMachine = candidates["machine"]
	var other: Character = candidates["other"]

	# 失敗要往下掉到搭話，不是直接 return。工作站被別人佔用（WORK_OCCUPIED）
	# 或自己正在工作（WORK_BUSY）時直接 return 的話，E 整個沒反應 ——
	# 玩家連站在眼前那個正在工作的人都搭不了話
	if workstation != null and candidates["to_work"] <= candidates["to_machine"] \
			and candidates["to_work"] <= candidates["to_other"]:
		var work_reason := work_at(workstation)
		if work_reason == WORK_OK:
			return
		if other == null:
			report_action_failure("work_at", work_reason)
			return
		# 工作失敗但旁邊還有人可以搭話——先試搭話，兩邊都失敗才回報，
		# 不然「工作站被佔用」跟「搭話失敗」會疊成兩則訊息一起蹦出來
		if talk_to(other) != TALK_OK:
			report_action_failure("work_at", work_reason)
		return
	# 販賣機不是立刻執行動作，是開商品選單——真正的購買發生在
	# vending_menu.gd 裡點下某一項的時候。vending_menu 理論上一定找得到
	# （場景裡固定掛著），這裡多防一手是避免場景漏掛的話直接炸掉
	elif machine != null and candidates["to_machine"] <= candidates["to_other"] and vending_menu != null:
		vending_menu.open(machine, self)
		return

	var talk_reason := talk_to(other)
	if talk_reason != TALK_OK:
		report_action_failure("talk_to", talk_reason)

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

## 找出目前附近的三種互動候選（工作站／販賣機／可搭話的人）跟各自的距離。
## `_unhandled_input()`（按 E 真的觸發）跟 `_process()`（每幀更新高亮）共用
## 這個函式——兩邊要看到同一個答案，不然會出現「亮的是這個，按下去卻打到
## 另一個」的狀況，比原本沒有高亮更誤導人。
##
## 純比距離會撞到 issue #81：桌子與販賣機都是擺在世界裡的固定物件，很容易
## 落在某個地點錨點的互動半徑內（`square` 那張距錨點 21px < WORK_RANGE 32），
## agent 的行程又正好把 NPC 帶去那些錨點，NPC 幾乎必然比物件更近，物件因此
## 永遠打不到。改成先用 `_is_facing()` 把沒面向的候選直接排除，玩家沒面向
## 任何東西時三個候選都是 null——這是刻意拍板的硬性門檻，不是「面向只影響
## 排序」：站在物件正上方但背對著，不該選得到它，玩家得自己轉身面對。
##
## 這套判斷沒有做成套用任何「可互動物件」共通分類的通用系統，是延續 #63
## 的決定，不是這次漏做——見 note/技術/販賣機.md：「不做一套通用的互動物件
## 框架，兩個物件不值得先蓋一層抽象」，Workstation／VendingMachine 本來就是
## 兩個獨立腳本、沒有共用基底
##
## 工作站／販賣機候選來自 InteractArea（Area2D，見 _ready()），取代原本每次
## 呼叫都掃過整個 group 的寫法。角色候選改用 vision.get_visible_characters()，
## 不另開一個 Area2D（issue #109 拍板，見 note/技術/talk 動作設計.md）——
## 反正 talk_to() 已經要做視線判定，搭話候選跟著視線走沒理由重複維護兩份
func _get_interact_candidates() -> Dictionary:
	var workstation := _nearest_facing(_nearby_group("workstations"), WORK_RANGE, func(n): return n.global_position) as Workstation
	var machine := _nearest_facing(_nearby_group("vending_machines"), BUY_RANGE, func(n): return n.global_position) as VendingMachine
	var visible_characters: Array = vision.get_visible_characters() if vision != null else []
	var other := _nearest_facing(visible_characters, TALK_RANGE, func(n): return (n as Character).get_body_position()) as Character

	# 不在範圍內／沒被面向的候選距離是 INF，直接輸掉比較，不用另外再寫一層
	# null 判斷
	return {
		"workstation": workstation,
		"machine": machine,
		"other": other,
		"to_work": get_body_position().distance_to(workstation.global_position) if workstation != null else INF,
		"to_machine": get_body_position().distance_to(machine.global_position) if machine != null else INF,
		"to_other": get_body_position().distance_to(other.get_body_position()) if other != null else INF,
	}

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

# InteractArea 偵測到的候選裡，篩出屬於某個 group 的那些（工作站／販賣機
# 各自呼叫一次）——InteractArea 的半徑是三個 RANGE 常數的最大值，同一個
# collision layer 上兩種物件都會進來，這裡才依 group 分開
func _nearby_group(group: String) -> Array:
	return _nearby_interactables.filter(func(n): return is_instance_valid(n) and n.is_in_group(group))

# 每幀重算一次「E 現在會打到誰」並更新高亮，跟 selection.gd::_update_hover()
# 同一種寫法——目標沒變就不重複呼叫 set_highlighted()。對話中不顯示任何
# 互動高亮：這時候按 E 是離開對話，不是觸發工作站/販賣機/搭話
var _highlighted_workstation: Workstation = null
var _highlighted_machine: VendingMachine = null
var _highlighted_other: Character = null

func _process(_delta: float) -> void:
	var vending_menu := get_tree().get_first_node_in_group("vending_menu")

	# 選單開著時 E 是關閉選單（見 vending_menu.gd 自己的 _unhandled_input），
	# 不是這三個候選裡的任何一個——選單不擋移動，玩家開著選單照樣能走位/轉向，
	# 這裡不擋的話高亮會跟著跳來跳去，暗示 E 現在會搭話/工作，實際上按下去
	# 只會關掉選單，跟對話中不顯示互動高亮是同一個理由
	if is_in_conversation() or (vending_menu != null and vending_menu.is_open()):
		_set_highlighted_workstation(null)
		_set_highlighted_machine(null)
		_set_highlighted_other(null)
		return

	var candidates := _get_interact_candidates()
	var workstation: Workstation = candidates["workstation"]
	var machine: VendingMachine = candidates["machine"]
	var other: Character = candidates["other"]

	var target_workstation: Workstation = null
	var target_machine: VendingMachine = null
	var target_other: Character = null

	# 跟 _unhandled_input() 判斷「E 會打到誰」用同一套優先序，只是不含失敗
	# 重試那段——重試只在真的按下 E、真的失敗時才有意義，高亮只回答
	# 「等一下按下去會先試誰」。machine 分支的 vending_menu != null 防呆
	# 也要跟 _unhandled_input() 對齊：場景漏掛選單節點時那邊會直接退回
	# 搭話，這裡不跟著擋的話高亮會亮著販賣機、但按下去其實打到人
	if workstation != null and candidates["to_work"] <= candidates["to_machine"] \
			and candidates["to_work"] <= candidates["to_other"]:
		target_workstation = workstation
	elif machine != null and candidates["to_machine"] <= candidates["to_other"] and vending_menu != null:
		target_machine = machine
	elif other != null:
		target_other = other

	_set_highlighted_workstation(target_workstation)
	_set_highlighted_machine(target_machine)
	_set_highlighted_other(target_other)

func _set_highlighted_workstation(target: Workstation) -> void:
	if target == _highlighted_workstation:
		return
	if is_instance_valid(_highlighted_workstation):
		_highlighted_workstation.set_highlighted(false)
	_highlighted_workstation = target
	if _highlighted_workstation != null:
		_highlighted_workstation.set_highlighted(true)

func _set_highlighted_machine(target: VendingMachine) -> void:
	if target == _highlighted_machine:
		return
	if is_instance_valid(_highlighted_machine):
		_highlighted_machine.set_highlighted(false)
	_highlighted_machine = target
	if _highlighted_machine != null:
		_highlighted_machine.set_highlighted(true)

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

	# 手動操作優先，直接中斷自動移動
	if input_dir != Vector2.ZERO:
		if is_moving():
			stop_moving()
		return input_dir * SPEED

	return super()

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
		var line: String = _pending_lines.pop_front()
		return {"ok": true, "line": line, "end": false}

	if is_instance_valid(listener) and listener.bubble != null:
		listener.bubble.hold(WAITING_FOR_PLAYER_TEXT)

	_turn_waiting = true
	var resolved: Array = await turn_resolved
	_turn_waiting = false

	if is_instance_valid(listener) and listener.bubble != null:
		listener.bubble.release_hold()

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
