@tool
class_name TestRevive
extends McpTestSuite

## 驗證 Character.revive() 不依賴場景樹的那幾道檢查（issue #386）。
##
## 跟 test_bury.gd 同一種輕量寫法：兩個角色都不掛進場景樹，手動組出
## collider／inventory／stats 卡位，用 death_at 字串直接模擬「死了多久」，
## 不透過 _die()（那個會呼叫 GameClock，在 test_run 這個 @tool 環境下會炸）。
## 事實句注入（_push_daily_event()）與 is_in_group("agents") 判斷依賴掛進
## 場景樹的 group，這裡驗證不到，留給 project_run + game_eval。

func suite_name() -> String:
	return "revive"


func _make_character(script: Script) -> Character:
	var character := script.new() as Character
	track(character)
	character.collider = track(CollisionShape2D.new()) as CollisionShape2D
	character.inventory = track(Inventory.new()) as Inventory
	character.stats = track(Stats.new()) as Stats
	character.stats.set_value("health", 100.0)
	return character


## 距現在 hours 小時前死亡的 death_at 字串，跟 _die() 寫入格式一致
## （ISO 8601 + "Z"），用來繞過需要 GameClock 才能觸發的 _die() 本身
func _death_at_hours_ago(hours: float) -> String:
	var unix_time := Time.get_unix_time_from_system() - int(hours * 3600.0)
	return Time.get_datetime_string_from_unix_time(unix_time, false) + "Z"


func test_revive_null_target_fails() -> void:
	var reviver := _make_character(Player)

	var failure := reviver.revive(null)

	assert_eq(failure, Character.REVIVE_TARGET_NOT_FOUND, "target 是 null 時應回 REVIVE_TARGET_NOT_FOUND")


func test_revive_self_fails() -> void:
	var reviver := _make_character(Player)

	var failure := reviver.revive(reviver)

	assert_eq(failure, Character.REVIVE_TARGET_IS_SELF, "復活自己應回 REVIVE_TARGET_IS_SELF")


func test_revive_alive_target_fails() -> void:
	var reviver := _make_character(Player)
	var target := _make_character(Agent)
	target.position = reviver.position

	var failure := reviver.revive(target)

	assert_eq(failure, Character.REVIVE_TARGET_NOT_DEAD, "對象還活著時應回 REVIVE_TARGET_NOT_DEAD")


func test_revive_too_far_fails() -> void:
	var reviver := _make_character(Player)
	var target := _make_character(Agent)
	target.position = reviver.position + Vector2(9999.0, 0.0)
	target.is_dead = true
	target.death_at = _death_at_hours_ago(1.0)

	var failure := reviver.revive(target)

	assert_eq(failure, Character.REVIVE_TOO_FAR, "超出 REVIVE_RANGE 應回 REVIVE_TOO_FAR")
	assert_true(target.is_dead, "失敗時不該被復活")


func test_revive_within_free_window_costs_nothing() -> void:
	var reviver := _make_character(Player)
	var target := _make_character(Agent)
	target.position = reviver.position
	target.is_dead = true
	target.death_at = _death_at_hours_ago(1.0)		# 死亡才 1 小時，在 24 小時免費窗口內
	reviver.inventory.add_money(1000)
	var money_before := reviver.inventory.get_money()

	var result := reviver.revive(target)

	assert_eq(result, Character.REVIVE_OK, "24 小時內應可免費復活")
	assert_false(target.is_dead, "復活成功後 is_dead 應為 false")
	assert_eq(reviver.inventory.get_money(), money_before, "免費窗口內不該扣款")


func test_revive_after_free_window_charges_normal_fee() -> void:
	var reviver := _make_character(Player)
	var target := _make_character(Agent)
	target.position = reviver.position
	target.is_dead = true
	target.death_at = _death_at_hours_ago(25.0)		# 超過 24 小時免費窗口
	reviver.inventory.add_money(1000)
	var money_before := reviver.inventory.get_money()

	var result := reviver.revive(target)

	assert_eq(result, Character.REVIVE_OK, "餘額足夠時超過窗口仍應復活成功")
	assert_eq(
		reviver.inventory.get_money(), money_before - Character.REVIVE_FEE_NORMAL,
		"未下葬對象應扣未下葬那一檔金額"
	)


func test_revive_after_free_window_charges_buried_fee() -> void:
	var reviver := _make_character(Player)
	var target := _make_character(Agent)
	target.position = reviver.position
	target.is_dead = true
	target.is_buried = true
	target.death_at = _death_at_hours_ago(25.0)
	reviver.inventory.add_money(1000)
	var money_before := reviver.inventory.get_money()

	var result := reviver.revive(target)

	assert_eq(result, Character.REVIVE_OK, "餘額足夠時已下葬對象仍應復活成功")
	assert_eq(
		reviver.inventory.get_money(), money_before - Character.REVIVE_FEE_BURIED,
		"已下葬對象應扣較高那一檔金額"
	)
	assert_false(target.is_buried, "復活成功後 is_buried 應釋放為 false")


func test_revive_after_free_window_insufficient_money_fails() -> void:
	var reviver := _make_character(Player)
	var target := _make_character(Agent)
	target.position = reviver.position
	target.is_dead = true
	target.death_at = _death_at_hours_ago(25.0)
	# reviver 沒加錢，money 預設 0

	var result := reviver.revive(target)

	assert_eq(result, Character.REVIVE_NOT_ENOUGH_MONEY, "餘額不足時應回 REVIVE_NOT_ENOUGH_MONEY")
	assert_true(target.is_dead, "扣款失敗時不該復活")
	assert_eq(reviver.inventory.get_money(), 0, "扣款失敗時不該扣到任何錢")


func test_revive_clears_death_fields_and_restores_stats() -> void:
	var reviver := _make_character(Player)
	var target := _make_character(Agent)
	target.position = reviver.position
	target.is_dead = true
	target.is_buried = true
	target.grave_id = "grave_test"
	target.buried_by = "someone"
	target.buried_tick = 42
	target.is_anonymous = true
	target.death_cause = "測試死因"
	target.death_at = _death_at_hours_ago(1.0)
	target.corpse_decay = 88.0
	target.conditions.append({"type": Character.CONDITION_PETRIFIED, "turns_left": -1})
	target.stats.set_value("health", 0.0)
	target.stats.set_value("injury", 80.0)
	reviver.inventory.add_money(1000)

	var result := reviver.revive(target)

	assert_eq(result, Character.REVIVE_OK, "應復活成功")
	assert_false(target.is_dead, "is_dead 應清空")
	assert_false(target.is_buried, "is_buried 應清空")
	assert_eq(target.grave_id, null, "grave_id 應清空")
	assert_eq(target.buried_by, null, "buried_by 應清空")
	assert_eq(target.buried_tick, -1, "buried_tick 應重置為 -1")
	assert_false(target.is_anonymous, "is_anonymous 應清空")
	assert_eq(target.death_cause, "", "death_cause 應清空")
	assert_eq(target.death_at, "", "death_at 應清空")
	assert_eq(target.corpse_decay, 0.0, "corpse_decay 應歸零")
	assert_false(
		target.conditions.any(func(c): return c["type"] == Character.CONDITION_PETRIFIED),
		"石化 condition 應被移除"
	)
	assert_eq(target.stats.get_value("health"), 50.0, "health 應恢復到安全值")
	assert_eq(target.stats.get_value("injury"), 0.0, "injury 應歸零")
