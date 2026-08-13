class_name MoneyPopup
extends Node2D

## 花錢／賺錢時頭上飄出的數字，跟 bubble.gd／work_progress.gd 同一種
## 「頭上飄一塊 UI」掛法。平常隱藏，show_change() 呼叫後往上飄、淡出，
## 動畫跑完自動歸位隱藏，呼叫端不用自己收尾。

const RISE_DISTANCE := 12.0
const DURATION := 0.8
const SPEND_COLOR := Color("8B1F14")	# Ember，警示／危險，跟花錢的語意一致
const EARN_COLOR := Color("5D6145")	# Moss，正面／成功

@onready var label: Label = $Label

var _tween: Tween = null

# 靜止位置由場景決定（player.tscn／agent.tscn 都掛在 (0, -18)），不是 ZERO。
# 飄完要回到這裡，寫死歸零的話第一次購買就把場景給的偏移永久洗掉，之後每次
# 都在角色身體上飄。bubble.gd／work_progress.gd 沒踩到是因為它們不動 position
var _rest := Vector2.ZERO


func _ready() -> void:
	_rest = position
	visible = false

# amount 正數是賺錢（+N，Moss 綠），負數是花錢（-N，Ember 紅）。
# 0 不會有視覺變化，直接跳過——沒有東西可以飄
func show_change(amount: int) -> void:
	if amount == 0:
		return

	if _tween != null and _tween.is_valid():
		_tween.kill()

	label.text = "%+d" % amount
	label.add_theme_color_override("font_color", EARN_COLOR if amount > 0 else SPEND_COLOR)
	position = _rest
	modulate.a = 1.0
	visible = true

	_tween = create_tween()
	_tween.set_parallel(true)
	_tween.tween_property(self, "position:y", _rest.y - RISE_DISTANCE, DURATION)
	_tween.tween_property(self, "modulate:a", 0.0, DURATION)
	_tween.chain().tween_callback(hide)
