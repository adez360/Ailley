class_name IncapacitationCountdown
extends Node2D

## 昏迷倒數的頭上提示（issue #803）：角色 health ≤ 0 進入昏迷後，頭上常駐
## 「昏迷倒數 N 分鐘」，讓玩家在畫面內一眼看到誰正在倒數、還剩多久。
##
## 跟 work_progress.gd／money_popup.gd 同一種「頭上飄一塊 UI」掛法，差別在
## 顯示時機不由呼叫端逐次推播，而是輪詢型：自己訂閱 GameClock.time_changed，
## 每遊戲分鐘重讀宿主（get_parent() 必須是 Character）的昏迷狀態。選輪詢的
## 理由：昏迷可能經 load_save_data() 還原——那條路徑只重建 condition、不會
## 經過 _start_incapacitation()，事件推播會漏掉；倒數本身也是「條件持續成立
## 就持續顯示」的狀態，不是一次性事件。
##
## 純程式建 UI（Label 在 _ready() 用程式碼生成），由 character.gd::_ready()
## add_child 掛到場景的 UI 節點下，不依賴任何 .tscn——godot-ai MCP 連不上時
## 場景操作走不了規定流程，這裡全部在「純 GDScript 邏輯」可直接編輯的範圍
## （比照 onboarding_hint.gd 的做法）。

## Ember，警示／危險語意：跟 money_popup.gd 的花費色同一個調色盤值
const TEXT_COLOR := Color("8B1F14")
## 頭上縱向錨點：Bubble(0,-10)／WorkProgress(0,-14)／MoneyPopup(0,-18)／
## ThinkingIndicator(0,-19) 之上，不跟既有頭上 UI 疊在同一條帶
const OFFSET := Vector2(0, -26)
## 跟 bubble.gd 的 11px 同級——字太大會蓋掉 16px 的角色本體
const FONT_SIZE := 11

var _label: Label


func _ready() -> void:
	position = OFFSET
	visible = false

	_label = Label.new()
	_label.add_theme_color_override("font_color", TEXT_COLOR)
	_label.add_theme_font_size_override("font_size", FONT_SIZE)
	add_child(_label)

	GameClock.time_changed.connect(_on_time_changed)
	# _ready() 當下宿主的存檔還原可能還沒跑完（load_save_data() 會在進場景樹後
	# 由 main_scene.gd 補呼叫），延一輪再做第一次重讀
	_refresh.call_deferred()


func _on_time_changed(_hour: int, _minute: int) -> void:
	_refresh()


func _refresh() -> void:
	var character := get_parent() as Character
	if character == null or character.is_dead:
		visible = false
		return
	var remaining := character.get_incapacitation_remaining_minutes()
	if remaining <= 0:
		visible = false
		return

	_label.text = "昏迷倒數 %d 分鐘" % remaining
	# 文字長度隨位數變（30→1），每輪重量測後水平置中在角色頭上
	_label.reset_size()
	_label.position = Vector2(-_label.size.x * 0.5, 0.0)
	visible = true
