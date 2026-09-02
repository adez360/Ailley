extends CanvasLayer

## 右側角色側欄：列出地圖上所有 Character（縮圖＋名稱），底部「新增角色」開角色庫。
##
## 面板結構在 side_bar.tscn 裡排好（錨點＋ailley_theme.tres 的 SideBarButton
## 樣式變體）。清單裡每一列的縮圖＋名稱是 character_row.tscn 的實例；「收回」
## 鈕是程式碼組的（見 _row()），跟 character_row.tscn 的 Button 包成兄弟節點
## 而不是子節點，避免 Button 包 Button 吃掉點擊。
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

const ROW_SCENE := preload("res://scenes/ui/character_row.tscn")

const CLAY := Color("75593C")

@onready var _control: Control = $Control
@onready var _tab_button: Button = $Control/HBoxContainer/Button
@onready var _panel: PanelContainer = $Control/HBoxContainer/PanelContainer
@onready var _list: VBoxContainer = $Control/HBoxContainer/PanelContainer/MarginContainer/VBoxContainer/ScrollContainer/List
@onready var _add_button: Button = $Control/HBoxContainer/PanelContainer/MarginContainer/VBoxContainer/AddButton

var _closed_x: float
var _open_x: float
var _tween: Tween

var _row_collapsed_height: float = 0.0


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


## 一列是 character_row.tscn 的實例（toggle_mode 的 Button，內含縮圖＋名稱＋
## 展開卡）＋一顆「收回」鈕，包成 HBoxContainer 當兄弟節點——不要把收回鈕塞
## 進 character_row.tscn 的 Button 裡面當子節點，那會撞上 character_create.gd
## 模板列已經踩過的坑（Button 包 Button 會吃掉子按鈕的點擊，見該檔案
## _template_row() 的說明）。character_row.tscn 本身的內容（縮圖＋名稱＋展開卡）
## 要調外觀去改那份場景，不要在
## 這裡再寫一套組節點的程式碼
func _row(character: Character) -> Control:
	var row: Button = ROW_SCENE.instantiate()
	var thumb: TextureRect = row.get_node("MarginContainer/HBoxContainer/Thumb")
	thumb.texture = _thumbnail(character)
	var name_label: Label = row.get_node("MarginContainer/HBoxContainer/Label")
	name_label.text = character.character_name
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_row_collapsed_height = row.custom_minimum_size.y
	var expand: Control = row.get_node("Expand")
	expand.set_character(character)
	row.toggled.connect(_on_row_toggled.bind(character, row, expand))

	# 收回（issue #974）：目前化身角色與已死亡角色不能收回
	# （GameManager.recall_from_library() 本來就會拒絕，這裡先 disable 讓玩家
	# 一眼看出來，不用點了才發現失敗）
	var recall_button := Button.new()
	recall_button.text = "UI_CS_BTN_RECALL"
	recall_button.focus_mode = Control.FOCUS_NONE
	recall_button.disabled = character.is_dead or character.character_id == GameManager.embodied_character_id
	recall_button.pressed.connect(_on_recall_pressed.bind(character))

	var wrapper := HBoxContainer.new()
	wrapper.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wrapper.add_child(row)
	wrapper.add_child(recall_button)
	return wrapper


## row 是 toggle 按鈕，每一列各自獨立開關，可以同時展開好幾列比較。按下（切
## 到展開）當下鏡頭跟著這個角色——走 Selection（world/selection.gd）同一套
## 選取機制，不繞過去直接呼叫 FollowCamera，這樣 _selected／描邊那些狀態
## 才會跟世界地圖上點角色是同一回事。收合不動選取，只有按下那一刻才切鏡頭。
## 展開高度直接讀 Expand（status_bars.tscn 實例）排版後的最小高度，不在這裡
## 另外寫一份數字跟場景重複
func _on_row_toggled(pressed: bool, character: Character, row: Button, expand: Control) -> void:
	if not is_instance_valid(character):
		return
	expand.visible = pressed
	if pressed:
		row.custom_minimum_size.y = expand.position.y + expand.get_combined_minimum_size().y
		var selection := get_tree().get_first_node_in_group("selection") as Selection
		if selection == null:
			push_error("CharacterSidebar: 找不到 Selection")
		else:
			selection.select(character)
	else:
		row.custom_minimum_size.y = _row_collapsed_height


## 收回（issue #974）：GameManager.recall_from_library() 把肉體 queue_free()、
## 角色庫紀錄的 deployed 改回 false。成功後這個角色就從「在場角色」清單消失，
## 靠 _refresh() 重新掃 characters 分組反映，不用自己從 _list 裡挑一列刪
func _on_recall_pressed(character: Character) -> void:
	if not is_instance_valid(character):
		return
	GameManager.recall_from_library(character.character_id)
	_refresh()


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
