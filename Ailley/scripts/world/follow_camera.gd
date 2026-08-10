extends Camera2D

## 跟隨鏡頭。預設跟著玩家，選取別的角色時改跟著他（見 world/selection.gd）。
##
## 跟隨是每幀對齊對象的座標，不是掛在對方底下 —— 掛父子關係換對象要 reparent，
## 而且鏡頭會跟著對方一起被移除。
## 換對象時的平滑是 Camera2D 自己的 position_smoothing，這裡不另外插值。
##
## 邊界在 _ready 依 TileMap 的實際範圍算出來，而不是寫死在場景裡 ——
## 地圖會一直擴建，寫死的座標遲早過期（PlaceAnchors 就吃過這個虧）。

## 邊界往外放寬幾格。0 表示鏡頭剛好貼齊地圖邊緣
@export var margin_cells := 0

var _target: Node2D = null


func _ready() -> void:
	add_to_group("follow_camera")
	_apply_limits()

	follow_player()
	if _target != null:
		# 開場直接就位，否則第一幀會從地圖原點滑過來
		global_position = _target.global_position
		reset_smoothing()

# 鏡頭跟著誰
func follow(target: Node2D) -> void:
	_target = target

func follow_player() -> void:
	_target = get_tree().get_first_node_in_group("player") as Node2D

func get_target() -> Node2D:
	return _target

# 跟隨對象是在 _physics_process 裡移動的，這裡用同一個節奏對齊，
# 免得永遠慢一幀
func _physics_process(_delta: float) -> void:
	if _target == null:
		return

	# 對象離場了就退回玩家，鏡頭不會卡在一個沒有人的地方
	if not is_instance_valid(_target):
		follow_player()
		return

	global_position = _target.global_position

func _apply_limits() -> void:
	var tile_map := _find_tile_map()
	if tile_map == null:
		push_warning("FollowCamera: 場景裡找不到 TileMapLayer，不設邊界")
		return

	var cell := Vector2(tile_map.tile_set.tile_size)
	var used := tile_map.get_used_rect().grow(margin_cells)

	# map_to_local 回傳的是格中心，要退半格才是地圖的左上角
	var top_left := tile_map.to_global(tile_map.map_to_local(used.position)) - cell * 0.5
	var span := Vector2(used.size) * cell

	limit_left = int(top_left.x)
	limit_top = int(top_left.y)
	limit_right = int(top_left.x + span.x)
	limit_bottom = int(top_left.y + span.y)

# 只找 TileMapDual 那一層（世界層）。生成的顯示層偏移半格，拿它算邊界會差半格
func _find_tile_map() -> TileMapLayer:
	for node in get_tree().current_scene.find_children("*", "TileMapDual", true, false):
		return node

	for node in get_tree().current_scene.find_children("*", "TileMapLayer", true, false):
		return node

	return null
