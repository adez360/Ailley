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
## L3 語意檢索（issue #571，《03》§7）：add_candidate() 產生一筆 level==3 的
## 候選記憶時，順手（call-and-forget，不 await）觸發 _embed_l3_entry() 把
## content 送去 EmbeddingService 算 embedding，回來後補寫回同一筆 entry
## （Dictionary 傳參照，補寫得到）。search_l3() 是唯一的檢索入口：查詢字串先
## 自己算一次 embedding，跟所有帶 embedding 的 L3 候選做 brute-force cosine
## 相似度，取分數最高的幾筆。規模很小（一隻角色的 L3 頂多幾十筆），用不上
## 向量資料庫或 ANN 索引，見 note/技術/LLM 串接與 AI 服務層.md。
## 記憶寫進存檔見下方「---- 存檔 ----」的 get_save_data()/load_save_data()。

## 分級門檻與規則，見《03》§2-4／《99》P-15（已定案）
const DISCARD_BELOW := 30
const L3_AT := 60
const L4_AT := 90
const L4_CAP := 5
const CONTENT_MAX_CHARS := 60
const BASE_DECAY_RATE := 3.0
const RETRIEVAL_BONUS := 10.0
const DECAY_MAX := 100.0
const L3_SEARCH_MAX_RESULTS := 5

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
		# 只有 L3 會被 search_l3() 檢索，才需要 embedding；L2/L4 這個欄位永遠是
		# 空的 PackedFloat32Array，統一形狀方便 get_save_data() 一視同仁處理
		"embedding": PackedFloat32Array(),
	}

	if level == 4:
		_demote_oldest_l4_if_full()

	entries.append(entry)

	if level == 3:
		# call-and-forget：add_candidate() 是同步函式，被很多呼叫端同步呼叫
		# （睡眠反思批次寫入等），改成 async 會讓簽名的變動一路擴散到所有呼叫端。
		# entry 是 Dictionary，Godot 裡傳參照，_embed_l3_entry() 事後補寫
		# entry["embedding"] 一樣能反映到 entries 陣列裡存的這一筆
		_embed_l3_entry(entry)

	return entry


## add_candidate() 產生一筆 L3 候選記憶後呼叫，不 await（見上方呼叫處說明）。
## EmbeddingService 逾時/連不上/未設定時回傳空陣列，這裡就讓 entry["embedding"]
## 維持初始的空 PackedFloat32Array——search_l3() 已經會跳過空 embedding 的候選，
## 不需要在這裡另外處理失敗
func _embed_l3_entry(entry: Dictionary) -> void:
	var embedding := await EmbeddingService.request_embedding(entry["content"])
	entry["embedding"] = embedding


## 《03》§7 唯一的檢索入口：L3 長期記憶庫做語意檢索，取分數最高的幾筆
## （預設上限 5，符合規格「每次取回 3~5 條」的上緣）。query_text 是查詢字串，
## 由呼叫端依《03》§7「地點＋在場角色＋current_goal」的觸發時機組好再傳進來
## （見 agent.gd 的四個觸發點）——這裡不管查詢字串怎麼組成，只負責拿它去比對。
##
## query embedding 算不出來（EmbeddingService 未設定/逾時/連不上）就直接回空
## 陣列，讓呼叫端走《03》§7 的兜底句「你想不起相關的事。」，不是把「查無結果」
## 跟「服務不可用」混在一起判斷
func search_l3(query_text: String, max_results: int = L3_SEARCH_MAX_RESULTS) -> Array[Dictionary]:
	if query_text.is_empty():
		return []

	var query_embedding := await EmbeddingService.request_embedding(query_text)
	if query_embedding.is_empty():
		return []

	return _rank_l3_candidates(query_embedding, max_results)


