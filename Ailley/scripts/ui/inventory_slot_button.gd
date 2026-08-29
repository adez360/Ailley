class_name InventorySlotButton
extends TextureButton

## 快捷欄／背包共用的格子按鈕。在原本純點擊選取的 TextureButton 上疊一層
## 文字，把格子裡有什麼東西秀出來——item 定義檔已有（`scripts/core/item_database.gd`
## 查 `data/items.json`），但還沒有物品圖示素材可畫，這裡先印
## `ItemDatabase.get_display_name()` 查到的中文名稱頂著用（見 #743，前身 #84
## 只做了定義檔本身，沒接上這裡），數量只在 count > 1 時才多印一行——單件
## 物品印「1」沒有資訊量，格子本來就小，省下這行給名稱多一點空間。真正的
## 圖示系統做出來之後這塊要整個換掉，不是拿去微調。
##
## 格子只有 26×28px（見 note/技術/UI 版面與素材規格.md），塞不下最長的
## 4 字品名（「小型獵物」「大型獵物」「一般衣物」）——`NAME_FONT_SIZE` 把字級
## 從預設 11 降到 8，但單靠 `clip_text` 逐像素裁切在中文字上會從字中間切
## 一刀，裁出來的殘缺字形比整份名稱少顯示一個字還醜（實機截圖驗證過）。
## 所以改成先用 `MAX_NAME_CHARS` 在組字串階段就砍到完整字元數，`clip_text`
## 只當漏網之魚的最後防線。這是暫時的示意畫法，不是要在文字排版上做到完美。
##
## slot_index 是這格對應到 Inventory.slots 的絕對索引（0-35，快捷欄 0-8、
## 主背包 9-35，見 inventory.gd）。跟 hotbar.gd／inventory_panel.gd 一樣不快取
## player 節點——每次刷新當下才查，避免角色重生、場景切換後拿到卡死的舊參照。
## 只有 changed 的連線是綁在開場那一個 Inventory 上的：目前沒有任何角色重生
## 或 despawn 的路徑，真的做出來時這裡要跟著重連。
##
## 拖放搬移物品（#304）：放到空格呼叫 Inventory.move_slot()，放到已佔用的格
## 呼叫 swap_slot()，格子本身不算堆疊、不判斷能不能放——那是資料層的事。
## Godot 的拖放是 viewport 層級判定，不是各自 CanvasLayer 自己的，所以快捷欄
## 常駐列跟背包面板裡的格子（不管是主背包 27 格還是面板內嵌的快捷欄 9 格）
## 天生就能互拖，不需要額外接線。

const NAME_FONT_SIZE := 8		# 預設 11 太大，4 字品名在 26px 寬的格子裡幾乎全被 clip 掉
const MAX_NAME_CHARS := 3		# 實機驗證：4 字在 8 級字下會被 clip_text 從字中間裁開，裁出殘缺字形

var slot_index := -1

var _label: Label


func _ready() -> void:
	# 預設 MOUSE_FILTER_STOP 會把滑鼠滾輪事件吃在這裡，輪不到 Hotbar 的
	# _unhandled_input 去切選格——PASS 讓按鈕照樣收得到點擊／拖放，
	# 沒人處理的滾輪事件則繼續往上傳
	mouse_filter = Control.MOUSE_FILTER_PASS

	_label = Label.new()
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE	# 不擋底下按鈕的點擊
	_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.clip_text = true
	_label.add_theme_font_size_override("font_size", NAME_FONT_SIZE)
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
	var slot: Dictionary = {}

	if inventory != null:
		slot = inventory.get_slot(slot_index)

	if slot.is_empty():
		_label.text = ""
		return

	var item_id: String = slot["item_id"]
	var count: int = slot["count"]
	var shown := ItemDatabase.get_display_name(item_id)
	if shown.length() > MAX_NAME_CHARS:
		shown = shown.substr(0, MAX_NAME_CHARS)

	_label.text = (
		"%s\n%d" % [shown, count]
		if count > 1
		else shown
	)

func _get_inventory() -> Inventory:
	var player := get_tree().get_first_node_in_group("player")
	if player == null:
		return null
	return player.inventory


# ---- 拖放 ----

# 空格沒東西可拖，回傳 null 讓 Godot 判定這格不能發起拖放
func _get_drag_data(_at_position: Vector2) -> Variant:
	var inventory := _get_inventory()
	if inventory == null or inventory.get_slot(slot_index).is_empty():
		return null

	var preview := Label.new()
	preview.text = _label.text
	set_drag_preview(preview)

	return {"slot_index": slot_index}

func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	return data is Dictionary and data.has("slot_index") and data["slot_index"] != slot_index

func _drop_data(_at_position: Vector2, data: Variant) -> void:
	var inventory := _get_inventory()
	if inventory == null:
		return

	var from: int = data["slot_index"]
	if inventory.get_slot(slot_index).is_empty():
		inventory.move_slot(from, slot_index)
	else:
		inventory.swap_slot(from, slot_index)
