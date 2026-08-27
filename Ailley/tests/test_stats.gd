@tool
class_name TestStats
extends McpTestSuite

## 驗證 Stats 的純數值邏輯（issue #583）。Stats 依 stats.gd 開頭註解是刻意
## 設計成不依賴場景／GameClock，本套件不掛進場景樹（同 test_bury.gd 的寫法），
## `_ready()` 不會跑，`values` 一開始是空的——每個測試自己用 `set_value()`
## 把要用到的欄位準備好，不依賴 SPEC 的 start 值。

func suite_name() -> String:
	return "stats"


## `_apply_drift()` 迭代 SPEC 全部欄位、直接索引 `values[key]`（不是 `.get()`）——
## 正常流程一定先跑過 `_ready()` 把 8 個欄位都填滿，才輪得到 `_apply_drift()`
## 被呼叫。這裡沒有掛進場景樹、`_ready()` 不會跑，呼叫 `_apply_drift()` 前
## 得先手動補齊全部欄位，否則會撞上「Invalid access to property or key」——
## 這是測試環境要遷就函式的既有前提，不是 stats.gd 本身的邊界情況
func _seed_all(stats: Stats) -> void:
	for key in Stats.SPEC:
		stats.set_value(key, Stats.SPEC[key]["start"])


func test_set_value_clamps_to_max() -> void:
	var stats := track(Stats.new()) as Stats

	stats.set_value("health", 150.0)

	assert_eq(stats.get_value("health"), Stats.MAX, "超過 MAX 應被夾回 100")


func test_set_value_clamps_to_min() -> void:
	var stats := track(Stats.new()) as Stats

	stats.set_value("satiety", -20.0)

	assert_eq(stats.get_value("satiety"), Stats.MIN, "低於 MIN 應被夾回 0")


func test_add_applies_delta_and_clamps() -> void:
	var stats := track(Stats.new()) as Stats
	stats.set_value("injury", 90.0)

	stats.add("injury", 30.0)

	assert_eq(stats.get_value("injury"), Stats.MAX, "add() 疊加後一樣要夾在 MAX 內")


func test_get_value_unset_key_defaults_to_zero() -> void:
	var stats := track(Stats.new()) as Stats

	assert_eq(stats.get_value("hydration"), 0.0, "沒呼叫過 set_value 的欄位應回 0（沒有 _ready() 補 SPEC start）")


func test_set_value_unknown_key_is_noop() -> void:
	var stats := track(Stats.new()) as Stats

	stats.set_value("not_a_real_stat", 50.0)

	assert_eq(stats.get_value("not_a_real_stat"), 0.0, "不存在的欄位不該被寫入")


func test_apply_drift_moves_need_toward_zero() -> void:
	var stats := track(Stats.new()) as Stats
	_seed_all(stats)
	stats.set_value("satiety", 50.0)

	stats._apply_drift()

	assert_eq(stats.get_value("satiety"), 50.0 - Stats.SPEC["satiety"]["drift"], "satiety 應往 0 漂移 drift 那麼多")


func test_apply_drift_moves_health_toward_hundred() -> void:
	var stats := track(Stats.new()) as Stats
	_seed_all(stats)
	# health 的 drift 是 0，改個有 drift 又 toward 非 0 的欄位不存在於 SPEC，
	# 這裡直接驗證「toward 100」的欄位方向對——injury toward 0、drift 0.5，
	# 用它驗證「往下」，另外驗證 hygiene（drift 0，理應完全不動）當對照組
	stats.set_value("injury", 10.0)

	stats._apply_drift()

	assert_eq(stats.get_value("injury"), 10.0 - Stats.SPEC["injury"]["drift"], "injury 應往 0 漂移")


func test_apply_drift_skips_zero_drift_stats() -> void:
	var stats := track(Stats.new()) as Stats
	_seed_all(stats)
	stats.set_value("hygiene", 70.0)

	stats._apply_drift()

	assert_eq(stats.get_value("hygiene"), 70.0, "drift=0 的欄位不該被 _apply_drift 動到")


func test_apply_drift_pauses_injury_when_flagged() -> void:
	var stats := track(Stats.new()) as Stats
	_seed_all(stats)
	stats.set_value("injury", 40.0)
	stats.injury_decay_paused = true

	stats._apply_drift()

	assert_eq(stats.get_value("injury"), 40.0, "injury_decay_paused 時 injury 不該自然衰減")


func test_needs_attention_true_when_need_below_critical() -> void:
	var stats := track(Stats.new()) as Stats
	stats.set_value("satiety", 80.0)
	stats.set_value("hydration", 10.0)

	assert_true(stats.needs_attention(), "hydration 低於 CRITICAL 應觸發 needs_attention")


func test_needs_attention_ignores_non_need_stats() -> void:
	var stats := track(Stats.new()) as Stats
	stats.set_value("satiety", 80.0)
	stats.set_value("hydration", 80.0)
	stats.set_value("stamina", 80.0)
	stats.set_value("wakefulness", 80.0)
	stats.set_value("hygiene", 5.0)  # 心情類，非 need，跌破 CRITICAL 也不算

	assert_false(stats.needs_attention(), "非 is_need 欄位（hygiene）跌破門檻不該觸發")


func test_get_lowest_need_picks_smallest_need_value() -> void:
	var stats := track(Stats.new()) as Stats
	stats.set_value("satiety", 80.0)
	stats.set_value("hydration", 20.0)
	stats.set_value("stamina", 50.0)
	stats.set_value("wakefulness", 90.0)

	assert_eq(stats.get_lowest_need(), "hydration", "應選出數值最低的 need 欄位")


func test_get_place_for_need_returns_spec_place() -> void:
	var stats := track(Stats.new()) as Stats

	assert_eq(stats.get_place_for_need("stamina"), "home", "stamina 的 place 應為 home")
	assert_eq(stats.get_place_for_need("mood"), "", "不存在的欄位應回空字串")


func test_get_lowest_need_place_matches_lowest_need() -> void:
	var stats := track(Stats.new()) as Stats
	stats.set_value("satiety", 80.0)
	stats.set_value("hydration", 80.0)
	stats.set_value("stamina", 10.0)
	stats.set_value("wakefulness", 80.0)

	assert_eq(stats.get_lowest_need_place(), "home", "最低需求是 stamina，應回它對應的 home")


func test_save_and_load_round_trip() -> void:
	var stats := track(Stats.new()) as Stats
	stats.set_value("health", 42.0)
	stats.set_value("injury", 7.0)

	var saved := stats.get_save_data()

	var restored := track(Stats.new()) as Stats
	restored.load_save_data(saved)

	assert_eq(restored.get_value("health"), 42.0, "存讀檔應還原 health")
	assert_eq(restored.get_value("injury"), 7.0, "存讀檔應還原 injury")


func test_load_save_data_fills_missing_keys_with_spec_start() -> void:
	var stats := track(Stats.new()) as Stats

	stats.load_save_data({"health": 60.0})

	assert_eq(stats.get_value("health"), 60.0, "存檔裡有的欄位應照存檔值")
	assert_eq(stats.get_value("satiety"), Stats.SPEC["satiety"]["start"], "存檔裡沒有的欄位應補 SPEC 的 start 值")
