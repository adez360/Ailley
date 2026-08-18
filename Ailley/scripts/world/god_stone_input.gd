extends CanvasLayer

## 天神之石的話語輸入框（#164，《15》§3）。
##
## 開關方式跟 status_panel.gd 同一套：點擊偵測走 _input()，不用 selection.gd
## 那條 _unhandled_input 的路——兩個 _unhandled_input 互搶同一個滑鼠事件時，
## 場景樹內部派發順序不可靠（status_panel.gd 已經踩過一次，見那邊註解），
## 而這裡開/關互斥，不需要跟 selection.gd 共用同一個點擊判定。
## Esc 關閉沿用 chat_input.gd 的理由：LineEdit 開著會先吃掉大部分按鍵，
## 只有 Esc 這種在 _input 就攔得到。
##
## 送出後的三件事（《15》§3-3）：石頭本體冒泡、6 格內角色收到事實句
## （Agent.hear_god_stone()）、進入 5 秒冷卻。「話語不屬於任何角色」
## （《10》B19）所以面板置中，不沿用 chat_input.tscn 的底部位置。

const MAX_LENGTH := 40
const COOLDOWN_SECONDS := 5.0
const CLICK_RADIUS := 16.0		# 石頭視覺只有 12x12px，點擊範圍放寬到一格

## 6 格，跟 character.gd 的 NOISE_RADIUS（128px＝8 格）同一種換算：16px/格
const HEAR_RADIUS := 96.0

@onready var panel: Panel = $Panel
@onready var input: LineEdit = $Panel/Input
@onready var status_label: Label = $Panel/StatusLabel

var _cooldown_remaining := 0.0
var _stone: Node2D = null


func _ready() -> void:
	input.max_length = MAX_LENGTH
	input.text_submitted.connect(_on_submitted)
	panel.hide()

	_stone = get_tree().get_first_node_in_group("god_stone")
	if _stone == null:
		push_error("GodStoneInput: 場景裡找不到 god_stone 群組的節點")

func _process(delta: float) -> void:
	if _cooldown_remaining <= 0.0:
		return
	_cooldown_remaining = maxf(_cooldown_remaining - delta, 0.0)
	if panel.visible:
		_update_status()

# 點石頭開面板。跟 status_panel.gd 同一個理由用 _input 而非 _unhandled_input，
# 且刻意不 set_input_as_handled()——空地點擊要繼續傳給 selection.gd 取消選取
func _input(event: InputEvent) -> void:
	if panel.visible and event.is_action_pressed("ui_cancel"):
		_set_open(false)
		get_viewport().set_input_as_handled()
		return

	var mouse := event as InputEventMouseButton
	if mouse == null or not (mouse.pressed and mouse.button_index == MOUSE_BUTTON_LEFT):
		return
	if _stone == null:
		return

	var world_pos := get_viewport().canvas_transform.affine_inverse() * mouse.position
	if world_pos.distance_to(_stone.global_position) <= CLICK_RADIUS:
		_set_open(true)

func _set_open(open: bool) -> void:
	panel.visible = open

	if open:
		input.clear()
		input.editable = _cooldown_remaining <= 0.0
		_update_status()
		input.grab_focus()
	else:
		input.release_focus()

func _update_status() -> void:
	if _cooldown_remaining > 0.0:
		status_label.text = L10n.tf("UI_GOD_STONE_COOLDOWN", {"n": ceili(_cooldown_remaining)})
	else:
		status_label.text = L10n.t("UI_GOD_STONE_READY")

func _on_submitted(text: String) -> void:
	var line := text.strip_edges()
	input.clear()
	_set_open(false)

	if line.is_empty() or _cooldown_remaining > 0.0:
		return

	_speak(line)

func _speak(line: String) -> void:
	_cooldown_remaining = COOLDOWN_SECONDS

	var bubble = _stone.get_node_or_null("Bubble")
	if bubble != null:
		bubble.say(line)
	else:
		push_error("GodStoneInput: 天神之石底下找不到 Bubble 節點")

	for node in get_tree().get_nodes_in_group("characters"):
		var agent := node as Agent
		if agent == null:
			continue
		if agent.get_body_position().distance_to(_stone.global_position) <= HEAR_RADIUS:
			agent.hear_god_stone(line)
