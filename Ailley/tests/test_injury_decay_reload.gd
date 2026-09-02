@tool
class_name TestInjuryDecayReload
extends McpTestSuite

## 驗證 issue #923：讀檔（Continue Game）套用 stats 存檔資料後，injury_decay_paused
## 沒有跟著立即同步，要等下一次 _update_conditions() 的 tick 邊界（最長約 10 遊戲
## 分鐘空窗期）才會補上，這段空窗期 injury 會被 Stats 的自然衰減悄悄漂走。
## 修法比照 attack() 命中瞬間的立即同步（見 test_give_attack_on_player.gd），
## 在 Character.load_save_data() 套用完 stats 資料後立刻重算 bleeding／
## injury_decay_paused，不等 tick。

func suite_name() -> String:
	return "injury_decay_reload"


## 不掛進場景樹（跟 test_give_attack_on_player.gd 同一種輕量寫法）——
## load_save_data() 不需要 collider／inventory，只需要 stats
func _make_character() -> Character:
	var character := Character.new()
	track(character)
	character.stats = track(Stats.new()) as Stats
	return character


func test_load_save_data_pauses_decay_when_injury_above_bleeding_threshold() -> void:
	var character := _make_character()

	character.load_save_data({"stats": {"injury": 25.0}})

	assert_true(character.has_condition(Character.CONDITION_BLEEDING), "injury 達到門檻應立即標記 bleeding，不等下個 tick")
	assert_true(character.stats.injury_decay_paused, "bleeding 中讀檔應立即暫停 injury 自然衰減，不等下個 tick")


func test_load_save_data_clears_decay_pause_when_injury_below_bleeding_threshold() -> void:
	var character := _make_character()
	character.stats.injury_decay_paused = true  # 模擬節點重用時殘留的舊旗標

	character.load_save_data({"stats": {"injury": 10.0}})

	assert_false(character.has_condition(Character.CONDITION_BLEEDING), "injury 低於門檻不該標記 bleeding")
	assert_false(character.stats.injury_decay_paused, "injury 低於門檻時衰減不該維持暫停")


func test_load_save_data_skips_bleeding_sync_for_dead_character() -> void:
	var character := _make_character()

	character.load_save_data({"is_dead": true, "stats": {"injury": 40.0}})

	assert_false(character.has_condition(Character.CONDITION_BLEEDING), "死屍不該被疊加 bleeding（#379）")
	assert_eq(character.conditions.size(), 1, "死屍 conditions 應只留 petrified")
	assert_eq(character.conditions[0]["type"], Character.CONDITION_PETRIFIED, "死屍 conditions 應只留 petrified")
