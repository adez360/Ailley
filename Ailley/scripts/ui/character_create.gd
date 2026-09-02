extends CanvasLayer

## 建角面板（規格書 05）。
##
## 整個面板——含六維滑桿列、性別／決策來源／造型格、左側模板長條——都是
## character_create.tscn 裡的節點，直接在編輯器調版面、調樣式。分頁用原生
## TabContainer；性別／決策來源／造型格用 Button 的 toggle_mode + ButtonGroup
## （三個 .tres：character_create_{gender,source,style}_group.tres）做互斥選取，
## 選中樣式吃 theme 的 pressed 狀態（造型格另外在場景裡烤了各自的 normal/pressed
## StyleBoxFlat，因為每格底色不同），script 不再手動切換樣式。
##
## 角色庫是純模板清單，不是「已建立角色的保存處」：左側長條只列未投放的
## 模板（GameManager.character_library 裡 deployed=false 的那些），點一列
## 套用（apply_template()）只是把資料帶回表單當起點，不會覆蓋原模板——原本
## 獨立一個畫面的 character_library.gd／.tscn 已經併進這裡，不再有另一個
## 「角色庫首頁」可以單獨開關。
##
## 底部三顆按鈕：取消（不存，直接關）／保存到模板（存一筆新模板，角色庫
## 那邊看得到）／投放（存一筆新模板後立刻生場上實體，GameManager
## .create_and_deploy_character() 一次做完，失敗——世界投放上限已滿——
## 會把那筆模板退掉並讓面板留著，不假裝成功關掉）。
##
## 只負責蒐集資料，存檔／投放驗證都在這裡做完，實際寫入 GameManager 的
## character_library、角色生成、system_prompt 組句都不在這裡（規格書 01-1）。

## 使用者按下「保存到模板」且通過驗證。帶著六維數值、character 文本，
## 與分頁 1／4 的欄位
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
const AGE_DEFAULT := 30

## 造型組數量（規格書 05 §5-0），_on_random_appearance_pressed() 用來擲亂數
const STYLE_COUNT := 6

const BARK := Color("2F2522")
const LOAM := Color("5D4A38")
const CLAY := Color("75593C")
const MOSS := Color("5D6145")
const EMBER := Color("8B1F14")
const HONEY := Color("F0A94E")

@onready var _template_capacity_label: Label = $Scrim/Center/Row/TemplateStrip/MarginContainer/Col/HeaderRow/CapacityLabel
@onready var _template_list: VBoxContainer = $Scrim/Center/Row/TemplateStrip/MarginContainer/Col/ScrollContainer/List

@onready var _slots_label: Label = $Scrim/Center/Row/Panel/MarginContainer/Col/Header/SlotsLabel
@onready var _tab_container: TabContainer = $Scrim/Center/Row/Panel/MarginContainer/Col/TabContainer

@onready var _name_edit: LineEdit = $Scrim/Center/Row/Panel/MarginContainer/Col/TabContainer/TabBasic/NameRow/NameEdit
@onready var _age_slider: HSlider = $Scrim/Center/Row/Panel/MarginContainer/Col/TabContainer/TabBasic/AgeRow/AgeSlider
@onready var _age_value_label: Label = $Scrim/Center/Row/Panel/MarginContainer/Col/TabContainer/TabBasic/AgeRow/AgeValueLabel

@onready var _male_button: Button = $Scrim/Center/Row/Panel/MarginContainer/Col/TabContainer/TabBasic/GenderRow/MaleButton
@onready var _female_button: Button = $Scrim/Center/Row/Panel/MarginContainer/Col/TabContainer/TabBasic/GenderRow/FemaleButton
@onready var _other_button: Button = $Scrim/Center/Row/Panel/MarginContainer/Col/TabContainer/TabBasic/GenderRow/OtherButton

## 化身者模式切換（issue #954）：面板頂端一排兩顆 toggle 鈕，共用
## character_create_mode_group.tres（跟性別／決策來源／造型格同一種 ButtonGroup
## 做法）。切「由我操控」→ _embodiment_mode 打開，_refresh_all() 把決策來源／
## 六維滑桿藏掉、footer「投放」變「操控」
@onready var _mode_ai_button: Button = $Scrim/Center/Row/Panel/MarginContainer/Col/ModeRow/AiModeButton
@onready var _mode_embody_button: Button = $Scrim/Center/Row/Panel/MarginContainer/Col/ModeRow/EmbodyModeButton

