extends Node2D

## 遊戲中的除錯疊圖，由主控台的 debug 指令開關。
##
## 每一項獨立開關而不是一個總開關 —— 全部同時畫會糊成一片，
## 而且座標文字在格子多的時候特別吵。

const GRID_COLOR := Color(1, 1, 1, 0.18)
const SOLID_COLOR := Color(1, 0.35, 0.35, 0.28)
const PATH_COLOR := Color(0.3, 1, 0.55, 0.9)
const LABEL_COLOR := Color(1, 1, 1, 0.55)
const VISION_COLOR := Color(0.3, 0.7, 1.0, 0.6)
const VISION_FILL := Color(0.3, 0.7, 1.0, 0.12)
const LABEL_FONT_SIZE := 5
const PATH_POINT_RADIUS := 1.2

## 項目名稱 -> 是否開啟。加一項就在這裡加一行，指令的清單與補完會自己跟上
var layers := {
	"grid": false,			# tile 網格線
	"coord": false,			# 每格的格座標
	"solid": false,			# NavGrid 判定為障礙的格
	"path": false,			# 角色目前的 A* 路徑
	"vision": false,		# 角色的視野範圍與目前看得到誰
	"collision": false,		# 碰撞形狀（走 Godot 自己的除錯繪製）
}


func _ready() -> void:
	# set_process(false) 要在 build guard 之前、對兩種建置都生效（CodeRabbit
	# review 抓到）：腳本定義了 _process() 就預設會被引擎打開，正式建置提早
	# return 的話這行永遠不會跑到，變成每幀白白呼叫 queue_redraw()
	set_process(false)

	# 正式建置關閉（正式版玩家可見的 AI 狀態呈現方式待 issue #1020 落地）。
	# 唯一的呼叫端是 debug_console.gd 的 debug
	# 指令，主控台自己已經在正式建置整個關掉，這裡不加入 group 是防禦性的
	# 第二道——之後任何地方誤用 get_first_node_in_group("debug_overlay") 都會
	# 拿到 null，不會意外把疊圖叫出來
	if not OS.is_debug_build():
		return

	add_to_group("debug_overlay")

# 路徑每幀都在變，開著的時候就持續重畫；全關就不要浪費每幀
func _process(_delta: float) -> void:
	queue_redraw()

func is_on(layer: String) -> bool:
	return layers.get(layer, false)

func set_layer(layer: String, on: bool) -> void:
	if not layers.has(layer):
		return

	layers[layer] = on

	# 碰撞形狀不是我們自己畫的，是叫 Godot 把它本來就有的除錯繪製打開
	if layer == "collision":
		_apply_collision(on)

	set_process(layers.values().has(true))
	queue_redraw()

func toggle(layer: String) -> bool:
	set_layer(layer, not is_on(layer))
	return is_on(layer)

# CollisionShape2D 的除錯繪製看的是 SceneTree 的旗標，改完要叫它們重畫一次；
# TileMap 的碰撞則是另一套獨立的 visibility mode
func _apply_collision(on: bool) -> void:
	get_tree().debug_collisions_hint = on

	var scene := get_tree().current_scene
	for shape in scene.find_children("*", "CollisionShape2D", true, false):
		shape.queue_redraw()

	var mode := (
		TileMapLayer.DEBUG_VISIBILITY_MODE_FORCE_SHOW if on
		else TileMapLayer.DEBUG_VISIBILITY_MODE_FORCE_HIDE
	)
	for layer in scene.find_children("*", "TileMapLayer", true, false):
		layer.collision_visibility_mode = mode

func _draw() -> void:
	var nav = get_tree().get_first_node_in_group("nav_grid")
	if nav == null:
		return

	# 順序有意義：障礙填色在最底，網格線疊上去，座標最上面才讀得到
	if layers["solid"]:
		_draw_solid(nav)
	if layers["grid"]:
		_draw_grid(nav)
	if layers["coord"]:
		_draw_coords(nav)
	if layers["path"]:
		_draw_paths()
	if layers["vision"]:
		_draw_vision()

# cell_to_world() 回傳的是格中心，畫線要的是格邊界，所以要退半格
func _cell_origin(nav, cell: Vector2i) -> Vector2:
	return nav.cell_to_world(cell) - Vector2(nav.astar.cell_size) * 0.5

func _draw_grid(nav) -> void:
	var region: Rect2i = nav.astar.region
	var cell := Vector2(nav.astar.cell_size)
	var origin := _cell_origin(nav, region.position)
	var span := Vector2(region.size) * cell

	for x in range(region.size.x + 1):
		var px := origin.x + x * cell.x
		draw_line(Vector2(px, origin.y), Vector2(px, origin.y + span.y), GRID_COLOR, 1.0)

	for y in range(region.size.y + 1):
		var py := origin.y + y * cell.y
		draw_line(Vector2(origin.x, py), Vector2(origin.x + span.x, py), GRID_COLOR, 1.0)

func _draw_coords(nav) -> void:
	var region: Rect2i = nav.astar.region
	var font := ThemeDB.fallback_font

	for y in range(region.position.y, region.end.y):
		for x in range(region.position.x, region.end.x):
			var origin := _cell_origin(nav, Vector2i(x, y))
			draw_string(
				font, origin + Vector2(1, LABEL_FONT_SIZE + 1), "%d,%d" % [x, y],
				HORIZONTAL_ALIGNMENT_LEFT, -1, LABEL_FONT_SIZE, LABEL_COLOR
			)

func _draw_solid(nav) -> void:
	var region: Rect2i = nav.astar.region
	var cell := Vector2(nav.astar.cell_size)

	for y in range(region.position.y, region.end.y):
		for x in range(region.position.x, region.end.x):
			var at := Vector2i(x, y)
			if nav.is_cell_free(at):
				continue
			draw_rect(Rect2(_cell_origin(nav, at), cell), SOLID_COLOR, true)

func _draw_paths() -> void:
	for character in get_tree().get_nodes_in_group("characters"):
		var points: PackedVector2Array = character.get_path_points()
		if points.size() < 2:
			continue

		draw_polyline(points, PATH_COLOR, 1.0)
		for point in points:
			draw_circle(point, PATH_POINT_RADIUS, PATH_COLOR)

# 視野半徑畫圈，另外對「真的看得到的人」拉一條線。
# 只畫圈的話看不出視線判定有沒有生效 —— 隔著牆時圈仍然涵蓋對方，但線不會出現
func _draw_vision() -> void:
	for character in get_tree().get_nodes_in_group("characters"):
		var vision: Vision = character.vision
		if vision == null:
			continue

		# get_nodes_in_group() 回傳 Array[Node]，型別要寫明，不能靠推斷
		var center: Vector2 = character.get_body_position()
		var radius := vision.get_radius_pixels()

		draw_circle(center, radius, VISION_FILL)
		draw_arc(center, radius, 0.0, TAU, 48, VISION_COLOR, 1.0)

		for other in vision.get_visible_characters():
			draw_line(center, other.get_body_position(), VISION_COLOR, 1.0)
