extends CanvasLayer

## 建角面板（規格書 05）。
##
## 版面在 640×360 下量過：最密的「個性」分頁裝得下，面板 560×344，下緣還剩 8px。
## 欄寬取 12 的倍數 —— Cubic 11 的中文字寬是 12px，不是字級的 11。
##
## 六個維度的列由 DIMENSIONS 驅動生成，不手刻六份；增減維度只要改那張表。
## 這也是整個面板在程式碼裡組、而不是把節點拉在場景裡的原因。
##
## 只負責蒐集資料，存檔時把 Dictionary 丟出 character_saved。
## hexaco → personality 的轉換、system_prompt 組句都不在這裡（規格書 01-1）。

## 使用者按下儲存且通過驗證。帶著六維數值與 character 文本
signal character_saved(data: Dictionary)
signal closed()

## 極端項 = 該滑桿 ≤25 或 ≥75（規格 4-4）
const EXTREME_LOW := 25.0
const EXTREME_HIGH := 75.0
const EXTREME_MAX := 4

## 存檔門檻依 character 有沒有填而不同：留空的話要求更多極端項，
## 否則會產生一個既沒數值特徵也沒文字描述的空角色
const EXTREME_MIN_WITH_DESC := 2
const EXTREME_MIN_WITHOUT_DESC := 3

const DEFAULT_VALUE := 50.0
const STEP := 5.0
const DESC_MAX := 250

const PANEL_SIZE := Vector2(560, 344)
const LABEL_W := 48			# 中文 4 字 @ Cubic 11
const VALUE_W := 20
const MARKER := 6

## 面板上的順序就是這張表的順序。兩端標籤的 key 是 key + _LO / _HI
const DIMENSIONS: Array[Dictionary] = [
	{"field": "hex_honesty", "key": "UI_CC_HEX_HONESTY"},
	{"field": "hex_emotionality", "key": "UI_CC_HEX_EMOTIONALITY"},
	{"field": "hex_extraversion", "key": "UI_CC_HEX_EXTRAVERSION"},
	{"field": "hex_agreeableness", "key": "UI_CC_HEX_AGREEABLENESS"},
	{"field": "hex_conscientiousness", "key": "UI_CC_HEX_CONSCIENTIOUSNESS"},
	{"field": "hex_openness", "key": "UI_CC_HEX_OPENNESS"},
]

const BARK := Color("2F2522")
const LOAM := Color("5D4A38")
const CLAY := Color("75593C")
const CREAM := Color("FAF3E8")
const AMBER := Color("C96C23")
const INK := Color("1A1512")
const MOSS := Color("5D6145")
const EMBER := Color("8B1F14")
const HONEY := Color("F0A94E")

const GRABBER := preload("res://assets/ui/slider_grabber.png")

var _sliders: Array[HSlider] = []
var _value_labels: Array[Label] = []
var _markers: Array[ColorRect] = []
var _slots_label: Label
var _strength_label: Label
var _hint_label: Label
var _desc_edit: TextEdit
var _desc_count: Label
var _save_button: Button

var _deployed := 2
var _deploy_max := 3

## 極端時蓋掉 theme 的 grabber_area。用 override 而不是 theme variation，
## 因為 variation 必須註冊 base type，而那只有編輯器 UI 做得到
var _ember_fill: StyleBoxFlat


func _ready() -> void:
	layer = 80
	_ember_fill = _flat(EMBER, 2)
	_build()
	_refresh_all()
	close()

func _notification(what: int) -> void:
	# 主控台的 locale 指令可以在執行期換語系，程式碼組出來的字串要自己重算
	if what == NOTIFICATION_TRANSLATION_CHANGED and _slots_label != null:
		_refresh_all()

func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		close()
		get_viewport().set_input_as_handled()


func open() -> void:
	visible = true

func close() -> void:
	visible = false
	closed.emit()

## 目前的面板內容，欄位名對應規格書 06 的資料欄位表
func collect() -> Dictionary:
	var data := {}
	for i in DIMENSIONS.size():
		data[DIMENSIONS[i]["field"]] = int(_sliders[i].value)
	data["character"] = _desc_edit.text.strip_edges()
	return data


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

	col.add_child(_header())
	col.add_child(_rule(CLAY))
	col.add_child(_tabs())
	col.add_child(_rule(BARK))
	col.add_child(_slider_block())
	col.add_child(_strength_block())
	col.add_child(_description_block())
	col.add_child(_footer())


