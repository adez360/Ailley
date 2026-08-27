extends CanvasLayer

## 對已安葬角色留悼詞（#385，《規格書09》§4-5）。
##
## 開關方式跟 status_panel.gd 同一套：點擊偵測走 _input()（不是
## _unhandled_input），且不 set_input_as_handled()——空地點擊要繼續傳給
## selection.gd 取消選取，跟 status_panel.gd 的理由一致。共用同一顆
## selection.character_at() 找點到誰，但這裡只對「已安葬」的角色開面板——
## 未安葬的屍體沒有墓碑可以留言（見《規格書09》§4-3「未安葬不顯示
## 遺言/生平」同一種「沒有墓碑」的語意，這裡延伸到悼詞）。
##
## 讀寫走 GraveEpitaphPersistence（SQLite grave／grave_epitaphs 兩張表），
## 不是 JsonSaveService——見《99》P-50：epitaphs 是「一對多」，刻意留在
## SQLite，跟 last_words 等「一份墓一筆」欄位分開存。preload 而不是靠
## class_name 全域識別字：新增的 class_name 剛建立時，編輯器的全域類別表
## 不保證即時同步（godot-ai filesystem_manage scan 也未必補得齊），preload
## 直接指向檔案路徑，不吃這個時序問題。
##
## 這則是「R 先做出功能版」（issue #385）：只做表單邏輯與讀寫，沒有查看
## 完整墓碑內容（last_words／life_highlights／既有悼詞列表）的面板，
## 排版與視覺留給後續（issue 本身拆兩段做）。

const MAX_LENGTH := 40
const GraveEpitaphPersistence := preload("res://scripts/database/GraveEpitaphPersistence.gd")

@onready var panel: Panel = $Panel
@onready var input: LineEdit = $Panel/Input
@onready var status_label: Label = $Panel/StatusLabel

var _corpse: Character = null


func _ready() -> void:
	input.max_length = MAX_LENGTH
	input.text_submitted.connect(_on_submitted)
	panel.hide()

func _input(event: InputEvent) -> void:
	if panel.visible and event.is_action_pressed("ui_cancel"):
		_close()
		get_viewport().set_input_as_handled()
		return

	var mouse := event as InputEventMouseButton
	if mouse == null or not (mouse.pressed and mouse.button_index == MOUSE_BUTTON_LEFT):
		return

	# 面板開著時，面板範圍內的點擊留給 GUI 的 _gui_input 處理，不能被下面的
	# 世界選取邏輯搶走（跟 status_panel.gd 同一個理由）
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
	input.clear()
	input.editable = true
	status_label.text = L10n.t("UI_EPITAPH_HINT")
	panel.show()
	input.grab_focus()

func _close() -> void:
	panel.hide()
	input.release_focus()
	_corpse = null

## 失敗時不清空輸入框（CodeRabbit review，PR #622 抓到）：原本一進來就
## input.clear()，寫入失敗時面板留著開但玩家剛打的字已經沒了，得重打一次。
## 改成只在真的要關面板的路徑（成功、或本來就沒東西可寫）才清空；DB 寫入
## 失敗那條路徑把內容放回 input，讓玩家可以直接修改重試，不用重新輸入
func _on_submitted(text: String) -> void:
	var content := text.strip_edges()

	if content.is_empty() or _corpse == null:
		input.clear()
		_close()
		return

	# 悼詞的作者一律是操作者本人——這個面板是玩家點擊觸發的，不是 AI 任務
	var player := get_tree().get_first_node_in_group("player") as Character
	if player == null:
		input.clear()
		_close()
		return

	var reason: String = GraveEpitaphPersistence.write_epitaph(player, _corpse, content)
	if reason.is_empty():
		input.clear()
		_close()
	else:
		push_warning("EpitaphInput: 留悼詞失敗（%s）" % reason)
		status_label.text = L10n.t("UI_EPITAPH_FAIL")
		input.text = content
		input.grab_focus()
