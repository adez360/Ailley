@tool
class_name TestCharacterAge
extends McpTestSuite

## 驗證 issue #837：建角面板收集的 age 從未寫入 Character 節點、狀態面板
## 永遠顯示佔位符。這裡只測 Character 層的資料契約（-1 哨兵值、
## get_save_data()／load_save_data() 存讀），不掛場景樹——GameManager.
## spawn_character()／deploy_from_library() 把角色庫的 age 寫進節點這段，
## 依賴 get_tree()／"world" 群組，已改用 project_run + game_eval 在編輯器
## 對活的遊戲場景驗證過，跟 test_home_assignment.gd 對 GameManager 場景相關
## 部分的取捨一致。

func suite_name() -> String:
	return "character_age"


func test_default_age_is_unknown_sentinel() -> void:
	var character := Character.new()
	track(character)

	assert_eq(character.age, -1, "沒有走過角色庫投放的角色，age 應維持 -1（未知）")


func test_get_save_data_includes_age() -> void:
	var character := Character.new()
	track(character)
	character.age = 42

	var data := character.get_save_data()

	assert_true(data.has("age"), "get_save_data() 應包含 age 欄位")
	assert_eq(data["age"], 42, "存檔資料應是設定的 age 值")


func test_load_save_data_restores_age() -> void:
	var character := Character.new()
	track(character)

	character.load_save_data({"age": 55})

	assert_eq(character.age, 55, "load_save_data() 應把 age 還原成存檔值")


func test_load_save_data_accepts_float_age() -> void:
	# JsonSaveService 走 JSON.parse_string()，JSON 數字一律回 float（#862
	# 同型陷阱）——load_save_data() 只收 int 的話，存檔年齡永不生效
	var character := Character.new()
	track(character)

	character.load_save_data({"age": 55.0})

	assert_eq(character.age, 55, "float 的 age 應轉型後還原成存檔值")


func test_load_save_data_missing_age_keeps_current_value() -> void:
	# 缺席（issue #837 前的舊存檔）沿用目前值，不強制清空——理由跟
	# home_location_id／character_name 那幾個既有欄位一致
	var character := Character.new()
	track(character)
	character.age = 33

	character.load_save_data({})

	assert_eq(character.age, 33, "存檔沒有 age 欄位時應沿用目前值，不被清成 -1")


func test_load_save_data_wrong_type_keeps_current_value() -> void:
	var character := Character.new()
	track(character)
	character.age = 33

	character.load_save_data({"age": "old"})

	assert_eq(character.age, 33, "型別不對的 age 不該被套用，沿用目前值")


func test_load_save_data_out_of_range_keeps_current_value() -> void:
	# 型別是 int 但超出《規格書01》§1-1 的 16–70 合法範圍（例如手改／損毀存檔）
	# 不該被套用，同樣沿用目前值（CodeRabbit review 抓到，PR #845）
	var character := Character.new()
	track(character)
	character.age = 33

	character.load_save_data({"age": 999})

	assert_eq(character.age, 33, "超出 16–70 範圍的 age 不該被套用，沿用目前值")


func test_load_save_data_accepts_unknown_sentinel() -> void:
	# -1（未知）本身是合法值，不該被範圍檢查誤擋——理由見 age 欄位本身的說明
	var character := Character.new()
	track(character)
	character.age = 33

	character.load_save_data({"age": -1})

	assert_eq(character.age, -1, "-1 是合法的「未知」哨兵值，應該被接受")
