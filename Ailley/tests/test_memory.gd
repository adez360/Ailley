@tool
class_name TestMemory
extends McpTestSuite

## 驗證 Memory 的 L1-L4 純邏輯（issue #583）。不掛進場景樹（同 test_bury.gd
## 的寫法），`_ready()` 不會跑，不會連上 GameClock.day_changed。
##
## `add_candidate()` 本身直接讀 `GameClock.day` 蓋一個 `created_day` 欄位——
## 跟 test_corpse_decay.gd 踩過的「Invalid access to property」是同一種
## autoload 未實例化的問題，在 test_run 這個 @tool 環境下呼叫必炸，不在這個
## 套件的涵蓋範圍內（見 note/技術/自動化測試（McpTestSuite）.md）。本套件用
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
	memory.entries.append(_make_entry(2, "neutral", 1.0))

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


func test_get_save_data_keeps_only_l2_and_l4() -> void:
	var memory := track(Memory.new()) as Memory
	memory.entries.append(_make_entry(2))
	memory.entries.append(_make_entry(3))
	memory.entries.append(_make_entry(4))

	var saved := memory.get_save_data()

	assert_eq(saved["entries"].size(), 2, "只有 level 2／4 應被存檔，level 3 不存")


func test_load_save_data_restores_l2_and_l4_and_clears_l1() -> void:
	var memory := track(Memory.new()) as Memory
	memory.push_l1("舊的 L1，讀檔後應被清掉")
	var entry := _make_entry(2, "neutral", 80.0, 5)
	entry["id"] = 9

	memory.load_save_data({"entries": [entry]})

	assert_eq(memory.l1.size(), 0, "讀檔應清空 L1")
	assert_eq(memory.entries.size(), 1, "應還原這一筆記憶")
	assert_eq(memory._next_id, 9, "_next_id 應同步成存檔裡最大的 id")


func test_load_save_data_skips_malformed_entries() -> void:
	var memory := track(Memory.new()) as Memory
	var valid := _make_entry(2)
	var wrong_level := _make_entry(3)  # level 3 不合法，該被跳過

	memory.load_save_data({"entries": [valid, wrong_level, "not_a_dict"]})

	assert_eq(memory.entries.size(), 1, "level 不是 2/4 或格式錯誤的項目應被跳過")


func test_load_save_data_with_missing_entries_key_results_in_empty() -> void:
	var memory := track(Memory.new()) as Memory
	memory.entries.append(_make_entry(2))

	memory.load_save_data({})

	assert_eq(memory.entries.size(), 0, "缺 entries 欄位應視為空存檔，清空現有記憶")
