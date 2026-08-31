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
## 4 字品名（「小型獵物」「大型獵物」「一般衣物」）。字級在 `_ready()` 明確
## override 成 11（theme 的 Label 預設是 12，見 `ailley_theme.tres`；11 是 Cubic
## 11 的原生尺寸——《UI 版面與素材規格》§字型：點陣中文字型只在原生尺寸或其
## 整數倍才銳利，12 已是放大渲染），改用 `MAX_NAME_CHARS` 在組字串階段砍到
## 2 個完整字元——11px × 2 字 = 22px，進得去 26px 的格子。代價：`herb`「藥草」與
## `herb_soup`「藥草湯」截斷後撞成同一個「藥草」，目前物品清單裡只有這一組
## 撞名，且兩者本就同源（湯是草煮的），暫時接受，等圖示系統做出來自然分辨。
## 單靠 `clip_text` 逐像素裁切會從中文字中間切一刀、裁出殘缺字形，所以
## `clip_text` 只當漏網之魚的最後防線。這是暫時的示意畫法，不是要在文字排版
## 上做到完美。
##
## slot_index 是這格對應到 Inventory.slots 的絕對索引（0-35，快捷欄 0-8、
## 主背包 9-35，見 inventory.gd）。跟 hotbar.gd／inventory_panel.gd 一樣不快取
## player 節點——每次刷新當下才查，避免角色重生、場景切換後拿到卡死的舊參照。
##
## changed 的連線綁在目前查到的那個 Inventory 實例上，換角（deploy_from_library
## queue_free 舊 player、生出新 player）時舊實例連同連線一起消失，新實例的
## changed 沒有人接，格子會卡著換角前最後一次刷新的畫面（實測重現過：換角後
## 快捷欄還顯示舊角色的物品，新角色買東西畫面也不會刷新）。靠
## GameManager.player_body_changed 訊號在換角當下重新接一次，_connected_inventory
## 記著目前接的是哪個實例，避免每次都重複 connect。
##
## 拖放搬移物品（#304）：放到空格呼叫 Inventory.move_slot()，放到已佔用的格
## 呼叫 swap_slot()，格子本身不算堆疊、不判斷能不能放——那是資料層的事。
## Godot 的拖放是 viewport 層級判定，不是各自 CanvasLayer 自己的，所以快捷欄
## 常駐列跟背包面板裡的格子（不管是主背包 27 格還是面板內嵌的快捷欄 9 格）
## 天生就能互拖，不需要額外接線。

const NAME_FONT_SIZE := 11		# Cubic 11 原生尺寸；theme 的 Label 預設是 12（ailley_theme.tres），_ready() 明確 override（理由見檔頭）
const MAX_NAME_CHARS := 2		# 11px × 2 字 = 22px 進得去 26px 格；字級 NAME_FONT_SIZE = 11 不降級（藥草／藥草湯撞名的取捨見檔頭）

var slot_index := -1

var _label: Label
var _connected_inventory: Inventory = null	# 目前 changed 訊號接在哪個實例上，見檔頭「changed 的連線」


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
	# theme 的 Label 預設字級是 12（ailley_theme.tres），這裡明確 override 成 11：
	# Cubic 11 的原生尺寸（《UI 版面與素材規格》§字型），11px × 2 字 = 22px 也才
	# 進得去 26px 格——算式的輸入值由此釘死，不跟著 theme 漂
	_label.add_theme_font_size_override("font_size", NAME_FONT_SIZE)
	_label.clip_text = true
	add_child(_label)

	# 掛 Inventory.changed，不是每幀重畫——36 個格子各輪詢一次 get_slot()
	# （內含 duplicate()）在 60fps 下是兩千多次配置／秒，而資料只在買東西或
	# 工作時才變。等一幀才連線是因為 Hotbar／InventoryPanel 跟 Player 誰先
	# _ready() 由場景樹順序決定，這一幀不保證找得到 player
	await get_tree().process_frame

	GameManager.player_body_changed.connect(_rebind_inventory)
	_rebind_inventory()

## 換角時重新把 changed 接到目前的 Inventory 實例上（見檔頭說明）。
## 也是 _ready() 首次連線的路徑，跟換角走同一套，不用另外寫一份
func _rebind_inventory() -> void:
	var inventory := _get_inventory()
	if inventory == _connected_inventory:
		return
	_connected_inventory = inventory
	# 舊實例已經被 queue_free()，不用手動 disconnect——物件釋放時連線自動清掉
	if inventory != null and not inventory.changed.is_connected(_refresh_label):
		inventory.changed.connect(_refresh_label)
	_refresh_label()

## 格子文字的單一來源：查 `ItemDatabase.get_display_name()`、截到
## `MAX_NAME_CHARS` 個完整字元、`count > 1` 才多印一行數量。status_panel.gd
## 的物品分頁共用這個組法（《15》§2-6 的「沿用 inventory_slot_button.gd」），
## 不另外複製一份邏輯。
static func slot_text(slot: Dictionary) -> String:
	var item_id: String = slot["item_id"]
	var count: int = slot["count"]
	var shown := ItemDatabase.get_display_name(item_id)
	if not ItemDatabase.has_item(item_id):
		shown = shown.to_upper()	# 未知 item_id 退回 item_id 本身；維持舊碼的大寫慣例（未定義的 rope → RO，不是 ro）
	if shown.length() > MAX_NAME_CHARS:
		shown = shown.substr(0, MAX_NAME_CHARS)
	return "%s\n%d" % [shown, count] if count > 1 else shown

func _refresh_label() -> void:
	var inventory := _get_inventory()
	var slot: Dictionary = {}

	if inventory != null:
		slot = inventory.get_slot(slot_index)

	if slot.is_empty():
		_label.text = ""
		return

	_label.text = slot_text(slot)

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
