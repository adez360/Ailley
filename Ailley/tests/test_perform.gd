@tool
class_name TestPerform
extends McpTestSuite

## 驗證 perform() 的前置檢查邏輯，以及 AISchema 對 tip 條件式欄位的驗證
## （issue #575）。
##
## perform() 成功時會呼叫 _run_perform()，那個協程第一步就是
## `await GameClock.time_changed`——跟 test_corpse_decay.gd 已經實測踩過的
## 「GameClock autoload 在編輯器工具測試環境沒有實例化，一碰就是 SCRIPT
## ERROR」同一個環境限制（見該檔案開頭註解），所以這裡只測得到 PERFORM_OK
## 之前的前置檢查分支（沒有背包／沒有樂器／沒有 Stats）——這幾條在真的呼叫
## _run_perform() 之前就提早 return，不會碰到 GameClock。
##
## hygiene 扣點、is_performing()==true、PERFORM_BUSY 這些成功路徑之後才會
## 出現的行為，跟 Vision 偵測→事實句→AI 決策→引擎執行打賞轉帳這整條流程
## 一樣，需要 _ready() 已經跑過的真實 Agent 節點，留給 project_run 手動驗證。

func suite_name() -> String:
	return "perform"


func _make_character(script: Script, with_inventory: bool = true, with_stats: bool = true) -> Character:
	var character := script.new() as Character
	track(character)
	character.collider = track(CollisionShape2D.new()) as CollisionShape2D
	if with_inventory:
		character.inventory = track(Inventory.new()) as Inventory
	if with_stats:
		character.stats = track(Stats.new()) as Stats
		character.stats.set_value("hygiene", 50.0)
	return character


func test_perform_no_inventory_fails() -> void:
	var character := _make_character(Agent, false, true)
	var reason := character.perform()
	assert_eq(reason, Character.PERFORM_NO_INVENTORY, "沒有背包應回 PERFORM_NO_INVENTORY")


func test_perform_without_instrument_fails() -> void:
	var character := _make_character(Agent)
	var reason := character.perform()
	assert_eq(reason, Character.PERFORM_NO_INSTRUMENT, "背包裡沒有 instrument 應回 PERFORM_NO_INSTRUMENT")
	assert_eq(character.stats.get_value("hygiene"), 50.0, "前置檢查沒過不該扣 hygiene")
	assert_eq(character.is_performing(), false, "前置檢查沒過不該進入表演狀態")


func test_perform_no_stats_fails() -> void:
	var character := _make_character(Agent, true, false)
	character.inventory.add_item("instrument", 1)

	var reason := character.perform()

	assert_eq(reason, Character.PERFORM_NO_STATS, "沒有 Stats 應回 PERFORM_NO_STATS")
	assert_eq(character.is_performing(), false, "前置檢查沒過不該進入表演狀態")


# ---- AISchema：tip 條件式欄位驗證（#575），純靜態函式，不需要任何 Character ----

func test_validate_tip_give_false_normalizes_amount_to_zero() -> void:
	var result := AISchema._validate_tip({"give": false})
	assert_true(result["ok"], "give=false 應通過驗證")
	assert_eq(result["data"]["give"], false)
	assert_eq(result["data"]["amount"], 0, "give=false 時 amount 正規化成 0")


func test_validate_tip_give_true_clamps_amount_to_range() -> void:
	var too_much := AISchema._validate_tip({"give": true, "amount": 9999})
	assert_true(too_much["ok"], "超出範圍的金額應夾制而不是整包拒絕")
	assert_eq(too_much["data"]["amount"], AISchema.TIP_MAX_AMOUNT, "超出上限應夾到 TIP_MAX_AMOUNT")

	var too_little := AISchema._validate_tip({"give": true, "amount": -5})
	assert_true(too_little["ok"])
	assert_eq(too_little["data"]["amount"], AISchema.TIP_MIN_AMOUNT, "低於下限應夾到 TIP_MIN_AMOUNT")


func test_validate_tip_missing_give_rejected() -> void:
	var result := AISchema._validate_tip({"amount": 5})
	assert_false(result["ok"], "缺少 give 欄位應整包拒絕")


func test_validate_tip_give_true_without_amount_rejected() -> void:
	var result := AISchema._validate_tip({"give": true})
	assert_false(result["ok"], "give=true 卻沒填 amount 應整包拒絕")


func test_validate_tasks_ignores_tip_when_not_allowed() -> void:
	var data := {
		"reasoning": "test",
		"tasks": [],
		"emotion": {"type": "neutral", "intensity": 0},
		"tip": {"give": true, "amount": 10},
	}
	var result := AISchema.validate_tasks(data, false, 0, false, false)
	assert_true(result["ok"], "allow_perform_tip=false 時整份回應不該因為模型硬塞 tip 而失敗")
	assert_eq(result["data"]["tip"], null, "allow_perform_tip=false 時 tip 應被忽略、正規化成 null")


func test_validate_tasks_accepts_tip_when_allowed() -> void:
	var data := {
		"reasoning": "test",
		"tasks": [],
		"emotion": {"type": "neutral", "intensity": 0},
		"tip": {"give": true, "amount": 7},
	}
	var result := AISchema.validate_tasks(data, false, 0, false, true)
	assert_true(result["ok"], "allow_perform_tip=true 時合法的 tip 應通過驗證")
	assert_eq(result["data"]["tip"]["give"], true)
	assert_eq(result["data"]["tip"]["amount"], 7)