@onready var _decision_source_container: Control = $Scrim/Center/Row/Panel/MarginContainer/Col/TabContainer/TabBasic/DecisionSourceBlock
@onready var _local_button: Button = $Scrim/Center/Row/Panel/MarginContainer/Col/TabContainer/TabBasic/DecisionSourceBlock/SourceButtonsRow/LocalButton
@onready var _cloud_button: Button = $Scrim/Center/Row/Panel/MarginContainer/Col/TabContainer/TabBasic/DecisionSourceBlock/SourceButtonsRow/CloudButton
@onready var _model_dropdown: OptionButton = $Scrim/Center/Row/Panel/MarginContainer/Col/TabContainer/TabBasic/DecisionSourceBlock/ModelDropdown
@onready var _model_hint: Label = $Scrim/Center/Row/Panel/MarginContainer/Col/TabContainer/TabBasic/DecisionSourceBlock/ModelHint
# issue #989：沒有本機 provider 時，旁邊補一個下載入口，不只是叫玩家自己
# 去手動編輯 ai_config.json（#982 那個提示本身也在同一次一併修正）
@onready var _download_model_button: Button = $Scrim/Center/Row/Panel/MarginContainer/Col/TabContainer/TabBasic/DecisionSourceBlock/DownloadModelButton

## 固定順序 = HEXACO 六維（誠實謙遜／情緒起伏／外向性／友善性／嚴謹性／開放性），
## 跟 collect()／_load_entry() 的欄位順序對齊——增減維度要動這裡跟場景兩邊
@onready var _sliders: Array[HSlider] = [
	$Scrim/Center/Row/Panel/MarginContainer/Col/TabContainer/TabPersonality/SliderBlock/HonestyRow/Slider,
	$Scrim/Center/Row/Panel/MarginContainer/Col/TabContainer/TabPersonality/SliderBlock/EmotionalityRow/Slider,
	$Scrim/Center/Row/Panel/MarginContainer/Col/TabContainer/TabPersonality/SliderBlock/ExtraversionRow/Slider,
	$Scrim/Center/Row/Panel/MarginContainer/Col/TabContainer/TabPersonality/SliderBlock/AgreeablenessRow/Slider,
	$Scrim/Center/Row/Panel/MarginContainer/Col/TabContainer/TabPersonality/SliderBlock/ConscientiousnessRow/Slider,
	$Scrim/Center/Row/Panel/MarginContainer/Col/TabContainer/TabPersonality/SliderBlock/OpennessRow/Slider,
]
@onready var _value_labels: Array[Label] = [
	$Scrim/Center/Row/Panel/MarginContainer/Col/TabContainer/TabPersonality/SliderBlock/HonestyRow/ValueLabel,
	$Scrim/Center/Row/Panel/MarginContainer/Col/TabContainer/TabPersonality/SliderBlock/EmotionalityRow/ValueLabel,
	$Scrim/Center/Row/Panel/MarginContainer/Col/TabContainer/TabPersonality/SliderBlock/ExtraversionRow/ValueLabel,
	$Scrim/Center/Row/Panel/MarginContainer/Col/TabContainer/TabPersonality/SliderBlock/AgreeablenessRow/ValueLabel,
	$Scrim/Center/Row/Panel/MarginContainer/Col/TabContainer/TabPersonality/SliderBlock/ConscientiousnessRow/ValueLabel,
	$Scrim/Center/Row/Panel/MarginContainer/Col/TabContainer/TabPersonality/SliderBlock/OpennessRow/ValueLabel,
]
@onready var _strength_label: Label = $Scrim/Center/Row/Panel/MarginContainer/Col/TabContainer/TabPersonality/StrengthBlock/StrengthLabel
@onready var _hint_label: Label = $Scrim/Center/Row/Panel/MarginContainer/Col/TabContainer/TabPersonality/StrengthBlock/HintLabel
@onready var _desc_edit: TextEdit = $Scrim/Center/Row/Panel/MarginContainer/Col/TabContainer/TabDescription/DescriptionBlock/DescEdit
@onready var _desc_count: Label = $Scrim/Center/Row/Panel/MarginContainer/Col/TabContainer/TabDescription/DescriptionBlock/DescHeadRow/DescCount

