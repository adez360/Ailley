class_name StatusPanel
extends CanvasLayer

## 點選角色彈出的三分頁面板：狀態／今日／物品（#172，《15》§2）。
##
## 三個分頁合成一個面板而不是三個各自獨立的面板，理由見《15》§2-1：三者是
## 「我點的這個角色現在是什麼狀況」的三個切面，選取機制只有一套，640×360
## 也放不下三個並存的面板。分頁互斥顯示，靠 visible 切換。
##
## 狀態頁（現況即規格，原本就有）：姓名、年齡、金錢、Stats.SPEC 全部數值。
## 今日頁（#172 新增）：today_plan（自我回報的意圖）＋ today_log（引擎寫的
## 客觀執行紀錄，agent.gd 新增機制）。物品頁（#172 新增）：該角色 Inventory
## 的 36 格，唯讀顯示——不重用 InventorySlotButton，那顆按鈕的 _get_inventory()
## 寫死抓 "player" 群組，只服務玩家自己的背包／快捷欄，這裡要顯示的是「玩家
## 選中的任意角色」，且《15》§2-6 明講不做拖放、不做點擊換手持，本來就不需要
## 那顆按鈕的互動能力。
##
## 場景結構是這份腳本的合約，改路徑要兩邊一起改：
##   CanvasLayer（本腳本）
##     Panel（280x208，Setting menu.png 帶標題列那格）
##       TitleBg／TitleLabel（角色名字）
##       TabBar（HBoxContainer，StatusTabButton／TodayTabButton／ItemsTabButton）
##       StatusTab（VBox：AgeLabel／MoneyLabel／StatsBox）
##       TodayTab（ScrollContainer > TodayVBox：PlanHeader／PlanList／LogHeader／LogList）
##       ItemsTab（GridContainer 9 欄，空的，本腳本長出 36 個唯讀格子）
##       HintLabel

const BARK := Color("2F2522")
const LOAM := Color("5D4A38")
const AGE_PLACEHOLDER := "—"
const EMPTY_PLACEHOLDER := "—"		# 《15》§1-1：沒資料一律顯示這個，不留空白不顯示假值

## 跟 hotbar.gd／inventory_panel.gd 同一張 sprite sheet 同一格素材，視覺一致
const SLOT_REGION := Rect2(11, 59, 26, 28)
const SLOT_SHEET := preload("res://assets/ui/Sprite sheet for Basic Pack.png")
const HOTBAR_TINT := Color("C96C23")	# Amber，手持格標記，跟 InventoryPanel 同一色語意
const NORMAL_TINT := Color(1, 1, 1, 1)

## 動作名 -> 顯示用中文（《15》§2-5 行動紀錄）。查不到就顯示動作名本身，
## 不是空白——跟 ItemDatabase.get_display_name() 查不到退回 item_id 同一種慣例
const ACTION_LABELS := {
	"talk": "搭話", "persuade": "說服", "give": "送禮", "shout": "呼喊",
	"murmur": "自語", "eat": "吃東西", "drink": "喝東西", "move_to": "移動",
	"sleep": "睡覺", "nap": "小睡", "rest": "休息", "wash": "洗漱",
	"idle": "發呆", "attack": "攻擊", "haul": "搬運", "struggle": "掙扎",
}

@onready var panel: Panel = $Panel
@onready var title_label: Label = $Panel/TitleLabel
@onready var status_tab_button: Button = $Panel/TabBar/StatusTabButton
@onready var today_tab_button: Button = $Panel/TabBar/TodayTabButton
@onready var items_tab_button: Button = $Panel/TabBar/ItemsTabButton
@onready var status_tab: VBoxContainer = $Panel/StatusTab
@onready var age_label: Label = $Panel/StatusTab/AgeLabel
@onready var money_label: Label = $Panel/StatusTab/MoneyLabel
@onready var stats_box: VBoxContainer = $Panel/StatusTab/StatsBox
@onready var today_tab: ScrollContainer = $Panel/TodayTab
@onready var plan_list: VBoxContainer = $Panel/TodayTab/TodayVBox/PlanList
@onready var log_list: VBoxContainer = $Panel/TodayTab/TodayVBox/LogList
@onready var items_tab: GridContainer = $Panel/ItemsTab
@onready var hint_label: Label = $Panel/HintLabel

var _stat_labels := {}				# key（Stats.SPEC 的鍵）-> Label
var _item_slots: Array[TextureRect] = []	# 36 格，_ready() 時建好，順序固定
var _character: Character = null
var _current_tab := 0				# 0=狀態 1=今日 2=物品


