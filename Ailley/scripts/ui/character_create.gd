extends CanvasLayer

## 建角面板（規格書 05）。
##
## 版面在 640×360 下量過：最密的「個性」分頁裝得下，面板 560×344，下緣還剩 8px。
## 欄寬取 12 的倍數 —— Cubic 11 的中文字寬是 12px，不是字級的 11。
##
## 六個維度的列由 DIMENSIONS 驅動生成，不手刻六份；增減維度只要改那張表。
## 這也是整個面板在程式碼裡組、而不是把節點拉在場景裡的原因。分頁 1／3 的
## 選項清單（GENDERS／DECISION_SOURCES）同一個理由，也是表驅動。
##
## 只負責蒐集資料，存檔時把 Dictionary 丟出 character_saved，交給
## GameManager.receive_created_character() 接手存檔驗證→角色生成→角色庫
## 那段管線（規格書 05 流程圖）。hexaco → personality 的轉換、system_prompt
## 組句都不在這裡（規格書 01-1）。
##
## 開 open() 是「建立新角色」；開 edit(id) 是把角色庫既有的一筆（僅未投放者，
## 由角色庫首頁自己保證）灌回面板欄位，存檔時走「原地覆蓋」而不是新增一筆。

## 使用者按下儲存且通過驗證。帶著六維數值、character 文本，與分頁 1／3 的欄位
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

const NAME_MAX := 12
const AGE_MIN := 16
const AGE_MAX := 70
const AGE_DEFAULT := 30

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

const GENDERS: Array[Dictionary] = [
	{"value": "male", "key": "UI_CC_GENDER_MALE"},
	{"value": "female", "key": "UI_CC_GENDER_FEMALE"},
	{"value": "other", "key": "UI_CC_GENDER_OTHER"},
]

## 對應《12》的 DecisionProvider 三種 MVP 實作（規格書 05 §3-1）。human 目前
## 沒有實作（decision_provider.gd 明講「HumanInput 留給之後的 issue」），但
## 選它是合法的——agent.gd::_make_provider() 會安靜退回 LocalLLMProvider，
## 不是這裡要擋的錯誤資料
const DECISION_SOURCES: Array[Dictionary] = [
	{"value": "local", "key": "UI_CC_SOURCE_LOCAL"},
	{"value": "cloud", "key": "UI_CC_SOURCE_CLOUD"},
	{"value": "human", "key": "UI_CC_SOURCE_HUMAN"},
]

## MVP 造型組（規格書 05 §5-0）：6 套現在長得一樣，只給編號與純色塊區分，
## 不拿同一張圖 modulate 六色充數——實際 appearance[] 內容待《99》P-38 填
const STYLE_COUNT := 6

const BARK := Color("2F2522")
const LOAM := Color("5D4A38")
const CLAY := Color("75593C")
const WHEAT := Color("D9C49A")
const CREAM := Color("FAF3E8")
const AMBER := Color("C96C23")
const INK := Color("1A1512")
const MOSS := Color("5D6145")
const EMBER := Color("8B1F14")
const HONEY := Color("F0A94E")
const ASH := Color("7E8A93")

## 造型組色塊，刻意不用 AMBER/HONEY——那兩色是選中狀態的強調色，
## 拿來當底色會讓「這格被選中」跟「這格本來就這個顏色」分不清楚
const STYLE_COLORS: Array[Color] = [LOAM, CLAY, WHEAT, MOSS, EMBER, ASH]

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

var _tab_buttons: Array[Button] = []
var _tab_pages: Array[Control] = []

var _name_edit: LineEdit
var _age_slider: HSlider
var _age_value_label: Label
var _gender_buttons: Array[Button] = []
var _gender_selected := "other"

var _source_buttons: Array[Button] = []
var _decision_source := "human"
var _model_dropdown: OptionButton
var _model_name := ""
var _model_hint: Label
var _decision_source_container: Control

## 六維滑桿與強度計數兩個區塊（issue #372），化身者模式一起隱藏——強度計數
## 純粹是滑桿極端項的統計，滑桿藏起來的話這個數字沒有意義可看
var _slider_block_container: Control
var _strength_block_container: Control