## 索引 = 造型組編號 - 1（規格書 05 §5-0），跟 StyleGrid 底下 Style1Cell..Style6Cell 對齊
@onready var _style_buttons: Array[Button] = [
	$Scrim/Center/Row/Panel/MarginContainer/Col/TabContainer/TabAppearance/StyleGrid/Style1Cell/Swatch,
	$Scrim/Center/Row/Panel/MarginContainer/Col/TabContainer/TabAppearance/StyleGrid/Style2Cell/Swatch,
	$Scrim/Center/Row/Panel/MarginContainer/Col/TabContainer/TabAppearance/StyleGrid/Style3Cell/Swatch,
	$Scrim/Center/Row/Panel/MarginContainer/Col/TabContainer/TabAppearance/StyleGrid/Style4Cell/Swatch,
	$Scrim/Center/Row/Panel/MarginContainer/Col/TabContainer/TabAppearance/StyleGrid/Style5Cell/Swatch,
	$Scrim/Center/Row/Panel/MarginContainer/Col/TabContainer/TabAppearance/StyleGrid/Style6Cell/Swatch,
]
@onready var _style_name_labels: Array[Label] = [
	$Scrim/Center/Row/Panel/MarginContainer/Col/TabContainer/TabAppearance/StyleGrid/Style1Cell/NameLabel,
	$Scrim/Center/Row/Panel/MarginContainer/Col/TabContainer/TabAppearance/StyleGrid/Style2Cell/NameLabel,
	$Scrim/Center/Row/Panel/MarginContainer/Col/TabContainer/TabAppearance/StyleGrid/Style3Cell/NameLabel,
	$Scrim/Center/Row/Panel/MarginContainer/Col/TabContainer/TabAppearance/StyleGrid/Style4Cell/NameLabel,
	$Scrim/Center/Row/Panel/MarginContainer/Col/TabContainer/TabAppearance/StyleGrid/Style5Cell/NameLabel,
	$Scrim/Center/Row/Panel/MarginContainer/Col/TabContainer/TabAppearance/StyleGrid/Style6Cell/NameLabel,
]

@onready var _missing_label: Label = $Scrim/Center/Row/Panel/MarginContainer/Col/Footer/MissingLabel
@onready var _cancel_button: Button = $Scrim/Center/Row/Panel/MarginContainer/Col/Footer/CancelButton
@onready var _save_template_button: Button = $Scrim/Center/Row/Panel/MarginContainer/Col/Footer/SaveTemplateButton
@onready var _deploy_button: Button = $Scrim/Center/Row/Panel/MarginContainer/Col/Footer/DeployButton

## 六維滑桿與強度計數兩個區塊（issue #372），化身者模式一起隱藏——強度計數
## 純粹是滑桿極端項的統計，滑桿藏起來的話這個數字沒有意義可看
@onready var _slider_block_container: Control = $Scrim/Center/Row/Panel/MarginContainer/Col/TabContainer/TabPersonality/SliderBlock
@onready var _strength_block_container: Control = $Scrim/Center/Row/Panel/MarginContainer/Col/TabContainer/TabPersonality/StrengthBlock

## 分頁 2 的隨機按鈕列（issue #676 拆出的場景節點）。化身者模式一併隱藏——
## 滑桿藏起來後這顆按鈕只改六顆看不見的滑桿，按了沒有任何可見變化卻默默
## 改寫 collect() 會存進角色庫的 hexaco 值（issue #372，#371 接上 UI 入口前的
## 潛伏問題）。分頁 4 的隨機鈕不用藏：造型組在化身者模式下照常要選
@onready var _personality_random_row: Control = $Scrim/Center/Row/Panel/MarginContainer/Col/TabContainer/TabPersonality/RandomRow

var _gender_selected := "other"
## 決策來源：MVP 只提供 "local" / "cloud"（建角面板的兩顆按鈕）。"human"
## 這個值仍是《06》的合法欄位值，保留給《12》HumanInput 決策面板（issue #156）
## 落地時再把「真人」按鈕加回來——在那之前面板不提供這個選項。真正的
## 「玩家親自操控」走面板頂端「由我操控」toggle（_embodiment_mode）
var _decision_source := "local"
var _model_name := ""

## true 時面板走化身者模式：決策來源、六維人格滑桿對玩家都沒有意義，一併
## 隱藏（issue #372，見 _refresh_all()）——玩家自己操控角色，不需要選 LLM
## 決策來源，也不需要靠六維滑桿描述「這個角色的個性」，那是給 AI 讀的行為
## 準則來源。隱藏的同時 _missing_items() 也要跳過極端項門檻（見那邊的說明），
## 不然滑桿摸不到、門檻卻還在擋，會變成存不了檔。
## 入口：面板頂端「AI 角色／由我操控」toggle（issue #954，_on_mode_pressed()），
## 或 open(as_player=true) 帶初始值；_on_deploy_pressed() 依這個旗標決定投放
## agent 還是 player
var _embodiment_mode := false

var _style_selected := -1


func _ready() -> void:
	add_to_group("character_create_panel")	# character_sidebar.gd 用這個找到面板
	_apply_tab_titles()
	_apply_style_names()
	_wire_signals()
	character_saved.connect(GameManager.receive_created_character)
	_reset_fields()
	_refresh_all()
	close()

func _notification(what: int) -> void:
	# 主控台的 locale 指令可以在執行期換語系，程式碼算出來的字串要自己重算
	if what == NOTIFICATION_TRANSLATION_CHANGED and _slots_label != null:
		_apply_tab_titles()
		_apply_style_names()
		_refresh_all()

func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()


