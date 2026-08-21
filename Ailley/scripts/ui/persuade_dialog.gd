class_name PersuadeDialog
extends CanvasLayer

## NPC 對玩家發起 persuade 時（#305）的 Y/N 彈窗。單一實例掛在 hud.tscn，
## 跟 vending_menu／god_stone_input 同一種「場景裡固定掛一個、用 group 找」
## 的既有寫法（player.gd::request_persuade_response() 用
## get_first_node_in_group("persuade_dialog") 找到它）。
##
## 同一時間只服務一個請求——ask() 被呼叫時若已經開著，直接回傳 false
## （視同拒絕），不排隊、不覆蓋：忙碌時後到的說服請求本來就該落空，
## 跟 Agent 目標的 try_record_pending_persuade() 忙碌拒絕是同一種精神，
## 只是玩家這邊沒有事後補顯示的機制，直接讓那筆說服失敗。

signal answered(accepted: bool)

@onready var panel: Panel = $Panel
@onready var text_label: Label = $Panel/TextLabel
@onready var yes_button: Button = $Panel/ButtonRow/YesButton
@onready var no_button: Button = $Panel/ButtonRow/NoButton

var _busy := false


func _ready() -> void:
	add_to_group("persuade_dialog")
	panel.hide()
	yes_button.text = L10n.t("UI_PERSUADE_YES")
	no_button.text = L10n.t("UI_PERSUADE_NO")
	yes_button.pressed.connect(func(): answered.emit(true))
	no_button.pressed.connect(func(): answered.emit(false))


## text 是要顯示的說服內容——呼叫端（agent.gd::_ask_player_persuade()）已經
## 組好完整句子，這裡只負責顯示，不重組措辭。回傳 true＝玩家選是，
## false＝選否，或忙碌中直接拒絕
func ask(text: String) -> bool:
	if _busy:
		return false
	_busy = true
	text_label.text = text
	panel.show()

	var accepted: bool = await answered

	panel.hide()
	_busy = false
	return accepted
