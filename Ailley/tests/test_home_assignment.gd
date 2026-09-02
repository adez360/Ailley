@tool
class_name TestHomeAssignment
extends McpTestSuite

## 驗證 home 的動態供給核心（issue #391 round-robin，issue #825 完全動態）：
## 占用判斷、沿用檢查、動態成長／拆除的 DB 語意。
##
## 純 DatabaseManager 層寫法（跟 test_stats.gd 同一種：不掛場景樹）：
## 「世界名冊」是場景狀態不是 DB 狀態，CharacterStatePersistence 把它收成
## _resolve_home_location_for()／_occupied_home_location_ids() 的參數，測試
## 直接傳入空名冊或測試用名冊，不必造場景節點也能決定性地測占用語意。
## DB 用測試字首（thhome_）的 npc 列模擬占用，teardown 清掉；home_assignment
## 游標是共用 DB 的單一列，每個測試前保存、teardown 還原。
##
## issue #825 後地圖上沒有畫死的家，loc_home_* 也不再被開機 seed——這套件
## 每個測試自己在 setup() 塞 loc_home_01~05 當 active fixture、teardown()
## 只還原 fixture 動過的列。
##
## 例外：兩個場景相關回歸測試（CodeRabbit review on #995）需要活的場景樹——
## 測試內自掛測試用節點（假世界 Level＋PlaceAnchors／characters 群組的假
## 角色），整棵交給 track() 讓 runner 在測試後收掉；真實世界的 NavGrid
## 落點搜尋仍不在涵蓋範圍。
##
## 不在本套件涵蓋範圍：需要真場景的部分——loc_home_* 錨點、has_for()/
## resolve_for() 的 home 轉譯、_world_character_ids() 對 characters 群組的
## 抓取、_grow_home_supply() 真的生成場景節點（house_001/002 instantiate、
## NavGrid 落點搜尋、從涼亭錨點起算落點）。這套件裡呼叫 _grow_home_supply()
## 只會走到「找不到 NavGrid，回傳 Vector2.INF」那條防呆分支——真正的成長
## 留給 project_run + game_eval 在編輯器裡活的場景驗證（同 test_bury.gd 的取捨）。

const PERSISTENCE_NODE_PATH := "CharacterStatePersistence"
const TEST_NPC_PREFIX := "thhome_"

var _persistence: Node = null
var _saved_cursor := -1
var _created_location_ids: Array[String] = []
# fixture 動到的既有 loc_home_* 列，記下原本的 is_active 好在 teardown 還原——
# 不能用「一律 UPDATE ... is_active=0 WHERE location_type='home'」收尾，那會把
# 實機玩出來、跟這個 suite 無關的動態家也一起關掉（CodeRabbit review on #995）
var _fixture_prior_active: Dictionary = {}
# 同 frame 拆家測試動過 pos_x/pos_y 的既有列，記下原本座標好在 teardown
# 還原——同一批「只還原 fixture 動過的列」原則
var _fixture_prior_pos: Dictionary = {}


func suite_name() -> String:
	return "home_assignment"


func suite_setup(_ctx: Dictionary) -> void:
	_persistence = DatabaseManager.get_node_or_null(PERSISTENCE_NODE_PATH)

	if _persistence == null:
		skip_suite("找不到 DatabaseManager/%s" % PERSISTENCE_NODE_PATH)
		return

	if not DatabaseManager.is_seeded:
		skip_suite("資料庫還沒 seed 完成，無法測 location/npc 表")


## setup() 塞 loc_home_01~05 當 active fixture：issue #825 後開機不再 seed
## 這些列，但沿用／占用／round-robin 的語意測試都需要一批現成的 active 家
const FIXTURE_HOME_COUNT := 5


func setup() -> void:
	_saved_cursor = _persistence._get_home_cursor()

	for i in range(1, FIXTURE_HOME_COUNT + 1):
		var location_id := _home_id(i)
		var rows := DatabaseManager.select(
			"location", "location_id = '%s'" % location_id, ["is_active"]
		)
		if rows.is_empty():
			DatabaseManager.insert("location", {
				"location_id": location_id,
				"name": "Home %d" % i,
				"description": "",
				"location_type": "home",
				"capacity": 1,
				"danger": 0,
				"is_active": 1,
			})
			_created_location_ids.append(location_id)
		else:
			_fixture_prior_active[location_id] = int(rows[0].get("is_active", 0))
			DatabaseManager.update(
				"location", {"is_active": 1}, "location_id = '%s'" % location_id
			)


