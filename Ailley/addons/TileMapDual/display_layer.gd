class_name DisplayLayer
extends TileMapLayer
##[br] A single TileMapLayer whose purpose is to display tiles to maintain the Dual Grid illusion.
##[br] Its contents are automatically computed and updated based on:
##[br] - the contents of the parent TileMapDual
##[br] - the rules set in its assigned TerrainLayer

##[br] How much to offset this DisplayLayer relative to the main TileMapDual grid.
##[br] This is independent of tile size.
var offset: Vector2
## See [TileSetWatcher]
var _tileset_watcher: TileSetWatcher
## See [TerrainDual]
var _terrain: TerrainLayer


func _init(
		world: TileMapDual,
		tileset_watcher: TileSetWatcher,
		fields: Dictionary,
		layer: TerrainLayer,
) -> void:
	#print('initializing Layer...')
	update_properties(world)
	offset = fields.offset
	_tileset_watcher = tileset_watcher
	_terrain = layer
	tile_set = tileset_watcher.tile_set
	tileset_watcher.tileset_resized.connect(reposition, 1)
	reposition()


## Adjusts the position of this DisplayLayer based on the tile set's tile_size
func reposition() -> void:
	position = offset * Vector2(_tileset_watcher.tile_size)


## Copies properties from parent TileMapDual to child display tilemap
func update_properties(parent: TileMapDual) -> void:
	# Both tilemaps must be the same, so we copy all relevant properties
	# Tilemap
	# already covered by parent._tileset_watcher
	# Rendering
	self.y_sort_origin = parent.y_sort_origin
	self.x_draw_order_reversed = parent.x_draw_order_reversed
	self.rendering_quadrant_size = parent.rendering_quadrant_size
	# Physics
	# LOCAL PATCH (Ailley): deliberately NOT copying collision_enabled.
	#
	# Upstream puts collision on this DisplayLayer, which sits half a tile offset
	# from the world grid. That is fine for a normal platformer, but this project
	# pathfinds on a cell-based A* grid aligned to the WORLD layer -- probing a
	# world-cell centre lands on a display-tile corner, so an agent-sized circle
	# touches up to 4 display tiles at once. Measured: 25 open cells wrongly
	# reported as blocked.
	#
	# Collision therefore comes from the world layer only, whose footprint was
	# measured to match the painted walls exactly (177 wall cells, 0 gaps,
	# 0 false obstacles). See note/30-技術架構/TileMapDual 雙層碰撞.md
	#
	# Trade-off: this assumes the world layer's terrain marker tiles carry the
	# collision polygons. Move collision to display-only tiles and there will be
	# none at all.
	self.collision_enabled = false
	self.use_kinematic_bodies = parent.use_kinematic_bodies
	self.collision_visibility_mode = parent.collision_visibility_mode
	# Navigation
	self.navigation_enabled = parent.navigation_enabled
	self.navigation_visibility_mode = parent.navigation_visibility_mode
	# Canvas item properties
	self.show_behind_parent = parent.show_behind_parent
	self.top_level = parent.top_level
	self.light_mask = parent.light_mask
	self.visibility_layer = parent.visibility_layer
	self.y_sort_enabled = parent.y_sort_enabled
	self.modulate = parent.modulate
	self.self_modulate = parent.self_modulate
	# NOTE: parent material takes priority over the current shaders,
	# causing the world tiles to show up
	self.use_parent_material = parent.use_parent_material

	# Save any manually introduced Material change:
	self.material = parent.display_material


## Updates all display tiles to reflect the current changes.
func update_tiles_all(cache: TileCache) -> void:
	update_tiles(cache, cache.cells.keys())


## Update all display tiles affected by the world cells
func update_tiles(cache: TileCache, updated_world_cells: Array) -> void:
	#push_warning('updating tiles')
	var already_updated := Set.new()
	for path: Array in _terrain.display_to_world_neighborhood:
		path = path.map(Util.reverse_neighbor)
		for world_cell: Vector2i in updated_world_cells:
			var display_cell: Vector2i = follow_path(world_cell, path)
			if already_updated.insert(display_cell):
				update_tile(cache, display_cell)


## Updates a specific world cell.
func update_tile(cache: TileCache, cell: Vector2i) -> void:
	var get_cell_at_path: Callable = func(
			path,
	):
		return cache.get_terrain_at(follow_path(cell, path))
	var terrain_neighbors: Array = _terrain.display_to_world_neighborhood.map(get_cell_at_path)
	var mapping: Dictionary = _terrain.apply_rule(terrain_neighbors, cell)
	var sid: int = mapping.sid
	var tile: Vector2i = mapping.tile
	set_cell(cell, sid, tile)


## Finds the neighbor of a given cell by following a path of CellNeighbors
func follow_path(cell: Vector2i, path: Array) -> Vector2i:
	for neighbor: TileSet.CellNeighbor in path:
		cell = get_neighbor_cell(cell, neighbor)
	return cell