## 建立新角色。上一次留下的欄位一律清空，這個面板沒有「暫存草稿」的語意——
## 見 close()。as_player=true 是化身者模式（issue #372）：決策來源對玩家
## 沒有意義，_refresh_all() 會把那個區塊藏起來
func open(as_player: bool = false) -> void:
	_reset_fields()
	# 一世界一個「由我操控」角色（issue #1024）：場上已有化身角色時，就算
	# 帶 as_player=true 進來也退回 AI 模式；_refresh_all() 會把 toggle disable
	_embodiment_mode = as_player and GameManager.embodied_character_id.is_empty()
	_refresh_all()
	_refresh_template_list()
	visible = true

## 套用一筆模板（左側長條點選觸發）：把資料灌回表單當起點，不記住是從
## 哪一筆套用來的——儲存／投放永遠產生新紀錄，原模板不變（角色庫是純模板
## 概念，套用不是「打開來改」）。找不到就安靜地什麼都不做，理由同舊版
## edit()：長條上的 id 只可能是上一輪操作留下的，找不到代表已經被刪了
func apply_template(id: String) -> void:
	var entry := GameManager.get_library_entry(id)
	if entry.is_empty():
		return
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
	data["hex_honesty"] = int(_sliders[0].value)
	data["hex_emotionality"] = int(_sliders[1].value)
	data["hex_extraversion"] = int(_sliders[2].value)
	data["hex_agreeableness"] = int(_sliders[3].value)
	data["hex_conscientiousness"] = int(_sliders[4].value)
	data["hex_openness"] = int(_sliders[5].value)
	data["character"] = _desc_edit.text.strip_edges()
	data["character_name"] = _name_edit.text.strip_edges()
	data["age"] = int(_age_slider.value)
	data["gender"] = _gender_selected
	data["decision_source"] = _decision_source
	data["model_name"] = _model_name
	# appearance[] 的實際內容（item_id／label）待《99》P-38 填，MVP 只驗證
	# 「有沒有選」（_can_save() 那關），不在這裡假造內容
	data["appearance"] = []
	return data


func _apply_tab_titles() -> void:
	_tab_container.set_tab_title(0, L10n.t("UI_CC_TAB_BASIC"))
	_tab_container.set_tab_title(1, L10n.t("UI_CC_TAB_PERSONALITY"))
	_tab_container.set_tab_title(2, L10n.t("UI_CC_TAB_DESC"))
	_tab_container.set_tab_title(3, L10n.t("UI_CC_TAB_APPEARANCE"))

## 造型名稱是帶編號的翻譯模板（"UI_CC_STYLE_NAME" 內文是 "{n}"），
## Label 的 auto-translate 沒辦法代入參數，只能自己算好文字塞進去
func _apply_style_names() -> void:
	for i in _style_name_labels.size():
		_style_name_labels[i].text = L10n.tf("UI_CC_STYLE_NAME", {"n": i + 1})

func _wire_signals() -> void:
	_male_button.pressed.connect(_on_gender_pressed.bind("male"))
	_female_button.pressed.connect(_on_gender_pressed.bind("female"))
	_other_button.pressed.connect(_on_gender_pressed.bind("other"))

	_local_button.pressed.connect(_on_source_pressed.bind("local"))
	_cloud_button.pressed.connect(_on_source_pressed.bind("cloud"))
	_model_dropdown.item_selected.connect(_on_model_selected)
	_download_model_button.pressed.connect(_on_download_model_pressed)

	for i in _sliders.size():
		_sliders[i].value_changed.connect(_on_slider_changed.bind(i))

	for i in _style_buttons.size():
		_style_buttons[i].pressed.connect(_on_style_pressed.bind(i))

	_name_edit.text_changed.connect(_on_name_changed)
	_age_slider.value_changed.connect(_on_age_changed)
	_desc_edit.text_changed.connect(_on_description_changed)
	$Scrim/Center/Row/Panel/MarginContainer/Col/TabContainer/TabPersonality/RandomRow/RandomButton.pressed.connect(_on_random_personality_pressed)
	$Scrim/Center/Row/Panel/MarginContainer/Col/TabContainer/TabAppearance/RandomRow/RandomButton.pressed.connect(_on_random_appearance_pressed)
	_cancel_button.pressed.connect(_on_cancel_pressed)
	_save_template_button.pressed.connect(_on_save_pressed)
	_deploy_button.pressed.connect(_on_deploy_pressed)

	_mode_ai_button.pressed.connect(_on_mode_pressed.bind(false))
	_mode_embody_button.pressed.connect(_on_mode_pressed.bind(true))


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
	_sliders[0].value = hexaco.get("hex_honesty", DEFAULT_VALUE)
	_sliders[1].value = hexaco.get("hex_emotionality", DEFAULT_VALUE)
	_sliders[2].value = hexaco.get("hex_extraversion", DEFAULT_VALUE)
	_sliders[3].value = hexaco.get("hex_agreeableness", DEFAULT_VALUE)
	_sliders[4].value = hexaco.get("hex_conscientiousness", DEFAULT_VALUE)
	_sliders[5].value = hexaco.get("hex_openness", DEFAULT_VALUE)
	_desc_edit.text = str(entry.get("character", ""))
	# appearance[] 內容本來就是空的（P-38 待填），沒有索引可以還原選中哪一格——
	# 套用模板時強制重選，不是這裡少寫了什麼
	_style_selected = -1
	# 面板只認得 local / cloud（issue #1024）；模板存的是 "human" 或其他舊值
	# 時一律當 local，讓下拉／驗證有個合法起點，不是黑洞
	var src := str(entry.get("decision_source", "local"))
	_decision_source = src if src in ["local", "cloud"] else "local"
	_model_name = str(entry.get("model_name", ""))

