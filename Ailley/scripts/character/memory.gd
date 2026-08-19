class_name Memory
extends Node

## 角色的記憶（《03 事件評估與記憶》L1-L4）。跟 Stats／Relationships 同一種
## 掛法——獨立子節點元件，不把資料塞進 Character 主檔案。
##
## L1 短期工作記憶：固定 8 條，FIFO，每次「剛發生的事/剛講的話」都可以推一筆，
## 跟分級無關、不會被丟棄，滿了就擠掉最舊的一條。跟 L2/L3/L4 資料形狀完全不同
## （沒有 importance/valence/decay_value），所以另外用 l1 陣列裝，不跟 entries
## 共用一份、硬塞 nullable 欄位。
##
## L2/L3/L4 由 importance 分級（見 add_candidate()），這一層才是「記憶」真正
## 會留存/衰減/被檢索的部分。三層共用同一個 entries 陣列，用 level 欄位分——
## 不拆三個陣列，是因為《03》§4-2「被檢索延長壽命」跟 L4 滿額降級都需要在
## 同一個集合裡搬動記憶，拆開反而要多寫搬移邏輯。
##
## 不做：向量檢索（§7，完整版才需要，MVP 用標籤/關鍵字/連結展開）、記憶寫進
## 存檔（依賴 #21/#22 先有存檔骨架）。

## 分級門檻與規則，見《03》§2-4／《99》P-15（已定案）
const DISCARD_BELOW := 30
const L3_AT := 60
const L4_AT := 90
const L4_CAP := 5
const CONTENT_MAX_CHARS := 60
const BASE_DECAY_RATE := 3.0
const RETRIEVAL_BONUS := 10.0
const DECAY_MAX := 100.0

## L1 固定 8 條，見《03》§1
const L1_CAP := 8

var l1: Array[Dictionary] = []			# 每筆 {content: String}
var entries: Array[Dictionary] = []		# L2/L3/L4，形狀見 add_candidate()

var _next_id := 0


func _ready() -> void:
	GameClock.day_changed.connect(_on_day_changed)


## 加一筆 L1。跟分級無關——L1 是「剛剛發生的事」的固定大小視窗，不是候選記憶，
## 不會被丟棄，只會被擠出去
func push_l1(content: String) -> void:
	l1.append({"content": content})
	if l1.size() > L1_CAP:
		l1.pop_front()


## 加一筆候選記憶，依 importance 分級寫入。《03》§3 分級對照：
## <30 丟棄／30-59 進 L2／60-89 進 L3／90+ 進 L4（L4 滿額時最舊一條降級 L3）。
## 回傳寫入後的 entry；被丟棄回傳 {}
func add_candidate(
	content: String,
	importance: int,
	valence: String = "neutral",
	related_npcs: Array[String] = [],
	location_id: String = "",
) -> Dictionary:
	if importance < DISCARD_BELOW:
		return {}

	var level := 2
	if importance >= L4_AT:
		level = 4
	elif importance >= L3_AT:
		level = 3

	var trimmed_content := content
	if trimmed_content.length() > CONTENT_MAX_CHARS:
		trimmed_content = trimmed_content.substr(0, CONTENT_MAX_CHARS)

	_next_id += 1
	var entry := {
		"id": _next_id,
		"level": level,
		"content": trimmed_content,
		"valence": valence,
		"importance": importance,
		"related_npcs": related_npcs,
		"location_id": location_id,
		"decay_value": 100,
		"created_day": GameClock.day,
	}

	if level == 4:
		_demote_oldest_l4_if_full()

	entries.append(entry)
	return entry


## L4 滿額（上限 5）時，新記憶要進來之前，先把最舊的一條 L4 降級成 L3——
## 不是丟棄，《03》§3 講的是「取代」，被取代者仍然留在記憶庫裡，只是不再是
## 核心記憶
func _demote_oldest_l4_if_full() -> void:
	var l4_entries := get_by_level(4)
	if l4_entries.size() < L4_CAP:
		return

	var oldest: Dictionary = l4_entries[0]
	for e in l4_entries:
		if e["created_day"] < oldest["created_day"]:
			oldest = e
	oldest["level"] = 3