## 分頁 2 的隨機按鈕列。化身者模式一併隱藏——滑桿藏起來後這顆按鈕只改六顆
## 看不見的滑桿，按了沒有任何可見變化卻默默改寫 collect() 會存進角色庫的
## hexaco 值（issue #372，#371 接上 UI 入口前的潛伏問題）。分頁 3 的隨機鈕
## 不用藏：造型組在化身者模式下照常要選
var _personality_random_row: Control

## true 時面板走化身者模式：決策來源、六維人格滑桿對玩家都沒有意義，一併
## 隱藏（issue #372，見 _refresh_all()）——玩家自己操控角色，不需要選
## LLM 決策來源，也不需要靠六維滑桿描述「這個角色的個性」，那是給 AI
## 讀的行為準則來源。隱藏的同時 _can_save() 也要跳過極端項門檻（見那邊
## 的說明），不然滑桿摸不到、門檻卻還在擋，會變成存不了檔。
## 目前唯一的入口是 open(as_player=true)，還沒有任何按鈕會傳這個值——
## UI 上「由我操控」的選項本身待後續視覺任務接上（issue #371）
var _embodiment_mode := false

var _style_buttons: Array[Button] = []
var _style_selected := -1

## 編輯既有角色庫項目時記著它的 id，儲存時原地覆蓋而不是新增一筆；
## 空字串代表「建立新角色」。見 edit()
var _editing_id := ""

## 極端時蓋掉 theme 的 grabber_area。用 override 而不是 theme variation，
## 因為 variation 必須註冊 base type，而那只有編輯器 UI 做得到
var _ember_fill: StyleBoxFlat


func _ready() -> void:
	layer = 80
	add_to_group("character_create_panel")	# character_library.gd 用這個找到面板，開 edit()
	_ember_fill = _flat(EMBER, 2)
	_build()
	character_saved.connect(GameManager.receive_created_character)
	_reset_fields()
	_refresh_all()
	close()

func _notification(what: int) -> void:
	# 主控台的 locale 指令可以在執行期換語系，程式碼組出來的字串要自己重算
	if what == NOTIFICATION_TRANSLATION_CHANGED and _slots_label != null:
		_refresh_all()

func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()


## 建立新角色。上一次編輯／建立留下的欄位一律清空，這個面板沒有「暫存草稿」
## 的語意——見 close()。as_player=true 是化身者模式（issue #372）：決策來源
## 對玩家沒有意義，_refresh_all() 會把那個區塊藏起來
func open(as_player: bool = false) -> void:
	_editing_id = ""
	_reset_fields()
	_embodiment_mode = as_player
	_refresh_all()
	visible = true

## 把角色庫既有的一筆（呼叫端保證是未投放者，規格書 05 §7-1）灌回面板欄位。
## 找不到就安靜地什麼都不做——呼叫端（角色庫首頁）給的 id 應該永遠有效，
## 找不到代表上一輪操作已經把它刪了，不是這裡該報錯的情況。編輯一律走
## AI 角色模式（沒有 as_player 參數）——化身者是否可編輯不在這則範圍內
func edit(id: String) -> void:
	var entry := GameManager.get_library_entry(id)
	if entry.is_empty():
		return
	_editing_id = id
	_load_entry(entry)
	_embodiment_mode = false
	_refresh_all()
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
	data["character_name"] = _name_edit.text.strip_edges()
	data["age"] = int(_age_slider.value)
	data["gender"] = _gender_selected
	data["decision_source"] = _decision_source
	data["model_name"] = _model_name
	# appearance[] 的實際內容（item_id／label）待《99》P-38 填，MVP 只驗證
	# 「有沒有選」（_can_save() 那關），不在這裡假造內容
	data["appearance"] = []
	if not _editing_id.is_empty():
		data["id"] = _editing_id
	return data


func _reset_fields() -> void:
	_name_edit.text = ""
	_age_slider.value = AGE_DEFAULT
	_gender_selected = "other"
	for slider in _sliders:
		slider.value = DEFAULT_VALUE
	_desc_edit.text = ""
	_style_selected = -1
	_apply_default_decision_source()