## 決策來源預設值（規格書 05 §3-1）：有可用的本機 provider 就預選本機
## （優先 AIConfig.default_provider 指到的那個，不是本機或不可用就退回本機
## 清單第一個）；沒有可用本機 provider 就停在 local（按鈕 disabled），由
## ModelHint／缺欄提示引導玩家去下載模型或設定雲端（issue #1024：不再退到
## 已移除的「真人」）——不預選 cloud，那會變成預設幫玩家選一個會產生帳單的選項
func _apply_default_decision_source() -> void:
	var locals := _providers_by_locality(true)
	if locals.is_empty():
		_decision_source = "local"
		_model_name = ""
		return

	_decision_source = "local"
	var config := AIService.config
	var default_provider: AIConfig.Provider = config.get_provider("") if config != null else null
	if default_provider != null and default_provider.valid and _is_local_url(default_provider.base_url):
		_model_name = default_provider.model
	else:
		_model_name = locals[0].model


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
	_decision_source = value
	_model_name = ""		# 換來源要重選，避免帶著另一邊的型號字串跑
	_refresh_source_buttons()
	_refresh_model_dropdown()
	_refresh_strength()

## issue #989：開下載進度面板，蓋在最上層（get_tree().root，不是這個面板
## 底下——ModelDownloadOverlay 自己是全螢幕 scrim，掛在建角面板內部會被
## TabContainer 的裁切範圍夾住）。面板關閉（不管成功或取消）後重新整理一次
## 來源按鈕與型號下拉，讓玩家不用重開建角面板就能看到剛下載好的本機模型
func _on_download_model_pressed() -> void:
	var overlay := ModelDownloadOverlay.new()
	get_tree().root.add_child(overlay)
	overlay.tree_exited.connect(func() -> void:
		_refresh_source_buttons()
		_refresh_model_dropdown()
	)


func _on_model_selected(index: int) -> void:
	if index < 0 or index >= _model_dropdown.item_count:
		return
	_model_name = _model_dropdown.get_item_text(index)
	_refresh_strength()

func _on_style_pressed(index: int) -> void:
	_style_selected = index
	_refresh_style_buttons()
	_refresh_strength()

## 只隨機分頁 2 的六維滑桿（issue #676）：隨機按鈕拆成各分頁各自觸發，不再
## 像舊版一次觸發全部分頁——玩家停在分頁 1 按下去畫面沒反應、切到別頁才
## 發現剛剛其實兩頁都被隨機掉，是誤導。決策來源刻意不隨機——那是玩家的成本
## 決定，不是角色設定（規格書 05 §3-1）。保證落在可存檔區間：先全部置中，再挑
## EXTREME_MIN_WITH_DESC + 1（= 3，`character` 留空時的門檻）個推向兩端——
## 挑 3 個讓有沒有寫描述都達標
func _on_random_personality_pressed() -> void:
	for slider in _sliders:
		slider.value = DEFAULT_VALUE
	var picks := range(_sliders.size())
	picks.shuffle()
	for i in picks.slice(0, EXTREME_MIN_WITH_DESC + 1):
		_sliders[i].value = (randi_range(0, 4) * STEP) if randf() < 0.5 else (100.0 - randi_range(0, 4) * STEP)
	_refresh_all()

## 只隨機分頁 4 的造型組選擇（issue #676）。化身者模式下這顆不用藏：造型組
## 在化身者模式下照常要選（規格書 05 §5-0），按了有可見反應
func _on_random_appearance_pressed() -> void:
	_style_selected = randi_range(0, STYLE_COUNT - 1)
	_refresh_all()

func _on_cancel_pressed() -> void:
	close()

