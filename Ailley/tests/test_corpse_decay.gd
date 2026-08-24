@tool
class_name TestCorpseDecay
extends McpTestSuite

## 驗證 Character._update_corpse_decay() 的行為（issue #387）。
##
## _update_corpse_decay() 只要 is_dead == true 就一定會呼叫 _current_tick()
## （用來跳過「死亡當下那個 tick 不算」），而 _current_tick() 讀的是 GameClock
## autoload——這個套件跑在編輯器的工具測試環境，不是活的遊戲場景樹，
## autoload 沒有實例化，一碰就是 SCRIPT ERROR「Invalid access to property
## 'hour' on a base object of type 'Node (GameClock.gd)'」（實測踩過，不是
## 猜測）。跟 test_bury.gd 的 get_tree() 限制同一類問題，只是範圍更大：
## is_dead == true 的分支整個測不了，不只「達到立碑門檻」那一段。
## 所以這裡只留得住「活人不累加」這個 is_dead == false 就提早 return 的案例；
## decay 累加、達到 100 自動立無名碑、墓碑格數滿了時立碑失敗並下個 tick
## 重試——已改用 project_run + game_eval 在編輯器裡對活的遊戲場景驗證過，
## 結果符合預期，不再需要補這幾條單元測試。

func suite_name() -> String:
	return "corpse_decay"


func test_corpse_decay_does_nothing_when_not_dead() -> void:
	var character := Agent.new() as Character
	track(character)
	character.collider = track(CollisionShape2D.new()) as CollisionShape2D
	character.inventory = track(Inventory.new()) as Inventory
	character.stats = track(Stats.new()) as Stats
	character.stats.set_value("health", 100.0)

	character._update_corpse_decay()

	assert_true(is_equal_approx(character.corpse_decay, 0.0), "活人不該累加 corpse_decay")
