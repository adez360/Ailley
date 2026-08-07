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
func _load_schedule() -> void:
	var assigned := GameManager.get_schedule_template(character_id)
	if not assigned.is_empty():
		schedule_template = assigned

	if schedule_template.is_empty():
		push_error("Agent %s: 沒有指定 schedule_template（可在 npc_schedule.json 的 assignments 指派）" % character_id)
		return

	var data = GameManager.get_npc(schedule_template)
	if data == null:
		push_error("Agent %s: npc_schedule.json 裡沒有模板 %s" % [character_id, schedule_template])
		return

	schedule = data["schedule"]

# 睡覺中的 Agent 不接受搭話。行程插槽之後會有 interruptible 欄位（計畫 §5.1），
# 現在先用 state 判斷
func is_interruptible() -> bool:
	return current_state != "sleep"

# 對話結束後重算一次「現在該做什麼」，而不是接續原本那條路 ——
# 對話期間可能已經跨過了行程的整點
func exit_conversation() -> void:
	super()
	_apply_current_entry()

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
	await get_tree().create_timer(NOTICE_PAUSE).timeout

	# 愣完重算行程而不是接回原本那條路：這 2 秒可能已經跨過行程的整點，
	# 與 exit_conversation() 同一個理由
	if not is_in_conversation():
		_apply_current_entry()

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

	var target := _resolve_place(current_place)

	# 已經在目的地就沒事要做。這一步不做的話，「早就到了」會被誤報成「走不到」：
	# move_to() 對「路徑不足兩點」一律回傳 false，而站在原地正好就是這種情形
	if _has_arrived_at(target):
		stop_moving()
		return

	if not move_to(target):
		push_warning("Agent %s: 走不到 %s" % [character_id, current_place])

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

# 地點座標優先取場景裡的 Marker2D 錨點，沒有錨點才退回 GameManager 的全域座標。
# places.json 的座標綁死在舊 village 場景的尺寸上，換一張地圖就落到界外；
# 錨點讓同一份行程表能在不同場景重用
func _resolve_place(place_name: String) -> Vector2:
	var anchors := get_tree().get_first_node_in_group("place_anchors")
	if anchors != null:
		var marker: Node2D = anchors.get_node_or_null(NodePath(place_name))
		if marker != null:
			return marker.global_position

	return GameManager.get_place(place_name)
