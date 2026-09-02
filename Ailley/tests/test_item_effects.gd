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
	_assert_eq(character.stats.get_value("stamina"), 10.0, "stamina 應套用 items.json 的 effect_stamina +10")
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


# 以下四個測試涵蓋 Character.use_item()／use_selected_item()（#865）：修正前，
# medicine（category: "carry"，帶 effect_injury）完全沒有路徑能被使用——
# use_selected_item() 原本寫死 is_consumable := category == "food" or "drink"，
# 擋掉了所有 carry 分類的道具，不論它有沒有 effect_*

func test_character_use_item_treats_injury_with_medicine() -> void:
	var character = Character.new()
	character.inventory = Inventory.new()
	character.stats = Stats.new()
	character.stats.add("injury", 50.0)
	character.inventory.add_item("medicine", 1)

	var result = character.use_item("medicine")

	_assert_eq(result, Character.USE_ITEM_OK, "使用 medicine 應成功")
	_assert_eq(character.stats.get_value("injury"), 20.0, "injury 應套用 items.json 的 effect_injury -30（50 → 20）")
	_assert_eq(character.inventory.has_item("medicine", 1), false, "使用後應消耗 1 份")
	character.free()


func test_character_use_item_rejects_carry_item_without_effect() -> void:
	# knife 是 carry 分類但沒有任何 effect_* 欄位——不該被判定成可消耗，
	# 跟 medicine 的差別只在「有沒有 effect_*」，不是 category
	var character = Character.new()
	character.inventory = Inventory.new()
	character.stats = Stats.new()
	character.inventory.add_item("knife", 1)

	var result = character.use_item("knife")

	_assert_eq(result, Inventory.USE_NOT_CONSUMABLE, "沒有 effect_* 的道具應回 NOT_CONSUMABLE")
	_assert_eq(character.inventory.has_item("knife", 1), true, "判定失敗不該消耗物品")
	character.free()


func test_character_use_item_not_found_in_inventory() -> void:
	var character = Character.new()
	character.inventory = Inventory.new()
	character.stats = Stats.new()

	var result = character.use_item("medicine")

	_assert_eq(result, Character.USE_ITEM_NOT_FOUND, "背包沒有該物品應回 NOT_FOUND")
	character.free()


func test_character_use_selected_item_delegates_to_use_item() -> void:
	# 玩家快捷欄路徑（原始 bug 的回歸測試，#865）：選到 medicine 那一格，
	# use_selected_item() 應該跟直接呼叫 use_item("medicine") 效果一致，
	# 不再被 is_consumable 的 category 白名單擋下
	var character = Character.new()
	character.inventory = Inventory.new()
	character.stats = Stats.new()
	character.stats.add("injury", 50.0)
	character.inventory.add_item("medicine", 1)
	character.inventory.set_selected_index(0)

	var result = character.use_selected_item()

	_assert_eq(result, Character.USE_ITEM_OK, "選到 medicine 時 use_selected_item() 應成功")
	_assert_eq(character.stats.get_value("injury"), 20.0, "injury 應套用 effect_injury -30（50 → 20）")
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


# 以下測試腐壞 tick 與食用懲罰（issue #840，《規格書08》§6-1）。tick_decay()
# 不碰 GameClock，可以直接呼叫測；_on_game_minute() 真的接上這個 tick 的
# 那條線已改用 project_run + game_eval 在編輯器裡對活的遊戲場景驗證過
# （跟 test_corpse_decay.gd 說明的同一個理由：is_dead 分支會碰 GameClock
# autoload，這裡雖然沒有 is_dead 分支，但為了跟既有先例一致仍分兩層驗證）

func test_use_item_stale_decay_applies_health_penalty() -> void:
	# decay 40–79（不新鮮）：食用時 health 額外扣 -3
	var inv = Inventory.new()
	inv.add_item("bread", 1, 50)
	var stats = Stats.new()
	stats.set_value("health", 100.0)  # Stats.new() 不掛進場景樹不會跑 _ready()，起始值得自己補

	var result = inv.use_item("bread", stats, {"effect_satiety": 25.0})

	_assert_eq(result, Inventory.USE_OK, "不新鮮仍可食用")
	_assert_eq(stats.get_value("satiety"), 25.0, "satiety 應正常套用")
	_assert_eq(stats.get_value("health"), 97.0, "health 應額外扣 -3（100 起始）")


func test_use_item_rotten_decay_applies_larger_health_penalty() -> void:
	# decay 80–99（快壞了）：食用時 health 額外扣 -10
	var inv = Inventory.new()
	inv.add_item("bread", 1, 90)
	var stats = Stats.new()
	stats.set_value("health", 100.0)

	var result = inv.use_item("bread", stats, {"effect_satiety": 25.0})

	_assert_eq(result, Inventory.USE_OK, "快壞了仍可食用")
	_assert_eq(stats.get_value("health"), 90.0, "health 應額外扣 -10（100 起始）")


