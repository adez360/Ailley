@tool
class_name TestMemoryL3
extends McpTestSuite

## 驗證 L3 語意檢索的純邏輯（issue #571，《03》§7）：cosine 相似度計算，
## 以及 Memory._rank_l3_candidates() 的排序/top-N/mark_retrieved 行為。
##
## 刻意不呼叫 Memory.search_l3() 本身——那個函式第一步就是 await
## EmbeddingService.request_embedding()，會真的打一次 HTTP 請求，這個環境連
## 不到真的 embedding server（見 issue 交辦說明）。_rank_l3_candidates() 是
## search_l3() 拆出來的純同步排序邏輯，測試直接餵一組手刻的 query_embedding
## 進去，繞過網路那一段。
##
## 同一個理由，這裡也不透過 add_candidate() 產生 L3 記憶（那會觸發
## _embed_l3_entry() 的 call-and-forget 網路請求）——直接手刻 entries 陣列，
## 跟 test_give_attack_on_player.gd 的離場景樹寫法一致：Memory.new() 不
## add_child()，不會觸發 _ready()（那裡面會連 GameClock.day_changed，不需要
## 這個測試碰）。

func suite_name() -> String:
	return "memory_l3"


func _make_memory() -> Memory:
	var memory := Memory.new() as Memory
	track(memory)
	return memory


## 手刻一筆 L3 候選記憶，跳過 add_candidate()（見上方說明），直接塞進
## entries——形狀對齊 add_candidate() 產生的欄位，才不會讓 mark_retrieved()／
## get_by_level() 這些既有函式讀到缺欄位
func _make_l3_entry(memory: Memory, id: int, content: String, embedding: PackedFloat32Array) -> Dictionary:
	var entry := {
		"id": id,
		"level": 3,
		"content": content,
		"valence": "neutral",
		"importance": 70,
		"related_npcs": [] as Array[String],
		"location_id": "",
		"decay_value": 100,
		"created_day": 1,
		"embedding": embedding,
	}
	memory.entries.append(entry)
	return entry


# ---- _cosine_similarity() ----

func test_cosine_similarity_identical_vectors_is_one() -> void:
	var memory := _make_memory()
	var v := PackedFloat32Array([1.0, 2.0, 3.0])
	var score: float = memory._cosine_similarity(v, v)
	assert_true(is_equal_approx(score, 1.0), "同一個向量跟自己比對應該是 1.0，實際 %s" % score)


func test_cosine_similarity_orthogonal_vectors_is_zero() -> void:
	var memory := _make_memory()
	var a := PackedFloat32Array([1.0, 0.0])
	var b := PackedFloat32Array([0.0, 1.0])
	var score: float = memory._cosine_similarity(a, b)
	assert_true(is_equal_approx(score, 0.0), "正交向量應該是 0.0，實際 %s" % score)


func test_cosine_similarity_opposite_vectors_is_negative_one() -> void:
	var memory := _make_memory()
	var a := PackedFloat32Array([1.0, 2.0])
	var b := PackedFloat32Array([-1.0, -2.0])
	var score: float = memory._cosine_similarity(a, b)
	assert_true(is_equal_approx(score, -1.0), "完全反向的向量應該是 -1.0，實際 %s" % score)


func test_cosine_similarity_mismatched_length_returns_zero() -> void:
	var memory := _make_memory()
	var a := PackedFloat32Array([1.0, 2.0, 3.0])
	var b := PackedFloat32Array([1.0, 2.0])
	assert_eq(memory._cosine_similarity(a, b), 0.0, "長度不同應回傳 0.0，不應該當掉或算錯")


func test_cosine_similarity_empty_vector_returns_zero() -> void:
	var memory := _make_memory()
	var a := PackedFloat32Array()
	var b := PackedFloat32Array([1.0, 2.0])
	assert_eq(memory._cosine_similarity(a, b), 0.0, "空向量應回傳 0.0")


func test_cosine_similarity_zero_vector_returns_zero() -> void:
	var memory := _make_memory()
	var a := PackedFloat32Array([0.0, 0.0, 0.0])
	var b := PackedFloat32Array([1.0, 2.0, 3.0])
	assert_eq(memory._cosine_similarity(a, b), 0.0, "零向量的 norm 是 0，應回傳 0.0 而不是除以零炸開")


# ---- _rank_l3_candidates() ----

func test_rank_l3_candidates_orders_by_similarity_descending() -> void:
	var memory := _make_memory()
	# query 是 (1,0)；entry_far 跟 query 正交（分數 0），entry_close 完全同向（分數 1）
	_make_l3_entry(memory, 1, "跟查詢無關的記憶", PackedFloat32Array([0.0, 1.0]))
	_make_l3_entry(memory, 2, "跟查詢很相關的記憶", PackedFloat32Array([1.0, 0.0]))

	var results := memory._rank_l3_candidates(PackedFloat32Array([1.0, 0.0]), 5)

	assert_eq(results.size(), 2, "兩筆都有 embedding，應該都回傳")
	assert_eq(results[0]["id"], 2, "分數較高（同向）的那筆應該排第一")
	assert_eq(results[1]["id"], 1, "分數較低（正交）的那筆應該排第二")


