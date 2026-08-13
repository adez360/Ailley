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
## 走遠散場／按 E 離開）。
##
## `next_line()` 等的是這個而**不是**直接等 `line_submitted`：後者只在玩家真的
## 打字時才發，玩家還沒打字就離開對話的話那個 await 永遠不會回來，
## `conversation.gd` 的 `_run()` 就永遠停在那裡——而它是唯一能安全釋放
## Conversation 節點的地方（見該檔 `_finish()` 的說明），節點因此永遠留在場景樹上
signal turn_resolved(text: String, ok: bool)


func _ready() -> void:
	super()
	add_to_group("player")
	line_submitted.connect(_on_line_submitted)

# 打字是「這一輪有結果了」的其中一種來源，另一種是對話結束（見 exit_conversation()）。
# 兩者收斂成同一個訊號，next_line() 才只要等一個東西
func _on_line_submitted(text: String) -> void:
	turn_resolved.emit(text, true)

# 對話結束時取消還在等打字的那一輪。conversation.gd 的 _finish() 一定會對雙方
# 呼叫這個函式，所以不管是走遠散場、按 E 離開、還是對方結束，都會走到這裡
func exit_conversation() -> void:
	super()
	turn_resolved.emit("", false)

# 用 _unhandled_input 而不是 _input：debug 主控台的輸入框拿到焦點時
# 打字不該觸發搭話
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("make_noise"):
		get_viewport().set_input_as_handled()
		make_noise()
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
	# 的說明。全部對玩家都是靜默失敗，沒有回饋 UI；但失敗原因會印成 warning
	# （跟 character.gd 的 _check_stuck() 同一種寫法），方便開發時對著
	# 編輯器 Output/Debugger 面板看，不用另外開主控台查
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
		push_warning("%s: work_at 失敗（%s）" % [character_name, work_reason])
	# 販賣機不是立刻執行動作，是開商品選單——真正的購買發生在
	# vending_menu.gd 裡點下某一項的時候。vending_menu 理論上一定找得到
	# （場景裡固定掛著），這裡多防一手是避免場景漏掛的話直接炸掉
	elif machine != null and candidates["to_machine"] <= candidates["to_other"] and vending_menu != null:
		vending_menu.open(machine, self)
		return

	var talk_reason := talk_to(other)
	if talk_reason != TALK_OK:
		push_warning("%s: talk_to 失敗（%s）" % [character_name, talk_reason])

# 面向判定的錐角容許值：跟面向方向的內積要 >= 這個值才算「面對著」。
# 0.5 大約是 ±60 度的錐角——夠寬容得下斜向靠近的誤差，又不會寬到整個
# 半圓都算數（那樣就跟沒篩選一樣）
const FACING_DOT_THRESHOLD := 0.5

# 沒被面向的候選要加多少距離懲罰，才能保證面向著的候選一定贏。
# 場景裡任何互動距離（TALK_RANGE/WORK_RANGE/BUY_RANGE）都是 32px，
# 這個值只要遠大於場景尺寸就夠，不需要精算
const UNFACED_DISTANCE_PENALTY := 10000.0

# target 是不是落在玩家目前面向的方向上。target 就在腳下（距離 0，理論上
# 不會發生，但除以零要擋）視為面向著，避免這種邊界情況把候選判掉
func _is_facing(target: Vector2) -> bool:
	var to_target := target - get_body_position()
	if to_target == Vector2.ZERO:
		return true
	return get_facing_direction().dot(to_target.normalized()) >= FACING_DOT_THRESHOLD

# 給互動優先序比較用的「有效距離」：面向著就是原始距離，沒面向就加懲罰值，
# 讓「有沒有被面向」變成比較時的第一層篩選，見呼叫端的說明
func _priority_distance(target: Vector2) -> float:
	var distance := get_body_position().distance_to(target)
	return distance if _is_facing(target) else distance + UNFACED_DISTANCE_PENALTY

