@tool
class_name TestGiveAttackOnPlayer
extends McpTestSuite

## 驗證 give／attack 執行層對 Player 目標可以正常運作（issue #376）。
## give_to()／attack() 本來就只吃 Character 型別，不區分 Agent／Player，
## 這裡直接對一個 Player 實例呼叫這兩個函式，確認介面真的相容，
## 不是「理論上應該相容」。

func suite_name() -> String:
	return "give_attack_on_player"


## 兩個角色都不掛進場景樹（跟 test_item_effects.gd 同一種輕量寫法），
## 但 give_to()／attack() 內部會呼叫 get_body_position()（= to_global(collider.position)），
## 需要 collider 有值才不會噴 null——手動塞一個 CollisionShape2D 卡位，
## 不需要真的加進場景樹，to_global() 只讀它的 position 屬性
func _make_character(script: Script) -> Character:
	var character := script.new() as Character
	track(character)
	character.collider = track(CollisionShape2D.new()) as CollisionShape2D
	character.inventory = track(Inventory.new()) as Inventory
	character.stats = track(Stats.new()) as Stats
	character.stats.set_value("health", 100.0)
	character.stats.set_value("injury", 0.0)
	return character


func test_give_to_player_target_transfers_item() -> void:
	var giver := _make_character(Agent)
	var player := _make_character(Player)
	player.position = giver.position  # 同一個位置，一定在 GIVE_RANGE 內

	giver.inventory.add_item("bread", 3)

	var failure := giver.give_to(player, "bread", 3)

	assert_eq(failure, Character.GIVE_OK, "對 Player 送禮應成功")
	assert_eq(giver.inventory.has_item("bread", 3), false, "送出方背包應扣掉 3 個")
	assert_eq(player.inventory.has_item("bread", 3), true, "Player 背包應收到 3 個")


func test_attack_player_target_applies_damage() -> void:
	var attacker := _make_character(Agent)
	var player := _make_character(Player)
	player.position = attacker.position  # 同一個位置，一定在 ATTACK_RANGE 內

	var failure := attacker.attack(player)

	assert_eq(failure, Character.ATTACK_OK, "對 Player 攻擊應成功（必中，見 attack() 的說明）")
	assert_eq(player.stats.get_value("health"), 100.0 + Character.ATTACK_HEALTH_DELTA, "Player health 應套用攻擊傷害")
	assert_eq(player.stats.get_value("injury"), Character.ATTACK_INJURY_DELTA, "Player injury 應套用攻擊傷害")
	assert_true(player.has_condition(Character.CONDITION_BLEEDING), "injury 達到門檻應立即標記 bleeding，不等下個 tick")


func test_attack_player_target_too_far_fails() -> void:
	var attacker := _make_character(Agent)
	var player := _make_character(Player)
	player.position = attacker.position + Vector2(9999.0, 0.0)

	var failure := attacker.attack(player)

	assert_eq(failure, Character.ATTACK_TOO_FAR, "超出 ATTACK_RANGE 應回 ATTACK_TOO_FAR")
	assert_eq(player.stats.get_value("health"), 100.0, "失敗時不該套用任何傷害")


func test_dead_attacker_cannot_attack() -> void:
	var attacker := _make_character(Agent)
	var player := _make_character(Player)
	player.position = attacker.position  # 同一個位置，一定在 ATTACK_RANGE 內
	attacker.is_dead = true

	var failure := attacker.attack(player)

	assert_eq(failure, Character.ATTACK_IS_DEAD, "死屍不能發起攻擊（PR #763）")
	assert_eq(player.stats.get_value("health"), 100.0, "死屍攻擊不該套用任何傷害")


func test_attack_dead_target_still_applies_damage() -> void:
	# 只擋攻擊者這一側：攻擊死屍（other.is_dead）的既有行為不變——數值照套，
	# 只跳過 bleeding 疊加（#379 死屍 conditions 只留 petrified）
	var attacker := _make_character(Agent)
	var corpse := _make_character(Player)
	corpse.position = attacker.position  # 同一個位置，一定在 ATTACK_RANGE 內
	corpse.is_dead = true

	var failure := attacker.attack(corpse)

	assert_eq(failure, Character.ATTACK_OK, "活人攻擊死屍應照舊成功")
	assert_eq(corpse.stats.get_value("health"), 100.0 + Character.ATTACK_HEALTH_DELTA, "攻擊死屍仍應套用傷害")
	assert_true(corpse.has_condition(Character.CONDITION_BLEEDING) == false, "死屍不該被疊加 bleeding（#379）")
