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
##
## layer 刻意設成 20（比 god_stone_input／vending_menu／chat_input 等其餘
## layer=1 的面板都高）：這則彈窗是 NPC AI 非同步觸發的，玩家隨時可能正開著
## 另一個 layer=1 面板時彈窗突然跳出來——跟那些面板「一次只會有一個由玩家
## 主動開啟」不同，是唯一會真的跟別的面板同時開著的情況。同一個 layer 時
## 視覺畫在最上層不代表滑鼠事件也會先分派到這裡（實測過：兩個 layer=1 面板
## 疊在一起時，畫面上看起來彈窗蓋住底下的面板，但按鈕點不到，事件被底下
## 那層搶走），只有明確調高 layer 才能同時保證畫面順序跟滑鼠事件優先權一致
## （CodeRabbit review 之外，使用者實測發現）。
##
## layer=20 是暫時性數字，不是系統性方案——見 #501（把所有可能互相覆蓋的
## 面板搬進共用容器，用子節點順序取代 layer 數字比較）。#501 完成後這裡的
## layer=20 要一併拿掉，改用新容器排序，不要留下雙重邏輯

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
