extends Camera2D

## 跟隨玩家的鏡頭。跟隨本身是靠掛在 Player 底下達成的，這個腳本只負責邊界。
##
## 邊界在 _ready 依 TileMap 的實際範圍算出來，而不是寫死在場景裡 ——
## 地圖會一直擴建，寫死的座標遲早過期（PlaceAnchors 就吃過這個虧）。

## 邊界往外放寬幾格。0 表示鏡頭剛好貼齊地圖邊緣
@export var margin_cells := 0


func _ready() -> void:
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
