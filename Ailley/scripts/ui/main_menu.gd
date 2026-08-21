class_name MainMenu
extends Control

## 遊戲開場的第一顆場景（issue #295：原本 run/main_scene 直接開進 main.tscn，
## 沒有任何前置流程）。入口：開始遊戲、繼續遊戲（issue #343，有存檔才顯示）、
## 銘謝（第三方授權）。具體文案、按鈕位置、排版留給前端組決定，這裡先把結構
## 跟行為做出來。
##
## 場景結構是這份腳本的合約：
##   Control（本腳本）
##     Background（ColorRect，全螢幕）
##     TitleLabel（遊戲名稱，不走翻譯 key——專有名詞）
##     ButtonsBox（VBoxContainer，置中）
##       ContinueButton（預設隱藏，只有 SaveService.has_world() 為 true 且
##                       is_world_data_valid() 通過才顯示）
##       StartButton / CreditsButton
##       LoadErrorLabel（預設隱藏，只有「存檔存在但讀不出來或格式不完整」時才顯示）
##     Scrim（ColorRect，全螢幕半透明，預設隱藏；點面板外關閉銘謝子畫面，
##            做法跟 status_panel.gd／各面板的「點面板外或按 ui_cancel 關閉」一致）
##       CreditsPanel（Setting menu.png 九宮格，樣式沿用 status_panel.gd）
##         TitleBg / TitleLabel
##         VBox
##           QwenLabel / LlamaCppLabel（《16》§2.2 列名的兩項第三方授權）
##           HintLabel

const MAIN_SCENE := "res://scenes/main.tscn"

@onready var continue_button: Button = $ButtonsBox/ContinueButton
@onready var start_button: Button = $ButtonsBox/StartButton
@onready var credits_button: Button = $ButtonsBox/CreditsButton
@onready var load_error_label: Label = $ButtonsBox/LoadErrorLabel
@onready var scrim: ColorRect = $Scrim


func _ready() -> void:
	scrim.hide()
	load_error_label.hide()
	_refresh_continue_button()

	continue_button.pressed.connect(_on_continue_pressed)
	start_button.pressed.connect(_on_start_pressed)
	credits_button.pressed.connect(_on_credits_pressed)
	scrim.gui_input.connect(_on_scrim_gui_input)
	start_button.grab_focus()


func _unhandled_input(event: InputEvent) -> void:
	if scrim.visible and event.is_action_pressed("ui_cancel"):
		_close_credits()
		get_viewport().set_input_as_handled()


## has_world()==true 但 is_world_data_valid() 沒過：存檔存在但解析失敗或
## 巢狀欄位格式不完整（損毀／格式錯誤），不能讓玩家以為自己從沒存過檔——
## 藏起 ContinueButton 的同時要顯示明確的失敗訊息，不能悄悄只留新遊戲選項
## （見 issue #343 範圍）
##
## GameManager.continue_load_failed 覆蓋另一種情況：這裡檢查時存檔還在，
## 玩家按下繼續遊戲之後，main_scene.gd 轉場套用時才發現存檔消失或讀不出來
## ——這時 has_world()/is_world_data_valid() 現在重新檢查會查到「不存在」，
## 跟「本來就沒存過」是同一個結果，沒有這個旗標會誤判成後者、悄悄只顯示
## StartButton。優先權比下面兩個檢查高，且是一次性的，讀過一次要立刻清掉
func _refresh_continue_button() -> void:
	if GameManager.continue_load_failed:
		GameManager.continue_load_failed = false
		continue_button.hide()
		load_error_label.show()
		return

	if not SaveService.has_world(GameManager.DEFAULT_WORLD_ID):
		continue_button.hide()
		return

	if not SaveService.is_world_data_valid(SaveService.get_world(GameManager.DEFAULT_WORLD_ID)):
		continue_button.hide()
		load_error_label.show()
		return

	continue_button.show()


func _on_continue_pressed() -> void:
	GameManager.continue_requested = true
	get_tree().change_scene_to_file(MAIN_SCENE)


func _on_start_pressed() -> void:
	GameManager.continue_requested = false
	get_tree().change_scene_to_file(MAIN_SCENE)


func _on_credits_pressed() -> void:
	scrim.show()
	# CreditsPanel 沒有可聚焦的控制項，ButtonsBox 底下的按鈕卻還留著
	# FOCUS_ALL——純鍵盤玩家開著銘謝時按 Tab 還是能切回去，按 Enter 就會在
	# 面板還開著的情況下直接開始/繼續遊戲。銘謝開著時先把按鈕摘出焦點鏈，
	# 關閉時在 _close_credits() 復原。continue_button 隱藏時 Godot 的焦點
	# 導覽本來就會跳過它，這裡一併處理不用另外判斷 visible
	credits_button.release_focus()
	continue_button.focus_mode = Control.FOCUS_NONE
	start_button.focus_mode = Control.FOCUS_NONE
	credits_button.focus_mode = Control.FOCUS_NONE


# Scrim 蓋滿全螢幕，CreditsPanel 疊在它上面。CreditsPanel 底下的 TitleBg 有
# 明確覆寫 mouse_filter=IGNORE 只是純裝飾；TitleLabel 跟 VBox 底下的 Label 群
# 沒覆寫，走 Godot 4 的 Label 預設值 IGNORE，點擊穿過它們；VBox（VBoxContainer）
# 沒覆寫則走 Container 預設值 PASS——PASS 一樣會把事件繼續往上送，最後落到
# CreditsPanel 本體（Panel 預設 STOP）才真正被吃掉，不會傳到這裡，收到代表
# 點在面板外。只認滑鼠左鍵：event 也包含滾輪 tick（合成的 button pressed
# 事件）與右鍵/中鍵，不過濾 button_index 的話滾一下滑鼠滾輪就會把面板關掉，
# 跟 status_panel.gd 的 _input() 用同一個判斷式對齊。
func _on_scrim_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_close_credits()


func _close_credits() -> void:
	scrim.hide()
	continue_button.focus_mode = Control.FOCUS_ALL
	start_button.focus_mode = Control.FOCUS_ALL
	credits_button.focus_mode = Control.FOCUS_ALL
	credits_button.grab_focus()
