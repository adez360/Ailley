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
##       ContinueButton（預設隱藏，只有 SaveService.list_world_ids() 非空
##                       且其中至少一個世界 is_world_data_valid() 通過才顯示）
##       StartButton / CreditsButton / QuitButton
##       LoadErrorLabel（預設隱藏，只有「存檔存在但讀不出來或格式不完整」時才顯示）
##     Scrim（ColorRect，全螢幕半透明，預設隱藏；點面板外關閉子畫面，
##            做法跟 status_panel.gd／各面板的「點面板外或按 Esc 關閉」一致）
##       CreditsPanel（Setting menu.png 九宮格，樣式沿用 status_panel.gd）
##         TitleBg / TitleLabel
##         VBox
##           QwenLabel / LlamaCppLabel（《16》§2.2 列名的兩項第三方授權）
##           HintLabel
##
## 世界選擇面板（issue #810，繼續遊戲多世界時）跟新槽位選擇面板（開始
## 新遊戲時）不進場景檔，執行期在 Scrim 底下用程式建立，結構與樣式比照
## CreditsPanel，兩種模式共用同一個 PanelContainer，見下方 _open_overlay()
## 一帶。

const MAIN_SCENE := "res://scenes/main.tscn"

# 世界選擇／新槽位選擇共用的面板（issue #810）。執行期建立一次，之後每次
# 開啟只重建 VBox 內容，見 _show_overlay_panel()
var _overlay_panel: PanelContainer
var _overlay_vbox: VBoxContainer
var _overlay_origin: Button

@onready var continue_button: Button = $ButtonsBox/ContinueButton
@onready var start_button: Button = $ButtonsBox/StartButton
@onready var credits_button: Button = $ButtonsBox/CreditsButton
@onready var quit_button: Button = $ButtonsBox/QuitButton
@onready var load_error_label: Label = $ButtonsBox/LoadErrorLabel
@onready var scrim: ColorRect = $Scrim


func _ready() -> void:
	scrim.hide()
	load_error_label.hide()
	_refresh_continue_button()

	continue_button.pressed.connect(_on_continue_pressed)
	start_button.pressed.connect(_on_start_pressed)
	credits_button.pressed.connect(_on_credits_pressed)
	quit_button.pressed.connect(_on_quit_pressed)
	scrim.gui_input.connect(_on_scrim_gui_input)
	start_button.grab_focus()


func _unhandled_input(event: InputEvent) -> void:
	if scrim.visible and event.is_action_pressed("ui_cancel"):
		_close_overlay()
		get_viewport().set_input_as_handled()


## 有沒有可繼續的世界改看 list_world_ids()（issue #810，多世界槽位）。
## 任一個槽位讀得出來就顯示 ContinueButton——多世界時玩家會在選擇面板
## 挑要進哪個；全部都讀不出來，跟單一世界時代的損毀情況一樣要顯示失敗
## 訊息，不能悄悄只留新遊戲選項（見 issue #343 範圍）
##
## GameManager.continue_load_failed 覆蓋另一種情況：這裡檢查時存檔還在，
## 玩家按下繼續遊戲之後，main_scene.gd 轉場套用時才發現存檔消失或讀不出來
## ——這時 list_world_ids()/is_world_data_valid() 現在重新檢查會查到「不存在」，
## 跟「本來就沒存過」是同一個結果，沒有這個旗標會誤判成後者、悄悄只顯示
## StartButton。優先權比下面兩個檢查高，且是一次性的，讀過一次要立刻清掉
func _refresh_continue_button() -> void:
	if GameManager.continue_load_failed:
		GameManager.continue_load_failed = false
		continue_button.hide()
		load_error_label.show()
		return

	var world_ids := SaveService.list_world_ids()
	for id in world_ids:
		if SaveService.is_world_data_valid(SaveService.get_world(id)):
			continue_button.show()
			return

	if world_ids.is_empty():
		continue_button.hide()
		return

	continue_button.hide()
	load_error_label.show()


func _on_continue_pressed() -> void:
	var world_ids := SaveService.list_world_ids()
	if world_ids.size() > 1:
		# 多個世界才開選擇面板；單一世界維持直接進場，不多一道點擊
		_open_world_select_panel(world_ids)
		return
	# 清單空但按鈕可按的窗口（檢查後存檔被手動刪掉之類）退回
	# DEFAULT_WORLD_ID，_apply_continue() 會如實回報存檔不存在
	GameManager.active_world_id = world_ids[0] if not world_ids.is_empty() \
			else GameManager.DEFAULT_WORLD_ID
	GameManager.continue_requested = true
	get_tree().change_scene_to_file(MAIN_SCENE)


func _on_start_pressed() -> void:
	# 新遊戲要先選槽位（issue #810）：新世界落到哪個 id 選好之後，才在
	# _on_new_slot_selected() 裡照原本的順序（#606／#875）重置時間與殘留
	# 欄位、進場
	_open_new_slot_panel()


func _on_quit_pressed() -> void:
	get_tree().quit()


func _on_credits_pressed() -> void:
	_open_overlay(credits_button)


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
		_close_overlay()


func _close_overlay() -> void:
	scrim.hide()
	for button in [continue_button, start_button, credits_button, quit_button]:
		button.focus_mode = Control.FOCUS_ALL
	if _overlay_origin != null:
		_overlay_origin.grab_focus()
	_overlay_origin = null