## 每遊戲日呼叫一次（見 _on_day_changed()）。grudge 由呼叫端傳入——人格資料
## 還沒接上（#117），這裡不讀 Character 的人格欄位，保持這個函式可以獨立測試。
## 公式見《03》§4-1：正面/中性 -= 基礎衰減率；負面 -= 基礎衰減率 × (100-grudge)/50。
## L4 不衰減（核心記憶永不遺忘）
##
## ⚠《03》§3 分級表另外寫「L2：30-59...三日後若未被檢索則淘汰」，字面上是跟
## §4-1 衰減公式不同的規則（3 天 vs 衰減率 3/天約 33 天才歸零）——兩者數字對
## 不起來。已列入《99》待釐清，這裡先只實作 §4-1 的衰減公式（唯一有明確公式、
## 對所有非 L4 層級一致適用的規則）
func decay_all(grudge: float = 50.0) -> void:
	var kept: Array[Dictionary] = []
	for entry in entries:
		if entry["level"] == 4:
			kept.append(entry)
			continue

		var rate := BASE_DECAY_RATE
		if entry["valence"] == "negative":
			rate = BASE_DECAY_RATE * (100.0 - grudge) / 50.0

		entry["decay_value"] = entry["decay_value"] - rate
		if entry["decay_value"] > 0:
			kept.append(entry)
		# decay_value <= 0：刪除，不放進 kept

	entries = kept


## 標記一筆記憶被檢索到，decay_value +10（上限 100，見《03》§4-2）。entry
## 要是 entries 陣列裡的同一個 Dictionary 參照（Godot Dictionary 是傳參照），
## 不是複製過的值，否則改了也回饋不到真正存著的那一筆
func mark_retrieved(entry: Dictionary) -> void:
	if not entries.has(entry):
		return
	entry["decay_value"] = minf(entry["decay_value"] + RETRIEVAL_BONUS, DECAY_MAX)


func get_by_level(level: int) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for entry in entries:
		if entry["level"] == level:
			result.append(entry)
	return result


## 一次掃描依 level 分桶回傳，取代呼叫端各自呼叫 get_by_level() 對同一份 entries
## 各自完整線性掃描一次（#215）。levels 沒出現在資料裡的桶，回傳空陣列而不是
## 缺 key，呼叫端不用防禦性判斷。get_by_level() 保留不動——L4 晉升邏輯跟
## debug_console.gd 的單一 level 查詢沒有重複掃描的問題，不需要跟著改
func get_by_levels(levels: Array[int]) -> Dictionary[int, Array]:
	var buckets: Dictionary[int, Array] = {}
	for level in levels:
		buckets[level] = [] as Array[Dictionary]

	for entry in entries:
		var level: int = entry["level"]
		if buckets.has(level):
			buckets[level].append(entry)

	return buckets


func _on_day_changed(_day: int) -> void:
	decay_all()


# ---- 存檔 ----

## 只存 L2／L4，見 note/技術/存檔.md「記憶怎麼存」：L1 每局可重建、不用存；
## L3（長期記憶庫）MVP 不做向量檢索，沒有檢索就沒有東西會再讀到它，存了也
## 用不上。跟 Relationships.get_save_data() 同一套規則——直接吐內部資料，
## 不另外包裝
func get_save_data() -> Dictionary:
	var saved: Array[Dictionary] = []
	for entry in entries:
		if entry["level"] == 2 or entry["level"] == 4:
			saved.append(entry.duplicate(true))
	return {"entries": saved}


## 呼叫端（Character.load_save_data()）永遠會呼叫這個函式，缺 memory 欄位時
## 傳空 Dictionary 進來——讀存檔要能把角色重設成「跟檔案內容一致」，不是
## 「保留呼叫前的狀態」，套到已經在場上跑過的角色（debug console `load`）才
## 不會讓存檔沒有的記憶繼續留著。l1 沒有存檔（每局可重建），同一個理由也要
## 清掉，否則場上角色的舊 L1 會在讀檔後跟新載入的 L2/L4 混在一起。
##
## entries 陣列本身或裡面任一筆不是預期形狀（不是 Array／不是 Dictionary／
## level 不是 2 或 4）時整筆跳過，不中途 push_error 中斷——存檔是外部檔案，
## 不假設它沒被手改過，但也不用像 Stats.SPEC 那樣逐欄位補值，因為這裡的欄位
## 全部由引擎自己的 add_candidate() 產生，不是模型輸出。驗證完才一次替換
## entries／_next_id，中途不動本體，避免格式錯誤只套用到一半
func load_save_data(data: Dictionary) -> void:
	l1.clear()

	var raw_entries: Variant = data.get("entries", [])
	var parsed: Array[Dictionary] = []
	var next_id := 0
	if raw_entries is Array:
		for raw_entry in raw_entries:
			if not (raw_entry is Dictionary):
				continue
			var entry: Dictionary = (raw_entry as Dictionary).duplicate(true)
			if entry.get("level") != 2 and entry.get("level") != 4:
				continue
			parsed.append(entry)
			next_id = maxi(next_id, int(entry.get("id", 0)))

	entries = parsed
	_next_id = next_id
