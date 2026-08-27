class_name Vision
extends Area2D

## 角色的視野：回報「現在看得到哪些角色」，不決定看到之後要做什麼。
## 反應行為留給決策層（`agent.gd`）—— 這條界線之後就是餵給 LLM 的 context.visible，
## 現在把它畫清楚，接 AI 時才不用把感知從行為裡拆出來。
##
## 從 villager 時代的視覺感測移植，但三件事刻意沒有照搬：
##
## 1. 舊版在 `_physics_process()` 裡逐目標判定，**只要看得到就每幀觸發**一次反應
##    （每幀重新呼叫 `_pause_movement(2.0)`）。這裡改成維護「目前看得到誰」的集合，
##    只在集合成員變動時發訊號 —— 反應該發生在「進入視野的那一刻」，不是持續發生。
## 2. 除錯圓圈與 D / + / - 熱鍵原本寫在角色身上。改由 `debug_overlay.gd` 的
##    `vision` 圖層畫，走既有的 `debug` 指令，遊戲實體不再帶除錯輸入。
## 3. 舊版掛一個 `RayCast2D` 節點、每幀 `force_raycast_update()`。這裡直接查
##    `direct_space_state`，不必為了一條射線多養一個節點，也不必每幀查。
##
## 場景端必須設定（刻意不寫在程式裡，免得 inspector 改了卻被程式蓋掉，
## 與 `player.tscn` / `agent.tscn` 的碰撞分層同一個理由）：
##   collision_layer = 0    視野本身不該被任何人偵測到
##   collision_mask  = 2    只看 character 層

signal spotted(other: Character)
signal lost(other: Character)

const TILE_SIZE := 16.0

## 半徑下限／上限，單位是格。0 格等於沒有視野（那應該直接移除節點），
## 太大則每次檢查要拉的射線數量會失控
const MIN_RADIUS_TILES := 1
const MAX_RADIUS_TILES := 20

## 視線檢查的間隔（現實秒）。牆不會動、角色走得也不快，每幀查是浪費；
## 0.2 秒足以讓「轉角遇到人」看起來仍是即時的
const CHECK_INTERVAL := 0.2

## 面向判定的錐角容許值：跟面向方向的內積要 >= 這個值才算「面對著」。
## 0.5 大約是 ±60 度的錐角——沿用 player.gd 的同一個值保持一致
const FACING_DOT_THRESHOLD := 0.5

@export var radius_tiles := 5:
	set(value):
		radius_tiles = clampi(value, MIN_RADIUS_TILES, MAX_RADIUS_TILES)
		_apply_radius()

## 什麼東西會擋住視線。1 = terrain，與 `nav_grid.gd` 的可走性查詢同一層。
## 角色在 layer 2，所以射線不會被別的角色擋住 —— 人不是牆
@export var blocker_mask := 1

var _character: Character = null
var _shape: CollisionShape2D = null

var _in_range: Array[Character] = []		# 在半徑內，但可能被牆擋著
var _visible: Array[Character] = []			# 扣掉被擋住的，真的看得到的
var _timer := 0.0


func _ready() -> void:
	_character = owner as Character
	if _character == null:
		push_error("Vision 所屬場景的根節點必須是 Character，目前是 %s" % owner)
		set_process(false)
		return

	_shape = get_node_or_null("CollisionShape2D")
	if _shape == null or _shape.shape == null:
		push_error("Vision %s: 缺少帶 CircleShape2D 的 CollisionShape2D 子節點" % _character.name)
		set_process(false)
		return

	# 兩隻 Agent 是同一份 agent.tscn 的 instance，CircleShape2D 是共用的 sub-resource。
	# 不 duplicate 的話調整其中一隻的視野半徑會連帶改到另一隻
	_shape.shape = _shape.shape.duplicate()
	_apply_radius()

	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)


# ---- 對外 ----

# 目前真的看得到的角色。回傳副本，呼叫端改它不會動到內部狀態
func get_visible_characters() -> Array[Character]:
	return _visible.duplicate()

func can_see(other: Character) -> bool:
	return _visible.has(other)

func get_radius_pixels() -> float:
	return radius_tiles * TILE_SIZE


# ---- 偵測 ----

# Area2D 會偵測到自己的父 CharacterBody2D，所以一定要濾掉自己 ——
# 少了這行每個角色都會回報「我看到我自己」
func _on_body_entered(body: Node2D) -> void:
	var other := body as Character
	if other == null or other == _character:
		return
	if not _in_range.has(other):
		_in_range.append(other)

func _on_body_exited(body: Node2D) -> void:
	var other := body as Character
	if other == null:
		return

	_in_range.erase(other)

	# 離開半徑等於一定看不到，不必等下一次視線檢查才發 lost
	if _visible.has(other):
		_visible.erase(other)
		lost.emit(other)

func _process(delta: float) -> void:
	_timer -= delta
	if _timer > 0.0:
		return

	_timer = CHECK_INTERVAL
	_refresh_visible()

# 重算「真的看得到誰」，並且只對進出的那幾個發訊號。
# 反著走 _in_range 是為了能安全地就地移除已經被釋放的角色 ——
# body_exited 對 queue_free() 掉的節點不保證會發
func _refresh_visible() -> void:
	var current: Array[Character] = []

	for i in range(_in_range.size() - 1, -1, -1):
		var other := _in_range[i]
		if not is_instance_valid(other):
			_in_range.remove_at(i)
			continue
		if _has_line_of_sight(other):
			current.append(other)

	for other in current:
		if not _visible.has(other):
			spotted.emit(other)

	for other in _visible:
		if is_instance_valid(other) and not current.has(other):
			lost.emit(other)

	_visible = current

# 目標是不是在視野錐體內。用面向方向與目標方向的點積判定
func _is_facing(target_pos: Vector2) -> bool:
	var to_target := target_pos - _character.get_body_position()
	if to_target == Vector2.ZERO:
		return true
	return _character.get_facing_direction().dot(to_target.normalized()) >= FACING_DOT_THRESHOLD

# 兩點之間有沒有牆。用碰撞圓心而不是 global_position —— 角色的 CollisionShape2D
# 有 y 偏移，拿節點原點拉線會從腳底下穿出去，貼牆時判定會反過來
func _has_line_of_sight(other: Character) -> bool:
	if not _is_facing(other.get_body_position()):
		return false
	var params := PhysicsRayQueryParameters2D.create(
		_character.get_body_position(), other.get_body_position(), blocker_mask
	)
	return get_world_2d().direct_space_state.intersect_ray(params).is_empty()

func _apply_radius() -> void:
	if _shape == null:
		return

	var circle := _shape.shape as CircleShape2D
	if circle != null:
		circle.radius = get_radius_pixels()
