extends CanvasLayer

## 天神之石的話語輸入框（#164，《15》§3），與化身後的地點事件記錄查看
## （issue #369 拍板、#377 落地）。
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
##
## 化身鎖定（《15》§3、《07_地點/天神之石》，2026-08-20 拍板）：玩家一旦化身
## （從角色庫以 as_player=true 投放），說話功能鎖住，點石頭改開「地點事件記錄」
## 查看面板。判斷「是否化身」看 game_manager.gd::embodied_character_id——只有
## deploy 路徑會改變的即時化身狀態，存檔記的也是同一個值。刻意不問
## get_first_node_in_group("player")：main.tscn 從頭就站著一個設計時期的測試用
## Player，分組在「從未化身」的場上也不是空的（robot-ru review 抓到）。
##
## 記錄面板照《15》§3-5「具體版面留待實作 issue 補」在程式碼裡組
## （跟 character_create.gd 同一種理由：內容是逐筆生成的清單，不是固定版面）；
## 純觀察者的第二入口——話語輸入框下方的「地點事件記錄」按鈕——是固定版面，
## 走 god_stone_input.tscn。化身玩家要先走到石頭旁（RECORD_VIEW_RANGE）才點得開，
## 純觀察者／純 AI 模式沒有這個距離限制（《15》§3-5 開頭那條「位置性約束的是
## 村民，不是玩家的滑鼠」，這裡延伸成「約束的是化身玩家，不是純觀察者」）。

const MAX_LENGTH := 40
const COOLDOWN_SECONDS := 5.0
const CLICK_RADIUS := 16.0		# 石頭視覺只有 12x12px，點擊範圍放寬到一格

## 6 格，跟 character.gd 的 NOISE_RADIUS（128px＝8 格）同一種換算：16px/格
const HEAR_RADIUS := 96.0

## 化身玩家要走到多近才能查看地點事件記錄。跟 BURY_RANGE／HAUL_RANGE／
## GIVE_RANGE 同一種「2 格內」互動距離門檻，沒有理由對這裡另訂一套
const RECORD_VIEW_RANGE := 32.0

## 記錄保留筆數（《15》§3-5「具體…保留筆數等留待實作 issue 補」，這裡拍板）：
## 20 筆是跟聊天視窗常見「最近幾則」量級對齊的 MVP 數字，玩起來太少/太多
## 再調，不是精算值
const RECORD_RETENTION := 20

const EMPTY_PLACEHOLDER := "—"		# 《15》§1-1：沒資料一律顯示這個，不留空白不顯示假值

const BARK := Color("2F2522")
const LOAM := Color("5D4A38")

@onready var panel: Panel = $Panel
@onready var input: LineEdit = $Panel/Input
@onready var record_button: Button = $Panel/RecordButton
@onready var status_label: Label = $Panel/StatusLabel

var _cooldown_remaining := 0.0
var _stone: Node2D = null

## {day, hour, minute, text}，由新到舊；只記透過天神之石說過的話，不記角色反應
## （《15》§3-5）。不隨存檔持久化——跟專案裡其他角色執行期狀態（today_log／
## emotion 等）現況一致，整個角色存讀檔管線都還沒接這層，不是這裡漏做
var _location_records: Array[Dictionary] = []

var _record_panel: Panel
var _record_list: VBoxContainer


func _ready() -> void:
	input.max_length = MAX_LENGTH
	input.text_submitted.connect(_on_submitted)
	record_button.pressed.connect(_open_record_view)
	panel.hide()

	_stone = get_tree().get_first_node_in_group("god_stone")
	if _stone == null:
		push_error("GodStoneInput: 場景裡找不到 god_stone 群組的節點")

	_build_record_panel()

func _process(delta: float) -> void:
	if _cooldown_remaining <= 0.0:
		return
	_cooldown_remaining = maxf(_cooldown_remaining - delta, 0.0)
	if panel.visible:
		_update_status()
		# input.editable 原本只在 _set_open(true) 那一刻算一次，倒數在面板
		# 開著的時候歸零不會被這裡追上——玩家會看到狀態列文字變成「可以
		# 說話了」卻打不了字，得先關面板再重開才能真的解鎖。跟上面的文字
		# 更新放在同一個 frame 一起做，不等下一次 _set_open()
		input.editable = _cooldown_remaining <= 0.0