func _load_entry(entry: Dictionary) -> void:
	_name_edit.text = str(entry.get("character_name", ""))
	_age_slider.value = int(entry.get("age", AGE_DEFAULT))
	_gender_selected = str(entry.get("gender", "other"))
	var hexaco: Dictionary = entry.get("hexaco", {})
	for i in DIMENSIONS.size():
		_sliders[i].value = hexaco.get(DIMENSIONS[i]["field"], DEFAULT_VALUE)
	_desc_edit.text = str(entry.get("character", ""))
	# appearance[] 內容本來就是空的（P-38 待填），沒有索引可以還原選中哪一格——
	# 編輯外觀分頁時強制重選，不是這裡少寫了什麼
	_style_selected = -1
	_decision_source = str(entry.get("decision_source", "human"))
	_model_name = str(entry.get("model_name", ""))

## 決策來源預設值（規格書 05 §3-1）：有可用的本機 provider 就預選本機
## （優先 AIConfig.default_provider 指到的那個，不是本機或不可用就退回本機
## 清單第一個）；否則退到真人——不退到雲端，那會變成預設幫玩家選一個
## 會產生帳單的選項
func _apply_default_decision_source() -> void:
	var locals := _providers_by_locality(true)
	if locals.is_empty():
		_decision_source = "human"
		_model_name = ""
		return

	_decision_source = "local"
	var config := AIService.config
	var default_provider: AIConfig.Provider = config.get_provider("") if config != null else null
	if default_provider != null and default_provider.valid and _is_local_url(default_provider.base_url):
		_model_name = default_provider.model
	else:
		_model_name = locals[0].model


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

	_tab_pages.append(_build_tab_basic())
	_tab_pages.append(_build_tab_personality())
	_tab_pages.append(_build_tab_appearance())
	for page in _tab_pages:
		col.add_child(page)

	col.add_child(_footer())
	_switch_tab(0)


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
		b.pressed.connect(_switch_tab.bind(i))
		row.add_child(b)
		_tab_buttons.append(b)
	return row

func _switch_tab(index: int) -> void:
	for i in _tab_pages.size():
		_tab_pages[i].visible = (i == index)
	for i in _tab_buttons.size():
		var b := _tab_buttons[i]
		if i == index:
			b.add_theme_stylebox_override("normal", _flat(AMBER, 3, 8))
			b.add_theme_color_override("font_color", INK)
		else:
			b.remove_theme_stylebox_override("normal")
			b.remove_theme_color_override("font_color")


## 分頁 1：基本資料 + 決策來源（規格書 05 §3、§3-1）
func _build_tab_basic() -> Control:
	var block := VBoxContainer.new()
	block.add_theme_constant_override("separation", 6)

	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", 8)
	name_row.add_child(_fixed_label("UI_CC_NAME", BARK, LABEL_W))
	_name_edit = LineEdit.new()
	_name_edit.max_length = NAME_MAX		# LineEdit 原生支援，不像 TextEdit 要自己截
	_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name_edit.text_changed.connect(_on_name_changed)
	name_row.add_child(_name_edit)
	block.add_child(name_row)

	var age_row := HBoxContainer.new()
	age_row.add_theme_constant_override("separation", 8)
	age_row.add_child(_fixed_label("UI_CC_AGE", BARK, LABEL_W))
	_age_slider = HSlider.new()
	_age_slider.min_value = AGE_MIN
	_age_slider.max_value = AGE_MAX
	_age_slider.step = 1
	_age_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_age_slider.add_theme_icon_override("grabber", GRABBER)
	_age_slider.add_theme_icon_override("grabber_highlight", GRABBER)
	_age_slider.value_changed.connect(_on_age_changed)
	age_row.add_child(_age_slider)
	_age_value_label = Label.new()
	_age_value_label.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_age_value_label.custom_minimum_size.x = VALUE_W
	_age_value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	age_row.add_child(_age_value_label)
	block.add_child(age_row)

	var gender_row := HBoxContainer.new()
	gender_row.add_theme_constant_override("separation", 8)
	gender_row.add_child(_fixed_label("UI_CC_GENDER", BARK, LABEL_W))
	for entry in GENDERS:
		var b := Button.new()
		b.text = entry["key"]
		b.pressed.connect(_on_gender_pressed.bind(entry["value"]))
		gender_row.add_child(b)
		_gender_buttons.append(b)
	block.add_child(gender_row)

	block.add_child(_rule(CLAY))
	block.add_child(_decision_source_block())
	return block