## 找出目前附近的三種互動候選（工作站／販賣機／可搭話的人）跟各自的優先序
## 分數。`_unhandled_input()`（按 E 真的觸發）跟 `_process()`（每幀更新高亮）
## 共用這個函式——兩邊要看到同一個答案，不然會出現「亮的是這個，按下去卻
## 打到另一個」的狀況，比原本沒有高亮更誤導人。
##
## 純比距離會撞到 issue #81：桌子與販賣機都是擺在世界裡的固定物件，很容易
## 落在某個地點錨點的互動半徑內（`square` 那張距錨點 21px < WORK_RANGE 32），
## agent 的行程又正好把 NPC 帶去那些錨點，NPC 幾乎必然比物件更近，物件因此
## 永遠打不到。改成先比「有沒有面向它」（見 _priority_distance()），距離只在
## 同樣有沒有被面向的候選之間才決勝負；都沒人被面向時（例如玩家側身站在
## 中間，沒有明確對著誰）大家一起加懲罰值，排序不變，自然退回純比距離那套
## ——這是刻意保留的保底，不然一般搭話情境會被這次改動連坐弄壞。
##
## 這套判斷沒有做成套用任何「可互動物件」共通分類的通用系統，是延續 #63
## 的決定，不是這次漏做——見 note/技術/販賣機.md：「不做一套通用的互動物件
## 框架，兩個物件不值得先蓋一層抽象」，Workstation／VendingMachine 本來就是
## 兩個獨立腳本、沒有共用基底
func _get_interact_candidates() -> Dictionary:
	var workstation := find_nearest_workstation()
	var machine := find_nearest_vending_machine()
	var other := find_nearest_character()

	# 不在範圍內的候選距離是 INF，直接輸掉比較，不用另外再寫一層 null 判斷
	return {
		"workstation": workstation,
		"machine": machine,
		"other": other,
		"to_work": _priority_distance(workstation.global_position) if workstation != null else INF,
		"to_machine": _priority_distance(machine.global_position) if machine != null else INF,
		"to_other": _priority_distance(other.get_body_position()) if other != null else INF,
	}

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
	if is_instance_valid(_highlighted_other):
		_highlighted_other.set_highlighted(false)
	_highlighted_other = target
	if _highlighted_other != null:
		_highlighted_other.set_highlighted(true)

# 讀取 WASD 輸入，回傳正規化後的方向（斜向不會加速）
func get_input_direction() -> Vector2:
	# 有 UI 拿到焦點時（例如 debug 輸入框）不吃移動鍵，
	# 因為 Input.get_axis() 讀的是全域輸入狀態，不會被 LineEdit 攔下來
	if get_viewport().gui_get_focus_owner() != null:
		return Vector2.ZERO

	return Vector2(
		Input.get_axis("move_left", "move_right"),
		Input.get_axis("move_up", "move_down")
	).normalized()

func _decide_velocity() -> Vector2:
	var input_dir := get_input_direction()

	# 手動操作優先，直接中斷自動移動
	if input_dir != Vector2.ZERO:
		if is_moving():
			stop_moving()
		return input_dir * SPEED

	return super()

# 玩家的下一句話就是玩家打的字。等 turn_resolved 而不是 line_submitted——
# 這個 await 一定要有辦法在「玩家沒打字就離開對話」時收場，理由見 turn_resolved
# 的宣告。ok=false 代表這一輪被取消，呼叫端（conversation.gd 的 _run()）緊接著
# 的 _bail_if_finished() 會看到 _finished 已經是 true 並釋放節點，不會走到
# fallback，也不會把空字串當台詞講出去。
#
# 沒有 end 這個概念——玩家不是靠一個結構化欄位收尾，是靠實際走開或
# leave_conversation()（_unhandled_input 的 interact 分支），所以這裡固定 false
func next_line(_listener: Character, _turns: Array[Dictionary], _max_turns: int) -> Dictionary:
	var resolved: Array = await turn_resolved
	return {"ok": resolved[1], "line": resolved[0], "end": false}