func _ready() -> void:
	panel.hide()
	hint_label.text = L10n.t("UI_STATUS_CLOSE_HINT")
	status_tab_button.text = L10n.t("UI_CHAR_TAB_STATUS")
	today_tab_button.text = L10n.t("UI_CHAR_TAB_TODAY")
	items_tab_button.text = L10n.t("UI_CHAR_TAB_ITEMS")
	status_tab_button.pressed.connect(_set_tab.bind(0))
	today_tab_button.pressed.connect(_set_tab.bind(1))
	items_tab_button.pressed.connect(_set_tab.bind(2))

	for key in Stats.SPEC:
		var label := Label.new()
		label.add_theme_color_override("font_color", BARK)
		stats_box.add_child(label)
		_stat_labels[key] = label

	for i in Inventory.SIZE:
		_item_slots.append(_make_item_slot())

	_set_tab(0)

func _make_item_slot() -> TextureRect:
	var atlas := AtlasTexture.new()
	atlas.atlas = SLOT_SHEET
	atlas.region = SLOT_REGION

	var rect := TextureRect.new()
	rect.texture = atlas
	rect.custom_minimum_size = Vector2(26, 28)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var label := Label.new()
	label.name = "Label"
	label.set_anchors_preset(Control.PRESET_FULL_RECT)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.clip_text = true
	rect.add_child(label)

	items_tab.add_child(rect)
	return rect

func _unhandled_input(event: InputEvent) -> void:
	if panel.visible and event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()

# 點擊偵測故意走 _input 而不是 _unhandled_input，跟 debug_console.gd 同一個理由：
# _input 是輸入管線裡最早、順序固定的一關，不受場景樹位置影響（見原本的說明，
# 這裡沿用不變）
func _input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT):
		return

	# CodeRabbit review：面板可見時，面板範圍內的點擊（例如分頁按鈕）留給
	# GUI 的 _gui_input 處理，不能被下面的世界選取邏輯搶走——否則點分頁會
	# 誤觸 close()，或選到分頁底下的世界角色
	if panel.visible and panel.get_global_rect().has_point(event.position):
		return

	var character := _pick_character(event.position)
	if character != null:
		open(character)
	elif panel.visible:
		close()

func _pick_character(screen_pos: Vector2) -> Character:
	var world_pos := get_viewport().canvas_transform.affine_inverse() * screen_pos

	var selection := get_tree().get_first_node_in_group("selection") as Selection
	if selection == null:
		return null

	return selection.character_at(world_pos)

## 面板先前隱藏時開啟：切回狀態分頁。面板開著時點另一個角色：只換資料，
## 維持目前分頁——玩家連續點角色比對物品時不該每次被踢回狀態頁（《15》§2-3）
##
## CodeRabbit review（#366）：原本在設定 _character 之前就呼叫 _set_tab(0)，
## 那時 _set_tab() 讀到的還是舊角色（甚至 null），內容刷新直接被它自己的
## null 檢查擋掉；而面板已開啟、只是換角色那個分支，先前完全沒呼叫任何刷新，
## 分頁內容會停在前一個角色身上。統一改成：先決定分頁號碼（要不要重置成 0）、
## 換好角色資料，最後一次呼叫 _set_tab() 把「顯示哪個分頁」跟「刷新該分頁
## 內容」黏在一起做，兩個分支都會用到已經換好的新角色
func open(character: Character) -> void:
	if not panel.visible:
		_current_tab = 0
	_disconnect_inventory_changed()
	_character = character
	_connect_inventory_changed()
	title_label.text = character.character_name
	panel.show()
	_set_tab(_current_tab)

func close() -> void:
	panel.hide()
	_disconnect_inventory_changed()
	_character = null

## 物品頁開著時角色吃東西／被送禮／換手持，格子要跟著動，不能只在開頁/切頁那瞬間
## 拍照（《15》§2-6：「掛 Inventory.changed 訊號，不逐幀輪詢」）
func _connect_inventory_changed() -> void:
	if _character != null and _character.inventory != null:
		_character.inventory.changed.connect(_on_inventory_changed)

func _disconnect_inventory_changed() -> void:
	if _character != null and _character.inventory != null \
			and _character.inventory.changed.is_connected(_on_inventory_changed):
		_character.inventory.changed.disconnect(_on_inventory_changed)

func _on_inventory_changed() -> void:
	if panel.visible and _current_tab == 2:
		_refresh_items_tab()

func _set_tab(tab: int) -> void:
	_current_tab = tab
	status_tab.visible = tab == 0
	today_tab.visible = tab == 1
	items_tab.visible = tab == 2
	status_tab_button.disabled = tab == 0
	today_tab_button.disabled = tab == 1
	items_tab_button.disabled = tab == 2

	if _character == null:
		return
	match tab:
		0: _refresh_status_tab()
		1: _refresh_today_tab()
		2: _refresh_items_tab()

