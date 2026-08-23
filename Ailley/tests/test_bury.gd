@tool
class_name TestBury
extends McpTestSuite

## 驗證 Character.bury() 不依賴場景樹的那幾道檢查（issue #380）。
##
## 跟 test_give_attack_on_player.gd 同一種輕量寫法：兩個角色都不掛進場景樹，
## 手動組出 collider／stats 卡位。but 距離／地點／墓碑格數這三關要用到
## get_tree().get_first_node_in_group("place_anchors")，跟既有的
## _resolve_death_location()（#379）同一個限制——沒有掛進真場景就查不到墓園
## 錨點，這幾項留給 project_run + game_eval 在編輯器裡活的場景驗證，
## 不在這個 test_run 套件涵蓋範圍內。

func suite_name() -> String:
	return "bury"


func _make_character(script: Script) -> Character:
	var character := script.new() as Character
	track(character)
	character.collider = track(CollisionShape2D.new()) as CollisionShape2D
	character.inventory = track(Inventory.new()) as Inventory
	character.stats = track(Stats.new()) as Stats
	character.stats.set_value("health", 100.0)
	return character


func test_bury_alive_target_fails() -> void:
	var burier := _make_character(Agent)
	var target := _make_character(Agent)
	target.position = burier.position

	var failure := burier.bury(target)

	assert_eq(failure, Character.BURY_TARGET_NOT_DEAD, "對象還活著時應回 BURY_TARGET_NOT_DEAD")
	assert_false(target.is_buried, "失敗時不該被標記為已安葬")


func test_bury_already_buried_target_fails() -> void:
	var burier := _make_character(Agent)
	var target := _make_character(Agent)
	target.position = burier.position
	target.is_dead = true
	target.is_buried = true

	var failure := burier.bury(target)

	assert_eq(failure, Character.BURY_ALREADY_BURIED, "已經安葬過的對象應回 BURY_ALREADY_BURIED")


func test_bury_too_far_fails() -> void:
	var burier := _make_character(Agent)
	var target := _make_character(Agent)
	target.position = burier.position + Vector2(9999.0, 0.0)
	target.is_dead = true

	var failure := burier.bury(target)

	assert_eq(failure, Character.BURY_TOO_FAR, "超出 BURY_RANGE 應回 BURY_TOO_FAR")
	assert_false(target.is_buried, "失敗時不該被標記為已安葬")


func test_bury_null_target_fails() -> void:
	var burier := _make_character(Agent)

	var failure := burier.bury(null)

	assert_eq(failure, Character.BURY_TARGET_NOT_FOUND, "target 是 null 時應回 BURY_TARGET_NOT_FOUND")
