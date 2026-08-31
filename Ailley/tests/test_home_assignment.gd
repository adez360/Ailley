@tool
class_name TestHomeAssignment
extends McpTestSuite

## 驗證 home 的動態供給核心（issue #391 round-robin，issue #751 動態成長）：
## 占用判斷、沿用檢查、動態成長／拆除目前零自動化覆蓋。
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
## 抓取、_grow_home_supply() 真的生成場景節點（house.tscn instantiate、
## NavGrid 落點搜尋）。這套件裡呼叫 _grow_home_supply() 只會走到「找不到
## NavGrid，回傳 Vector2.INF」那條防呆分支，驗證的是「沒有場景時不會崩潰、
## 仍回傳一個合法值」，不是真的成長行為——那個留給 project_run + game_eval
## 在編輯器裡活的場景驗證（同 test_bury.gd 的取捨）。

const PERSISTENCE_NODE_PATH := "CharacterStatePersistence"
const TEST_NPC_PREFIX := "thhome_"

var _persistence: Node = null
var _saved_cursor := -1
var _created_location_ids: Array[String] = []


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

	# 測試中可能經 _grow_home_supply()／_create_or_reactivate_home() 額外
	# 建出動態 location 列（沒有場景時不會生出場景節點，但 DB 列會留下）——
	# 清掉，不讓一次測試跑完後汙染下一輪的 _active_home_location_ids()
	for location_id in _created_location_ids:
		DatabaseManager.delete("location", "location_id = '%s'" % location_id)
	_created_location_ids.clear()

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


## 游標歸零後連續分配 5 次，拿到 01～05 全不重複，且游標剛好繞回起點
## （5 間都是靜態，issue #751 不影響這個場景）
func test_five_consecutive_assignments_cover_all_homes_without_duplicates() -> void:
	_persistence._set_home_cursor(0)

	var count: int = _persistence.STATIC_HOME_ANCHOR_COUNT
	assert_eq(count, 5, "5 間靜態家是 level.tscn 裡的永久內容（issue #391）")

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

	assert_eq(assigned.size(), count, "5 次分配應涵蓋全部 5 間靜態家")
	assert_eq(_persistence._get_home_cursor(), 0, "分配完 5 間游標應繞回 0")


## issue #751：5 間靜態家全滿時不再走溢出共用安全閥，改成呼叫
## _grow_home_supply()。這裡沒有掛場景樹，NavGrid 找不到，
## _find_home_placement() 回傳 Vector2.INF——驗證這個「沒有場景」的邊界
##情形不會讓整個分配崩潰，仍會落到「跟現有家共用」的最終防呆，回傳值
## 依然合法。真正的成長（NavGrid 找到落點、house.tscn instantiate）留給
## project_run + game_eval
func test_grow_falls_back_gracefully_without_scene() -> void:
	var all_occupied := {}
	for i in range(1, _persistence.STATIC_HOME_ANCHOR_COUNT + 1):
		all_occupied[_home_id(i)] = true

	var result: String = _persistence._assign_next_home_location(all_occupied)

	assert_true(
		_persistence._is_valid_home_location_id(result) or result.is_empty(),
		"沒有場景時的防呆結果 %s 應是合法命名或空字串（真的一間家都沒有才會是空字串）" % result
	)


## _is_valid_home_location_id() 不再有上限（issue #751 之前 loc_home_09
## 算界外值）——現在只檢查格式，DB 裡有沒有這一列是另一回事
func test_valid_id_has_no_upper_bound() -> void:
	assert_true(
		_persistence._is_valid_home_location_id("loc_home_09"),
		"loc_home_09 現在只驗格式，動態成長後沒有固定上限"
	)
	assert_true(
		_persistence._is_valid_home_location_id("loc_home_42"),
		"loc_home_42 一樣該是合法格式"
	)
	assert_false(
		_persistence._is_valid_home_location_id("home_001"),
		"舊 fallback 格式仍然無效"
	)


## _home_location_index()：靜態範圍與動態範圍的邊界判斷
func test_home_location_index_boundary() -> void:
	assert_eq(_persistence._home_location_index(_home_id(5)), 5, "loc_home_05 是編號 5")
	assert_eq(_persistence._home_location_index(_home_id(6)), 6, "loc_home_06 是編號 6")
	assert_eq(_persistence._home_location_index("home_001"), -1, "舊格式不是合法編號")


## 舊格式（issue #391 之前）寫的 home_001 這類舊值，會被視為無效、
## 重分配成新格式的 loc_home_0N
func test_legacy_format_value_is_reassigned() -> void:
	var home: String = _persistence._resolve_home_location_for(
		"home_001", TEST_NPC_PREFIX + "a", {}
	)

	assert_true(
		_persistence._is_valid_home_location_id(home),
		"舊格式 home_001 應被重分配成新格式，實際拿到 %s" % home
	)


