class_name CorpseMenu
extends CanvasLayer

## 玩家對屍體按 E 時的二選一選單（issue #758）。revive() 跟 start_haul() 對
## 屍體都能成功執行，同一個 interact 鍵沒辦法讓玩家表達要哪一種，所以跟
## tip_menu.gd 同一種「開小選單」寫法：player.gd 負責開（先確認對方是屍體
## 才呼叫 open()），這裡自己負責關（E 再按一次或 Esc，或對方狀態變了自動關）。

## 每 tick +0.7、100/0.7 換算成的「滿值需要幾個 tick」，跟
## character.gd::_update_corpse_decay() 用同一個常數——這裡不 import 那個
## 私有變數，直接照抄同一個數字算剩餘時間，兩邊要一起改（issue #839）
const DECAY_PER_TICK := 0.7

@onready var panel: Panel = $Panel
@onready var title_label: Label = $Panel/VBox/TitleLabel
@onready var decay_label: Label = $Panel/VBox/DecayLabel
@onready var decay_bar: ProgressBar = $Panel/VBox/DecayBar
@onready var revive_button: Button = $Panel/VBox/ReviveButton
@onready var haul_button: Button = $Panel/VBox/HaulButton
@onready var hint_label: Label = $Panel/VBox/HintLabel

var _corpse: Character = null
var _actor: Character = null


func _ready() -> void:
	add_to_group("corpse_menu")
	panel.hide()
	set_process(false)		# 只在選單開著時才需要確認對方還是屍體、距離還夠近
	title_label.text = L10n.t("UI_CORPSE_MENU_TITLE")
	hint_label.text = L10n.t("UI_TIP_CLOSE_HINT")		# 跟 tip_menu 同一句關閉提示，不重複註冊一筆

	revive_button.text = L10n.t("UI_CORPSE_MENU_REVIVE")
	haul_button.text = L10n.t("UI_CORPSE_MENU_HAUL")
	revive_button.focus_mode = Control.FOCUS_NONE		# 理由跟 hotbar.gd 的格子按鈕同一段註解
	haul_button.focus_mode = Control.FOCUS_NONE
	revive_button.pressed.connect(_revive)
	haul_button.pressed.connect(_haul)

# 對方被別人搶先復活／搬走安葬、或玩家自己走遠了就自動關掉——跟 tip_menu.gd
# 對方走出範圍或表演結束自動關閉同一個理由，不然選單開著、按鈕點下去卻打不到
# 屍體，看起來像壞掉
func _process(_delta: float) -> void:
	if not is_instance_valid(_corpse) or not is_instance_valid(_actor) \
			or not _corpse.is_dead \
			or _actor.get_body_position().distance_to(_corpse.get_body_position()) > Character.TALK_RANGE:
		close()
		return
	_refresh_decay()

# 腐壞進度顯示（issue #839）：已安葬的屍體不會再自動立無名碑，顯示「還剩多久」
# 沒有意義，改顯示「已安葬」。呈現方式（百分比＋剩餘遊戲時數）是這則決定的，
# issue 本身刻意沒有定案要用哪種——選這個是因為玩家決定要不要現在處理，
# 需要的是「還有多急」的感覺，單純百分比沒有時間感
func _refresh_decay() -> void:
	if _corpse.is_buried:
		decay_label.text = L10n.t("UI_CORPSE_MENU_BURIED")
		decay_bar.value = 100.0
		return
	decay_bar.value = _corpse.corpse_decay
	var remaining_game_minutes := (100.0 - _corpse.corpse_decay) / DECAY_PER_TICK * GameClock.GAME_MINUTES_PER_TICK
	var remaining_hours := int(remaining_game_minutes / 60.0)
	decay_label.text = L10n.tf("UI_CORPSE_MENU_DECAY", {
		"percent": int(_corpse.corpse_decay),
		"hours": remaining_hours,
	})

func is_open() -> bool:
	return panel.visible

func _unhandled_input(event: InputEvent) -> void:
	if not panel.visible:
		return

	if event.is_action_pressed("interact") or event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()

func open(corpse: Character, actor: Character) -> void:
	_corpse = corpse
	_actor = actor
	panel.show()
	set_process(true)

func close() -> void:
	panel.hide()
	set_process(false)
	_corpse = null
	_actor = null

func _revive() -> void:
	if not is_instance_valid(_actor) or not is_instance_valid(_corpse):
		close()
		return
	var reason := _actor.revive(_corpse)
	if reason != Character.REVIVE_OK:
		_actor.report_action_failure("revive", reason)
	close()

func _haul() -> void:
	if not is_instance_valid(_actor) or not is_instance_valid(_corpse):
		close()
		return
	var reason := _actor.start_haul(_corpse)
	if reason != Character.HAUL_OK:
		_actor.report_action_failure("start_haul", reason)
	close()
