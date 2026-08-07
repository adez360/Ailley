extends Node2D

## 角色頭上的對話氣泡。
##
## 取代 villager 時代的 Bubble。舊版有兩個問題會讓對話跑不起來，這裡都處理掉：
##   1. MAX_CHAR = 10 會把長句截斷成刪節號 —— 這裡改成自動折行，不截字
##   2. say() 是 await + 固定 2 秒，連續呼叫會蓋掉前一句 ——
##      這裡改成佇列，一句播完才播下一句

## 超過這個寬度就折行。角色只有 16px，氣泡再寬會整個蓋掉畫面
const MAX_LINE_WIDTH := 72.0
const SECONDS_PER_CHAR := 0.14		# 句子越長顯示越久
const MIN_DURATION := 1.2
const MAX_DURATION := 5.0

## 文字要避開的邊框厚度，對應 Box 的 patch margin。
## 底部特別厚是因為素材的箭嘴跟底邊框線是連在一起的，整個右下角都在固定格裡
const BORDER_X := 9.0
const BORDER_TOP := 10.0
const BORDER_BOTTOM := 12.0

## 箭嘴尖端在素材上的位置：距離右緣 9px、貼齊下緣。
## 氣泡靠這個值對齊到說話者頭上，所以框體是往左上長，不是置中
const TAIL_INSET_FROM_RIGHT := 9.0

@onready var box: NinePatchRect = $Box
@onready var label: Label = $Box/Label

var _queue: Array[String] = []
var _remaining := 0.0


func _ready() -> void:
	visible = false
	set_process(false)

func _process(delta: float) -> void:
	_remaining -= delta
	if _remaining > 0.0:
		return

	if _queue.is_empty():
		visible = false
		set_process(false)
		return

	_show_next()

# 排一句進佇列。不會蓋掉正在播的那句
func say(message: String) -> void:
	if message.strip_edges().is_empty():
		return

	_queue.append(message)

	if not visible:
		_show_next()

# 立刻閉嘴並清空佇列，對話被打斷時用
func clear() -> void:
	_queue.clear()
	_remaining = 0.0
	visible = false
	set_process(false)

func is_speaking() -> bool:
	return visible or not _queue.is_empty()

func _show_next() -> void:
	var message: String = _queue.pop_front()
	label.text = message

	var size := _measure(message)
	label.position = Vector2(BORDER_X, BORDER_TOP)
	label.size = size

	box.size = Vector2(
		size.x + BORDER_X * 2.0,
		size.y + BORDER_TOP + BORDER_BOTTOM
	)

	# 把箭嘴尖端對到 Bubble 節點原點（角色頭上）。箭嘴固定在右下角，
	# 所以框體是往左上長出去的
	box.position = Vector2(
		-(box.size.x - TAIL_INSET_FROM_RIGHT),
		-box.size.y
	)

	_remaining = clampf(message.length() * SECONDS_PER_CHAR, MIN_DURATION, MAX_DURATION)
	visible = true
	set_process(true)

# 直接用字型量文字尺寸。不能用 label.get_minimum_size() —— 開了 autowrap 之後
# 它回傳的是「最窄可接受寬度」（中文會變成一行一個字），拿它當寬度會得到
# 又細又高的氣泡
func _measure(message: String) -> Vector2:
	var font := label.get_theme_font("font")
	var font_size := label.get_theme_font_size("font_size")

	var one_line := font.get_string_size(message, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
	var width := minf(one_line.x, MAX_LINE_WIDTH)

	var block: Vector2 = font.get_multiline_string_size(
		message, HORIZONTAL_ALIGNMENT_CENTER, width, font_size
	)

	# get_multiline_string_size() 只疊字高，不含 Label 自己的 line_spacing，
	# 少算的話最後一行會被 Label 裁掉
	var line_count := maxi(1, int(round(block.y / one_line.y)))
	var spacing := label.get_theme_constant("line_spacing")

	return Vector2(width, block.y + float(spacing * (line_count - 1)))
