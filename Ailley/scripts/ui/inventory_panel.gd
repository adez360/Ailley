class_name InventoryPanel
extends CanvasLayer

## 主背包面板：inventory_toggle（Tab）開關，27 格，滑鼠點擊任一格可以選取，
## 格子之間（含快捷欄）可以互相拖放搬移物品。
##
## 面板內也嵌了一份快捷欄的 9 格（HotbarColumn），純顯示＋可拖放，不接
## 點擊選取——快捷欄真正的「選中哪一格」互動留在螢幕下方常駐的 hotbar.gd，
## 這裡兩份 InventorySlotButton 都指向 Inventory.slots 同一批索引（0-8），
## 資料共通，畫面各自刷新，不是兩份資料。
##
## 主背包（MainGrid）的 27 格不一樣：點了只是**面板自己的視覺高亮**，
## Inventory 沒有對應的資料欄位可以存（set_selected_index() 只服務快捷欄
## 0-8，硬呼叫的話等於誤把主背包點擊當成換手持物品）。
##
## 格子上的文字（見 inventory_slot_button.gd）是暫時的示意畫法：印
## `ItemDatabase.get_display_name()` 查到的中文名稱（最多 2 字），數量 > 1
## 才多印一行，等物品圖示素材到位再換。
##
## 場景結構是這份腳本的合約：
##   CanvasLayer（本腳本）
##     Panel（Setting menu.png 九宮格，素面那格，見 UI 版面與素材規格.md）
##       VBox
##         TitleLabel
##         Row（HBoxContainer）
##           MainGrid（GridContainer，columns=9，空的，本腳本長出 27 個格子）
##           HotbarColumn（VBoxContainer）
##             HotbarLabel
##             HotbarGrid（GridContainer，columns=3，空的，本腳本長出 9 個格子）
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
@onready var main_grid: GridContainer = $Panel/VBox/Row/MainGrid
@onready var hotbar_label: Label = $Panel/VBox/Row/HotbarColumn/HotbarLabel
@onready var hotbar_grid: GridContainer = $Panel/VBox/Row/HotbarColumn/HotbarGrid
@onready var hint_label: Label = $Panel/VBox/HintLabel

var _slots: Array[TextureButton] = []	# index 0..26，_ready() 時建好
var _highlighted_index := 0


func _ready() -> void:
	panel.hide()
	title_label.text = L10n.t("UI_INV_TITLE")
	hotbar_label.text = L10n.t("UI_INV_HOTBAR")
	hint_label.text = L10n.t("UI_INV_CLOSE_HINT")

	for i in SIZE:
		_slots.append(_make_slot(i))
	for i in Inventory.HOTBAR_SIZE:
		_make_hotbar_slot(i)

	_refresh_highlight()

func _make_slot(index: int) -> TextureButton:
	var button := _new_slot_button()
	# 面板的 index 是 0-26，Inventory.slots 裡主背包是接在快捷欄後面的 9-35
	button.slot_index = index + Inventory.HOTBAR_SIZE
	button.pressed.connect(_select.bind(index))
	main_grid.add_child(button)
	return button

# 純顯示＋拖放，不接 pressed——選取快捷欄哪一格是 hotbar.gd 的事，這裡
# 只是同一批資料（Inventory.slots 0-8）的另一個畫面
func _make_hotbar_slot(index: int) -> void:
	var button := _new_slot_button()
	button.slot_index = index
	hotbar_grid.add_child(button)

func _new_slot_button() -> InventorySlotButton:
	var atlas := AtlasTexture.new()
	atlas.atlas = SLOT_SHEET
	atlas.region = SLOT_REGION

	var button := InventorySlotButton.new()
	button.texture_normal = atlas
	button.stretch_mode = TextureButton.STRETCH_KEEP
	# 純滑鼠點擊格，不搶鍵盤焦點——理由跟 hotbar.gd 同一段註解：按鈕預設
	# FOCUS_ALL，焦點卡住會被 _ui_is_busy() 誤判成有 UI 在忙
	button.focus_mode = Control.FOCUS_NONE
	return button

# inventory_toggle 走 input_map_manage 綁的 Tab，不是硬寫 KEY_TAB——
# 理由跟 hotbar.gd 的 hotbar_1..9 一樣，鍵位要能在 ProjectSettings 重新綁定
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("inventory_toggle"):
		_toggle()
		get_viewport().set_input_as_handled()
		return

	if panel.visible and event.is_action_pressed("ui_cancel"):
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