func _on_save_pressed() -> void:
	if not _can_save():
		return
	character_saved.emit(collect())
	# 存完不關面板——方便連續存好幾筆模板，不用每次都重新點開。
	# 立刻刷新左側長條，不然剛存的那筆要等下次 open() 才會冒出來
	_refresh_template_list()

## 投放跟保存到模板共用 _can_save() 驗證，但不走 character_saved 訊號——
## 投放需要立刻知道成功或失敗（世界投放上限已滿）才能決定要不要關面板，
## 訊號是 fire-and-forget，拿不到回傳值，這裡改直接呼叫 GameManager
func _on_deploy_pressed() -> void:
	if not _can_save():
		return
	# 化身模式投放為 player.tscn 並寫入 embodied_character_id（issue #954），
	# 走 GameManager 同一條路徑，只多帶一個 as_player 旗標
	var character := GameManager.create_and_deploy_character(collect(), _embodiment_mode)
	if character == null:
		return
	close()

## 化身者模式切換（issue #954）。open() 的 as_player 是初始值，這裡是面板開著
## 時玩家改主意——跟 _on_source_pressed() 同一種「改一個狀態欄位＋_refresh_all()
## 重畫」寫法。apply_template() 一律強制切回 AI 模式（套用既有模板走的一定是
## AI 角色），_refresh_all() 會把兩顆按鈕的選中狀態同步回 _embodiment_mode
func _on_mode_pressed(as_player: bool) -> void:
	if _embodiment_mode == as_player:
		return
	_embodiment_mode = as_player
	_refresh_all()


func _extreme_count() -> int:
	var n := 0
	for slider in _sliders:
		if slider.value <= EXTREME_LOW or slider.value >= EXTREME_HIGH:
			n += 1
	return n

func _extreme_min() -> int:
	var has_desc := not _desc_edit.text.strip_edges().is_empty()
	return EXTREME_MIN_WITH_DESC if has_desc else EXTREME_MIN_WITHOUT_DESC

## 目前還沒填完的項目，順序 = 分頁順序（分頁 1 姓名／分頁 2 個性強度／
## 分頁 4 造型／分頁 1 型號）。存檔驗證與 footer 提示共用這一份清單，
## 免得兩邊條件走鐘
func _missing_items() -> Array[String]:
	var items: Array[String] = []
	if _name_edit.text.strip_edges().is_empty():
		items.append(L10n.t("UI_CC_MISSING_NAME"))
	# 化身者模式整段跳過極端項門檻（issue #372）：六維滑桿藏起來後玩家碰不到，
	# 門檻卻還在擋的話會變成永遠存不了檔——這幾個滑桿本來就只給 AI 決策讀，
	# 玩家自己操控時沒有意義，見 _embodiment_mode 的說明
	if not _embodiment_mode:
		var n := _extreme_count()
		var required := _extreme_min()
		if n < required:
			items.append(L10n.tf("UI_CC_MISSING_EXTREME", {"n": required - n}))
		elif n > EXTREME_MAX:
			items.append(L10n.tf("UI_CC_MISSING_EXTREME_HIGH", {"n": n - EXTREME_MAX}))
	if _style_selected < 0:
		items.append(L10n.t("UI_CC_MISSING_STYLE"))
	# 化身者模式決策來源整段隱藏，型號對玩家操控的角色沒有意義——跟極端項
	# 門檻同一個理由跳過（issue #1024：移除「真人」後 _decision_source 一定是
	# local／cloud，沒有 fallback 到不需型號的來源可以自然免掉這關）
	if not _embodiment_mode and _model_name.is_empty():
		items.append(L10n.t("UI_CC_MISSING_MODEL"))
	return items

func _can_save() -> bool:
	return _missing_items().is_empty()


func _refresh_all() -> void:
	_slots_label.text = L10n.tf("UI_CC_SLOTS", {"used": _deployed_count(), "max": GameManager.DEPLOY_CAP})
	for i in _sliders.size():
		_refresh_slider(i)
	_refresh_description()
	_age_value_label.text = str(int(_age_slider.value))
	_refresh_gender_buttons()
	_refresh_source_buttons()
	_refresh_model_dropdown()
	_refresh_style_buttons()
	# 個性強度／footer 提示放最後：_refresh_model_dropdown() 會補上自動選中的
	# 型號，先算的話提示會停在「還缺 AI 型號」
	_refresh_strength()
	# 設 button_pressed 才會通知 ButtonGroup 取消另一顆（set_pressed_no_signal
	# 會跳過群組通知，兩顆會同時亮）。這裡設 property 只發 toggled、不發 pressed，
	# _on_mode_pressed() 接的是 pressed，不會被自己回呼觸發
	_mode_ai_button.button_pressed = not _embodiment_mode
	_mode_embody_button.button_pressed = _embodiment_mode
	# 一世界一個「由我操控」角色（issue #1024，使用者 point 2）：場上已有化身
	# 角色時停用 toggle，只能建 AI 角色。已在化身模式編輯（尚未投放）時
	# embodied_character_id 仍是空的，不會誤鎖自己
	_mode_embody_button.disabled = not GameManager.embodied_character_id.is_empty()
	# footer「投放」在化身模式改叫「操控」，跟左側模板列的操控鈕同一個字串
	_deploy_button.text = "UI_CL_BTN_EMBODY" if _embodiment_mode else "UI_CL_BTN_DEPLOY"

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
	_value_labels[index].text = str(int(_sliders[index].value))

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

	_refresh_footer()

