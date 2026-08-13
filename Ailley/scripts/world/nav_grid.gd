extends Node2D

## A* 尋徑網格。
## 可走性是用物理查詢量出來的，不是讀 tile data，所以 TileMapDual 的 dual-grid
## 半格位移不影響結果，之後手動丟進場景的 StaticBody2D 也會自動被算成障礙。

## 開場的第一次建置是非同步的，太早呼叫 find_path() 只會拿到空路徑。
## 要在開場就尋徑的角色（例如依行程表出發的 Agent）先等這個訊號。
signal grid_built

const INVALID_CELL := Vector2i(-2147483648, -2147483648)
const BUILD_ATTEMPTS := 10		# 開場等地形碰撞就位的重試次數

@export var tile_map: TileMapLayer		# 讀 tile_size 與使用範圍；留空則自動找同層的
@export var agent_radius := 6.0			# 對應 Player 的 CircleShape2D
@export var collision_mask := 1			# 對應 TileSet 的 physics_layer_0/collision_layer
@export var region_margin := 2			# 網格比 tilemap 使用範圍多留幾格

var astar := AStarGrid2D.new()
var solid_count := 0
var built := false			# 開場的第一次建置是否已完成

func _ready() -> void:
	add_to_group("nav_grid")
	if tile_map == null:
		tile_map = _find_sibling_tile_map()

	# TileMapDual 的顯示層是執行時生成的，地形碰撞體不會在第一幀就進到物理空間；
	# 場景裡手動放的 StaticBody2D（workstation、vending_machine 等）則從第一幀就是
	# 實體，掃到障礙不代表地形也就位了——「掃到就停」在有這種靜態物件時會太早 break。
	# 改成連續兩次掃到同樣的 solid_count 才停：地形填完後計數會穩定下來，
	# 靜態物件從頭到尾都算在計數裡，不需要另外區分來源。
	var previous_solid := -1
	for attempt in BUILD_ATTEMPTS:
		await get_tree().physics_frame
		rebuild()
		if solid_count == previous_solid:
			break
		previous_solid = solid_count

	built = true
	grid_built.emit()

# 角色本身也是碰撞體，掃格時要排除，否則玩家腳下那格會被當成障礙
func _actor_body_rids() -> Array[RID]:
	var rids: Array[RID] = []
	var scene := get_tree().current_scene
	for type in ["CharacterBody2D", "RigidBody2D"]:
		for node in scene.find_children("*", type, true, false):
			rids.append(node.get_rid())
	return rids

# 只找同層的兄弟節點：TileMapDual 執行時生成的顯示層是它的子節點，不會被誤抓
func _find_sibling_tile_map() -> TileMapLayer:
	for sibling in get_parent().get_children():
		if sibling is TileMapLayer:
			return sibling
	return null

# 重建整張網格。改完地圖後可以直接呼叫，不用重開遊戲
func rebuild() -> void:
	if tile_map == null:
		push_error("NavGrid: tile_map 未設定")
		return

	astar.clear()
	astar.region = tile_map.get_used_rect().grow(region_margin)
	astar.cell_size = Vector2(tile_map.tile_set.tile_size)
	astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	astar.default_compute_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	astar.default_estimate_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	astar.update()

	# 用玩家大小的圓去試每一格，貼牆的格子才會被正確排除
	var shape := CircleShape2D.new()
	shape.radius = agent_radius

	var query := PhysicsShapeQueryParameters2D.new()
	query.shape = shape
	query.collision_mask = collision_mask
	query.collide_with_areas = false
	query.exclude = _actor_body_rids()

	var space := get_world_2d().direct_space_state
	var region := astar.region
	solid_count = 0

	for y in range(region.position.y, region.end.y):
		for x in range(region.position.x, region.end.x):
			var cell := Vector2i(x, y)
			query.transform = Transform2D(0.0, cell_to_world(cell))
			if not space.intersect_shape(query, 1).is_empty():
				astar.set_point_solid(cell, true)
				solid_count += 1

	print("NavGrid: region=", region, " solid=", solid_count)

# 回傳世界座標的路徑點；找不到路徑時回傳空陣列
func find_path(from: Vector2, to: Vector2) -> PackedVector2Array:
	var goal_cell := world_to_cell(to)
	var start := nearest_free_cell(world_to_cell(from))
	var goal := nearest_free_cell(goal_cell)

	if start == INVALID_CELL or goal == INVALID_CELL:
		return PackedVector2Array()

	var cells := astar.get_id_path(start, goal)
	if cells.is_empty():
		return PackedVector2Array()

	var points := PackedVector2Array()
	for cell in cells:
		points.append(cell_to_world(cell))

	# 終點格本來就可走的話，直接走到指定的精確座標
	if goal == goal_cell:
		points[points.size() - 1] = to

	return points

func cell_to_world(cell: Vector2i) -> Vector2:
	return tile_map.to_global(tile_map.map_to_local(cell))

func world_to_cell(pos: Vector2) -> Vector2i:
	return tile_map.local_to_map(tile_map.to_local(pos))

func is_cell_free(cell: Vector2i) -> bool:
	return astar.is_in_boundsv(cell) and not astar.is_point_solid(cell)

# 目標落在牆裡或網格外時，往外一圈一圈找最近的可走格
func nearest_free_cell(cell: Vector2i, max_radius := 8) -> Vector2i:
	if is_cell_free(cell):
		return cell

	for radius in range(1, max_radius + 1):
		for y in range(-radius, radius + 1):
			for x in range(-radius, radius + 1):
				# 只掃這一圈的外框
				if absi(x) != radius and absi(y) != radius:
					continue
				var candidate := cell + Vector2i(x, y)
				if is_cell_free(candidate):
					return candidate

	return INVALID_CELL
