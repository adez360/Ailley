@tool
class_name TestRelationships
extends McpTestSuite

## 驗證 Relationships 的 last_seen 欄位（issue #497）不依賴 GameClock 的那部分。
##
## note_meeting() 本身會讀 GameClock.day 寫入 last_seen，跟 memory.gd 的
## add_candidate() 讀 GameClock.day 蓋 created_day 是同一種問題——test_run
## 這個 @tool 環境沒有活的 GameClock，呼叫會炸。這裡改成直接操作
## records 內部狀態驗證 get_last_seen()／load_save_data() 的邏輯，note_meeting()
## 寫入 last_seen 這件事本身、以及 prompt_builder.gd::_last_seen_sentence()
## 留給 project_run + game_eval 驗證。

func suite_name() -> String:
	return "relationships"


func test_get_last_seen_defaults_to_never() -> void:
	var relationships := track(Relationships.new()) as Relationships

	assert_eq(relationships.get_last_seen("stranger"), -1, "沒有紀錄時應回 -1（從沒見過）")


func test_get_last_seen_reads_existing_record() -> void:
	var relationships := track(Relationships.new()) as Relationships
	relationships.records["aji"] = {"trust": 20.0, "met_count": 1, "appearance_cache": "", "last_seen": 5}

	assert_eq(relationships.get_last_seen("aji"), 5, "應回傳紀錄裡存的 last_seen")


func test_load_save_data_restores_last_seen() -> void:
	var relationships := track(Relationships.new()) as Relationships

	relationships.load_save_data({
		"aji": {"trust": 30.0, "met_count": 2, "appearance_cache": "", "last_seen": 12},
	})

	assert_eq(relationships.get_last_seen("aji"), 12, "應還原存檔裡的 last_seen")


func test_load_save_data_missing_last_seen_defaults_to_never() -> void:
	var relationships := track(Relationships.new()) as Relationships

	# 舊存檔沒有 last_seen 欄位（issue #497 之前存的）
	relationships.load_save_data({
		"aji": {"trust": 30.0, "met_count": 2, "appearance_cache": ""},
	})

	assert_eq(relationships.get_last_seen("aji"), -1, "缺席應視為從沒見過，不是 0 或其他預設值")


func test_load_save_data_invalid_last_seen_type_defaults_to_never() -> void:
	var relationships := track(Relationships.new()) as Relationships

	relationships.load_save_data({
		"aji": {"trust": 30.0, "met_count": 2, "appearance_cache": "", "last_seen": "bad"},
	})

	assert_eq(relationships.get_last_seen("aji"), -1, "型別不對應沿用預設值 -1，不當機")


func test_load_save_data_negative_last_seen_clamped_to_never() -> void:
	var relationships := track(Relationships.new()) as Relationships

	relationships.load_save_data({
		"aji": {"trust": 30.0, "met_count": 2, "appearance_cache": "", "last_seen": -99},
	})

	assert_eq(relationships.get_last_seen("aji"), -1, "手改存檔塞進更小的負數應夾在 -1")