func _header() -> Control:
	var row := HBoxContainer.new()
	var title := Label.new()
	title.text = "UI_CC_TITLE"			# Control 的 text 填 key 會自動翻譯
	title.add_theme_color_override("font_color", BARK)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(title)

	_slots_label = Label.new()
	_slots_label.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_slots_label.add_theme_color_override("font_color", LOAM)
	row.add_child(_slots_label)
	return row

func _tabs() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 2)
	var keys := ["UI_CC_TAB_BASIC", "UI_CC_TAB_PERSONALITY", "UI_CC_TAB_APPEARANCE"]
	for i in keys.size():
		var b := Button.new()
		b.text = keys[i]
		b.custom_minimum_size.x = 60
		if i == 1:
			# 目前只有「個性」有內容；另外兩頁的規格分別在 §3 與 §5【待規劃】
			b.add_theme_stylebox_override("normal", _flat(AMBER, 3, 8))
			b.add_theme_color_override("font_color", INK)
		else:
			b.disabled = true
		row.add_child(b)
	return row

func _slider_block() -> Control:
	var block := VBoxContainer.new()
	block.add_theme_constant_override("separation", 4)
	for i in DIMENSIONS.size():
		block.add_child(_slider_row(i))
	return block

func _slider_row(index: int) -> Control:
	var key: String = DIMENSIONS[index]["key"]
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	row.add_child(_fixed_label(key, BARK, LABEL_W))
	row.add_child(_fixed_label(key + "_LO", CLAY, LABEL_W))

	var slider := HSlider.new()
	slider.min_value = 0
	slider.max_value = 100
	slider.step = STEP
	slider.value = DEFAULT_VALUE
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	slider.add_theme_icon_override("grabber", GRABBER)
	slider.add_theme_icon_override("grabber_highlight", GRABBER)
	slider.value_changed.connect(_on_slider_changed.bind(index))
	row.add_child(slider)
	_sliders.append(slider)

	row.add_child(_fixed_label(key + "_HI", CLAY, LABEL_W))

	var value := Label.new()
	value.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	value.custom_minimum_size.x = VALUE_W
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(value)
	_value_labels.append(value)

	var marker := ColorRect.new()
	marker.color = EMBER
	marker.custom_minimum_size = Vector2(MARKER, MARKER)
	marker.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(marker)
	_markers.append(marker)
	return row

func _strength_block() -> Control:
	var block := VBoxContainer.new()
	block.add_theme_constant_override("separation", 2)

	_strength_label = Label.new()
	_strength_label.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_strength_label.add_theme_color_override("font_color", BARK)
	block.add_child(_strength_label)

	_hint_label = Label.new()
	_hint_label.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	block.add_child(_hint_label)
	return block

func _description_block() -> Control:
	var block := VBoxContainer.new()
	block.add_theme_constant_override("separation", 2)

	var head := HBoxContainer.new()
	var caption := Label.new()
	caption.text = "UI_CC_DESC"
	caption.add_theme_color_override("font_color", BARK)
	caption.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(caption)

	_desc_count = Label.new()
	_desc_count.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_desc_count.add_theme_color_override("font_color", LOAM)
	head.add_child(_desc_count)
	block.add_child(head)

	_desc_edit = TextEdit.new()
	_desc_edit.custom_minimum_size.y = 60
	_desc_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_desc_edit.text_changed.connect(_on_description_changed)
	block.add_child(_desc_edit)

	var hint := Label.new()
	hint.text = "UI_CC_DESC_HINT"
	hint.add_theme_color_override("font_color", CLAY)
	block.add_child(hint)
	return block

func _footer() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)

	var random := Button.new()
	random.text = "UI_CC_BTN_RANDOM"
	random.pressed.connect(_on_random_pressed)
	row.add_child(random)

	_save_button = Button.new()
	_save_button.text = "UI_CC_BTN_SAVE"
	_save_button.add_theme_stylebox_override("normal", _flat(AMBER, 3, 8))
	_save_button.add_theme_stylebox_override("hover", _flat(HONEY, 3, 8))
	_save_button.add_theme_color_override("font_color", INK)
	_save_button.add_theme_color_override("font_hover_color", INK)
	_save_button.pressed.connect(_on_save_pressed)
	row.add_child(_save_button)
	return row


func _on_slider_changed(_value: float, index: int) -> void:
	_refresh_slider(index)
	_refresh_strength()