func _decision_source_block() -> Control:
	var block := VBoxContainer.new()
	block.add_theme_constant_override("separation", 4)
	_decision_source_container = block

	var label_row := HBoxContainer.new()
	label_row.add_child(_fixed_label("UI_CC_SOURCE", BARK, LABEL_W))
	block.add_child(label_row)

	var source_row := HBoxContainer.new()
	source_row.add_theme_constant_override("separation", 4)
	for entry in DECISION_SOURCES:
		var b := Button.new()
		b.text = entry["key"]
		b.pressed.connect(_on_source_pressed.bind(entry["value"]))
		source_row.add_child(b)
		_source_buttons.append(b)
	block.add_child(source_row)

	_model_dropdown = OptionButton.new()
	_model_dropdown.item_selected.connect(_on_model_selected)
	block.add_child(_model_dropdown)

	_model_hint = Label.new()
	_model_hint.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_model_hint.add_theme_color_override("font_color", EMBER)
	block.add_child(_model_hint)

	return block


## 分頁 2：個性（六維滑桿 + 強度計數 + 自我描述），內容不變，只是搬進獨立分頁
func _build_tab_personality() -> Control:
	var block := VBoxContainer.new()
	block.add_theme_constant_override("separation", 4)
	_slider_block_container = _slider_block()
	block.add_child(_slider_block_container)
	_strength_block_container = _strength_block()
	block.add_child(_strength_block_container)
	block.add_child(_description_block())
	_personality_random_row = _random_button_row(_on_random_personality_pressed)
	block.add_child(_personality_random_row)
	return block

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


## 分頁 3：造型組挑選（規格書 05 §5-0，MVP 佔位）
func _build_tab_appearance() -> Control:
	var block := VBoxContainer.new()
	block.add_theme_constant_override("separation", 4)

	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 4)
	grid.add_theme_constant_override("v_separation", 4)

	for i in STYLE_COUNT:
		var cell := VBoxContainer.new()

		var swatch := Button.new()
		swatch.custom_minimum_size = Vector2(48, 48)
		swatch.text = str(i + 1)
		swatch.pressed.connect(_on_style_pressed.bind(i))
		cell.add_child(swatch)
		_style_buttons.append(swatch)

		var name_label := Label.new()
		name_label.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
		name_label.text = L10n.tf("UI_CC_STYLE_NAME", {"n": i + 1})
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		cell.add_child(name_label)

		grid.add_child(cell)

	block.add_child(grid)

	var hint := Label.new()
	hint.text = "UI_CC_STYLE_HINT"
	hint.add_theme_color_override("font_color", CLAY)
	block.add_child(hint)
	block.add_child(_random_button_row(_on_random_appearance_pressed))
	return block


## 隨機按鈕不放這裡（issue #676）：改成分頁 2／3 各自一顆，見 _random_button_row()。
## 這個 footer 現在只有存檔鍵
func _footer() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)

	_save_button = Button.new()
	_save_button.text = "UI_CC_BTN_SAVE"
	_save_button.add_theme_stylebox_override("normal", _flat(AMBER, 3, 8))
	_save_button.add_theme_stylebox_override("hover", _flat(HONEY, 3, 8))
	_save_button.add_theme_color_override("font_color", INK)
	_save_button.add_theme_color_override("font_hover_color", INK)
	_save_button.pressed.connect(_on_save_pressed)
	row.add_child(_save_button)
	return row

## 分頁 2／3 各自的隨機按鈕列（issue #676）。分頁 1（基本資料）沒有這一列——
## 姓名／年齡／性別本來就不隨機，決策來源更是玩家的成本決定不是角色設定
## （規格書 05 §6），分頁 1 沒有任何欄位可以隨機，不留一顆按下去沒反應的按鈕
func _random_button_row(handler: Callable) -> Control:
	var row := HBoxContainer.new()
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)
	var button := Button.new()
	button.text = "UI_CC_BTN_RANDOM"
	button.pressed.connect(handler)
	row.add_child(button)
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