## 相關度下限（WU-YI-RU review）：語意相反（cosine < 0）的候選不該被當命中
func test_rank_l3_candidates_excludes_negative_similarity() -> void:
	var memory := _make_memory()
	# query 是 (1,0)；entry_opposite 完全反向（分數 -1），entry_close 完全同向（分數 1）
	_make_l3_entry(memory, 1, "語意相反的記憶", PackedFloat32Array([-1.0, 0.0]))
	_make_l3_entry(memory, 2, "跟查詢很相關的記憶", PackedFloat32Array([1.0, 0.0]))

	var results := memory._rank_l3_candidates(PackedFloat32Array([1.0, 0.0]), 5)

	assert_eq(results.size(), 1, "語意相反那筆應該被排除，只剩同向那筆")
	assert_eq(results[0]["id"], 2, "剩下的應該是同向、分數為正的那筆")


func test_rank_l3_candidates_respects_max_results() -> void:
	var memory := _make_memory()
	for i in 5:
		_make_l3_entry(memory, i, "記憶 %d" % i, PackedFloat32Array([1.0, 0.0]))

	var results := memory._rank_l3_candidates(PackedFloat32Array([1.0, 0.0]), 3)

	assert_eq(results.size(), 3, "max_results=3 時最多只能回 3 筆，即使有 5 筆候選")


func test_rank_l3_candidates_skips_entries_without_embedding() -> void:
	var memory := _make_memory()
	_make_l3_entry(memory, 1, "沒有 embedding 的記憶", PackedFloat32Array())
	_make_l3_entry(memory, 2, "有 embedding 的記憶", PackedFloat32Array([1.0, 0.0]))

	var results := memory._rank_l3_candidates(PackedFloat32Array([1.0, 0.0]), 5)

	assert_eq(results.size(), 1, "沒有 embedding 的候選（例如 EmbeddingService 逾時／未設定）應該被排除")
	assert_eq(results[0]["id"], 2, "剩下的應該是有 embedding 的那一筆")


func test_rank_l3_candidates_ignores_non_level_3_entries() -> void:
	var memory := _make_memory()
	_make_l3_entry(memory, 1, "L3 記憶", PackedFloat32Array([1.0, 0.0]))
	var l2_entry := {
		"id": 2, "level": 2, "content": "L2 記憶", "valence": "neutral",
		"importance": 40, "related_npcs": [] as Array[String], "location_id": "",
		"decay_value": 100, "created_day": 1, "embedding": PackedFloat32Array([1.0, 0.0]),
	}
	memory.entries.append(l2_entry)

	var results := memory._rank_l3_candidates(PackedFloat32Array([1.0, 0.0]), 5)

	assert_eq(results.size(), 1, "只有 L3 才是語意檢索的範圍，L2 即使有 embedding 也不該被選中")
	assert_eq(results[0]["id"], 1)


func test_rank_l3_candidates_marks_hits_as_retrieved() -> void:
	var memory := _make_memory()
	var entry := _make_l3_entry(memory, 1, "被檢索到的記憶", PackedFloat32Array([1.0, 0.0]))
	entry["decay_value"] = 50

	memory._rank_l3_candidates(PackedFloat32Array([1.0, 0.0]), 5)

	assert_eq(entry["decay_value"], 60, "《03》§4-2：命中應該 decay_value +10")


func test_rank_l3_candidates_mark_retrieved_caps_at_decay_max() -> void:
	var memory := _make_memory()
	var entry := _make_l3_entry(memory, 1, "已經接近上限的記憶", PackedFloat32Array([1.0, 0.0]))
	entry["decay_value"] = 95

	memory._rank_l3_candidates(PackedFloat32Array([1.0, 0.0]), 5)

	assert_eq(entry["decay_value"], Memory.DECAY_MAX, "decay_value 不該超過上限 100")


func test_rank_l3_candidates_empty_when_no_l3_entries() -> void:
	var memory := _make_memory()
	var results := memory._rank_l3_candidates(PackedFloat32Array([1.0, 0.0]), 5)
	assert_eq(results.size(), 0, "沒有任何 L3 候選時應該回傳空陣列")


# ---- get_save_data() / load_save_data() 的 embedding 序列化 ----

func test_save_and_load_round_trips_embedding() -> void:
	var memory := _make_memory()
	_make_l3_entry(memory, 1, "帶 embedding 的記憶", PackedFloat32Array([0.5, -1.5, 2.0]))

	var saved := memory.get_save_data()
	assert_true(saved["entries"][0]["embedding"] is Array, "存檔時 embedding 應該轉成一般 Array，JSON.stringify() 才認得")

	var loaded := Memory.new() as Memory
	track(loaded)
	loaded.load_save_data(saved)

	var loaded_entry := loaded.get_by_level(3)[0]
	var loaded_embedding: PackedFloat32Array = loaded_entry["embedding"]
	assert_eq(loaded_embedding.size(), 3, "讀檔後 embedding 應還原成 3 維")
	assert_true(is_equal_approx(loaded_embedding[0], 0.5), "讀檔後的向量內容應該跟存檔前一致")
	assert_true(is_equal_approx(loaded_embedding[1], -1.5))
	assert_true(is_equal_approx(loaded_embedding[2], 2.0))


## 直接測 _parse_stored_embedding()，不透過完整的 load_save_data()——後者
## 現在對「解析完是空陣列」的 L3 entry 會連帶觸發 _embed_l3_entry() 重新
## 排隊算 embedding，那段會打 EmbeddingService，這個專案的 MCP 編輯器內
## test_run 環境對 autoload 只有 placeholder，一測就崩潰（見檔頭環境限制
## 說明）。這裡要測的是純解析邏輯本身，跟會不會觸發重新排隊是兩件事
func test_load_save_data_tolerates_malformed_embedding() -> void:
	var embedding := Memory._parse_stored_embedding(["not", "a", "number"])
	assert_eq(embedding.size(), 0, "格式不對的 embedding 應該退回空陣列，而不是半吊子資料")
