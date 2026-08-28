extends CanvasLayer

## 墓碑查看面板（issue #385 改範圍，見 note/技術/墓碑查看面板.md）。原本的悼詞留言
## 功能整段拆掉——改成點擊已安葬角色，唯讀顯示三件事：
##
## - **個性**：`Character.personality` 現有的 10 項引擎數值，含睡前反思
##   （`apply_personality_delta()`）累積調整的漂移。死後決策迴圈已停，
##   讀到的就是死掉當下的狀態，不用另外拍照存一份
## - **生平**：`Agent.life_highlights`（#381），引擎彙整、絕不讓 LLM 潤飾
## - **臨終遺言**：`Character.last_words`，死者自己的 LLM 產生，可能是 null
##   （來不及開口）
##
## 開關方式跟 status_panel.gd 同一套：點擊偵測走 _input()（不是
## _unhandled_input），且不 set_input_as_handled()——空地點擊要繼續傳給
## selection.gd 取消選取，跟 status_panel.gd 同一個理由（也因此買帳同一個
## 既有現象：點擊已安葬角色時 StatusPanel 也會一起開，這不是這裡新造成的，
## 兩邊都不吃掉點擊事件本來就會疊加）。只對「已安葬」的角色開面板——未安葬
## 的屍體沒有墓碑（《規格書09》§4-3「未安葬不顯示遺言/生平」）。
##
## 無名碑（`is_anonymous`，同一個 §4-3）另外走限縮顯示：面板照樣開，但
## 標題不顯示真名、內容只留「無人知曉他是誰」跟死亡日期，個性/生平/遺言
## 整段不顯示——見 `_add_anonymous_lines()`。

const EMPTY_PLACEHOLDER := "—"		# 《15》§1-1：沒資料一律顯示這個，不留空白不顯示假值
const BARK := Color("2F2522")

@onready var panel: Panel = $Panel
@onready var title_label: Label = $Panel/TitleLabel
@onready var hint_label: Label = $Panel/StatusLabel
@onready var content_vbox: VBoxContainer = $Panel/ContentScroll/ContentVBox

var _corpse: Character = null


func _ready() -> void:
	hint_label.text = L10n.t("UI_GRAVE_CLOSE_HINT")
	panel.hide()

func _input(event: InputEvent) -> void:
	if panel.visible and event.is_action_pressed("ui_cancel"):
		_close()
		get_viewport().set_input_as_handled()
		return

	var mouse := event as InputEventMouseButton
	if mouse == null or not (mouse.pressed and mouse.button_index == MOUSE_BUTTON_LEFT):
		return

	# 面板開著時，面板範圍內的點擊（例如捲軸）留給 GUI 的 _gui_input 處理，
	# 不能被下面的世界選取邏輯搶走（跟 status_panel.gd 同一個理由）
	if panel.visible and panel.get_global_rect().has_point(mouse.position):
		return

	var character := _pick_character(mouse.position)
	if character != null and character.is_buried:
		_open(character)
	elif panel.visible:
		_close()

func _pick_character(screen_pos: Vector2) -> Character:
	var world_pos := get_viewport().canvas_transform.affine_inverse() * screen_pos
	var selection := get_tree().get_first_node_in_group("selection") as Selection
	if selection == null:
		return null
	return selection.character_at(world_pos)

func _open(corpse: Character) -> void:
	_corpse = corpse
	title_label.text = L10n.t("UI_GRAVE_ANONYMOUS_TITLE") if corpse.is_anonymous else corpse.character_name
	_refresh_content()
	panel.show()

func _close() -> void:
	panel.hide()
	_corpse = null

func _refresh_content() -> void:
	_clear_children(content_vbox)
	if _corpse.is_anonymous:
		_add_anonymous_lines()
		return
	_add_section_header("UI_GRAVE_SECTION_PERSONALITY")
	_add_personality_lines()
	_add_section_header("UI_GRAVE_SECTION_LIFE")
	_add_life_highlights_lines()
	_add_section_header("UI_GRAVE_SECTION_LAST_WORDS")
	_add_last_words_line()

