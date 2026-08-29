extends CanvasLayer

## 右側角色側欄：列出地圖上所有 Character（縮圖＋名稱），底部「新增角色」開角色庫。
##
## 面板結構在 side_bar.tscn 裡排好（錨點＋ailley_theme.tres 的 SideBarButton
## 樣式變體），這支腳本只接訊號、管展開/收合、刷新清單，不再用程式碼組節點。
## 縮圖借用角色本身 AnimatedSprite2D 當下那一幀（character.gd 的
## _current_frame_texture() 同一招，但那支是私有方法，這裡自己重算一次）。
##
## 點右邊 Tab 按鈕（toggle_mode）展開/收合，Esc 收合。按鈕跟面板是同一個
## HBoxContainer，靠 Tween 整組水平滑動——收合時只有 Tab 貼著螢幕邊緣，面板
## 部分滑到畫面外（viewport 天然裁掉，不用另外設 clip_contents）。開合的目標
## x 座標直接讀 Button／PanelContainer 在場景裡設好的 custom_minimum_size 算，
## 不在這裡另外寫一份寬度常數跟場景重複。清單只在展開當下 _refresh() 一次，
## 跟 character_library.gd 的 open() 同一種「開啟時刷新、不即時跟蹤」，不額外接訊號。

const VIEWPORT_W := 640
const SLIDE_TIME := 0.2

const THUMB_SIZE := 24

const BARK := Color("2F2522")
const CLAY := Color("75593C")

@onready var _control: Control = $Control
@onready var _tab_button: Button = $Control/HBoxContainer/Button
@onready var _panel: PanelContainer = $Control/HBoxContainer/PanelContainer
@onready var _list: VBoxContainer = $Control/HBoxContainer/PanelContainer/MarginContainer/VBoxContainer/ScrollContainer/List
@onready var _add_button: Button = $Control/HBoxContainer/PanelContainer/MarginContainer/VBoxContainer/AddButton

var _closed_x: float
var _open_x: float
var _tween: Tween


func _ready() -> void:
	_closed_x = VIEWPORT_W - _tab_button.custom_minimum_size.x
	_open_x = VIEWPORT_W - (_tab_button.custom_minimum_size.x + _panel.custom_minimum_size.x)
	_control.position.x = _closed_x
	_tab_button.toggled.connect(_on_toggled)
	_add_button.pressed.connect(_on_add_pressed)


func _unhandled_input(event: InputEvent) -> void:
	if not _tab_button.button_pressed:
		return
	if event.is_action_pressed("ui_cancel"):
		_close()
		get_viewport().set_input_as_handled()


func _on_toggled(expanded: bool) -> void:
	if expanded:
		_refresh()
	_slide_to(_open_x if expanded else _closed_x)


func _close() -> void:
	_tab_button.set_pressed_no_signal(false)
	_slide_to(_closed_x)


func _slide_to(target_x: float) -> void:
	# 收合中途又展開（或反過來）要打斷上一個 Tween，不然兩個 tween_property
	# 疊加會互相搶控制權，滑到一半卡住或抖動
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = create_tween()
	_tween.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	_tween.tween_property(_control, "position:x", target_x, SLIDE_TIME)


func _refresh() -> void:
	# remove_child() 先讓子節點立刻脫離樹，queue_free() 才真的釋放記憶體——
	# 只呼叫 queue_free() 要等到幀尾，character_library.gd 同一個坑
	for child in _list.get_children():
		_list.remove_child(child)
		child.queue_free()

	var characters: Array[Character] = []
	for node in get_tree().get_nodes_in_group("characters"):
		if node is Character:
			characters.append(node)

	if characters.is_empty():
		var empty := Label.new()
		empty.text = "UI_CS_EMPTY"
		empty.add_theme_color_override("font_color", CLAY)
		_list.add_child(empty)
		return

	for character in characters:
		_list.add_child(_row(character))


## row 本身是 HBoxContainer，靠 gui_input 偵測點擊——跟 status_panel.gd 點世界
## 角色同一種判斷方式。刻意不包 Button：Button 不是 Container，不會照子節點
## 內容自動撐開大小，縮圖＋名稱包在裡面會讓可點擊範圍跟看到的範圍對不上
func _row(character: Character) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.gui_input.connect(_on_row_gui_input.bind(character))

	var thumb := TextureRect.new()
	thumb.custom_minimum_size = Vector2(THUMB_SIZE, THUMB_SIZE)
	thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	thumb.texture = _thumbnail(character)
	thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(thumb)

	var name_label := Label.new()
	name_label.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	name_label.text = character.character_name
	name_label.add_theme_color_override("font_color", BARK)
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(name_label)

	return row


## 點列表裡的角色，鏡頭跟著他——走 Selection（world/selection.gd）同一套
## 選取機制，不繞過去直接呼叫 FollowCamera，這樣 _selected／描邊那些狀態
## 才會跟世界地圖上點角色是同一回事，不會兩邊各自一套。側欄本身留著不收合，
## 方便連續點好幾個角色比較
func _on_row_gui_input(event: InputEvent, character: Character) -> void:
	if not (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT):
		return
	if not is_instance_valid(character):
		return
	var selection := get_tree().get_first_node_in_group("selection") as Selection
	if selection == null:
		push_error("CharacterSidebar: 找不到 Selection")
		return
	selection.select(character)


func _thumbnail(character: Character) -> Texture2D:
	var sprite := character.sprite
	if sprite.sprite_frames == null or sprite.animation == &"":
		return null
	if not sprite.sprite_frames.has_animation(sprite.animation):
		return null
	return sprite.sprite_frames.get_frame_texture(sprite.animation, sprite.frame)


func _on_add_pressed() -> void:
	var panel := get_tree().get_first_node_in_group("character_create_panel")
	if panel == null:
		push_error("CharacterSidebar: 找不到 character_create_panel")
		return
	_close()
	panel.open()
