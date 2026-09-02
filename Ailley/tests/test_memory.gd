@tool
class_name TestMemory
extends McpTestSuite

## 驗證 Memory 的 L1-L4 純邏輯（issue #583）。不掛進場景樹（同 test_bury.gd
## 的寫法），`_ready()` 不會跑，不會連上 GameClock.day_changed。
##
## `add_candidate()` 本身直接讀 `GameClock.day` 蓋一個 `created_day` 欄位——
## 跟 test_corpse_decay.gd 踩過的「Invalid access to property」是同一種
## autoload 未實例化的問題，在 test_run 這個 @tool 環境下呼叫必炸，不在這個
## 套件的涵蓋範圍內（見 note/技術/自動化測試.md）。本套件用
## `_make_entry()` 手動組出跟 add_candidate() 產生的形狀一致的 entry，繞過
## GameClock 依賴，直接測 entries 陣列上的其餘邏輯（decay/檢索/分級/存讀檔）。

func suite_name() -> String:
	return "memory"


func _make_entry(level: int, valence: String = "neutral", decay_value: float = 100.0, created_day: int = 0) -> Dictionary:
	return {
		"id": 0,
		"level": level,
		"content": "test",
		"valence": valence,
		"importance": 0,
		"related_npcs": [] as Array[String],
		"location_id": "",
		"decay_value": decay_value,
		"created_day": created_day,
	}


func test_push_l1_appends() -> void:
	var memory := track(Memory.new()) as Memory

	memory.push_l1("說了一句話")

	assert_eq(memory.l1.size(), 1, "應有一筆 L1")
	assert_eq(memory.l1[0]["content"], "說了一句話", "內容應原樣存入")


func test_push_l1_evicts_oldest_when_over_cap() -> void:
	var memory := track(Memory.new()) as Memory

	for i in range(Memory.L1_CAP + 3):
		memory.push_l1("event_%d" % i)

	assert_eq(memory.l1.size(), Memory.L1_CAP, "超過 L1_CAP 應維持在上限")
	assert_eq(memory.l1[0]["content"], "event_3", "應擠掉最舊的幾筆，留下最新的 L1_CAP 筆")


func test_decay_all_reduces_neutral_at_base_rate() -> void:
	var memory := track(Memory.new()) as Memory
	memory.entries.append(_make_entry(2, "neutral", 50.0))

	memory.decay_all()

	assert_eq(memory.entries[0]["decay_value"], 50.0 - Memory.BASE_DECAY_RATE, "中性記憶應以基礎衰減率下降")


func test_decay_all_reduces_negative_faster_with_low_grudge() -> void:
	var memory := track(Memory.new()) as Memory
	memory.entries.append(_make_entry(2, "negative", 50.0))

	memory.decay_all(0.0)  # grudge=0：負面記憶衰減率變 BASE_DECAY_RATE * 2

	assert_eq(memory.entries[0]["decay_value"], 50.0 - Memory.BASE_DECAY_RATE * 2.0, "grudge 越低，負面記憶衰減越快")


func test_decay_all_removes_entry_at_or_below_zero() -> void:
	var memory := track(Memory.new()) as Memory
	# 起始值抓成剛好衰減到 0.0（BASE_DECAY_RATE 本身），釘住「>0 才留、
	# 等於 0 也要移除」這條邊界；起始值抓遠大於衰減率只驗證得到「衰減夠多
	# 會被移除」，抓不到 kept 判斷式若從 `> 0` 鬆成 `>= 0` 的邊界迴歸
	memory.entries.append(_make_entry(2, "neutral", Memory.BASE_DECAY_RATE))

	memory.decay_all()

	assert_eq(memory.entries.size(), 0, "decay_value 歸零以下應被移除")


func test_decay_all_never_decays_l4() -> void:
	var memory := track(Memory.new()) as Memory
	memory.entries.append(_make_entry(4, "negative", 50.0))

	memory.decay_all(0.0)

	assert_eq(memory.entries[0]["decay_value"], 50.0, "L4 核心記憶不衰減")


func test_mark_retrieved_adds_bonus_capped_at_max() -> void:
	var memory := track(Memory.new()) as Memory
	var entry := _make_entry(2, "neutral", 95.0)
	memory.entries.append(entry)

	memory.mark_retrieved(entry)

	assert_eq(entry["decay_value"], Memory.DECAY_MAX, "檢索加成不該超過上限 100")


func test_mark_retrieved_adds_exact_bonus_when_not_capped() -> void:
	var memory := track(Memory.new()) as Memory
	var entry := _make_entry(2, "neutral", 50.0)
	memory.entries.append(entry)

	memory.mark_retrieved(entry)

	assert_eq(entry["decay_value"], 50.0 + Memory.RETRIEVAL_BONUS, "未封頂時應精確加上 RETRIEVAL_BONUS，不是隨便一個增量")