func teardown() -> void:
	DatabaseManager.delete("npc", "npc_id LIKE '%s%%'" % TEST_NPC_PREFIX)

	# 測試中經 _grow_home_supply()／_create_or_reactivate_home() 額外建出的
	# 動態 location 列（沒有場景時不會生出場景節點，但 DB 列會留下）——連同
	# setup() 自己 insert 的 fixture 一起刪
	for location_id in _created_location_ids:
		DatabaseManager.delete("location", "location_id = '%s'" % location_id)
	_created_location_ids.clear()

	# setup() 動過 is_active 的既有列還原成原值——只碰 fixture 動過的那幾列，
	# 不掃 location_type='home' 全表（會誤關實機玩出來的動態家）
	for location_id in _fixture_prior_active:
		DatabaseManager.update(
			"location",
			{"is_active": _fixture_prior_active[location_id]},
			"location_id = '%s'" % location_id
		)
	_fixture_prior_active.clear()

	# 同 frame 拆家測試動過座標的既有列還原 pos_x/pos_y——一樣只碰記錄過
	# 的那幾列
	for location_id in _fixture_prior_pos:
		DatabaseManager.update(
			"location", _fixture_prior_pos[location_id],
			"location_id = '%s'" % location_id
		)
	_fixture_prior_pos.clear()

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

## 兩個場景相關回歸測試共用的 loc_home_NN fixture：共用 DB 可能已有實機
## 玩出來的同名列——沒有就建一筆（teardown 刪掉），有就記下原值（teardown
## 還原），不假設它不存在
func _ensure_test_home(location_id: String) -> void:
	var rows := DatabaseManager.select(
		"location", "location_id = '%s'" % location_id, ["is_active", "pos_x", "pos_y"]
	)
	if rows.is_empty():
		assert_true(
			DatabaseManager.insert("location", {
				"location_id": location_id,
				"name": location_id,
				"description": "",
				"location_type": "home",
				"capacity": 1,
				"danger": 0,
				"is_active": 0,
			}),
			"測試前置：建立已拆除（is_active=0）的 %s" % location_id
		)
		_created_location_ids.append(location_id)
	else:
		_fixture_prior_active[location_id] = int(rows[0].get("is_active", 0))
		_fixture_prior_pos[location_id] = {
			"pos_x": rows[0].get("pos_x", 0.0),
			"pos_y": rows[0].get("pos_y", 0.0),
		}


## 游標歸零後連續分配 FIXTURE_HOME_COUNT 次，拿到 01～05 全不重複，且
## 游標剛好繞回起點（fixture 的 5 間都 active，沒觸發成長）
func test_consecutive_assignments_cover_active_homes_without_duplicates() -> void:
	_persistence._set_home_cursor(0)

	var assigned := {}
	for i in FIXTURE_HOME_COUNT:
		var home: String = _persistence._assign_next_home_location({})
		assert_true(
			_persistence._is_valid_home_location_id(home),
			"第 %d 次分配 %s 應是合法的 loc_home_NN 命名" % [i + 1, home]
		)
		assert_false(
			assigned.has(home),
			"第 %d 次分配 %s 不該跟前面的重複" % [i + 1, home]
		)
		assigned[home] = true

	assert_eq(assigned.size(), FIXTURE_HOME_COUNT, "應涵蓋全部 %d 間 active fixture" % FIXTURE_HOME_COUNT)
	assert_eq(_persistence._get_home_cursor(), 0, "分配完一輪游標應繞回 0")


## 現有 active 家全滿時改呼叫 _grow_home_supply()（issue #825：不犧牲每人一間）。
## 這裡沒有掛場景樹，NavGrid 找不到，_find_home_placement() 回傳 Vector2.INF
## ——驗證這個「沒有場景」的邊界情形不會讓整個分配崩潰，仍會落到「跟現有家
## 共用」的最終防呆，回傳值依然合法。真正的成長（NavGrid 找到落點、
## house_001/002 instantiate）留給 project_run + game_eval
func test_grow_falls_back_gracefully_without_scene() -> void:
	var all_occupied := {}
	for i in range(1, FIXTURE_HOME_COUNT + 1):
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


## _home_location_index()：編號解析，非法命名回傳 -1
func test_home_location_index_boundary() -> void:
	assert_eq(_persistence._home_location_index(_home_id(5)), 5, "loc_home_05 是編號 5")
	assert_eq(_persistence._home_location_index(_home_id(6)), 6, "loc_home_06 是編號 6")
	assert_eq(_persistence._home_location_index("home_001"), -1, "舊格式不是合法編號")


