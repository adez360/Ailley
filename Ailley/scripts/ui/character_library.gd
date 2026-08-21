extends CanvasLayer

## 角色庫首頁（規格書 05 §7-1，issue #122）。
##
## 列出 GameManager.character_library 裡「已建立‧未投放」與已投放的角色，
## 提供編輯（僅未投放者）／刪除／投放／複製四個操作。沒有立繪縮圖與六維
## 雷達圖——素材與繪圖元件都還沒有，MVP 用一行文字摘要代替，跟 status_panel.gd
## 的 StatsBox／hotbar.gd 同一種「資料變動時動態長出 Row、不在場景裡手排」寫法。
##
## 跟建角面板一樣獨立 CanvasLayer，open()/close()，Esc 關閉。「＋」按鈕與
## 「編輯」都是切去建角面板（用 group 找到它，兩個面板不用互相持節點參照），
## 這裡自己則隱藏，不疊在建角面板上面。

signal closed()

const PANEL_SIZE := Vector2(560, 260)
const ROW_HEIGHT := 12

const BARK := Color("2F2522")
const LOAM := Color("5D4A38")
const CLAY := Color("75593C")
const CREAM := Color("FAF3E8")
const AMBER := Color("C96C23")
const INK := Color("1A1512")
const MOSS := Color("5D6145")
const EMBER := Color("8B1F14")

## 六維欄位縮寫，跟 character_create.gd 的 DIMENSIONS 同一組欄位，只是這裡
## 只需要簡短的摘要文字，不需要那張表驅動整排 UI
const HEXACO_ABBR: Array[Dictionary] = [
	{"field": "hex_honesty", "short": "H"},
	{"field": "hex_emotionality", "short": "E"},
	{"field": "hex_extraversion", "short": "X"},
	{"field": "hex_agreeableness", "short": "A"},
	{"field": "hex_conscientiousness", "short": "C"},
	{"field": "hex_openness", "short": "O"},
]

var _list: VBoxContainer
var _capacity_label: Label


func _ready() -> void:
	layer = 79
	add_to_group("character_library_panel")
	_build()
	close()

func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()


func open() -> void:
	_refresh()
	visible = true

func close() -> void:
	visible = false
	closed.emit()


func _build() -> void:
	var scrim := ColorRect.new()
	scrim.color = Color(0.10, 0.08, 0.07, 0.55)
	scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(scrim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	scrim.add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = PANEL_SIZE
	center.add_child(panel)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	panel.add_child(col)

	var header := HBoxContainer.new()
	var title := Label.new()
	title.text = "UI_CL_TITLE"
	title.add_theme_color_override("font_color", BARK)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	_capacity_label = Label.new()
	_capacity_label.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_capacity_label.add_theme_color_override("font_color", LOAM)
	header.add_child(_capacity_label)
	col.add_child(header)

	var rule := ColorRect.new()
	rule.color = CLAY
	rule.custom_minimum_size.y = 1
	col.add_child(rule)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.y = 180
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(scroll)

	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 2)
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_list)

	var footer := HBoxContainer.new()
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(spacer)
	var new_button := Button.new()
	new_button.text = "UI_CL_BTN_NEW"
	new_button.add_theme_stylebox_override("normal", _flat(AMBER, 3, 8))
	new_button.add_theme_color_override("font_color", INK)
	new_button.pressed.connect(_on_new_pressed)
	footer.add_child(new_button)
	col.add_child(footer)


func _refresh() -> void:
	_capacity_label.text = L10n.tf("UI_CL_CAPACITY", {
		"used": GameManager.character_library.size(), "max": GameManager.CHARACTER_LIBRARY_CAP,
	})

	# remove_child() 先讓子節點立刻脫離樹，queue_free() 才真的釋放記憶體——
	# 只呼叫 queue_free() 的話要等到幀尾，連續刷新兩次（例如刪除後緊接著
	# 投放）舊列還沒真的消失，新列就疊上去了。同一個坑 vending_menu.gd 踩過
	for child in _list.get_children():
		_list.remove_child(child)
		child.queue_free()

	if GameManager.character_library.is_empty():
		var empty := Label.new()
		empty.text = "UI_CL_EMPTY"
		empty.add_theme_color_override("font_color", CLAY)
		_list.add_child(empty)
		return

	for entry in GameManager.character_library:
		_list.add_child(_row(entry))


