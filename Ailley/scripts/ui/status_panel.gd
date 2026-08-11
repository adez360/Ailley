class_name StatusPanel
extends CanvasLayer

## 點選角色彈出的狀態表：姓名（標題列）、年齡，以及 Stats.SPEC 的全部數值。
## 點角色本體開啟，再點一次空白處或按 Esc 關閉。
##
## 年齡目前是 AGE_PLACEHOLDER 示意值 —— Character 還沒有年齡欄位，等年齡系統
## 設計出來再接上真正的數值，這裡先佔住版面。
##
## 場景結構是這份腳本的合約，改路徑要兩邊一起改：
##   CanvasLayer（本腳本）
##     Panel（Setting menu.png 九宮格，region 只切帶 "SETTINGS" 標題列的那格）
##       TitleBg（ColorRect，蓋掉素材裡烤進去的 "SETTINGS" 字樣，顏色是面板底色 #DCB98A；
##                底下的底線裝飾留著不蓋，所以只蓋文字那一小條，不是整個標題列）
##       TitleLabel（疊在 TitleBg 上面，放角色名字）
##       VBox
##         AgeLabel
##         StatsBox（VBoxContainer，空的 —— 本腳本依 Stats.SPEC 動態長出一個 Label）
##         HintLabel
##
## 數值故意不寫成 HungerLabel／EnergyLabel 這種固定節點，理由跟 stats.gd
## 開頭註解一樣：Stats.SPEC 加一項，這裡要自動多一行，不用回頭改場景或程式碼。
##
## 點擊偵測重用 world/selection.gd 的 character_at()，不自己查物理碰撞形狀 ——
## Character 的碰撞形狀只有腳下那個小圓（selection.gd 的註解寫過理由：物理查詢
## 點頭部、身體都會落空），selection.gd 早就用視覺矩形（get_pick_rect）解決了
## 同一個問題，這裡沒有理由重新發明一次更差的判定。

## 跟 character_create.gd 同一份調色盤（技術/UI 版面與素材規格.md）。
## StatsBox 的 Label 是動態生成的，場景裡設不到，只能在這裡上色
const BARK := Color("2F2522")

## Character 目前沒有年齡欄位（character_create.gd 的六維人格也沒有），
## 年齡系統還沒設計，先寫死示意值占住這一列版面，不要顯示 0 或空字串
const AGE_PLACEHOLDER := "—"

@onready var panel: Panel = $Panel
@onready var title_label: Label = $Panel/TitleLabel
@onready var age_label: Label = $Panel/VBox/AgeLabel
@onready var stats_box: VBoxContainer = $Panel/VBox/StatsBox
@onready var hint_label: Label = $Panel/VBox/HintLabel

var _stat_labels := {}	# key（Stats.SPEC 的鍵）-> Label，_ready() 時建好，順序固定


func _ready() -> void:
	panel.hide()
	hint_label.text = L10n.t("UI_STATUS_CLOSE_HINT")
	for key in Stats.SPEC:
		var label := Label.new()
		label.add_theme_color_override("font_color", BARK)
		stats_box.add_child(label)
		_stat_labels[key] = label

func _unhandled_input(event: InputEvent) -> void:
	if panel.visible and event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		close()
		get_viewport().set_input_as_handled()

# 點擊偵測故意走 _input 而不是 _unhandled_input，跟 debug_console.gd 同一個理由：
# _input 是輸入管線裡最早、順序固定的一關，不受場景樹位置影響。
# world/selection.gd 也在監聽同一顆滑鼠左鍵（點角色讓鏡頭跟過去），它走
# _unhandled_input，且不管有沒有點中角色都會 set_input_as_handled() —— 兩個
# 節點都用 _unhandled_input 的話，誰先誰後要看場景樹的內部派發順序，測過不可靠
# （新加的 StatusPanel 反而後收到）。走 _input 就不用賭這個順序。
#
# 這裡故意不 set_input_as_handled()：點角色要同時「開狀態表」與「鏡頭跟過去」，
# 兩件事不衝突，讓事件繼續往下傳給 selection.gd
func _input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT):
		return

	var character := _pick_character(event.position)
	if character != null:
		open(character)
	elif panel.visible:
		close()

# event.position 是螢幕座標（CanvasLayer 沒有 global_position 可用），
# 拿 canvas_transform 的反矩陣還原成世界座標，鏡頭有跟隨時才不會點錯地方
func _pick_character(screen_pos: Vector2) -> Character:
	var world_pos := get_viewport().canvas_transform.affine_inverse() * screen_pos

	var selection := get_tree().get_first_node_in_group("selection") as Selection
	if selection == null:
		return null

	return selection.character_at(world_pos)

func open(character: Character) -> void:
	title_label.text = character.character_name
	age_label.text = _line("UI_STATUS_AGE", AGE_PLACEHOLDER)

	var has_stats := character.stats != null
	stats_box.visible = has_stats
	if has_stats:
		for key in Stats.SPEC:
			_stat_labels[key].text = _stat_line(character.stats, key)

	panel.show()

func close() -> void:
	panel.hide()

func _line(label_key: String, value: String) -> String:
	return "%s：%s" % [L10n.t(label_key), value]

func _stat_line(stats: Stats, key: String) -> String:
	return _line(Stats.SPEC[key]["label"], str(int(stats.get_value(key))))