## _home_scene_path()：奇數編號用 house_001、偶數用 house_002
func test_home_scene_path_alternates_by_parity() -> void:
	assert_eq(
		_persistence._home_scene_path(_home_id(1)), _persistence.HOME_SCENE_ODD,
		"loc_home_01 是奇數，用 house_001"
	)
	assert_eq(
		_persistence._home_scene_path(_home_id(2)), _persistence.HOME_SCENE_EVEN,
		"loc_home_02 是偶數，用 house_002"
	)
	assert_eq(
		_persistence._home_scene_path(_home_id(7)), _persistence.HOME_SCENE_ODD,
		"loc_home_07 是奇數，用 house_001"
	)


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

	assert_ne(home, "loc_home_09", "不存在的 location 不可被直接沿用")
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
	# fixture 的 loc_home_01~05 都在，缺口從 6 開始
	var next_id: String = _persistence._next_new_home_location_id()
	assert_eq(next_id, _home_id(6), "01~05 都在，下一個新編號應是 6")

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


## 同一幀內「離場拆家 → 進場復活同一個 location_id」的回歸測試（CodeRabbit
## review on #995）：_demolish_home_scene() 用 queue_free()，節點要幀末才真正
## 離樹；拆完同幀內 _reactivatable_home_location_id() 就會挑回剛拆的 id，
## _create_or_reactivate_home() 把 DB 列標回 is_active=1 並呼叫
## _spawn_home_scene()。guard 若只看 has_node()，會撞到「還在樹上但已排刪除」
## 的舊節點提前 return——幀末殘骸釋放後，active 列就沒有任何對應的執行期
## 節點。重建出來的錨點跟房屋必須是活的（未排刪除）新節點。
func test_same_frame_demolish_then_reactivate_rebuilds_live_nodes() -> void:
	var tree := _persistence.get_tree()
	if tree == null:
		skip("測試環境沒有場景樹，無法驗證節點重建")
		return
	if tree.get_first_node_in_group("place_anchors") != null:
		skip("測試環境已有 place_anchors 節點，無法安全掛測試用假世界")
		return

	var location_id := _home_id(6)
	var house_name := "DynamicHome_%s" % location_id

	# fixture：共用 DB 可能已有實機玩出來的 loc_home_06，不假設它不存在
	_ensure_test_home(location_id)

	# 假世界：比照 level.tscn 的父子結構——Level 底下掛 PlaceAnchors
	#（place_anchors 群組）；_spawn_home_scene() 靠 anchors.get_parent() 找
	# Level 掛房屋
	var level := Node2D.new()
	level.name = "TestLevel995"
	var anchors := Node2D.new()
	anchors.name = "PlaceAnchors"
	anchors.add_to_group("place_anchors")
	level.add_child(anchors)
	tree.root.add_child(level)
	track(level)

	# 前置：這間家上一輪還在場上——先造出錨點＋房屋（_spawn_home_scene()
	# 只管場景表現，不看 DB 的 is_active）
	_persistence._spawn_home_scene(location_id, Vector2(100.0, 100.0))
	var house_before := level.get_node_or_null(NodePath(house_name))
	assert_true(
		house_before != null and not house_before.is_queued_for_deletion(),
		"測試前置：%s 應是樹上的活節點" % house_name
	)
	assert_true(
		anchors.has_node(NodePath(location_id)),
		"測試前置：PlaceAnchors 底下應有 %s 錨點" % location_id
	)

	# 離場拆家：queue_free() 之後節點要幀末才離樹，同一幀內仍在樹上——
	# 這正是 bug 的重現前提
	_persistence._demolish_home_scene(location_id)
	assert_true(
		house_before != null and house_before.is_queued_for_deletion(),
		"拆家後房屋節點應已排刪除（幀末才真正離樹）"
	)
	assert_true(
		level.has_node(NodePath(house_name)),
		"同一幀內已排刪除的節點仍在樹上（bug 重現前提）"
	)

	# 進場復活：全滿時 _grow_home_supply() 優先復活剛拆的 id——這裡直接走
	# 復活兩步，不經 _grow_home_supply()（它要 NavGrid 找落點，測試環境沒有，
	# 會提前落到溢出共用分支）
	assert_eq(
		_persistence._reactivatable_home_location_id(), location_id,
		"同幀內復活應挑回剛拆的 %s" % location_id
	)
	assert_true(
		_persistence._create_or_reactivate_home(location_id, Vector2(120.0, 100.0)),
		"復活 %s 應成功" % location_id
	)

	# 重建後：level 底下要有活的 DynamicHome_<id>（未排刪除的新節點），
	# PlaceAnchors 底下要有同名錨點，DB 列標回 is_active=1
	var house_after := level.get_node_or_null(NodePath(house_name))
	assert_true(
		house_after != null and not house_after.is_queued_for_deletion(),
		"重建後 level 底下應有活的 %s（不是排刪除的殘骸）" % house_name
	)
	assert_ne(
		house_after, house_before,
		"重建的應是新節點，不是摘出樹前的舊殘骸"
	)
	var anchor_after := anchors.get_node_or_null(NodePath(location_id))
	assert_true(
		anchor_after != null and not anchor_after.is_queued_for_deletion(),
		"重建後 PlaceAnchors 底下應有活的 %s 錨點" % location_id
	)
	var rows_after := DatabaseManager.select(
		"location", "location_id = '%s'" % location_id, ["is_active"]
	)
	assert_true(
		not rows_after.is_empty() and int(rows_after[0].get("is_active", 0)) == 1,
		"復活後 %s 應標回 is_active=1" % location_id
	)