func _refresh_status_tab() -> void:
	age_label.text = _line("UI_STATUS_AGE", AGE_PLACEHOLDER)

	# 跟 debug_console.gd 的 status 指令同一個條件——沒掛 Inventory 就沒有錢可顯示，
	# 不是「顯示 0」，是這個角色根本沒有這項資料
	var has_money := _character.inventory != null
	money_label.visible = has_money
	if has_money:
		money_label.text = _line("UI_STATUS_MONEY", str(_character.inventory.get_money()))

	var has_stats := _character.stats != null
	stats_box.visible = has_stats
	if has_stats:
		for key in Stats.SPEC:
			_stat_labels[key].text = _stat_line(_character.stats, key)

## today_plan／today_log 只有 Agent 才有（Player 不走任務池／仲裁器）——
## Player 沒有這兩份資料，整頁顯示佔位字元，不是空白也不是報錯
func _refresh_today_tab() -> void:
	_clear_children(plan_list)
	_clear_children(log_list)

	var agent := _character as Agent
	if agent == null:
		_add_placeholder_line(plan_list)
		_add_placeholder_line(log_list)
		return

	var plan: Array = agent.get("_today_plan")
	if plan == null or plan.is_empty():
		_add_placeholder_line(plan_list)
	else:
		for item in plan:
			_add_plan_line(item)

	var today_log: Array[Dictionary] = agent.get_today_log()
	if today_log.is_empty():
		_add_placeholder_line(log_list)
	else:
		for entry in today_log:
			_add_log_line(entry)

func _add_placeholder_line(parent: VBoxContainer) -> void:
	var label := Label.new()
	label.text = EMPTY_PLACEHOLDER
	label.add_theme_color_override("font_color", BARK)
	parent.add_child(label)

## is_done 行首打勾、字色壓成 Loam；未完成行首用點、字色 Bark 讓它跳出來
## （《15》§2-5「今天打算」顯示規則，順序照陣列原順序，不重排）
func _add_plan_line(item: Dictionary) -> void:
	var label := Label.new()
	var is_done: bool = item.get("is_done", false)
	label.text = "%s %s" % ["✓" if is_done else "・", str(item.get("text", ""))]
	label.add_theme_color_override("font_color", LOAM if is_done else BARK)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD
	plan_list.add_child(label)

## get_today_log() 已經是「由新到舊」排序（agent.gd 端反轉過），這裡照原順序
## 逐筆加進去就是正確的顯示順序，不用再處理
func _add_log_line(entry: Dictionary) -> void:
	var label := Label.new()
	var minute: int = int(entry.get("minute", 0))
	@warning_ignore("integer_division")
	var time_str := "%02d:%02d" % [minute / 60, minute % 60]
	var raw_action := str(entry.get("action", ""))
	var action: String = ACTION_LABELS.get(raw_action, raw_action)
	var target := str(entry.get("target", ""))

	var line := "%s  %s" % [time_str, action]
	if not target.is_empty():
		line += " → %s" % target
	if not bool(entry.get("ok", true)):
		line += L10n.t("UI_CHAR_TODAY_LOG_FAILED_SUFFIX")

	label.text = line
	label.add_theme_color_override("font_color", BARK)
	log_list.add_child(label)

func _clear_children(container: Node) -> void:
	for child in container.get_children():
		container.remove_child(child)
		child.queue_free()

## 沒掛 Inventory 的角色（理論上 Agent／Player 都有，這裡防禦性處理）36 格
## 全部顯示空格，不強制跳分頁——玩家點了這頁就該看到這頁，跳分頁反而讓人
## 以為按鈕失靈
func _refresh_items_tab() -> void:
	var inventory := _character.inventory
	for i in _item_slots.size():
		var rect := _item_slots[i]
		var label := rect.get_node("Label") as Label

		var slot: Dictionary = inventory.get_slot(i) if inventory != null else {}
		if slot.is_empty():
			label.text = ""
			rect.modulate = NORMAL_TINT
			continue

		# 格子文字單一來源：InventorySlotButton.slot_text()（中文名稱最多 2 字，
		# 數量 > 1 才多印一行）——《15》§2-6 的「沿用 inventory_slot_button.gd」
		label.text = InventorySlotButton.slot_text(slot)

		# 手持格（快捷欄第一列裡被選中的那格）疊 Amber，跟 InventoryPanel
		# 同一種標記法（《15》§2-6）
		var is_hotbar_selected := i < Inventory.HOTBAR_SIZE and i == inventory.get_selected_index()
		rect.modulate = HOTBAR_TINT if is_hotbar_selected else NORMAL_TINT

func _line(label_key: String, value: String) -> String:
	return "%s：%s" % [L10n.t(label_key), value]

func _stat_line(stats: Stats, key: String) -> String:
	return _line(Stats.SPEC[key]["label"], str(int(stats.get_value(key))))