func test_mark_retrieved_ignores_entry_not_in_entries() -> void:
	var memory := track(Memory.new()) as Memory
	var foreign_entry := _make_entry(2, "neutral", 50.0)

	memory.mark_retrieved(foreign_entry)

	assert_eq(foreign_entry["decay_value"], 50.0, "不在 entries 裡的 entry 不該被更動")


func test_get_by_level_filters_correctly() -> void:
	var memory := track(Memory.new()) as Memory
	memory.entries.append(_make_entry(2))
	memory.entries.append(_make_entry(3))
	memory.entries.append(_make_entry(4))

	var l3_entries := memory.get_by_level(3)

	assert_eq(l3_entries.size(), 1, "應只回傳 level 3 的那一筆")
	assert_eq(l3_entries[0]["level"], 3, "回傳的那一筆本身也該是 level 3，不是巧合湊出同樣的筆數")


func test_get_by_levels_buckets_by_level() -> void:
	var memory := track(Memory.new()) as Memory
	memory.entries.append(_make_entry(2))
	memory.entries.append(_make_entry(2))
	memory.entries.append(_make_entry(4))

	var buckets := memory.get_by_levels([2, 3, 4])

	assert_eq(buckets[2].size(), 2, "level 2 桶應有 2 筆")
	assert_eq(buckets[3].size(), 0, "level 3 沒資料應回空陣列而不是缺 key")
	assert_eq(buckets[4].size(), 1, "level 4 桶應有 1 筆")


func test_demote_oldest_l4_if_full_demotes_oldest_to_l3() -> void:
	var memory := track(Memory.new()) as Memory
	for day in range(Memory.L4_CAP):
		memory.entries.append(_make_entry(4, "neutral", 100.0, day))

	memory._demote_oldest_l4_if_full()

	var l4_entries := memory.get_by_level(4)
	var l3_entries := memory.get_by_level(3)
	assert_eq(l4_entries.size(), Memory.L4_CAP - 1, "應降級一筆，L4 剩 L4_CAP - 1 筆")
	assert_eq(l3_entries.size(), 1, "被降級的那一筆應變成 level 3")
	assert_eq(l3_entries[0]["created_day"], 0, "應降級 created_day 最小（最舊）的那一筆")


func test_demote_oldest_l4_if_full_noop_when_not_full() -> void:
	var memory := track(Memory.new()) as Memory
	memory.entries.append(_make_entry(4, "neutral", 100.0, 0))

	memory._demote_oldest_l4_if_full()

	assert_eq(memory.get_by_level(4).size(), 1, "未滿額時不該降級任何一筆")


## L3 現在會被 search_l3() 檢索（issue #571），跟 L2／L4 一樣要存——不是
##「level 2／4 才存，3 不存」，那是 L3 語意檢索接上之前的舊行為。這裡改成
## 驗證「合法的三種 level 都存、非法 level 會被排除」，後者用直接塞進
## memory.entries 的方式模擬（正常只會透過 add_candidate() 產生，不會出現
## 非法 level，這裡純粹測 get_save_data() 自己的防禦性過濾）
func test_get_save_data_keeps_only_valid_levels() -> void:
	var memory := track(Memory.new()) as Memory
	memory.entries.append(_make_entry(2))
	memory.entries.append(_make_entry(3))
	memory.entries.append(_make_entry(4))
	var bogus := _make_entry(2)
	bogus["level"] = 99
	memory.entries.append(bogus)

	var saved := memory.get_save_data()

	assert_eq(saved["entries"].size(), 3, "level 2／3／4 都應被存檔，非法 level 應被排除")
	var saved_levels: Array[int] = []
	for saved_entry in saved["entries"]:
		saved_levels.append(saved_entry["level"])
	assert_true(saved_levels.has(2) and saved_levels.has(3) and saved_levels.has(4), "存檔應保留 level 2、3、4 這三種合法等級")


func test_load_save_data_restores_l2_and_l4_and_clears_l1() -> void:
	var memory := track(Memory.new()) as Memory
	memory.push_l1("舊的 L1，讀檔後應被清掉")
	var entry := _make_entry(2, "neutral", 80.0, 5)
	entry["id"] = 9
	var l4_entry := _make_entry(4, "neutral", 90.0, 6)
	l4_entry["id"] = 10

	memory.load_save_data({"entries": [entry, l4_entry]})

	assert_eq(memory.l1.size(), 0, "讀檔應清空 L1")
	assert_eq(memory.get_by_level(2).size(), 1, "應還原 level 2 記憶")
	assert_eq(memory.get_by_level(4).size(), 1, "應還原 level 4 記憶")
	assert_eq(memory._next_id, 10, "_next_id 應同步成存檔裡最大的 id")


