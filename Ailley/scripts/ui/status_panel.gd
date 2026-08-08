class_name StatusPanel
extends CanvasLayer

## 點選角色彈出的狀態表：姓名、年齡、飢餓、口渴、體力。
## 點角色本體開啟，再點一次空白處或按 Esc 關閉。
##
## 場景結構是這份腳本的合約，改路徑要兩邊一起改：
##   CanvasLayer（本腳本）
##     Panel
##       VBox
##         NameLabel / AgeLabel / HungerLabel / ThirstLabel / EnergyLabel / HintLabel
##
## 點擊偵測用物理查詢而不是逐一比對角色座標，跟 nav_grid.gd／vision.gd
## 同一個理由：不必為了滑鼠多養一個 Area2D，也不必每幀查。
## mask=2 是「character」碰撞層，見 技術/Character 基底與 Agent 的分層表。
const CHARACTER_MASK := 2

@onready var panel: Panel = $Panel
@onready var name_label: Label = $Panel/VBox/NameLabel
@onready var age_label: Label = $Panel/VBox/AgeLabel
@onready var hunger_label: Label = $Panel/VBox/HungerLabel
@onready var thirst_label: Label = $Panel/VBox/ThirstLabel
@onready var energy_label: Label = $Panel/VBox/EnergyLabel
@onready var hint_label: Label = $Panel/VBox/HintLabel


func _ready() -> void:
	panel.hide()
	hint_label.text = L10n.t("UI_STATUS_CLOSE_HINT")

func _unhandled_input(event: InputEvent) -> void:
	if panel.visible and event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		close()
		get_viewport().set_input_as_handled()
		return

	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var character := _pick_character(event.position)
		if character != null:
			open(character)
		elif panel.visible:
			close()

# event.position 是螢幕座標（CanvasLayer 沒有 global_position 可用），
# 拿 canvas_transform 的反矩陣還原成世界座標，鏡頭有跟隨時才不會點錯地方
func _pick_character(screen_pos: Vector2) -> Character:
	var world_pos := get_viewport().canvas_transform.affine_inverse() * screen_pos

	var params := PhysicsPointQueryParameters2D.new()
	params.position = world_pos
	params.collision_mask = CHARACTER_MASK
	params.collide_with_areas = false

	var space := get_viewport().world_2d.direct_space_state
	for hit in space.intersect_point(params, 4):
		if hit["collider"] is Character:
			return hit["collider"]

	return null

func open(character: Character) -> void:
	name_label.text = _line("UI_STATUS_NAME", character.character_name)
	age_label.text = _line("UI_STATUS_AGE", str(character.age))

	var has_stats := character.stats != null
	hunger_label.visible = has_stats
	thirst_label.visible = has_stats
	energy_label.visible = has_stats
	if has_stats:
		hunger_label.text = _stat_line(character.stats, "hunger")
		thirst_label.text = _stat_line(character.stats, "thirst")
		energy_label.text = _stat_line(character.stats, "energy")

	panel.show()

func close() -> void:
	panel.hide()

func _line(label_key: String, value: String) -> String:
	return "%s：%s" % [L10n.t(label_key), value]

func _stat_line(stats: Stats, key: String) -> String:
	return _line(Stats.SPEC[key]["label"], str(int(stats.get_value(key))))
