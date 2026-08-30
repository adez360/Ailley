@tool
class_name TestHomeAssignment
extends McpTestSuite

## 驗證 home 的 round-robin 分配核心（issue #391，PR #727 第一輪 review 要求
## 的補測）：占用判斷、沿用檢查、溢出安全閥目前零自動化覆蓋，而 review 抓到
## 的兩個 major 都出在這裡。
##
## 純 DatabaseManager 層寫法（跟 test_stats.gd 同一種：不掛場景樹）：
## 「世界名冊」是場景狀態不是 DB 狀態，CharacterStatePersistence 把它收成
## _resolve_home_location_for()／_occupied_home_location_ids() 的參數，測試
## 直接傳入空名冊或測試用名冊，不必造場景節點也能決定性地測占用語意。
## DB 用測試字首（thhome_）的 npc 列模擬占用，teardown 清掉；home_assignment
## 游標是共用 DB 的單一列，每個測試前保存、teardown 還原。
##
## 不在本套件涵蓋範圍：需要真場景的部分——loc_home_* 錨點、has_for()/
## resolve_for() 的 home 轉譯、_world_character_ids() 對 characters 群組的
## 抓取（同 test_bury.gd 的取捨，留給 project_run + game_eval 在編輯器裡
## 活的場景驗證）。

const PERSISTENCE_NODE_PATH := "CharacterStatePersistence"
const TEST_NPC_PREFIX := "thhome_"

var _persistence: Node = null
var _saved_cursor := -1


func suite_name() -> String:
	return "home_assignment"


func suite_setup(_ctx: Dictionary) -> void:
	_persistence = DatabaseManager.get_node_or_null(PERSISTENCE_NODE_PATH)

	if _persistence == null:
		skip_suite("找不到 DatabaseManager/%s" % PERSISTENCE_NODE_PATH)
		return

	if not DatabaseManager.is_seeded:
		skip_suite("資料庫還沒 seed 完成，無法測 location/npc 表")


func setup() -> void:
	_saved_cursor = _persistence._get_home_cursor()
	_persistence._ensure_home_locations_seeded()


func teardown() -> void:
	DatabaseManager.delete("npc", "npc_id LIKE '%s%%'" % TEST_NPC_PREFIX)

	if _saved_cursor >= 0:
		_persistence._set_home_cursor(_saved_cursor)
		_saved_cursor = -1


func _insert_test_npc(npc_id: String, home_location_id: String) -> void:
	assert_true(
		DatabaseManager.insert("npc", {
			"npc_id": npc_id,
			"name": npc_id.substr(0, 12),
			"age": 30,
			"gender": "other",
			"village_id": "default_village",
			"character": "",
			"reputation": 0,
			"system_prompt": "",
			"words_to_creator": "",
			"is_spoken": 0,
			"generated_at": null,
			"spoken_at": null,
			"trigger": null,
			"home_location_id": home_location_id,
			"decision_source": "local",
			"model_name": "",
			"is_active": 1,
		}),
		"測試前置：插入 npc %s（home=%s）" % [npc_id, home_location_id]
	)


func _home_id(index: int) -> String:
	return "%s%02d" % [_persistence.HOME_LOCATION_PREFIX, index]


## review 要求的場景一：游標歸零後連續分配 5 次，拿到 01～05 全不重複，
## 且游標剛好繞回起點
func test_five_consecutive_assignments_cover_all_homes_without_duplicates() -> void:
	_persistence._set_home_cursor(0)

	var count: int = _persistence.HOME_LOCATION_COUNT
	assert_eq(count, 5, "MVP／Phase 2 拍板固定 5 間（見《99》P-58）")

	var assigned := {}
	for i in count:
		var home: String = _persistence._assign_next_home_location({})
		assert_true(
			_persistence._is_valid_home_location_id(home),
			"第 %d 次分配 %s 應是合法的 loc_home_0N 命名" % [i + 1, home]
		)
		assert_false(
			assigned.has(home),
			"第 %d 次分配 %s 不該跟前面的重複" % [i + 1, home]
		)
		assigned[home] = true

	assert_eq(assigned.size(), count, "5 次分配應涵蓋全部 5 間")
	assert_eq(_persistence._get_home_cursor(), 0, "分配完 5 間游標應繞回 0")