## footer 提示：把還沒填完的項目列在按鈕左邊，玩家不用逐頁翻找為什麼存檔／
## 投放是灰的。項目多的時候靠 Label autowrap 換行，footer 高度跟著長一列，
## 不截字——面板高度是 344 的固定下限，多一列吃得下
func _refresh_footer() -> void:
	var missing := _missing_items()
	_missing_label.text = "" if missing.is_empty() else L10n.tf("UI_CC_MISSING", {
		"items": L10n.t("UI_CC_MISSING_SEP").join(missing),
	})
	_save_template_button.disabled = not missing.is_empty()
	_deploy_button.disabled = not missing.is_empty()

func _refresh_gender_buttons() -> void:
	_male_button.button_pressed = (_gender_selected == "male")
	_female_button.button_pressed = (_gender_selected == "female")
	_other_button.button_pressed = (_gender_selected == "other")

func _refresh_source_buttons() -> void:
	var locals := _providers_by_locality(true)
	var clouds := _providers_by_locality(false)
	_local_button.disabled = locals.is_empty()
	_cloud_button.disabled = clouds.is_empty()
	_local_button.button_pressed = (_decision_source == "local")
	_cloud_button.button_pressed = (_decision_source == "cloud")

func _refresh_model_dropdown() -> void:
	_model_dropdown.clear()
	_model_dropdown.visible = true
	_model_hint.visible = false
	_download_model_button.visible = false

	# 下載按鈕看的是 LlamaSidecar.status，不是「provider 存不存在」——
	# ai_config.json 首次啟動會自動寫一份指到 127.0.0.1:8080 的 local
	# provider（格式合法，_providers_by_locality() 判定通過），但那不代表
	# llama-server 執行檔／模型檔真的落地了。缺檔案時 LlamaSidecar._maybe_
	# launch()（開機時跑過一次）會停在 MISSING_BINARY／MISSING_MODEL，
	# 這才是「需要下載」的真正訊號——只看 provider pool 空不空，在「設定檔
	# 已經有預設值但檔案還沒下載」這個最常見的首次安裝情境下永遠不會顯示
	if _decision_source == "local" and ModelDownloader.is_platform_supported():
		_download_model_button.visible = LlamaSidecar.status in [
			LlamaSidecar.Status.MISSING_BINARY, LlamaSidecar.Status.MISSING_MODEL
		]

	var pool := _providers_by_locality(_decision_source == "local")
	if pool.is_empty():
		_model_name = ""
		# 帶入真實路徑，不是寫死的字面檔名——之前這句提示指向的
		# "ai_config.json" 對不上實際存在的 user://ai_config_<hash>.json，
		# 玩家照著找根本找不到檔案（issue #982）
		_model_hint.text = L10n.tf(
			"UI_CC_SOURCE_NO_PROVIDER", {"path": AIConfig.CONFIG_PATH, "example": AIConfig.EXAMPLE_PATH}
		)
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
		_style_buttons[i].button_pressed = (i == _style_selected)


## 左側模板長條：只列未投放的模板，外加「已下葬屍體」例外（issue #999）——
## deployed=true 但場上肉體已死亡且安葬、玩家確定不付費復活的角色，列上提供
## 「永久移除」釋放投放名額；目前化身角色的屍體不列（remove_from_library()
## 拒絕刪化身）。其他已投放角色（活的、未葬屍體）仍然只在側欄「在場角色」
## 出現，不該當模板選
func _refresh_template_list() -> void:
	_template_capacity_label.text = L10n.tf("UI_CL_CAPACITY", {
		"used": GameManager.character_library.size(), "max": GameManager.CHARACTER_LIBRARY_CAP,
	})

	# remove_child() 先讓子節點立刻脫離樹，queue_free() 才真的釋放記憶體——
	# character_sidebar.gd／character_library.gd 同一個坑
	for child in _template_list.get_children():
		_template_list.remove_child(child)
		child.queue_free()

	var templates: Array[Dictionary] = []
	for entry in GameManager.character_library:
		if not entry.get("deployed", false) \
				or (entry.get("id", "") != GameManager.embodied_character_id \
					and GameManager.is_library_entry_buried(entry.get("id", ""))):
			templates.append(entry)
	if templates.is_empty():
		var empty := Label.new()
		empty.text = "UI_CL_EMPTY"
		empty.add_theme_color_override("font_color", CLAY)
		_template_list.add_child(empty)
		return

	for entry in templates:
		_template_list.add_child(_template_row(entry))

