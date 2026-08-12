class_name InventorySlotButton
extends TextureButton

## 快捷欄／背包共用的格子按鈕。在原本純點擊選取的 TextureButton 上疊一層
## 文字，把格子裡有什麼東西秀出來——專案還沒有 item 定義檔可以查真正的圖示
## 跟顯示名稱（見 #54），先印 item_id 前三碼＋數量頂著用，真正的圖示系統
## 做出來之後這塊要整個換掉，不是拿去微調。
##
## slot_index 是這格對應到 Inventory.slots 的絕對索引（0-35，快捷欄 0-8、
## 主背包 9-35，見 inventory.gd）。跟 hotbar.gd／inventory_panel.gd 一樣不快取
## player 節點——每次刷新當下才查，避免角色重生、場景切換後拿到卡死的舊參照。
##
## 只做顯示，沒有拖放——那是 #35 的範圍，這裡不需要

var slot_index := -1

var _label: Label


func _ready() -> void:
	_label = Label.new()
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE	# 不擋底下按鈕的點擊
	_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.clip_text = true
	add_child(_label)
	_refresh_label()

# 用 _process() 每幀重畫而不是等訊號，是因為 Inventory 目前沒有「格子變了」
# 的訊號可以掛
func _process(_delta: float) -> void:
	_refresh_label()

func _refresh_label() -> void:
	var inventory := _get_inventory()
	var slot := inventory.get_slot(slot_index) if inventory != null else {}

	if slot.is_empty():
		_label.text = ""
		return

	var item_id: String = slot["item_id"]
	var count: int = slot["count"]
	var shown := item_id.substr(0, 3).to_upper()
	_label.text = "%s\n%d" % [shown, count] if count > 1 else shown

func _get_inventory() -> Inventory:
	var player := get_tree().get_first_node_in_group("player")
	if player == null:
		return null
	return player.inventory
