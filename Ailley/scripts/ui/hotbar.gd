class_name Hotbar
extends CanvasLayer

## 快捷欄：螢幕下方常駐 HUD，9 格，不受 InventoryPanel 開關影響——跟時鐘一樣
## 「一直在」，玩家不用開背包也要看得到手上選到第幾格。
##
## 選取狀態是 Inventory 自己的（_selected_index，代表「手上拿著哪一格」，
## Agent 沒有 UI 也要有這個概念，見 inventory.gd），這裡只負責畫出來、
## 接數字鍵 1-9、滑鼠滾輪、滑鼠點擊。跟 InventoryPanel 的主背包格不一樣——
## 那邊點擊只是面板自己的視覺高亮，因為主背包沒有對應的 Inventory 欄位；
## 快捷欄這 9 格全部都對得到 Inventory.set_selected_index()。
##
## 格子上的文字（見 inventory_slot_button.gd）是暫時的示意畫法：專案還沒有
## item 定義檔可以查真正的圖示，先印 item_id 前三碼＋數量。
##
## 場景結構：
##   CanvasLayer（本腳本）
##     Backdrop（半透明底板，跟 ConsoleOutput 同款 StyleBoxFlat）
##       Grid（GridContainer，columns=9，空的，本腳本長出 9 個格子）

const SIZE := 9

## 跟 inventory_panel.gd 用同一個 region——兩邊都是同一張 sprite sheet
## 的同一格，換素材時兩邊要一起改
const SLOT_REGION := Rect2(11, 59, 26, 28)
const SLOT_SHEET := preload("res://assets/ui/Sprite sheet for Basic Pack.png")

const SELECTED_TINT := Color("C96C23")	# Amber，跟 inventory_panel.gd 同一個顏色語意
const NORMAL_TINT := Color(1, 1, 1, 1)

@onready var grid: GridContainer = $Backdrop/Grid

var _slots: Array[TextureButton] = []


func _ready() -> void:
	for i in SIZE:
		_slots.append(_make_slot(i))
	_refresh()

func _make_slot(index: int) -> TextureButton:
	var atlas := AtlasTexture.new()
	atlas.atlas = SLOT_SHEET
	atlas.region = SLOT_REGION

	var button := InventorySlotButton.new()
	button.slot_index = index		# 快捷欄在 Inventory.slots 就是 0-8，跟格子 index 一樣
	button.texture_normal = atlas
	button.stretch_mode = TextureButton.STRETCH_KEEP
	# 純滑鼠點擊格，不搶鍵盤焦點——按鈕預設 FOCUS_ALL，點一下焦點就卡在上面
	# 不放，_ui_is_busy() 拿「有沒有東西拿著焦點」判斷有沒有別的 UI 在忙，
	# 卡住的焦點會被誤判成「忙」，Enter 永遠開不了聊天框
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(_select.bind(index))
	grid.add_child(button)
	return button

# 走 input_map_manage 建的 hotbar_1..hotbar_9 / 滑鼠滾輪，不是硬寫 keycode——
# 鍵位要能在 ProjectSettings 重新綁定。打字時（聊天框、主控台輸入框持有焦點）
# 不切選格，理由跟 chat_input.gd 的 _ui_is_busy() 一樣：那些輸入框也吃 1-9
func _unhandled_input(event: InputEvent) -> void:
	if _ui_is_busy():
		return

	for i in SIZE:
		if event.is_action_pressed("hotbar_%d" % (i + 1)):
			_select(i)
			get_viewport().set_input_as_handled()
			return

	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_select_relative(-1)
			get_viewport().set_input_as_handled()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_select_relative(1)
			get_viewport().set_input_as_handled()

func _ui_is_busy() -> bool:
	return get_viewport().gui_get_focus_owner() != null

# 滾輪繞著 9 格轉圈，wrapi() 處理兩端——8 往下滾回 0，0 往上滾回 8。
# 目前沒有選取（-1）時從第 0 格開始算，跟數字鍵 1 選到的格一致
func _select_relative(delta: int) -> void:
	var player := get_tree().get_first_node_in_group("player")
	if player == null or player.inventory == null:
		return
	var current: int = player.inventory.get_selected_index()
	var base := 0 if current < 0 else current
	_select(wrapi(base + delta, 0, SIZE))

# 選到已經選取的那一格 = 取消選擇（#304：點兩下同一格）。滾輪不會踩到這條——
# delta 固定 ±1、SIZE=9，不可能繞回原地
func _select(index: int) -> void:
	var player := get_tree().get_first_node_in_group("player")
	if player == null or player.inventory == null:
		return

	var inventory: Inventory = player.inventory
	if inventory.get_selected_index() == index:
		inventory.set_selected_index(-1)
	else:
		inventory.set_selected_index(index)
	_refresh()

func _refresh() -> void:
	var player := get_tree().get_first_node_in_group("player")
	var selected: int = player.inventory.get_selected_index() if player != null and player.inventory != null else 0

	for i in _slots.size():
		_slots[i].modulate = SELECTED_TINT if i == selected else NORMAL_TINT
