class_name GiveMenu
extends CanvasLayer

## 玩家主動送禮選單（issue #841）。跟 tip_menu.gd 同一種「開／關」職責切法：
## player.gd 負責開（先確認範圍內有目標才呼叫 open()），這裡自己負責關
## （give 鍵再按一次或 Esc）。
##
## 物品清單直接列 giver.inventory.slots 裡目前有東西的格（含快捷欄與主背包
## 全部 36 格），每格一顆按鈕，格式沿用 inventory_slot_button.gd 的
## slot_text() 靜態函式（品名+數量），不是全新一套顯示邏輯。點下去呼叫既有
## Character.give_to()（give_to() 本身已有距離檢查／容量模擬回滾／decay 逐筆
## 保留，這裡不重複做）——固定送 1 件，要送更多就再點一次，理由同 tip_menu.gd
## 的固定金額按鈕：不為此另外做一個數量輸入元件。

@onready var panel: Panel = $Panel
@onready var title_label: Label = $Panel/VBox/TitleLabel
@onready var item_list: VBoxContainer = $Panel/VBox/ItemScroll/ItemList
@onready var hint_label: Label = $Panel/VBox/HintLabel

var _target: Character = null
var _giver: Character = null


func _ready() -> void:
	add_to_group("give_menu")
	panel.hide()
	set_process(false)		# 只在選單開著時才需要量距離／確認對方還在
	title_label.text = L10n.t("UI_GIVE_TITLE")
	hint_label.text = L10n.t("UI_GIVE_CLOSE_HINT")

# 對方走出範圍或死亡就自動關掉——跟 tip_menu.gd 走出範圍自動關閉同一個理由，
# 不然選單開著、按鈕點下去卻送不到人，看起來像壞掉
func _process(_delta: float) -> void:
	if not is_instance_valid(_target) or not is_instance_valid(_giver) \
			or _target.is_dead \
			or _giver.get_body_position().distance_to(_target.get_body_position()) > Character.GIVE_RANGE:
		close()

func is_open() -> bool:
	return panel.visible

func _unhandled_input(event: InputEvent) -> void:
	if not panel.visible:
		return

	if event.is_action_pressed("give") or event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()

func open(target: Character, giver: Character) -> void:
	_target = target
	_giver = giver
	panel.show()
	set_process(true)
	_refresh_items()

func close() -> void:
	panel.hide()
	set_process(false)
	_target = null
	_giver = null

# 每次送出後要重刷——送到最後一件，這個按鈕代表的格就空了，不重刷的話
# 玩家會對著一顆點下去沒反應的按鈕繼續點
func _refresh_items() -> void:
	for child in item_list.get_children():
		child.queue_free()

	if _giver == null or _giver.inventory == null:
		return

	for i in _giver.inventory.slots.size():
		var slot: Dictionary = _giver.inventory.get_slot(i)
		if slot.is_empty():
			continue
		var button := Button.new()
		button.text = InventorySlotButton.slot_text(slot).replace("\n", " ")
		button.focus_mode = Control.FOCUS_NONE		# 理由跟 tip_menu.gd 的金額按鈕一致
		button.pressed.connect(_give_from_slot.bind(i))
		item_list.add_child(button)

func _give_from_slot(slot_index: int) -> void:
	if _giver == null or _target == null or not is_instance_valid(_target):
		return
	var slot: Dictionary = _giver.inventory.get_slot(slot_index)
	if slot.is_empty():
		return
	var item_id: String = slot["item_id"]

	var give_reason := _giver.give_to(_target, item_id, 1)
	if give_reason != Character.GIVE_OK:
		_giver.report_action_failure("give", give_reason)
		return

	var item_name := ItemDatabase.get_display_name(item_id)
	# 讓 AI 收得到事實句（issue #841 步驟 3）：agent.gd 裡 AI 互送禮物時會對
	# 收禮的 Agent 補這句，玩家送禮這條路要比照同一個 pattern。giver 這端
	# 不補——_push_daily_event() 是 Agent 自己的每日事件日誌，Player 沒有
	# 這個機制，也不需要（那是 AI 給自己留的行為記憶，不是玩家的）
	if _target.is_in_group("agents"):
		(_target as Agent)._push_daily_event(
			"你收到了%s的%s。" % [_giver.character_name, item_name], [_giver.character_id]
		)

	_refresh_items()
