class_name InventorySlotButton
extends TextureButton

## 快捷欄／背包共用的格子按鈕。在原本純點擊選取的 TextureButton 上疊一層
## 文字，把格子裡有什麼東西秀出來——item 定義檔已有（`scripts/core/item_database.gd`
## 查 `data/items.json`），但還沒有物品圖示素材可畫，這裡先印 item_id 前三碼＋
## 數量頂著用（見 #84），真正的圖示系統做出來之後這塊要整個換掉，不是拿去微調。
##
## slot_index 是這格對應到 Inventory.slots 的絕對索引（0-35，快捷欄 0-8、
## 主背包 9-35，見 inventory.gd）。跟 hotbar.gd／inventory_panel.gd 一樣不快取
## player 節點——每次刷新當下才查，避免角色重生、場景切換後拿到卡死的舊參照。
## 只有 changed 的連線是綁在開場那一個 Inventory 上的：目前沒有任何角色重生
## 或 despawn 的路徑，真的做出來時這裡要跟著重連。
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

	# 掛 Inventory.changed，不是每幀重畫——36 個格子各輪詢一次 get_slot()
	# （內含 duplicate()）在 60fps 下是兩千多次配置／秒，而資料只在買東西或
	# 工作時才變。等一幀才連線是因為 Hotbar／InventoryPanel 跟 Player 誰先
	# _ready() 由場景樹順序決定，這一幀不保證找得到 player
	await get_tree().process_frame

	var inventory := _get_inventory()
	if inventory != null:
		inventory.changed.connect(_refresh_label)
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
