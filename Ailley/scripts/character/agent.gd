extends Character

## 由行程表驅動的角色。
## 這一版讀 data/npc_schedule.json 的靜態行程；日後會換成 AI 維護的行程表，
## 換掉的只有 _load_schedule() 與行程項目的結構，移動與動畫都在 Character 基底。

## 初始行程模板，對應 npc_schedule.json 的鍵（例如 "npc001"）。
## 這是「用哪份資料」而不是「我是誰」，所以刻意不共用 character_id ——
## id 是全遊戲唯一的身分，不可能同時等於一個手寫的模板名。
##
## 這個 @export 是**後備值**，優先權低於 npc_schedule.json 的 assignments：
## 場景裡的預設值是所有 instance 共用的，只靠它的話同一份 agent.tscn 生出來的
## 每一隻 Agent 都會拿到同一份行程、在同一分鐘走去同一個地點。
## 誰用哪份行程是資料，寫在資料檔裡才有辦法逐隻不同。
##
## 暫時性欄位：行程改由 AI 逐一維護後（見計畫 §5.1）就會消失
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

var schedule: Array = []
var current_place := ""
var current_state := "idle"

# 這一場已經對誰驚訝過。Vision 只回報「看到誰」，要不要有反應是這裡決定的；
# 沒有這張表的話，走出視野再走回來就會再驚訝一次
var _noticed := {}


func _ready() -> void:
	super()
	add_to_group("agents")
	_load_schedule()
	GameClock.time_changed.connect(_on_time_changed)

	if vision != null:
		vision.spotted.connect(_on_spotted)

	# NavGrid 開場是非同步建的，不等它建完就出發只會拿到空路徑
	var nav = get_tree().get_first_node_in_group("nav_grid")
	if nav != null and not nav.built:
		await nav.grid_built

	_apply_current_entry()

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

	schedule = data["schedule"]

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

# 睡覺中的 Agent 不接受搭話。行程插槽之後會有 interruptible 欄位（計畫 §5.1），
# 現在先用 state 判斷
func is_interruptible() -> bool:
	return current_state != "sleep"

# 對話結束後重算一次「現在該做什麼」，而不是接續原本那條路 ——
# 對話期間可能已經跨過了行程的整點
func exit_conversation() -> void:
	super()
	_apply_current_entry()

# 基底的快照加上行程表這一段。schedule/current_place/current_state 宣告在這裡，
# 所以是這裡負責放進去 —— 基底不必去猜誰有行程表
func get_state_snapshot() -> Dictionary:
	var snapshot := super()
	snapshot["schedule"] = {
		"place": current_place,
		"state": current_state,
		"size": schedule.size(),
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
	await get_tree().create_timer(NOTICE_PAUSE).timeout

	# 愣完重算行程而不是接回原本那條路：這 2 秒可能已經跨過行程的整點，
	# 與 exit_conversation() 同一個理由
	if not is_in_conversation():
		_apply_current_entry()

# 之前吃過虧：decide_and_act() 完全沒有可見的回饋，跑失敗或跑成功但
# 剛好沒事發生（沒話、動作不是 move_to）看起來一模一樣，使用者分不出來
# 「壞了」還是「這次剛好沒事」。這裡一律 print()——不進遊戲內 UI，
# 印到 Godot 的 Output 面板／終端機，跟 debug 主控台的 _cmd_village_ai_act
# 是兩個不同的可見管道，但至少有一個能看
func _trigger_village_ai() -> void:
	print("[village_ai] %s 看到玩家，觸發自動決策（poc_character_id=%s）" % [character_name, poc_character_id])
	var result: Dictionary = await VillageSimDecision.decide_and_act(self, poc_character_id)

	if not result["ok"]:
		print("[village_ai] %s 決策失敗：%s" % [character_name, result["error"]])
		return

	var data: Dictionary = result["data"]
	var output: Dictionary = data.get("output", {})
	# reasoning 是 AI 決策前寫的分析文字（先分析、再決定 intent，見
	# poc_village_sim 的推理鷹架設計），判斷這次決策合不合理主要看這個——
	# 但要記得現在 AI 看到的生理狀態是 poc_village_sim 自己存的那份，不是
	# Godot 這邊的即時 Stats.SPEC（physiology_override 還沒接），reasoning
	# 講得通不代表跟這隻角色在遊戲裡的真實狀態吻合，見 [[LLM 串接與 AI 服務層]]
	print("[village_ai] %s 決策完成：action_en=%s speech=%s" % [
		character_name, data.get("action_en", ""), output.get("speech")
	])
	print("[village_ai]   reasoning: %s" % output.get("reasoning", ""))

# 行程表是「到點切換」，所以只在時間字串剛好吻合的那一分鐘換目標
func _on_time_changed(hour: int, minute: int) -> void:
	var now := "%02d:%02d" % [hour, minute]
	for entry in schedule:
		if entry["time"] == now:
			_start_entry(entry)
			return

# 開場時間通常不是第一筆行程的整點，直接套用「已經開始的最後一筆」，
# 否則 Agent 會站在原地空等到下一個整點
func _apply_current_entry() -> void:
	var now := "%02d:%02d" % [GameClock.hour, GameClock.minute]
	var current = null

	for entry in schedule:
		if entry["time"] <= now:
			current = entry

	if current != null:
		_start_entry(current)

func _start_entry(entry: Dictionary) -> void:
	current_place = entry["place"]
	current_state = entry["state"]

	# 對話中先記下該去哪但不動身，講完由 exit_conversation() 重算
	if is_in_conversation():
		return

	var anchors := get_tree().get_first_node_in_group("place_anchors")
	if anchors == null or not anchors.has(current_place):
		push_error("Agent %s: 沒有這個地點 %s" % [character_name, current_place])
		return

	var target: Vector2 = anchors.resolve(current_place)

	# 已經在目的地就沒事要做。這一步不做的話，「早就到了」會被誤報成「走不到」：
	# move_to() 對「路徑不足兩點」一律回傳 false，而站在原地正好就是這種情形
	if _has_arrived_at(target):
		stop_moving()
		return

	if not move_to(target):
		push_warning("Agent %s: 走不到 %s" % [character_name, current_place])

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
