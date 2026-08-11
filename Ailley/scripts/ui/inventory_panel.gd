class_name InventoryPanel
extends CanvasLayer

## 主背包面板：按 P 開關，27 格，滑鼠點擊任一格可以選取。
##
## 快捷欄（9 格，數字鍵 1-9）不在這裡——它是螢幕下方常駐的 hotbar.gd，
## 不受這個面板開關影響，玩家不開背包也要看得到手上選到第幾格。
## 兩邊分開的理由：快捷欄的選取是 Inventory 自己的狀態（_selected_index，
## 代表「手上拿著哪一格」，Agent 沒有 UI 也要有這個概念，見 inventory.gd），
## 這裡的 27 格點了只是**面板自己的視覺高亮**，Inventory 沒有對應的資料欄位
## 可以存（set_selected_index() 只服務快捷欄 0-8，硬呼叫的話等於誤把主背包
## 點擊當成換手持物品）。
##
## 目前 Inventory.slots 全部是空的（沒有任何 item_id 定義過，見 #54），
## 27 格目前一律畫成空框，不畫道具圖示。
##
## 場景結構是這份腳本的合約：
##   CanvasLayer（本腳本）
##     Panel（Setting menu.png 九宮格，素面那格，見 UI 版面與素材規格.md）
##       VBox
##         TitleLabel
##         MainGrid（GridContainer，columns=9，空的，本腳本長出 27 個格子）
##         HintLabel

const SIZE := 27		# 跟 Inventory.MAIN_SIZE 對齊，這裡不依賴場景裡有沒有角色就能畫格子

## 跟 hotbar.gd 用同一個 region——兩邊都是同一張 sprite sheet 的同一格，
## 換素材時兩邊要一起改
const SLOT_REGION := Rect2(11, 59, 26, 28)
const SLOT_SHEET := preload("res://assets/ui/Sprite sheet for Basic Pack.png")

const SELECTED_TINT := Color("C96C23")	# Amber，跟 ailley_theme.tres 的 TextEdit focus 框同一個顏色語意
const NORMAL_TINT := Color(1, 1, 1, 1)

@onready var panel: Panel = $Panel
@onready var title_label: Label = $Panel/VBox/TitleLabel
@onready var main_grid: GridContainer = $Panel/VBox/MainGrid
@onready var hint_label: Label = $Panel/VBox/HintLabel

var _slots: Array[TextureButton] = []	# index 0..26，_ready() 時建好
var _highlighted_index := 0


func _ready() -> void:
	panel.hide()
	title_label.text = L10n.t("UI_INV_TITLE")
	hint_label.text = L10n.t("UI_INV_CLOSE_HINT")

	for i in SIZE:
		_slots.append(_make_slot(i))

	_refresh_highlight()

func _make_slot(index: int) -> TextureButton:
	var atlas := AtlasTexture.new()
	atlas.atlas = SLOT_SHEET
	atlas.region = SLOT_REGION

	var button := TextureButton.new()
	button.texture_normal = atlas
	button.stretch_mode = TextureButton.STRETCH_KEEP
	button.pressed.connect(_select.bind(index))
	main_grid.add_child(button)
	return button

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed):
		return

	if event.keycode == KEY_P:
		_toggle()
		get_viewport().set_input_as_handled()
		return

	if panel.visible and event.keycode == KEY_ESCAPE:
		close()
		get_viewport().set_input_as_handled()

func _select(index: int) -> void:
	_highlighted_index = index
	_refresh_highlight()

func _refresh_highlight() -> void:
	for i in _slots.size():
		_slots[i].modulate = SELECTED_TINT if i == _highlighted_index else NORMAL_TINT

func _toggle() -> void:
	if panel.visible:
		close()
	else:
		open()

func open() -> void:
	panel.show()

func close() -> void:
	panel.hide()