## 無名碑（《規格書09》§3-4／§4-3）：corpse_decay 達 100 沒人安葬時
## _erect_unmarked_grave()（#387）自動立碑、設 is_anonymous = true——
## 個性／生平／遺言整段不顯示，只留「無人知曉他是誰」跟死亡日期，
## 跟已具名安葬的完整顯示（上面那個分支）刻意不同，不是漏寫
func _add_anonymous_lines() -> void:
	var unknown_label := Label.new()
	unknown_label.text = L10n.t("UI_GRAVE_ANONYMOUS_UNKNOWN")
	unknown_label.add_theme_color_override("font_color", BARK)
	unknown_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	content_vbox.add_child(unknown_label)

	var day_label := Label.new()
	day_label.text = L10n.tf("UI_GRAVE_ANONYMOUS_DAY", {"day": _corpse.death_day})
	day_label.add_theme_color_override("font_color", BARK)
	content_vbox.add_child(day_label)

## personality 沒資料（identity 沒帶 hexaco，見 Personality.from_identity()）
## 時是空字典，不是每個角色都保證有這 10 項——一律用 has() 檢查，缺的略過，
## 不是顯示 0（0 是合法數值，代表「沒資料」跟「這項是 0」語意不同）
func _add_personality_lines() -> void:
	var personality: Dictionary = _corpse.personality
	if personality.is_empty():
		_add_placeholder_line()
		return
	for key in Personality.PERSONALITY_KEYS:
		if not personality.has(key):
			continue
		var label := Label.new()
		label.text = "%s：%d" % [L10n.t(Personality.PERSONALITY_LABELS[key]), int(round(float(personality[key])))]
		label.add_theme_color_override("font_color", BARK)
		content_vbox.add_child(label)

## life_highlights 只有 Agent 才有這個欄位（#381）——場景固定 NPC／角色庫
## 投放都是 Agent，Player 死亡（若發生）沒有這份資料，顯示佔位文案而非報錯，
## 跟 status_panel.gd 的 today_plan／today_log 對 Player 的處理同一個理由
func _add_life_highlights_lines() -> void:
	var agent := _corpse as Agent
	# 三元運算子兩側型別要一致（GDScript 對 Array[String] 這種具型別陣列的
	# 隱式轉換不會套用在三元運算式裡，直接寫 [] 在執行期會拋
	# "Trying to assign an array of type Array to a variable of type
	# Array[String]"）——用 if/else 明確賦值，不要圖方便寫成一行三元運算
	var highlights: Array[String] = []
	if agent != null:
		highlights = agent.life_highlights
	if highlights.is_empty():
		var label := Label.new()
		label.text = L10n.t("UI_GRAVE_NO_LIFE_HIGHLIGHTS")
		label.add_theme_color_override("font_color", BARK)
		label.autowrap_mode = TextServer.AUTOWRAP_WORD
		content_vbox.add_child(label)
		return
	for line in highlights:
		var label := Label.new()
		label.text = "・%s" % line
		label.add_theme_color_override("font_color", BARK)
		label.autowrap_mode = TextServer.AUTOWRAP_WORD
		content_vbox.add_child(label)

## last_words 是 String 或 null（來不及開口，見 character.gd 欄位註解）——
## null 不是「沒資料」，是死亡本身的一種狀態，用專屬文案跟 EMPTY_PLACEHOLDER
## 那種「這個角色沒有這項資料」的泛用佔位語意分開
func _add_last_words_line() -> void:
	var label := Label.new()
	var words: Variant = _corpse.last_words
	label.text = str(words) if words is String else L10n.t("UI_GRAVE_NO_LAST_WORDS")
	label.add_theme_color_override("font_color", BARK)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD
	content_vbox.add_child(label)

func _add_section_header(label_key: String) -> void:
	var label := Label.new()
	label.text = L10n.t(label_key)
	label.add_theme_color_override("font_color", BARK)
	content_vbox.add_child(label)

func _add_placeholder_line() -> void:
	var label := Label.new()
	label.text = EMPTY_PLACEHOLDER
	label.add_theme_color_override("font_color", BARK)
	content_vbox.add_child(label)

func _clear_children(container: Node) -> void:
	for child in container.get_children():
		container.remove_child(child)
		child.queue_free()