func _on_name_changed(_new_text: String) -> void:
	_refresh_strength()

func _on_age_changed(value: float) -> void:
	_age_value_label.text = str(int(value))

func _on_gender_pressed(value: String) -> void:
	_gender_selected = value
	_refresh_gender_buttons()

func _on_source_pressed(value: String) -> void:
	if _source_buttons[_source_index(value)].disabled:
		return
	_decision_source = value
	_model_name = ""		# 換來源要重選，避免帶著另一邊的型號字串跑
	_refresh_source_buttons()
	_refresh_model_dropdown()
	_refresh_strength()

func _on_model_selected(index: int) -> void:
	if index < 0 or index >= _model_dropdown.item_count:
		return
	_model_name = _model_dropdown.get_item_text(index)
	_refresh_strength()

func _on_style_pressed(index: int) -> void:
	_style_selected = index
	_refresh_style_buttons()
	_refresh_strength()

## 只隨機分頁 2 的六維滑桿（issue #676）：隨機按鈕拆成各分頁各自觸發，
## 不再像舊版一次觸發全部分頁——玩家停在分頁 1 按下去畫面沒反應、切到
## 別頁才發現剛剛其實兩頁都被隨機掉，是誤導。保證落在可存檔區間：
## 先全部置中，再挑 EXTREME_MIN_WITH_DESC + 1（= 3，`character` 留空時的門檻）
## 個推向兩端——挑 3 個讓有沒有寫描述都達標
func _on_random_personality_pressed() -> void:
	for slider in _sliders:
		slider.value = DEFAULT_VALUE
	var picks := range(DIMENSIONS.size())
	picks.shuffle()
	for i in picks.slice(0, EXTREME_MIN_WITH_DESC + 1):
		_sliders[i].value = (randi_range(0, 4) * STEP) if randf() < 0.5 else (100.0 - randi_range(0, 4) * STEP)
	_refresh_all()

## 只隨機分頁 3 的造型組選擇（issue #676）
func _on_random_appearance_pressed() -> void:
	_style_selected = randi_range(0, STYLE_COUNT - 1)
	_refresh_all()

## 存檔完成後直接開角色庫首頁（issue #679）：投放是存檔後的自然下一步
## （規格書 05 流程圖），玩家不用自己想到再重打一次 charlib 指令才找得到
## 剛存的角色。找不到角色庫面板只 push_error，不擋存檔本身——兩個面板
## 互相知道彼此（見 character_library.gd 用同一個 group 找回這裡）
func _on_save_pressed() -> void:
	if not _can_save():
		return
	character_saved.emit(collect())
	close()
	var library := get_tree().get_first_node_in_group("character_library_panel")
	if library == null:
		push_error("CharacterCreate: 找不到 character_library_panel")
		return
	library.open()


func _extreme_count() -> int:
	var n := 0
	for slider in _sliders:
		if slider.value <= EXTREME_LOW or slider.value >= EXTREME_HIGH:
			n += 1
	return n

func _extreme_min() -> int:
	var has_desc := not _desc_edit.text.strip_edges().is_empty()
	return EXTREME_MIN_WITH_DESC if has_desc else EXTREME_MIN_WITHOUT_DESC

## 化身者模式跳過極端項門檻（issue #372）：六維滑桿藏起來後玩家碰不到，
## 門檻卻還在擋的話會變成永遠存不了檔——這幾個滑桿本來就只給 AI 決策讀，
## 玩家自己操控時沒有意義，見 _embodiment_mode 的說明
func _can_save() -> bool:
	if not _embodiment_mode:
		var n := _extreme_count()
		if n < _extreme_min() or n > EXTREME_MAX:
			return false
	if _name_edit.text.strip_edges().is_empty():
		return false
	if _style_selected < 0:
		return false
	if _decision_source in ["local", "cloud"] and _model_name.is_empty():
		return false
	return true


