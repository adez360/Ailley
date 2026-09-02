class_name IncapacitationAlert
extends CanvasLayer

## 全畫面的昏迷倒數警示（issue #803）：任何角色（含玩家自己）進入昏迷後，
## 畫面頂端中央列出「誰正在倒數、剩餘幾分鐘」，每遊戲分鐘隨
## GameClock.time_changed 重掃場上 characters 群組刷新，沒有人在倒數時整層隱藏。
##
## 頭上的 IncapacitationCountdown 只有角色在畫面內才看得到，負責「到了附近
## 找得到人」；這個警示負責「遠處也有人正在倒數」的發現——實測（Test B，
## 見 issue #803）三隻角色全數倒數死亡、玩家毫無察覺，缺的就是這個全域訊號。
## 兩者讀同一個狀態來源（Character.get_incapacitation_remaining_minutes()）。
##
## 純程式建 UI、由 main_scene.gd::_ready() add_child 掛上（比照 OnboardingHint），
## 不依賴任何 .tscn——godot-ai MCP 連不上時場景操作走不了規定流程，
## 這裡全部在「純 GDScript 邏輯」可直接編輯的範圍。

## 全專案 CanvasLayer 慣例（見 model_download_overlay.gd）：一般 UI = 1
const LAYER := 1
## Ember，警示／危險語意：跟 money_popup.gd 的花費色同一個調色盤值
const TEXT_COLOR := Color("8B1F14")

var _box: VBoxContainer


func _ready() -> void:
	layer = LAYER
	visible = false

	_box = VBoxContainer.new()
	_box.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_box.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_box.grow_vertical = Control.GROW_DIRECTION_END
	# 不吃滑鼠事件：警示只是訊號，不能擋住底下的世界點擊／選取
	_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_box)

	GameClock.time_changed.connect(_on_time_changed)
	_refresh.call_deferred()


func _on_time_changed(_hour: int, _minute: int) -> void:
	_refresh()


func _refresh() -> void:
	for child in _box.get_children():
		child.free()

	var rows := 0
	for node in get_tree().get_nodes_in_group("characters"):
		var character := node as Character
		if character == null or character.is_dead:
			continue
		var remaining := character.get_incapacitation_remaining_minutes()
		if remaining <= 0:
			continue
		rows += 1
		var line := Label.new()
		line.text = "%s：昏迷倒數 %d 分鐘" % [character.character_name, remaining]
		line.add_theme_color_override("font_color", TEXT_COLOR)
		line.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_box.add_child(line)

	visible = rows > 0