## location 表裡沒有這一列的值（不論是格式合法但沒建過、還是純粹亂填），
## 一樣要重分配——「沿用檢查」要求格式合法＋DB 有這一列＋is_active=1 三者
## 同時成立，缺一都會落到 round-robin／成長
func test_nonexistent_value_is_reassigned() -> void:
	var home: String = _persistence._resolve_home_location_for(
		"loc_home_09", TEST_NPC_PREFIX + "a", {}
	)

	assert_true(
		_persistence._is_valid_home_location_id(home),
		"loc_home_09 在 DB 沒有這一列，應被重分配，實際拿到 %s" % home
	)


## issue #751：is_active=0（已拆除）的家，即使格式合法、DB 也查得到這一列，
## 沿用檢查仍要失敗——這是「重進不保留分配權」的核心機制，不需要另外去清
## npc.home_location_id
func test_inactive_home_is_not_reused() -> void:
	var location_id := _home_id(2)

	assert_true(
		DatabaseManager.update(
			"location", {"is_active": 0}, "location_id = '%s'" % location_id
		),
		"測試前置：把 %s 標記成 is_active=0" % location_id
	)

	var home: String = _persistence._resolve_home_location_for(
		location_id, TEST_NPC_PREFIX + "a", {}
	)

	assert_ne(home, location_id, "%s 已被標記拆除，不該沿用" % location_id)

	# 復原，不讓這個測試汙染其他測試對 loc_home_02 的假設
	DatabaseManager.update(
		"location", {"is_active": 1}, "location_id = '%s'" % location_id
	)


## 值合法、location 表也有這一列、也是 active，但已被「還在世界裡」的別人
## 佔用——不能沿用，要落到 round-robin 重分配
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
## 自己的舊值要能沿用
func test_own_npc_row_does_not_block_reuse() -> void:
	_insert_test_npc(TEST_NPC_PREFIX + "b", _home_id(2))
	_insert_test_npc(TEST_NPC_PREFIX + "a", _home_id(3))

	var home: String = _persistence._resolve_home_location_for(
		_home_id(3),
		TEST_NPC_PREFIX + "a",
		{TEST_NPC_PREFIX + "a": true, TEST_NPC_PREFIX + "b": true}
	)

	assert_eq(home, _home_id(3), "自己的舊值不該被自己的 npc 列擋下來")


## 不在世界名冊裡的 npc 列不算占用——角色離開世界後那間家釋出，
## 別的角色可以沿用（不會被舊世界的列永久占滿）
func test_home_of_character_no_longer_in_world_is_reusable() -> void:
	_insert_test_npc(TEST_NPC_PREFIX + "b", _home_id(2))

	var home: String = _persistence._resolve_home_location_for(
		_home_id(2),
		TEST_NPC_PREFIX + "a",
		{}
	)

	assert_eq(home, _home_id(2), "佔用者已不在世界，loc_home_02 應可沿用")


## _next_new_home_location_id()：取現有編號的最小缺口，不是無止盡往後加
func test_next_new_home_location_id_fills_gap() -> void:
	# 靜態 5 間（1~5）都已 seed，缺口從 6 開始
	var next_id: String = _persistence._next_new_home_location_id()
	assert_eq(next_id, _home_id(6), "5 間靜態家都在，下一個新編號應是 6")

	# 手動建一筆 loc_home_06（模擬先前成長過），下一個缺口應該是 7，不是跳號
	assert_true(
		DatabaseManager.insert("location", {
			"location_id": _home_id(6),
			"name": _home_id(6),
			"description": "",
			"location_type": "home",
			"capacity": 1,
			"danger": 0,
			"is_active": 1,
		}),
		"測試前置：建立 loc_home_06"
	)
	_created_location_ids.append(_home_id(6))

	assert_eq(
		_persistence._next_new_home_location_id(), _home_id(7),
		"loc_home_06 已存在，下一個新編號應是 7"
	)


## _reactivatable_home_location_id()：優先復活既有的 inactive 家，不開新編號
func test_reactivatable_home_prefers_existing_inactive() -> void:
	assert_true(
		DatabaseManager.insert("location", {
			"location_id": _home_id(6),
			"name": _home_id(6),
			"description": "",
			"location_type": "home",
			"capacity": 1,
			"danger": 0,
			"is_active": 0,
		}),
		"測試前置：建立已拆除（is_active=0）的 loc_home_06"
	)
	_created_location_ids.append(_home_id(6))

	assert_eq(
		_persistence._reactivatable_home_location_id(), _home_id(6),
		"應該挑到既有的 is_active=0 的 loc_home_06 來復活"
	)
