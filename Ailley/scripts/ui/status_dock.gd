extends CanvasLayer

## 左下角常駐狀態列（status_panel.tscn）：快照＋名字＋分頁按鈕，點 CollapsButton 開合。
##
## 開合不整條滑出畫面：收合時隱藏分隔線與分頁按鈕，狀態列寬度收到只剩
## 快照＋名字＋CollapsButton（仍貼著左緣），展開時還原全寬。收合寬度從
## 節點自身排好的最小尺寸算，不在這裡另外寫一份寬度常數跟場景重複。
##
## 快照與名字跟著當前選取目標（世界點擊或 sidebar 點角色都走
## Selection.select()，掛 selection_changed 訊號刷新）；沒選人時一律退回
## 顯示 player 自己，不留空值。

@onready var _bar: HBoxContainer = $HBoxContainer
@onready var _panel: PanelContainer = $HBoxContainer/TabContainer
@onready var _tab_button: Button = $HBoxContainer/CollapsButton
@onready var _snapshot: TextureRect = $HBoxContainer/TabContainer/MarginContainer/HBoxContainer/VBoxContainer/快照
@onready var _name_label: Label = $HBoxContainer/TabContainer/MarginContainer/HBoxContainer/VBoxContainer/Label
@onready var _status_button: Button = $HBoxContainer/TabContainer/MarginContainer/HBoxContainer/狀態
@onready var _expand: CanvasLayer = $StatusExpand
@onready var _expand_panel: PanelContainer = $StatusExpand/PanelContainer
@onready var _status_bars := $StatusExpand/PanelContainer/MarginContainer/VBoxContainer/StatusBars
@onready var _tabs: Array[Control] = [
	$HBoxContainer/TabContainer/MarginContainer/HBoxContainer/VSeparator,
	$HBoxContainer/TabContainer/MarginContainer/HBoxContainer/狀態,
	$HBoxContainer/TabContainer/MarginContainer/HBoxContainer/行程,
	$HBoxContainer/TabContainer/MarginContainer/HBoxContainer/Button3,
]

var _open_width: float
var _expand_rest_y: float
var _expand_tween: Tween


func _ready() -> void:
	_tab_button.toggled.connect(_on_toggled)
	_status_button.toggled.connect(_on_status_toggled)
	# 展開寬度要等容器第一輪排版才有，Selection 也可能還沒進樹，延一輪套初始狀態
	_apply_initial_state.call_deferred()


func _apply_initial_state() -> void:
	_open_width = _bar.size.x
	_expand_rest_y = _expand_panel.position.y
	_expand.visible = false
	var selection := get_tree().get_first_node_in_group("selection") as Selection
	if selection == null:
		push_error("StatusDock: 找不到 Selection")
	else:
		selection.selection_changed.connect(_on_selection_changed)
		_refresh_target(selection.get_selected())
	_apply_collapsed()	# 預設收合，只留快照＋名字


func _on_toggled(expanded: bool) -> void:
	for tab in _tabs:
		tab.visible = expanded
	if expanded:
		_bar.size.x = _open_width
		return

	# 收合時「狀態」按鈕會跟著上面那個迴圈一起被藏起來——卡片若當下是開著
	# 的，玩家會連唯一能關掉它的入口都不見，卡片因此孤兒化留在畫面上
	# （issue #940）。直接把按鈕的 button_pressed 撥回 false：BaseButton
	# 的 set_pressed()（.button_pressed 的 setter）本身就會發 toggled 訊號
	# （跟不發訊號的 set_pressed_no_signal() 是兩個方法），觸發既有的
	# _on_status_toggled(false) 收尾，不在這裡另外複製一份關卡片的動畫邏輯
	if _status_button.button_pressed:
		_status_button.button_pressed = false

	# 隱藏分頁後容器的最小寬度要等下一輪排版才穩，延一輪再收
	await get_tree().process_frame
	_bar.size.x = _panel.get_combined_minimum_size().x + _tab_button.custom_minimum_size.x


func _apply_collapsed() -> void:
	_on_toggled(false)


## 「狀態」按鈕彈出 status_panel_expand.tscn 的小卡片，從螢幕下緣往上滑；
## 面板錨點固定在螢幕底部，收起狀態就是往下位移自己的高度，直接 tween
## position:y 即可，一段位移用不著另外建 AnimationPlayer 資源
func _on_status_toggled(open: bool) -> void:
	if _expand_tween != null and _expand_tween.is_valid():
		_expand_tween.kill()
	_expand_tween = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	if open:
		_expand.visible = true
		_expand_panel.position.y = _expand_rest_y + _expand_panel.size.y
		_expand_tween.tween_property(_expand_panel, "position:y", _expand_rest_y, 0.2)
	else:
		_expand_tween.tween_property(_expand_panel, "position:y", _expand_rest_y + _expand_panel.size.y, 0.2)
		_expand_tween.finished.connect(func() -> void: _expand.visible = false)


func _on_selection_changed(character: Character) -> void:
	_refresh_target(character)


## 顯示當前選取目標，顯示方式跟 character_sidebar.gd 的 _row() 同一種：
## 縮圖借用角色 AnimatedSprite2D 當下那一幀，名字用 character_name。
## 沒選人時退回顯示 player——快照跟名字永遠有目標，不顯示空值
func _refresh_target(character: Character) -> void:
	if character == null:
		character = get_tree().get_first_node_in_group("player") as Character
	if character == null:
		push_error("StatusDock: 沒有選取對象，場景裡也找不到 player")
		return
	_snapshot.texture = _current_frame_texture(character)
	_name_label.text = character.character_name
	_status_bars.set_character(character)


func _current_frame_texture(character: Character) -> Texture2D:
	var sprite := character.sprite
	if sprite.sprite_frames == null or sprite.animation == &"":
		return null
	if not sprite.sprite_frames.has_animation(sprite.animation):
		return null
	return sprite.sprite_frames.get_frame_texture(sprite.animation, sprite.frame)