func test_load_save_data_skips_wrong_level_and_non_dict_entries() -> void:
	var memory := track(Memory.new()) as Memory
	var valid := _make_entry(2)
	valid["id"] = 1
	var wrong_level := _make_entry(99)  # 不是 2/3/4，該被跳過

	memory.load_save_data({"entries": [valid, wrong_level, "not_a_dict"]})

	assert_eq(memory.entries.size(), 1, "level 不是 2/3/4 或不是 Dictionary 的項目應被跳過")
	assert_eq(memory.entries[0]["id"], 1, "留下的應是那筆合法的 level 2 記憶，不是跳過後恰好剩一筆")


## issue #664：load_save_data() 原本只驗 level，不驗 content／valence／
## decay_value／created_day 是否存在——缺欄位但 level 合法的 entry（例如手改
## 過或版本升級留下的 {"level": 2}）會被原樣收進 entries，讀檔當下不報錯，
## 要等到下一次 decay_all()／_demote_oldest_l4_if_full()／get_life_highlights()
## 這些直接方括號索引讀欄位的地方才噴 Invalid access。這裡驗證這四個欄位
## 缺任何一個都會讓整筆在讀檔當下就被跳過，不會留到之後才炸
func test_load_save_data_skips_entries_missing_required_fields() -> void:
	var memory := track(Memory.new()) as Memory
	var valid := _make_entry(2)
	valid["id"] = 1
	var missing_valence := _make_entry(2)
	missing_valence["id"] = 2
	missing_valence.erase("valence")
	var missing_decay := _make_entry(2)
	missing_decay["id"] = 3
	missing_decay.erase("decay_value")
	var missing_content := _make_entry(2)
	missing_content["id"] = 4
	missing_content.erase("content")
	var missing_created_day := _make_entry(2)
	missing_created_day["id"] = 5
	missing_created_day.erase("created_day")

	memory.load_save_data({
		"entries": [valid, missing_valence, missing_decay, missing_content, missing_created_day],
	})

	assert_eq(memory.entries.size(), 1, "缺 valence／decay_value／content／created_day 任一欄位的 entry 都應被跳過")
	assert_eq(memory.entries[0]["id"], 1, "留下的應是那筆欄位齊全的合法記憶")


## decay_value／created_day 存檔後經 JSON 讀回來是 float，不是原本寫入時的
## int（同一個病根見 issue #857／#861）——這裡確保這個型別轉換不會被
## _has_required_fields() 誤判成「缺欄位」而整筆跳過
func test_load_save_data_accepts_float_decay_value_and_created_day() -> void:
	var memory := track(Memory.new()) as Memory
	var entry := _make_entry(2)
	entry["id"] = 1
	entry["decay_value"] = 97.5
	entry["created_day"] = 3.0

	memory.load_save_data({"entries": [entry]})

	assert_eq(memory.entries.size(), 1, "decay_value／created_day 是 float 時不該被當成缺欄位跳過")


func test_load_save_data_with_missing_entries_key_results_in_empty() -> void:
	var memory := track(Memory.new()) as Memory
	memory.entries.append(_make_entry(2))

	memory.load_save_data({})

	assert_eq(memory.entries.size(), 0, "缺 entries 欄位應視為空存檔，清空現有記憶")


## issue #953：get_life_highlights()（#384）原本沒有呼叫端把結果寫進墓碑欄位，
## Agent._capture_life_highlights() 是死亡流程（_die() 死亡當下）新接上的掛點。
## 直接測掛點本身，繞過 _die() 對 GameClock 的依賴（見套件頂端說明）；
## _die() 的接線（character.gd）由 project_run＋game_eval 冒煙驗證
## （test_run 的 GameClock 限制，同 test_revive.gd）。
func test_capture_life_highlights_populates_field_from_l4() -> void:
	var agent := track(Agent.new()) as Agent
	agent.memory = track(Memory.new()) as Memory
	agent.memory.entries.append(_make_entry(4, "neutral", 100.0, 41))
	agent.memory.entries.append(_make_entry(4, "neutral", 100.0, 12))

	agent._capture_life_highlights()

	assert_eq(agent.life_highlights.size(), 2, "兩筆 L4 核心記憶應各彙整成一行生平")
	assert_true(agent.life_highlights[0].begins_with("第 12 天"), "應依 created_day 由舊到新排序")


func test_capture_life_highlights_without_memory_is_noop() -> void:
	var agent := track(Agent.new()) as Agent
	agent.memory = null

	agent._capture_life_highlights()

	assert_eq(agent.life_highlights.size(), 0, "沒有 memory 時應安全略過，不噴錯")