func _on_description_changed() -> void:
	# TextEdit 沒有 max_length，只能自己截。截字時游標會跳到開頭，所以要記回去
	if _desc_edit.text.length() > DESC_MAX:
		var caret := _desc_edit.get_caret_column()
		_desc_edit.text = _desc_edit.text.substr(0, DESC_MAX)
		_desc_edit.set_caret_column(mini(caret, DESC_MAX))
	_refresh_description()
	_refresh_strength()

func _on_random_pressed() -> void:
	# 隨機但保證落在可存檔區間：先全部置中，再挑 2 個推向兩端
	for slider in _sliders:
		slider.value = DEFAULT_VALUE
	var picks := range(DIMENSIONS.size())
	picks.shuffle()
	for i in picks.slice(0, EXTREME_MIN_WITH_DESC + 1):
		_sliders[i].value = (randi_range(0, 4) * STEP) if randf() < 0.5 else (100.0 - randi_range(0, 4) * STEP)
	_refresh_all()

func _on_save_pressed() -> void:
	if not _can_save():
		return
	character_saved.emit(collect())


func _extreme_count() -> int:
	var n := 0
	for slider in _sliders:
		if slider.value <= EXTREME_LOW or slider.value >= EXTREME_HIGH:
			n += 1
	return n

func _extreme_min() -> int:
	var has_desc := not _desc_edit.text.strip_edges().is_empty()
	return EXTREME_MIN_WITH_DESC if has_desc else EXTREME_MIN_WITHOUT_DESC

func _can_save() -> bool:
	var n := _extreme_count()
	return n >= _extreme_min() and n <= EXTREME_MAX


func _refresh_all() -> void:
	_slots_label.text = L10n.tf("UI_CC_SLOTS", {"used": _deployed, "max": _deploy_max})
	for i in _sliders.size():
		_refresh_slider(i)
	_refresh_description()
	_refresh_strength()

func _refresh_slider(index: int) -> void:
	var slider := _sliders[index]
	var extreme: bool = slider.value <= EXTREME_LOW or slider.value >= EXTREME_HIGH
	_value_labels[index].text = str(int(slider.value))
	_value_labels[index].add_theme_color_override("font_color", EMBER if extreme else BARK)
	_markers[index].visible = extreme
	if extreme:
		slider.add_theme_stylebox_override("grabber_area", _ember_fill)
	else:
		slider.remove_theme_stylebox_override("grabber_area")

func _refresh_description() -> void:
	_desc_count.text = L10n.tf("UI_CC_DESC_COUNT", {"n": _desc_edit.text.length(), "max": DESC_MAX})
	if _desc_edit.placeholder_text.is_empty():
		_desc_edit.placeholder_text = "\n".join([
			L10n.t("UI_CC_DESC_PH1"), L10n.t("UI_CC_DESC_PH2"), L10n.t("UI_CC_DESC_PH3")
		])

func _refresh_strength() -> void:
	var n := _extreme_count()
	var required := _extreme_min()
	var dots := "●".repeat(n) + "○".repeat(maxi(0, EXTREME_MAX - n))
	_strength_label.text = "%s  %s   %d / %d" % [L10n.t("UI_CC_STRENGTH"), dots, n, EXTREME_MAX]

	if n < required:
		_hint_label.text = L10n.tf("UI_CC_STRENGTH_LOW", {"n": required - n})
		_hint_label.add_theme_color_override("font_color", EMBER)
	elif n > EXTREME_MAX:
		_hint_label.text = L10n.tf("UI_CC_STRENGTH_HIGH", {"n": n - EXTREME_MAX})
		_hint_label.add_theme_color_override("font_color", HONEY)
	else:
		_hint_label.text = L10n.t("UI_CC_STRENGTH_OK")
		_hint_label.add_theme_color_override("font_color", MOSS)

	_save_button.disabled = not _can_save()


func _fixed_label(key: String, colour: Color, width: int) -> Label:
	var l := Label.new()
	l.text = key
	l.custom_minimum_size.x = width
	l.add_theme_color_override("font_color", colour)
	return l

func _rule(colour: Color) -> Control:
	var r := ColorRect.new()
	r.color = colour
	r.custom_minimum_size.y = 1
	return r

func _flat(bg: Color, vertical: int, horizontal: int = 0) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = bg
	box.content_margin_top = vertical
	box.content_margin_bottom = vertical
	box.content_margin_left = horizontal
	box.content_margin_right = horizontal
	return box