# 點石頭開面板：純觀察者開話語輸入框，化身玩家改開地點事件記錄（見上方
# class 註解）。跟 status_panel.gd 同一個理由用 _input 而非 _unhandled_input，
# 且刻意不 set_input_as_handled()——空地點擊要繼續傳給 selection.gd 取消選取
func _input(event: InputEvent) -> void:
	if panel.visible and event.is_action_pressed("ui_cancel"):
		_set_open(false)
		get_viewport().set_input_as_handled()
		return
	if _record_panel.visible and event.is_action_pressed("ui_cancel"):
		_record_panel.hide()
		get_viewport().set_input_as_handled()
		return

	var mouse := event as InputEventMouseButton
	if mouse == null or not (mouse.pressed and mouse.button_index == MOUSE_BUTTON_LEFT):
		return
	if _stone == null:
		return

	var world_pos := get_viewport().canvas_transform.affine_inverse() * mouse.position
	if world_pos.distance_to(_stone.global_position) > CLICK_RADIUS:
		return

	# 觀察者沒有化身（見 class 註解）：開話語輸入框，框上的「地點事件記錄」
	# 按鈕是觀察者回顧記錄的入口（《15》§3-5：觀察者不受距離限制）
	if GameManager.embodied_character_id.is_empty():
		_set_open(true)
		return

	# 化身玩家：位置性限制（見 class 註解），太遠就當沒點到，靜默不理——
	# 不是要顯示的錯誤，走過去再點就好。目前操控的身體照舊從 "player" 分組
	# 查——這裡只負責量距離，化身與否的判定在上面
	var player_node := get_tree().get_first_node_in_group("player") as Character
	if player_node != null and player_node.get_body_position().distance_to(_stone.global_position) <= RECORD_VIEW_RANGE:
		_open_record_view()

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

	_record_location_event(line)


## 地點事件記錄：只記透過天神之石說過的話（《15》§3-5），由新到舊、
## 超過保留筆數就丟最舊的一筆
func _record_location_event(line: String) -> void:
	_location_records.push_front({
		"day": GameClock.day,
		"hour": GameClock.hour,
		"minute": GameClock.minute,
		"text": line,
	})
	if _location_records.size() > RECORD_RETENTION:
		_location_records.resize(RECORD_RETENTION)


## 記錄面板照《15》§3-5「具體版面留待實作 issue 補」在程式碼裡組，見 class 註解。
## 用 CenterContainer 包一層置中（跟 character_create.gd 同一種作法），
## 不手算 offset_left/top/right/bottom——那套算法容易跟 custom_minimum_size 對不上
func _build_record_panel() -> void:
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	_record_panel = Panel.new()
	_record_panel.custom_minimum_size = Vector2(260, 160)
	_record_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_record_panel.hide()
	center.add_child(_record_panel)

	var col := VBoxContainer.new()
	col.set_anchors_preset(Control.PRESET_FULL_RECT)
	col.offset_left = 10
	col.offset_top = 10
	col.offset_right = -10
	col.offset_bottom = -10
	col.add_theme_constant_override("separation", 4)
	_record_panel.add_child(col)

	var title := Label.new()
	title.text = "UI_GOD_STONE_RECORD_TITLE"		# Control.text 填 key 會自動翻譯
	title.add_theme_color_override("font_color", BARK)
	col.add_child(title)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(scroll)

	_record_list = VBoxContainer.new()
	_record_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_record_list)

func _open_record_view() -> void:
	_set_open(false)		# 兩個面板互斥，跟話語輸入框同一套邏輯
	_refresh_record_list()
	_record_panel.show()

func _refresh_record_list() -> void:
	# free() 而不是 queue_free()：兩次刷新之間不保證隔了一個 frame
	# （例如 game_eval 測試腳本同一輪內連續呼叫），queue_free() 的延遲釋放
	# 會讓上一輪的殘留節點跟這輪新加的一起顯示——這幾個節點只是純文字
	# Label，沒有掛訊號／計時器，立即釋放沒有風險
	for child in _record_list.get_children():
		child.free()

	if _location_records.is_empty():
		var placeholder := Label.new()
		placeholder.text = EMPTY_PLACEHOLDER
		placeholder.add_theme_color_override("font_color", BARK)
		_record_list.add_child(placeholder)
		return

	for entry in _location_records:
		var label := Label.new()
		label.text = "D%d %02d:%02d  %s" % [
			int(entry["day"]), int(entry["hour"]), int(entry["minute"]), str(entry["text"])
		]
		label.add_theme_color_override("font_color", LOAM)
		label.autowrap_mode = TextServer.AUTOWRAP_WORD
		_record_list.add_child(label)
