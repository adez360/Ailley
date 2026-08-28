class_name TipMenu
extends CanvasLayer

## 玩家（天神）主動打賞表演中角色的選單（#575）。跟 vending_menu.gd 同一種
## 「開／關」職責切法：player.gd 負責開（先確認對方正在表演才呼叫 open()），
## 這裡自己負責關（E 再按一次或 Esc）。
##
## 跟 NPC 打賞不同——這裡完全不經過 AI 決策，按下按鈕就直接呼叫
## Character.inventory.add_money()，不扣玩家端的錢。
##
## 這不是「玩家打賞這個機制本身不該扣錢」的設計原則——是目前玩家自己
## 還沒有一套完整的「怎麼賺錢」的系統與流程（Player 沒有工作/收入來源），
## 沒東西可扣、扣了也沒有意義。等玩家自己的金錢系統做出來後，這裡的
## 「玩家端不扣款」例外要回頭重新檢視，比照那時候玩家實際持有金錢的方式
## 合理地扣款——不是永久的設計決定，見 note/規格書/99_待規劃項目清單.md

const TIP_AMOUNTS := [1, 5, 10]

@onready var panel: Panel = $Panel
@onready var title_label: Label = $Panel/VBox/TitleLabel
@onready var amount_list: VBoxContainer = $Panel/VBox/AmountList
@onready var hint_label: Label = $Panel/VBox/HintLabel

var _performer: Character = null
var _tipper: Character = null


func _ready() -> void:
	add_to_group("tip_menu")
	panel.hide()
	set_process(false)		# 只在選單開著時才需要量距離／確認對方還在表演
	title_label.text = L10n.t("UI_TIP_TITLE")
	hint_label.text = L10n.t("UI_TIP_CLOSE_HINT")

	for amount in TIP_AMOUNTS:
		var button := Button.new()
		button.text = str(amount)
		button.focus_mode = Control.FOCUS_NONE		# 理由跟 hotbar.gd 的格子按鈕同一段註解
		button.pressed.connect(_tip.bind(amount))
		amount_list.add_child(button)

# 對方走出範圍或表演結束就自動關掉——跟 vending_menu.gd 走出 BUY_RANGE 自動
# 關閉同一個理由，不然選單開著、按鈕點下去卻打不到人，看起來像壞掉
func _process(_delta: float) -> void:
	if not is_instance_valid(_performer) or not is_instance_valid(_tipper) \
			or not _performer.is_performing() \
			or _tipper.get_body_position().distance_to(_performer.get_body_position()) > Character.TALK_RANGE:
		close()

func is_open() -> bool:
	return panel.visible

func _unhandled_input(event: InputEvent) -> void:
	if not panel.visible:
		return

	if event.is_action_pressed("interact") or event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()

func open(performer: Character, tipper: Character) -> void:
	_performer = performer
	_tipper = tipper
	panel.show()
	set_process(true)

func close() -> void:
	panel.hide()
	set_process(false)
	_performer = null
	_tipper = null

func _tip(amount: int) -> void:
	if _performer == null or not is_instance_valid(_performer) or _performer.inventory == null:
		return
	_performer.inventory.add_money(amount)