## 溢出共用的家不能被單一退場拆掉（CodeRabbit review on #995）：
## _grow_home_supply() 的兩條溢出 fallback（找不到落點、建立／復活失敗）會把
## 第二隻角色指到現有 active 家，兩列 npc 共用同一個 home_location_id。任一隻
## 退場就把家拆掉＋is_active=0 的話，還留在世界裡那隻的
## PlaceAnchors.resolve_for() 會解析不到自己的家——_release_home_if_dynamic()
## 要先查排除自己後的占用集合，還有別人占著就不拆；最後一隻退場才照舊拆
func test_shared_home_survives_release_until_last_occupant_leaves() -> void:
	if GameManager._world_unloading:
		skip("測試環境處於世界卸載狀態，_release_home_if_dynamic() 會提前 return")
		return

	var tree := _persistence.get_tree()
	if tree == null:
		skip("測試環境沒有場景樹，無法組世界名冊")
		return
	if tree.get_nodes_in_group("characters").size() > 0:
		skip("測試環境已有 characters 群組節點，無法控制世界名冊")
		return

	var location_id := _home_id(6)
	_ensure_test_home(location_id)

	# 溢出共用：兩列 npc 指到同一個家
	_insert_test_npc(TEST_NPC_PREFIX + "x", location_id)
	_insert_test_npc(TEST_NPC_PREFIX + "y", location_id)

	# thhome_y 還在世界裡：characters 群組掛一個帶 character_id 的假角色。
	# _world_character_ids() 用 node.get("character_id") 抓 id、不轉型成
	# Character，所以一顆掛內聯腳本的 Node 就夠
	var character_script := GDScript.new()
	character_script.source_code = "@tool\nextends Node\nvar character_id := \"\""
	assert_true(
		character_script.reload() == OK,
		"測試前置：編譯假角色腳本"
	)
	var other_character := Node.new()
	other_character.set_script(character_script)
	other_character.set("character_id", TEST_NPC_PREFIX + "y")
	tree.root.add_child(other_character)
	other_character.add_to_group("characters")
	track(other_character)

	# 前置：排除自己（thhome_x）後的占用集合應含這個家
	var occupied := _persistence._occupied_home_location_ids(
		_persistence._world_character_ids(), TEST_NPC_PREFIX + "x"
	)
	assert_true(
		occupied.has(location_id),
		"測試前置：thhome_y 還在世界，%s 應算占用" % location_id
	)

	# thhome_x 退場：thhome_y 還占著，家不能拆
	_persistence._release_home_if_dynamic(TEST_NPC_PREFIX + "x")
	var rows_after := DatabaseManager.select(
		"location", "location_id = '%s'" % location_id, ["is_active"]
	)
	assert_true(
		not rows_after.is_empty() and int(rows_after[0].get("is_active", 0)) == 1,
		"共用家的另一位占用者還在，%s 不該被拆（is_active 應維持 1）" % location_id
	)
	occupied = _persistence._occupied_home_location_ids(
		_persistence._world_character_ids(), TEST_NPC_PREFIX + "x"
	)
	assert_true(
		occupied.has(location_id),
		"退場後占用集合應仍含 %s（thhome_y 還在世界）" % location_id
	)

	# thhome_y 也退場：沒有別人占用了，照舊拆掉（is_active=0）
	_persistence._release_home_if_dynamic(TEST_NPC_PREFIX + "y")
	var rows_last := DatabaseManager.select(
		"location", "location_id = '%s'" % location_id, ["is_active"]
	)
	assert_true(
		not rows_last.is_empty() and int(rows_last[0].get("is_active", 0)) == 0,
		"最後一隻退場後 %s 應照舊拆掉（is_active=0）" % location_id
	)
	occupied = _persistence._occupied_home_location_ids(
		_persistence._world_character_ids(), TEST_NPC_PREFIX + "y"
	)
	assert_false(
		occupied.has(location_id),
		"全部退場後占用集合不該再含 %s" % location_id
	)
