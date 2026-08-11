class_name Hotbar
extends CanvasLayer

## 快捷欄：螢幕下方常駐 HUD，9 格，不受 InventoryPanel 開關影響——跟時鐘一樣
## 「一直在」，玩家不用開背包也要看得到手上選到第幾格。
##
## 選取狀態是 Inventory 自己的（_selected_index，代表「手上拿著哪一格」，
## Agent 沒有 UI 也要有這個概念，見 inventory.gd），這裡只負責畫出來、
## 接數字鍵 1-9 跟滑鼠點擊。跟 InventoryPanel 的主背包格不一樣——
## 那邊點擊只是面板自己的視覺高亮，因為主背包沒有對應的 Inventory 欄位；
## 快捷欄這 9 格全部都對得到 Inventory.set_selected_index()。
##
## 目前 Inventory.slots 全部是空的，9 格先畫空框，不畫道具圖示（見 #54）。
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

	var button := TextureButton.new()
	button.texture_normal = atlas
	button.stretch_mode = TextureButton.STRETCH_KEEP
	button.pressed.connect(_select.bind(index))
	grid.add_child(button)
	return button

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed):
		return

	# KEY_1..KEY_9 是連續的 keycode，減去 KEY_1 直接算出 0-8 的格子 index
	if event.keycode >= KEY_1 and event.keycode <= KEY_9:
		_select(event.keycode - KEY_1)
		get_viewport().set_input_as_handled()

func _select(index: int) -> void:
	var player := get_tree().get_first_node_in_group("player")
	if player != null and player.inventory != null:
		player.inventory.set_selected_index(index)
	_refresh()

func _refresh() -> void:
	var player := get_tree().get_first_node_in_group("player")
	var selected: int = player.inventory.get_selected_index() if player != null and player.inventory != null else 0

	for i in _slots.size():
		_slots[i].modulate = SELECTED_TINT if i == selected else NORMAL_TINT
