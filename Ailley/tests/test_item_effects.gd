@tool
class_name TestItemEffects
extends McpTestSuite

## 測試 Inventory.use_item() 通用化：effect_* 依 Stats.SPEC 動態讀取（不再
## 寫死 4 個欄位），且驗證失敗時不消耗物品、不套用效果（atomicity）。

func suite_name() -> String:
	return "item_effects"


func test_use_item_applies_arbitrary_stats_fields() -> void:
	# ale 的效果橫跨 hydration/alcohol/wakefulness 三個欄位，其中
	# wakefulness 是負值——用來驗證「不是只有原本那 4 個欄位才讀得到」
	var inv = Inventory.new()
	inv.add_item("ale", 1)

	var stats = Stats.new()
	stats.add("wakefulness", 50.0)  # 先給一個非 0 起始值，才能驗證負向 delta

	var effects = {"effect_hydration": 20.0, "effect_alcohol": 25.0, "effect_wakefulness": -8.0}
	var result = inv.use_item("ale", stats, effects)

	_assert_eq(result, Inventory.USE_OK, "使用 ale 應成功")
	_assert_eq(stats.get_value("hydration"), 20.0, "hydration 應套用 +20")
	_assert_eq(stats.get_value("alcohol"), 25.0, "alcohol 應套用 +25")
	_assert_eq(stats.get_value("wakefulness"), 42.0, "wakefulness 應套用 -8（50 → 42）")
	_assert_eq(inv.has_item("ale", 1), false, "使用成功後應消耗 1 個")


func test_use_item_not_found_leaves_stats_untouched() -> void:
	var inv = Inventory.new()  # 空背包
	var stats = Stats.new()

	var result = inv.use_item("bread", stats, {"effect_satiety": 25.0})

	_assert_eq(result, Inventory.USE_NOT_FOUND, "背包沒有該物品應回 NOT_FOUND")
	_assert_eq(stats.get_value("satiety"), 0.0, "失敗時不該套用效果")


func test_use_item_invalid_effect_rejected_before_consuming() -> void:
	# 驗證順序：無效數值要在扣物品之前就擋下來，不能「先扣了才發現算不出來」
	var inv = Inventory.new()
	inv.add_item("bread", 1)
	var stats = Stats.new()

	var result = inv.use_item("bread", stats, {"effect_satiety": INF})

	_assert_eq(result, Inventory.USE_INVALID_EFFECT, "非有限數值應回 INVALID_EFFECT")
	_assert_eq(inv.has_item("bread", 1), true, "驗證失敗不應消耗物品")
	_assert_eq(stats.get_value("satiety"), 0.0, "驗證失敗不應套用效果")


# 以下三個測試從 Character.eat()/drink()/apply_personality_delta() 進場，
# 不像上面三個直接呼叫 Inventory.use_item()——驗證的是 ItemDatabase 查表
# （真的讀 Ailley/data/items.json，不是測試自己手寫 effects dict）跟
# Character 這層呼叫路徑本身，兩層合起來才是玩家實際會走到的路徑
# （CodeRabbit review 抓到：原本三個測試都繞過了這一層）

func test_character_eat_reads_real_item_database() -> void:
	var character = Character.new()
	character.inventory = Inventory.new()
	character.stats = Stats.new()
	character.inventory.add_item("cooked_meat", 1)

	var result = character.eat()

	_assert_eq(result, Character.EAT_OK, "吃烤肉應成功")
	_assert_eq(character.stats.get_value("satiety"), 40.0, "satiety 應套用 items.json 的 effect_satiety +40")
	_assert_eq(character.inventory.has_item("cooked_meat", 1), false, "吃掉後應消耗 1 份")
	character.free()


func test_character_drink_reads_real_item_database() -> void:
	var character = Character.new()
	character.inventory = Inventory.new()
	character.stats = Stats.new()
	character.stats.add("wakefulness", 50.0)  # 給非 0 起始值才能驗證負向 delta
	character.inventory.add_item("ale", 1)

	var result = character.drink()

	_assert_eq(result, Character.DRINK_OK, "喝麥酒應成功")
	_assert_eq(character.stats.get_value("hydration"), 20.0, "hydration 應套用 items.json 的 effect_hydration +20")
	_assert_eq(character.stats.get_value("alcohol"), 25.0, "alcohol 應套用 items.json 的 effect_alcohol +25")
	_assert_eq(character.stats.get_value("wakefulness"), 42.0, "wakefulness 應套用 items.json 的 effect_wakefulness -8（50 → 42）")
	character.free()


func test_apply_personality_delta_clamps_both_boundaries() -> void:
	var character = Character.new()
	character.personality = {"greed": 95.0, "honesty": 5.0}

	character.apply_personality_delta({"greed": 20.0, "honesty": -20.0})

	_assert_eq(character.personality["greed"], 100.0, "greed 加超過 100 應夾到 100")
	_assert_eq(character.personality["honesty"], 0.0, "honesty 減到負值應夾到 0")
	character.free()


func test_apply_personality_delta_skips_unknown_field() -> void:
	# 對應 character.gd 的修正：items.json 手打錯人格欄位名稱時只跳過該欄位、
	# 印警告，不能真的寫進 personality——多一個陌生 key 會讓下次存讀時
	# _is_valid_personality_data() 判定整包不合法，連本來合法的 10 項都遭殃
	var character = Character.new()
	character.personality = {"greed": 50.0}

	character.apply_personality_delta({"greeed": 10.0})

	_assert_eq(character.personality.has("greeed"), false, "拼錯的欄位名稱不該被寫進 personality")
	_assert_eq(character.personality["greed"], 50.0, "沒被指定的既有欄位應維持不變")
	character.free()


# 測試輔助方法
func _assert_eq(actual: Variant, expected: Variant, message: String) -> void:
	_assertion_count += 1
	if actual != expected:
		_failed = true
		_message = "%s（實際：%s，預期：%s）" % [message, actual, expected]