## review 要求的場景二：5 間全滿時溢出安全閥要回傳「界內」的 loc_home_0N，
## 不能算出 loc_home_06 撞 NPCSchema 外鍵；游標也要收斂
func test_overflow_returns_in_range_home_and_converges_cursor() -> void:
	var all_occupied := {}
	for i in range(1, _persistence.HOME_LOCATION_COUNT + 1):
		all_occupied[_home_id(i)] = true

	_persistence._set_home_cursor(_persistence.HOME_LOCATION_COUNT - 1)

	var overflow: String = _persistence._assign_next_home_location(all_occupied)

	assert_true(
		_persistence._is_valid_home_location_id(overflow),
		"溢出共用 %s 仍要是 loc_home_01～05，不能是 loc_home_06 這種界外值" % overflow
	)

	var cursor: int = _persistence._get_home_cursor()
	assert_true(
		cursor >= 0 and cursor < _persistence.HOME_LOCATION_COUNT,
		"溢出後游標 %d 應收斂在 0～N-1" % cursor
	)


## review 要求的場景三：舊 fallback（issue #391 之前）寫的 home_001 這類
## 舊格式值，會被視為無效、重分配成新格式的 loc_home_0N
func test_legacy_format_value_is_reassigned() -> void:
	var home: String = _persistence._resolve_home_location_for(
		"home_001", TEST_NPC_PREFIX + "a", {}
	)

	assert_true(
		_persistence._is_valid_home_location_id(home),
		"舊格式 home_001 應被重分配成新格式，實際拿到 %s" % home
	)


func test_out_of_range_value_is_reassigned() -> void:
	var home: String = _persistence._resolve_home_location_for(
		"loc_home_09", TEST_NPC_PREFIX + "a", {}
	)

	assert_true(
		_persistence._is_valid_home_location_id(home),
		"界外值 loc_home_09 應被重分配成界內的家，實際拿到 %s" % home
	)


## review 要求的場景四：值合法、location 表也有這一列，但已被「還在世界裡」
## 的別人佔用——不能沿用，要落到 round-robin 重分配（major ②）
func test_home_occupied_by_other_character_is_not_reused() -> void:
	_insert_test_npc(TEST_NPC_PREFIX + "b", _home_id(2))

	var home: String = _persistence._resolve_home_location_for(
		_home_id(2),
		TEST_NPC_PREFIX + "a",
		{TEST_NPC_PREFIX + "b": true}
	)

	assert_ne(home, _home_id(2), "loc_home_02 已被別人佔用，不該沿用")
	assert_true(
		_persistence._is_valid_home_location_id(home),
		"重分配結果 %s 應是合法命名" % home
	)


## 排除自己：自己既有 npc 列上的 home_location_id 不算占用，
## 自己的舊值要能沿用（major ② 的 exclude-self）
func test_own_npc_row_does_not_block_reuse() -> void:
	_insert_test_npc(TEST_NPC_PREFIX + "b", _home_id(2))
	_insert_test_npc(TEST_NPC_PREFIX + "a", _home_id(3))

	var home: String = _persistence._resolve_home_location_for(
		_home_id(3),
		TEST_NPC_PREFIX + "a",
		{TEST_NPC_PREFIX + "a": true, TEST_NPC_PREFIX + "b": true}
	)

	assert_eq(home, _home_id(3), "自己的舊值不該被自己的 npc 列擋下來")


## major ①：不在世界名冊裡的 npc 列不算占用——角色離開世界後那間家釋出，
## 別的角色可以沿用（不會被舊世界的列永久占滿）
func test_home_of_character_no_longer_in_world_is_reusable() -> void:
	_insert_test_npc(TEST_NPC_PREFIX + "b", _home_id(2))

	var home: String = _persistence._resolve_home_location_for(
		_home_id(2),
		TEST_NPC_PREFIX + "a",
		{}
	)

	assert_eq(home, _home_id(2), "佔用者已不在世界，loc_home_02 應可沿用")