func _refresh_all() -> void:
	_slots_label.text = L10n.tf("UI_CC_SLOTS", {"used": _deployed_count(), "max": GameManager.DEPLOY_CAP})
	for i in _sliders.size():
		_refresh_slider(i)
	_refresh_description()
	_refresh_strength()
	_age_value_label.text = str(int(_age_slider.value))
	_refresh_gender_buttons()
	_refresh_source_buttons()
	_refresh_model_dropdown()
	_refresh_style_buttons()
	_decision_source_container.visible = not _embodiment_mode
	_slider_block_container.visible = not _embodiment_mode
	_strength_block_container.visible = not _embodiment_mode
	_personality_random_row.visible = not _embodiment_mode

func _deployed_count() -> int:
	var n := 0
	for entry in GameManager.character_library:
		if entry.get("deployed", false):
			n += 1
	return n

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

func _refresh_gender_buttons() -> void:
	for i in GENDERS.size():
		var selected: bool = GENDERS[i]["value"] == _gender_selected
		_style_selected_button(_gender_buttons[i], selected)

func _refresh_source_buttons() -> void:
	var locals := _providers_by_locality(true)
	var clouds := _providers_by_locality(false)
	for i in DECISION_SOURCES.size():
		var value: String = DECISION_SOURCES[i]["value"]
		var b := _source_buttons[i]
		if value == "local":
			b.disabled = locals.is_empty()
		elif value == "cloud":
			b.disabled = clouds.is_empty()
		else:
			b.disabled = false
		_style_selected_button(b, value == _decision_source)

func _refresh_model_dropdown() -> void:
	_model_dropdown.clear()
	_model_dropdown.visible = _decision_source != "human"
	_model_hint.visible = false

	if _decision_source == "human":
		_model_name = ""
		return

	var pool := _providers_by_locality(_decision_source == "local")
	if pool.is_empty():
		_model_name = ""
		_model_hint.text = L10n.t("UI_CC_SOURCE_NO_PROVIDER")
		_model_hint.visible = true
		return

	var selected_index := 0
	for i in pool.size():
		var p: AIConfig.Provider = pool[i]
		_model_dropdown.add_item(p.model)
		if p.model == _model_name:
			selected_index = i

	if _model_name.is_empty() or not pool.any(func(p): return p.model == _model_name):
		_model_name = pool[selected_index].model

	_model_dropdown.selected = selected_index

func _refresh_style_buttons() -> void:
	for i in _style_buttons.size():
		var b := _style_buttons[i]
		var selected := i == _style_selected
		var box := _flat(STYLE_COLORS[i], 0, 0)
		box.border_width_left = 2
		box.border_width_right = 2
		box.border_width_top = 2
		box.border_width_bottom = 2
		box.border_color = AMBER if selected else STYLE_COLORS[i]
		b.add_theme_stylebox_override("normal", box)


## AIConfig 裡「base_url 指向本機」的 provider（規格書 05 §3-1）。用常見的
## loopback 位址判斷，跟專案裡沒有其他更精確的判斷依據——provider 設定檔
## 本身沒有一個「這是不是本機」的旗標可以查
func _providers_by_locality(local: bool) -> Array[AIConfig.Provider]:
	var result: Array[AIConfig.Provider] = []
	var config := AIService.config
	if config == null:
		return result
	for provider in config.providers.values():
		var p: AIConfig.Provider = provider
		if p.valid and _is_local_url(p.base_url) == local:
			result.append(p)
	return result

func _is_local_url(base_url: String) -> bool:
	return base_url.contains("localhost") or base_url.contains("127.0.0.1")

func _source_index(value: String) -> int:
	for i in DECISION_SOURCES.size():
		if DECISION_SOURCES[i]["value"] == value:
			return i
	return -1


func _style_selected_button(b: Button, selected: bool) -> void:
	if selected:
		b.add_theme_stylebox_override("normal", _flat(AMBER, 3, 8))
		b.add_theme_color_override("font_color", INK)
	else:
		b.remove_theme_stylebox_override("normal")
		b.remove_theme_color_override("font_color")

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