func test_use_item_fresh_decay_no_health_penalty() -> void:
	# decay 0–39（新鮮）：無懲罰
	var inv = Inventory.new()
	inv.add_item("bread", 1, 20)
	var stats = Stats.new()
	stats.set_value("health", 100.0)

	inv.use_item("bread", stats, {"effect_satiety": 25.0})

	_assert_eq(stats.get_value("health"), 100.0, "新鮮不該扣 health")


func test_use_item_spoiled_rejected_atomically() -> void:
	# decay=100：不可食用，判定失敗——物品不消耗、任何效果都不套用
	var inv = Inventory.new()
	inv.add_item("bread", 1, 100)
	var stats = Stats.new()
	stats.set_value("health", 100.0)

	var result = inv.use_item("bread", stats, {"effect_satiety": 25.0})

	_assert_eq(result, Inventory.USE_SPOILED, "完全腐壞應回 USE_SPOILED")
	_assert_eq(inv.has_item("bread", 1), true, "判定失敗不應消耗物品")
	_assert_eq(stats.get_value("satiety"), 0.0, "判定失敗不應套用效果")
	_assert_eq(stats.get_value("health"), 100.0, "判定失敗不應扣 health")


func test_eat_spoiled_reason_distinct_from_no_food() -> void:
	# 完全腐壞要回報 EAT_SPOILED，不能被既有「沒有食物可吃」的收斂邏輯
	# 吞掉——玩家/AI 才分得出「背包沒食物」跟「有食物但腐壞了」的差別
	var character = Character.new()
	character.inventory = Inventory.new()
	character.stats = Stats.new()
	character.inventory.add_item("cooked_meat", 1, 100)

	var result = character.eat()

	_assert_eq(result, Character.EAT_SPOILED, "完全腐壞應回 EAT_SPOILED，不是 EAT_NO_FOOD")
	_assert_eq(character.inventory.has_item("cooked_meat", 1), true, "判定失敗不應消耗物品")
	character.free()


func test_tick_decay_accumulates_fractional_rate() -> void:
	# 0.3／tick 這種小數速率要能跨多個 tick 累加，不能被 int 截斷成恆等於 0
	# （見 inventory.gd::tick_decay() 的說明）
	var inv = Inventory.new()
	inv.add_item("bread", 1, 0)

	for i in range(3):
		inv.tick_decay({"bread": 0.3})

	var slot = inv.get_slot(0)
	assert_true(is_equal_approx(float(slot.get("decay", -1.0)), 0.9), "3 個 tick 累加應約為 0.9（0.3 x 3）")


func test_tick_decay_skips_carry_items() -> void:
	# carry 類（durability >= 0）用耐久不用腐壞，就算 rates 裡剛好有這個
	# item_id 也該跳過
	var inv = Inventory.new()
	inv.add_item("knife", 1, 0, 100)

	inv.tick_decay({"knife": 5.0})

	var slot = inv.get_slot(0)
	_assert_eq(slot.get("decay", -1), 0, "carry 類的 decay 不該被 tick_decay() 改動")


func test_tick_decay_ignores_items_without_rate() -> void:
	# water 沒有 decay_rate（不腐壞），查不到 rate 就該跳過
	var inv = Inventory.new()
	inv.add_item("water", 1, 0)

	inv.tick_decay({"bread": 0.3})  # water 不在這份 rates 表裡

	var slot = inv.get_slot(0)
	_assert_eq(slot.get("decay", -1), 0, "沒有 decay_rate 的物品不該被改動")


func test_tick_decay_clamps_at_100() -> void:
	var inv = Inventory.new()
	inv.add_item("bread", 1, 99)

	inv.tick_decay({"bread": 5.0})

	var slot = inv.get_slot(0)
	assert_true(is_equal_approx(float(slot.get("decay", -1.0)), 100.0), "decay 不該超過 100")


func test_item_database_get_decay_rates_reads_real_data() -> void:
	# 跟 test_character_eat_reads_real_item_database() 同一種立場：驗證真的
	# 讀 data/items.json，不是測試自己手寫的 rates 字典
	var rates = ItemDatabase.get_decay_rates()

	_assert_eq(rates.get("bread", -1.0), 0.3, "bread 的 decay_rate 應是 0.3")
	_assert_eq(rates.has("water"), false, "water 不腐壞，不該出現在這份表裡")
	_assert_eq(rates.has("knife"), false, "carry 類沒有 decay_rate 欄位，不該出現在這份表裡")


# 測試輔助方法
func _assert_eq(actual: Variant, expected: Variant, message: String) -> void:
	_assertion_count += 1
	if actual != expected:
		_failed = true
		_message = "%s（實際：%s，預期：%s）" % [message, actual, expected]
