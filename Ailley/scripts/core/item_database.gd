class_name ItemDatabase
extends RefCounted

## 物品定義檔的查詢介面：`item_id` → 顯示名稱、分類、圖示。品項清單抄自
## 《規格書 08 物品與經濟》§2、§3（食物／飲品／獵物／水產／採集品／隨身用品），
## 資料放 `res://data/items.json`。
##
## `icon` 目前全部是 `null`——專案還沒有任何物品圖示素材（現有的
## `Sprite sheet for Basic Pack.png` 是通用 UI 圖示如星星／獎盃，不是物品圖），
## 先把欄位定好形狀，等美術素材到位再填 `{"source": "res://...", "region": [x, y, w, h]}`。
## `inventory_slot_button.gd` 已改讀這個定義檔（#743）查顯示名稱——顯示端
## 仍是文字佔位，等物品圖示素材。
##
## Inventory 本身不查這份定義檔——`item_id` 那階段收任意字串（見
## note/技術/物品欄.md），這裡只服務顯示端。

const PATH := "res://data/items.json"

static var _items: Dictionary = {}
static var _decay_rates: Dictionary = {}
static var _loaded := false


static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true

	var file := FileAccess.open(PATH, FileAccess.READ)
	if file == null:
		push_error("ItemDatabase: 找不到 %s" % PATH)
		return

	# 用 JSON 實例解析，跟 ai_config.gd 同一個理由：parse_string() 失敗時
	# 引擎錯誤訊息會帶出錯位置附近的原文，這裡雖然沒有金鑰，但統一寫法比較好認
	var json := JSON.new()
	var text := file.get_as_text()
	file.close()

	if json.parse(text) != OK or not json.data is Dictionary:
		push_error("ItemDatabase: %s 不是合法的 JSON 物件" % PATH)
		return

	_items = json.data as Dictionary

	# 只收有填 decay_rate 且 > 0 的項目（《規格書08》§3-1～§3-4）——water、
	# spirit【待填】、carry 類（用 durability 不用 decay）都沒有這個欄位，
	# tick_decay() 查不到就當非易腐直接跳過，不用另外查 category 白名單
	_decay_rates = {}
	for id in _items:
		var rate := float(_items[id].get("decay_rate", 0.0))
		if rate > 0.0:
			_decay_rates[id] = rate


## 查不到回空字典，呼叫端用 is_empty() 判斷——跟 Inventory.get_slot() 的
## 空格慣例一致，顯示端不用另外分兩套「找不到」的判斷方式
static func get_item(item_id: String) -> Dictionary:
	_ensure_loaded()
	return _items.get(item_id, {})


static func has_item(item_id: String) -> bool:
	_ensure_loaded()
	return _items.has(item_id)


## item_id → 每 tick 腐壞速率（《規格書08》§6-1），只收 decay_rate > 0 的項目。
## `Inventory.tick_decay()` 拿這份表用，Inventory 本身不查這份定義檔（見上方
## 檔案說明），呼叫端（`character.gd`）負責把這份表傳進去
static func get_decay_rates() -> Dictionary:
	_ensure_loaded()
	return _decay_rates


## 查不到定義檔就退回 item_id 本身，不是空字串——顯示端至少還看得出是什麼，
## 不會因為定義檔漏掉一筆就整格空白
static func get_display_name(item_id: String) -> String:
	var item := get_item(item_id)
	return str(item.get("display_name", item_id))
