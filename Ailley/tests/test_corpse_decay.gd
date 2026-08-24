@tool
class_name TestCorpseDecay
extends McpTestSuite

## 驗證 Character._update_corpse_decay() 在達到自動立無名碑門檻前的累加行為
## （issue #387）。
##
## 跟 test_bury.gd 同一種限制：_erect_unmarked_grave() 會呼叫
## _cemetery_grave_count()，而它依賴 get_tree().get_nodes_in_group("characters")——
## 這裡的角色沒有掛進場景樹，一旦 corpse_decay 真的到 100 觸發立碑，
## get_tree() 是 null 就會直接炸掉。所以這個套件只覆蓋「還沒到門檻」那段
## 安全範圍；「decay 到 100 自動立碑」與「墓碑格數滿了時立碑失敗、下個 tick
## 重試」這兩項留給 project_run + game_eval 在編輯器裡活的場景驗證。

func suite_name() -> String:
	return "corpse_decay"


func _make_dead_character() -> Character:
	var character := Agent.new() as Character
	track(character)
	character.collider = track(CollisionShape2D.new()) as CollisionShape2D
	character.inventory = track(Inventory.new()) as Inventory
	character.stats = track(Stats.new()) as Stats
	character.stats.set_value("health", 100.0)
	character.is_dead = true
	character.death_tick = -999	# 遠離目前 tick，不觸發「死亡當下那個 tick 不算」的跳過邏輯
	return character


func test_corpse_decay_accumulates_below_threshold() -> void:
	var character := _make_dead_character()

	for i in range(5):
		character._update_corpse_decay()

	assert_true(is_equal_approx(character.corpse_decay, 3.5), "5 個 tick 應累加 5*0.7=3.5")
	assert_false(character.is_buried, "還沒到門檻不該被標記為已安葬")
	assert_eq(character.grave_id, null, "還沒到門檻不該被立碑")
	assert_false(character.is_anonymous, "還沒到門檻不該被標記為無名碑")


func test_corpse_decay_does_nothing_when_not_dead() -> void:
	var character := Agent.new() as Character
	track(character)
	character.collider = track(CollisionShape2D.new()) as CollisionShape2D
	character.inventory = track(Inventory.new()) as Inventory
	character.stats = track(Stats.new()) as Stats
	character.stats.set_value("health", 100.0)

	character._update_corpse_decay()

	assert_true(is_equal_approx(character.corpse_decay, 0.0), "活人不該累加 corpse_decay")