## row 本身是 HBoxContainer，靠 gui_input 偵測點擊——這一列裡面還有「操控」跟
## 刪除兩顆真的 Button，整列包成一顆 Button 會把它們的點擊吃掉（側欄那邊沒有
## 這個限制，已改成 character_row.tscn 的 Button）。刪除鈕預設
## mouse_filter=STOP 會先吃掉那次點擊，不會連帶觸發 row 的套用。
## 已下葬屍體列（issue #999）不可套用也不可投放，整列只有「永久移除」一顆鈕
func _template_row(entry: Dictionary) -> Control:
	var id: String = entry.get("id", "")
	var buried := entry.get("deployed", false) and GameManager.is_library_entry_buried(id)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	if not buried:
		row.gui_input.connect(_on_template_row_gui_input.bind(id))

	var name_label := Label.new()
	name_label.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	name_label.text = str(entry.get("character_name", ""))
	name_label.clip_text = true
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.add_theme_color_override("font_color", BARK)
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(name_label)

	if buried:
		var buried_tag := Label.new()
		buried_tag.text = "UI_CL_BURIED_TAG"
		buried_tag.add_theme_color_override("font_color", CLAY)
		buried_tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(buried_tag)

		var remove_button := Button.new()
		# 永久移除（issue #999）：收掉場上屍體節點、整筆刪除角色庫紀錄，釋放
		# 一個 DEPLOY_CAP 名額。deployed 紀錄能不能刪的授權在 GameManager
		# .remove_from_library() 的已葬例外裡，這裡不重複判斷；共用「×」鈕的
		# _on_template_delete_pressed()，刪完同樣刷新清單
		remove_button.text = "UI_CL_BTN_REMOVE_BURIED"
		remove_button.focus_mode = Control.FOCUS_NONE
		remove_button.add_theme_color_override("font_color", EMBER)
		remove_button.pressed.connect(_on_template_delete_pressed.bind(id))
		row.add_child(remove_button)
		return row

	var deploy_button := Button.new()
	# 投放成一般 NPC（issue #974）：deploy_from_library(id, false)，跟「操控」
	# 共用同一套投放機制，差別只在 as_player。列表只列未投放模板，不需要
	# disabled 判斷
	deploy_button.text = "UI_CL_BTN_DEPLOY"
	deploy_button.focus_mode = Control.FOCUS_NONE
	deploy_button.pressed.connect(_on_template_deploy_pressed.bind(id))
	row.add_child(deploy_button)

	var embody_button := Button.new()
	# 操控（#726 自舊角色庫面板移植）：把這筆未投放模板直接投放為玩家化身
	# （deploy_from_library(id, true)）。列表只列未投放模板，不需要 disabled 判斷
	embody_button.text = "UI_CL_BTN_EMBODY"
	embody_button.focus_mode = Control.FOCUS_NONE
	embody_button.pressed.connect(_on_template_embody_pressed.bind(id))
	row.add_child(embody_button)

	var delete_button := Button.new()
	# 語言無關的符號，不走 L10n——跟 side_bar 的 ◀/▶ 同一招，不是句子
	delete_button.text = "×"
	delete_button.focus_mode = Control.FOCUS_NONE
	delete_button.add_theme_color_override("font_color", EMBER)
	delete_button.pressed.connect(_on_template_delete_pressed.bind(id))
	row.add_child(delete_button)

	return row

func _on_template_row_gui_input(event: InputEvent, id: String) -> void:
	if not (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT):
		return
	apply_template(id)

func _on_template_delete_pressed(id: String) -> void:
	GameManager.remove_from_library(id)
	_refresh_template_list()

func _on_template_deploy_pressed(id: String) -> void:
	if GameManager.deploy_from_library(id, false) == null:
		_template_capacity_label.text = L10n.t("UI_CL_DEPLOY_FAILED")
		_template_capacity_label.add_theme_color_override("font_color", EMBER)
		return
	_template_capacity_label.remove_theme_color_override("font_color")
	_refresh_template_list()

func _on_template_embody_pressed(id: String) -> void:
	if GameManager.deploy_from_library(id, true) == null:
		_template_capacity_label.text = L10n.t("UI_CL_DEPLOY_FAILED")
		_template_capacity_label.add_theme_color_override("font_color", EMBER)
		return
	_template_capacity_label.remove_theme_color_override("font_color")
	_refresh_template_list()


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
