extends CanvasLayer

## 右側角色側欄：列出地圖上所有 Character（縮圖＋名稱），底部「新增角色」開角色庫。
##
## 跟 character_library.gd 同一種「面板在程式碼裡組」寫法與同一組色票——這裡也還沒有
## 立繪素材，縮圖借用角色本身 AnimatedSprite2D 當下那一幀（character.gd 的
## _current_frame_texture() 同一招，但那支是私有方法，這裡自己重算一次）。
##
## 點右邊 Tab 按鈕展開/收合，Esc 收合。清單只在展開當下 _refresh() 一次，跟
## character_library.gd 的 open() 同一種「開啟時刷新、不即時跟蹤」，不額外接訊號。

const VIEWPORT_W := 640
const VIEWPORT_H := 360
const TAB_SIZE := Vector2(20, 40)
const PANEL_WIDTH := 140
const THUMB_SIZE := 24

const BARK := Color("2F2522")
const CLAY := Color("75593C")
const CREAM := Color("FAF3E8")
const AMBER := Color("C96C23")
const INK := Color("1A1512")

var _expanded := false
var _tab_button: Button
var _panel: PanelContainer
var _list: VBoxContainer


func _ready() -> void:
	_build()
	_set_expanded(false)


func _unhandled_input(event: InputEvent) -> void:
	if not _expanded:
		return
	if event.is_action_pressed("ui_cancel"):
		_set_expanded(false)
		get_viewport().set_input_as_handled()


func _build() -> void:
	_tab_button = Button.new()
	_tab_button.custom_minimum_size = TAB_SIZE
	_tab_button.position = Vector2(VIEWPORT_W - TAB_SIZE.x, (VIEWPORT_H - TAB_SIZE.y) / 2.0)
	_tab_button.add_theme_stylebox_override("normal", _flat(CLAY))
	_tab_button.add_theme_color_override("font_color", CREAM)
	_tab_button.pressed.connect(func(): _set_expanded(not _expanded))
	add_child(_tab_button)

	_panel = PanelContainer.new()
	_panel.position = Vector2(VIEWPORT_W - PANEL_WIDTH - TAB_SIZE.x, 0)
	_panel.size = Vector2(PANEL_WIDTH, VIEWPORT_H)
	add_child(_panel)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	_panel.add_child(col)

	var title := Label.new()
	title.text = "UI_CS_TITLE"
	title.add_theme_color_override("font_color", BARK)
	col.add_child(title)

	var rule := ColorRect.new()
	rule.color = CLAY
	rule.custom_minimum_size.y = 1
	col.add_child(rule)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(scroll)

	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 2)
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_list)

	var add_button := Button.new()
	add_button.text = "UI_CS_BTN_ADD"
	add_button.add_theme_stylebox_override("normal", _flat(AMBER, 3, 8))
	add_button.add_theme_color_override("font_color", INK)
	add_button.pressed.connect(_on_add_pressed)
	col.add_child(add_button)


func _set_expanded(expanded: bool) -> void:
	_expanded = expanded
	_panel.visible = expanded
	# 語言無關的箭頭符號，不走 L10n——跟 character_library.gd 的按鈕文字不同，
	# 這裡不是句子，是純方向指示
	_tab_button.text = "▶" if expanded else "◀"
	if expanded:
		_refresh()


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


func _row(character: Character) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)

	var thumb := TextureRect.new()
	thumb.custom_minimum_size = Vector2(THUMB_SIZE, THUMB_SIZE)
	thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	thumb.texture = _thumbnail(character)
	row.add_child(thumb)

	var name_label := Label.new()
	name_label.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	name_label.text = character.character_name
	name_label.add_theme_color_override("font_color", BARK)
	row.add_child(name_label)

	return row


func _thumbnail(character: Character) -> Texture2D:
	var sprite := character.sprite
	if sprite.sprite_frames == null or sprite.animation == &"":
		return null
	if not sprite.sprite_frames.has_animation(sprite.animation):
		return null
	return sprite.sprite_frames.get_frame_texture(sprite.animation, sprite.frame)


func _on_add_pressed() -> void:
	var panel := get_tree().get_first_node_in_group("character_library_panel")
	if panel == null:
		push_error("CharacterSidebar: 找不到 character_library_panel")
		return
	_set_expanded(false)
	panel.open()


func _flat(bg: Color, vertical: int = 4, horizontal: int = 4) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = bg
	box.content_margin_top = vertical
	box.content_margin_bottom = vertical
	box.content_margin_left = horizontal
	box.content_margin_right = horizontal
	return box