func _row(entry: Dictionary) -> Control:
	var deployed: bool = entry.get("deployed", false)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)

	var name_label := Label.new()
	name_label.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	name_label.text = str(entry.get("character_name", ""))
	name_label.custom_minimum_size.x = 80
	name_label.add_theme_color_override("font_color", BARK)
	row.add_child(name_label)

	var summary := Label.new()
	summary.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	summary.text = _hexaco_summary(entry.get("hexaco", {}))
	summary.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	summary.add_theme_color_override("font_color", LOAM)
	row.add_child(summary)

	var source_label := Label.new()
	source_label.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	source_label.text = str(entry.get("decision_source", ""))
	source_label.custom_minimum_size.x = 40
	source_label.add_theme_color_override("font_color", LOAM)
	row.add_child(source_label)

	var status_label := Label.new()
	status_label.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	status_label.text = L10n.t("UI_CL_DEPLOYED") if deployed else ""
	status_label.custom_minimum_size.x = 40
	status_label.add_theme_color_override("font_color", MOSS)
	row.add_child(status_label)

	var id: String = entry.get("id", "")

	var edit_button := Button.new()
	edit_button.text = "UI_CL_BTN_EDIT"
	edit_button.disabled = deployed		# 已投放的不可編輯（規格書 05 §7-1）
	edit_button.pressed.connect(_on_edit_pressed.bind(id))
	row.add_child(edit_button)

	var duplicate_button := Button.new()
	duplicate_button.text = "UI_CL_BTN_DUPLICATE"
	duplicate_button.disabled = GameManager.character_library.size() >= GameManager.CHARACTER_LIBRARY_CAP
	duplicate_button.pressed.connect(_on_duplicate_pressed.bind(id))
	row.add_child(duplicate_button)

	var deploy_button := Button.new()
	deploy_button.text = "UI_CL_BTN_DEPLOY"
	deploy_button.disabled = deployed
	deploy_button.pressed.connect(_on_deploy_pressed.bind(id))
	row.add_child(deploy_button)

	var delete_button := Button.new()
	delete_button.text = "UI_CL_BTN_DELETE"
	delete_button.disabled = deployed		# 已投放的不能刪（見 GameManager.remove_from_library()）
	delete_button.add_theme_color_override("font_color", EMBER)
	delete_button.pressed.connect(_on_delete_pressed.bind(id))
	row.add_child(delete_button)

	return row

func _hexaco_summary(hexaco: Dictionary) -> String:
	var parts: Array[String] = []
	for entry in HEXACO_ABBR:
		parts.append("%s%d" % [entry["short"], int(hexaco.get(entry["field"], 50))])
	return " ".join(parts)


func _on_new_pressed() -> void:
	var panel := get_tree().get_first_node_in_group("character_create_panel")
	if panel == null:
		push_error("CharacterLibrary: 找不到 character_create_panel")
		return
	close()
	panel.open()

func _on_edit_pressed(id: String) -> void:
	var panel := get_tree().get_first_node_in_group("character_create_panel")
	if panel == null:
		push_error("CharacterLibrary: 找不到 character_create_panel")
		return
	close()
	panel.edit(id)

func _on_duplicate_pressed(id: String) -> void:
	GameManager.duplicate_library_entry(id)
	_refresh()

func _on_deploy_pressed(id: String) -> void:
	# deploy_from_library() 回 null 有三種原因（查無此紀錄／已投放／世界投放
	# 上限已滿），原本只印 push_warning，玩家在畫面上完全看不到任何反應
	# （CodeRabbit review 抓到）。沿用既有的 _capacity_label 顯示位置，
	# 不用另外開一塊 UI——下次 _refresh() 會把它蓋回正常的容量文字
	if GameManager.deploy_from_library(id) == null:
		_capacity_label.text = L10n.t("UI_CL_DEPLOY_FAILED")
		_capacity_label.add_theme_color_override("font_color", EMBER)
		return
	_capacity_label.remove_theme_color_override("font_color")
	_refresh()

func _on_delete_pressed(id: String) -> void:
	GameManager.remove_from_library(id)
	_refresh()


func _flat(bg: Color, vertical: int, horizontal: int = 0) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = bg
	box.content_margin_top = vertical
	box.content_margin_bottom = vertical
	box.content_margin_left = horizontal
	box.content_margin_right = horizontal
	return box