# ---------- 世界選擇／新槽位選擇共用面板（issue #810）----------
# 結構比照銘謝面板：Scrim 上疊 Panel，內容是標題 + 每列一個按鈕 + 關閉
# 提示。場景檔裡的 CreditsPanel 是設計期節點，這裡的面板執行期建立——
# 樣式沿用同一張 Setting menu.png 九宮格（main_menu.tscn 的
# StyleBoxTexture_wu84c 參數）。點擊行為一致：PanelContainer 預設 STOP
# 吃掉面板上的點擊，點到 Scrim（面板外）走上面的 _on_scrim_gui_input()
func _open_overlay(origin: Button) -> void:
	_overlay_origin = origin
	_ensure_overlay_panel()
	scrim.show()
	# 銘謝面板同款焦點處理（原本寫在 _on_credits_pressed）：面板開著時把
	# ButtonsBox 的按鈕摘出焦點鏈，純鍵盤玩家按 Tab／Enter 才不會在面板
	# 還開著時在背後直接進場
	origin.release_focus()
	for button in [continue_button, start_button, credits_button, quit_button]:
		button.focus_mode = Control.FOCUS_NONE


func _ensure_overlay_panel() -> void:
	if _overlay_panel != null:
		return
	_overlay_panel = PanelContainer.new()
	var style := StyleBoxTexture.new()
	style.texture = load("res://assets/ui/Setting menu.png")
	style.texture_margin_left = 6.0
	style.texture_margin_top = 28.0
	style.texture_margin_right = 6.0
	style.texture_margin_bottom = 6.0
	style.region_rect = Rect2(11, 12, 106, 122)
	_overlay_panel.add_theme_stylebox_override("panel", style)
	# 錨在畫面正中，grow BOTH 讓面板隨內容列數以中心擴縮，不會往一邊長
	_overlay_panel.set_anchors_preset(Control.PRESET_CENTER)
	_overlay_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_overlay_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	_overlay_vbox = VBoxContainer.new()
	_overlay_vbox.custom_minimum_size = Vector2(220, 0)
	_overlay_vbox.add_theme_constant_override("separation", 6)
	_overlay_panel.add_child(_overlay_vbox)
	scrim.add_child(_overlay_panel)


## 每次開啟重建整個 VBox 內容：標題、entries（每列一個 Button）、關閉提示。
## 標題與按鈕文字可以是翻譯 key（Control 文字 Godot 會自動翻）或
## L10n.tf() 組好的句子；disabled 列只展示不回應，callback 是按下時呼叫
func _show_overlay_panel(title_key: String, entries: Array[Dictionary]) -> void:
	for child in _overlay_vbox.get_children():
		_overlay_vbox.remove_child(child)
		child.queue_free()

	var title := Label.new()
	title.text = title_key
	title.add_theme_color_override("font_color", Color(0.18431373, 0.14509805, 0.13333334, 1))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_overlay_vbox.add_child(title)

	var first_selectable: Button = null
	for entry in entries:
		var button := Button.new()
		button.text = entry["text"]
		button.disabled = entry.get("disabled", false)
		if entry.has("callback"):
			button.pressed.connect(entry["callback"])
		_overlay_vbox.add_child(button)
		if first_selectable == null and not button.disabled:
			first_selectable = button
	# 鍵盤玩家一開面板焦點就落在第一個可選的列上，Esc／點面板外關閉
	if first_selectable != null:
		first_selectable.grab_focus()

	var hint := Label.new()
	hint.text = "UI_STATUS_CLOSE_HINT"
	hint.add_theme_color_override("font_color", Color(0.45882353, 0.34901962, 0.23529412, 1))
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_overlay_vbox.add_child(hint)


func _open_world_select_panel(world_ids: Array[String]) -> void:
	_open_overlay(continue_button)
	var entries: Array[Dictionary] = []
	for id in world_ids:
		# 遊戲日是世界存檔現成的欄位（get_world_save_data() 一定會寫 day），
		# 有就顯示幫玩家認出是哪一輪；讀不出來的槽位不為它發明新顯示，
		# 就列 id——選下去 _apply_continue() 會如實回報並回主選單顯示錯誤
		var data := SaveService.get_world(id)
		if SaveService.is_world_data_valid(data) and data.has("day"):
			entries.append({
				"text": L10n.tf("UI_MENU_WORLD_ENTRY", {"world": id, "day": int(data.get("day", 0))}),
				"callback": _on_world_selected.bind(id),
			})
		else:
			entries.append({"text": id, "callback": _on_world_selected.bind(id)})
	_show_overlay_panel("UI_MENU_WORLD_TITLE", entries)


func _on_world_selected(world_id: String) -> void:
	GameManager.active_world_id = world_id
	GameManager.continue_requested = true
	get_tree().change_scene_to_file(MAIN_SCENE)


func _open_new_slot_panel() -> void:
	_open_overlay(start_button)
	var entries: Array[Dictionary] = []
	# 既有世界列出來但不能選——開新遊戲不能蓋掉舊世界的存檔
	for id in SaveService.list_world_ids():
		entries.append({
			"text": L10n.tf("UI_MENU_SLOT_OCCUPIED", {"world": id}),
			"disabled": true,
		})
	# 建議槽位從 next_free_world_id() 起算連取兩號：都在現有最大號之後，
	# 一定不會跟既有世界撞名
	var next_num := int(SaveService.next_free_world_id().trim_prefix("world_"))
	for offset in 2:
		var slot_id := "world_%03d" % (next_num + offset)
		entries.append({
			"text": L10n.tf("UI_MENU_SLOT_FREE", {"world": slot_id}),
			"callback": _on_new_slot_selected.bind(slot_id),
		})
	_show_overlay_panel("UI_MENU_SLOT_TITLE", entries)


func _on_new_slot_selected(world_id: String) -> void:
	GameManager.active_world_id = world_id
	# 跟 _on_start_pressed() 原本的三步順序一致：時間重置（#606）→
	# 殘留欄位重置（#875）→ 進場
	GameClock.reset_to_new_game_start()
	GameManager.reset_for_new_game()
	get_tree().change_scene_to_file(MAIN_SCENE)