## search_l3() 拆出來的排序邏輯，本身是純同步函式、不碰網路——拆開是為了讓
## test_memory_l3.gd 能繞過 EmbeddingService 的真實 HTTP 呼叫：測試自己準備
## 一組手刻的 query_embedding 直接呼叫這裡驗證排序/top-N/mark_retrieved
## 行為，不需要真的連上 embedding server。search_l3() 本身只負責「先把查詢
## 字串換成向量」這一步 await，換到向量之後的邏輯全部在這裡
func _rank_l3_candidates(query_embedding: PackedFloat32Array, max_results: int) -> Array[Dictionary]:
	var scored: Array[Dictionary] = []
	for entry in get_by_level(3):
		var embedding: PackedFloat32Array = entry.get("embedding", PackedFloat32Array())
		if embedding.is_empty():
			continue
		scored.append({"entry": entry, "score": _cosine_similarity(query_embedding, embedding)})

	scored.sort_custom(func(a, b): return a["score"] > b["score"])

	var results: Array[Dictionary] = []
	for i in mini(max_results, scored.size()):
		var entry: Dictionary = scored[i]["entry"]
		# 《03》§4-2：語意檢索命中一樣要延長壽命，跟 PromptBuilder._memory_block()
		# 對 L2 命中的處理是同一條規則，不是 L2 專屬的
		mark_retrieved(entry)
		results.append(entry)
	return results


## dot(a,b) / (|a| * |b|)。任一邊長度為 0 或兩邊長度對不上（理論上不該發生——
## 同一個 embedding server／model 產生的向量應該永遠同一個維度——但存檔可能被
## 手改過，或設定檔中途換過 embedding model）一律回傳 0.0 分，不當除以零的
## 例外炸開
func _cosine_similarity(a: PackedFloat32Array, b: PackedFloat32Array) -> float:
	if a.size() == 0 or b.size() == 0 or a.size() != b.size():
		return 0.0

	var dot := 0.0
	var norm_a := 0.0
	var norm_b := 0.0
	for i in a.size():
		dot += a[i] * b[i]
		norm_a += a[i] * a[i]
		norm_b += b[i] * b[i]

	if norm_a == 0.0 or norm_b == 0.0:
		return 0.0

	return dot / (sqrt(norm_a) * sqrt(norm_b))


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

## 存 L2／L3／L4，見 note/技術/存檔.md「記憶怎麼存」：L1 每局可重建、不用存。
## L3 現在會被 search_l3() 檢索（issue #571），不再是「存了也用不上」，跟
## L2／L4 一樣要存。跟 Relationships.get_save_data() 同一套規則——直接吐內部
## 資料，不另外包裝；唯一的例外是 embedding 欄位：PackedFloat32Array 不是
## JSON.stringify() 認得的型別，存檔前轉成一般 Array（元素是 float），
## load_save_data() 讀回來時再轉回 PackedFloat32Array
func get_save_data() -> Dictionary:
	var saved: Array[Dictionary] = []
	for entry in entries:
		if entry["level"] == 2 or entry["level"] == 3 or entry["level"] == 4:
			var copy := entry.duplicate(true)
			if copy.has("embedding"):
				copy["embedding"] = Array(copy["embedding"])
			saved.append(copy)
	return {"entries": saved}


## 呼叫端（Character.load_save_data()）永遠會呼叫這個函式，缺 memory 欄位時
## 傳空 Dictionary 進來——讀存檔要能把角色重設成「跟檔案內容一致」，不是
## 「保留呼叫前的狀態」，套到已經在場上跑過的角色（debug console `load`）才
## 不會讓存檔沒有的記憶繼續留著。l1 沒有存檔（每局可重建），同一個理由也要
## 清掉，否則場上角色的舊 L1 會在讀檔後跟新載入的 L2/L4 混在一起。
##
## entries 陣列本身或裡面任一筆不是預期形狀（不是 Array／不是 Dictionary／
## level 不是 2、3 或 4）時整筆跳過，不中途 push_error 中斷——存檔是外部檔案，
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
			if entry.get("level") != 2 and entry.get("level") != 3 and entry.get("level") != 4:
				continue
			# embedding 存檔時是 JSON 陣列（float 元素），讀回來要轉成
			# PackedFloat32Array 才能參與 _cosine_similarity()。型別不是 Array，
			# 或裡面有非數字元素，就只丟掉這個欄位（回退成空陣列），不整筆
			# entry 一起丟——content/importance/valence 等其餘欄位依然有效，
			# 只是這一筆不會再被 search_l3() 選中
			var raw_embedding: Variant = entry.get("embedding")
			var floats := PackedFloat32Array()
			if raw_embedding is Array:
				var valid := true
				for v in (raw_embedding as Array):
					if not (v is float or v is int):
						valid = false
						break
					floats.append(float(v))
				if not valid:
					floats = PackedFloat32Array()
			entry["embedding"] = floats
			parsed.append(entry)
			next_id = maxi(next_id, int(entry.get("id", 0)))

	entries = parsed
	_next_id = next_id
