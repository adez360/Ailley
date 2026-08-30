extends Node2D

## 角色頭上的對話氣泡。
##
## 取代 villager 時代的 Bubble。舊版有兩個問題會讓對話跑不起來，這裡都處理掉：
##   1. MAX_CHAR = 10 會把長句截斷成刪節號 —— 這裡改成自動折行，不截字
##   2. say() 是 await + 固定 2 秒，連續呼叫會蓋掉前一句 ——
##      這裡改成佇列，一句播完才播下一句

## 超過這個寬度就折行。角色只有 16px，氣泡再寬會整個蓋掉畫面。
## 132px 是 640 寬的 20%，11px 字型下一行約 12 個中文字
const MAX_LINE_WIDTH := 132.0
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

## agent.tscn／player.tscn 裡 Bubble instance 的基準 z_index（CodeRabbit review
## 抓到：_reassign_z_indices() 原本直接拿陣列位置覆蓋，把這個基準值蓋成 0 起跳，
## 場景裡其他 z_index 落在 1~9 之間的 CanvasItem 就可能畫到氣泡前面）。跟兩份
## .tscn 保持一致，改這裡記得同步改
const BASE_BUBBLE_Z_INDEX := 10

@onready var box: NinePatchRect = $Box
@onready var label: Label = $Box/Label

## 兩個氣泡同時顯示時，z_index 相同會互相遮擋（issue #409）。真實對話是
## 輪流講，很少同時出現，不需要位移/防碰撞這種排版方案——排一份「目前顯示中」
## 的疊放順序，最近開口的那句排到陣列尾端（=最上層），z_index 用 BASE_BUBBLE_Z_INDEX
## 加陣列位置重算，不直接拿位置覆蓋掉場景設定的基準值。static 讓所有 Bubble
## instance 共用同一份順序。
##
## 原本用全域遞增計數器＋對 4096（CanvasItem z_index 合法範圍上限）取模，
## CodeRabbit review 抓到：hold() 可以讓一顆氣泡長期停在畫面上（例如「輪到你了」
## 的常駐提示），計數器繞回 0 時完全可能撞到還在顯示的舊氣泡、把新氣泡排到
## 它後面——不是機率低的邊角案例，是真的會發生。改成陣列位置就沒有這個問題：
## 位置範圍永遠落在「目前同時可見的氣泡數」內，不會無限增長，也就不會繞回去
static var _visible_order: Array = []

var _queue: Array[String] = []
var _remaining := 0.0

## true 時 _process() 只重夾位置、不跑自動消失的計時——見 hold()（#207）
var _holding := false

## _render() 排版算出的未 clamp box 位置。_process() 每幀重夾時從這裡出發，
## 偏移不會一幀疊一幀
var _unclamped_box_position := Vector2.ZERO


func _ready() -> void:
	visible = false
	set_process(false)

# 角色被 queue_free()（例如死亡、退場）時，就算這時候氣泡還在顯示中，
# 也要退出疊放順序——不然陣列會留著死掉的參照，長期下來一樣是無限增長
func _exit_tree() -> void:
	_leave_visible_order()

func _process(delta: float) -> void:
	# 顯示期間每幀重夾一次：角色移動（鏡頭跟著動）之後，_render() 當下算好的
	# clamp 會失效——hold() 的常駐提示最明顯，常駐期間角色照樣在動
	if visible:
		_clamp_to_camera_view()

	if _holding:
		return

	_remaining -= delta
	if _remaining > 0.0:
		return

	if _queue.is_empty():
		visible = false
		set_process(false)
		_leave_visible_order()
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
	_holding = false
	visible = false
	set_process(false)
	_leave_visible_order()

func is_speaking() -> bool:
	return visible or not _queue.is_empty()

## 常駐顯示，不會自動消失——跟 say() 排隊機制不同，這裡要「一直掛著直到
## release_hold() 被呼叫」（例如「輪到玩家了」這種要等玩家真的動作才能收起
## 的提示，見 note/技術/talk 動作設計.md、issue #207）。清掉目前的佇列：
## 常駐提示期間不該有排隊的舊訊息突然插進來
func hold(message: String) -> void:
	_queue.clear()
	_holding = true
	_bring_to_front()
	_render(message)
	# _process() 要開著，角色移動時才能持續重夾位置；自動消失的計時由
	# _process() 開頭的 _holding guard 擋掉，行為等同原本的 set_process(false)
	set_process(true)

## 解除常駐顯示。持有期間排進來的 say() 佇列（理論上不會發生，因為
## hold() 已經清空過，但 release 之後正常恢復排隊行為）接著播
func release_hold() -> void:
	if not _holding:
		return
	_holding = false
	if _queue.is_empty():
		visible = false
		_leave_visible_order()
	else:
		_show_next()

func _show_next() -> void:
	var message: String = _queue.pop_front()
	_bring_to_front()
	_render(message)
	_remaining = clampf(message.length() * SECONDS_PER_CHAR, MIN_DURATION, MAX_DURATION)
	set_process(true)

# 把自己搬到疊放順序的最後一個位置（=最上層），蓋過所有還沒消失的舊氣泡
# （issue #409）。先移除自己既有的位置（可能已經在陣列裡，例如同一顆氣泡
# 連續播兩句），避免重複
func _bring_to_front() -> void:
	_visible_order.erase(self)
	_visible_order.append(self)
	_reassign_z_indices()

# 自己不再顯示時要退出疊放順序，不然陣列會無限增長，繞回原本 CodeRabbit
# 抓到的「計數器爆表」同一類問題，只是換了個增長的東西
func _leave_visible_order() -> void:
	if _visible_order.has(self):
		_visible_order.erase(self)
		_reassign_z_indices()

# z_index 直接用陣列位置——範圍永遠落在同時可見的氣泡數量內，不會超出
# CanvasItem 的合法範圍（[-4096, 4096]），也就不需要處理繞回的問題。
# is_instance_valid() 防呆：角色被 queue_free() 時 Bubble 是子節點會跟著死，
# 但還沒被下一次 _process() 從陣列清掉之前，這裡不能對死掉的參照賦值
static func _reassign_z_indices() -> void:
	for i in range(_visible_order.size()):
		var bubble = _visible_order[i]
		if is_instance_valid(bubble):
			bubble.z_index = BASE_BUBBLE_Z_INDEX + i

# 量測、排版、顯示——say() 的排隊訊息與 hold() 的常駐訊息共用同一套呈現，
# 差別只在要不要跑自動消失的計時（see _show_next() / hold()）
func _render(message: String) -> void:
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

	# 記下未 clamp 的基準位置——_process() 每幀重夾時從這裡出發，偏移不會疊加
	_unclamped_box_position = box.position

	_clamp_to_camera_view()

	visible = true

## 角色站在鏡頭可視範圍邊界附近時，box 往左上長出去的部分會超出畫面、被
## 螢幕邊緣硬生生裁切掉——不是文字被截斷，是氣泡的顯示區域本身跑出可視
## 範圍（issue #742，一開始被誤判成「AI 回應句子本身不完整」）。這裡在算完
## box 的預設位置之後，用目前鏡頭的可視世界座標範圍把 box 的全域矩形夾回
## 畫面內。只平移 box.position，不動 Bubble 節點本身的 global_position——
## 那是角色頭上的錨點，不該被這裡改到，`label` 是 box 的子節點會跟著一起
## 平移，不用另外處理。
##
## 代價：箭嘴（烤在 box 的九宮格材質裡，跟著整個框體一起平移）在夾制生效
## 的那幾幀不會再精準指向角色頭上——跟 issue 建議的「調整錨點方向或位移」
## 二選一，這裡選位移，改動範圍最小；沒有鏡頭（找不到 Camera2D）時整段
## 跳過，維持原本行為，不因為這個防呆擋掉氣泡顯示
##
## clamp 不是只在 _render() 算一次：角色（跟著鏡頭）移動後畫面範圍就變了，
## _process() 顯示期間每幀重跑一次，起點固定用 _render() 記下的
## _unclamped_box_position，不是 box.position 本身——不然每幀的偏移會疊加。
## 測試裡有不進場景樹的 bubble（test_shout_reaches_player.gd），那時
## get_viewport() 回 null，跟找不到鏡頭一樣整段跳過
func _clamp_to_camera_view() -> void:
	var vp := get_viewport()
	if vp == null:
		return

	var cam := vp.get_camera_2d()
	if cam == null:
		return

	var visible_size := vp.get_visible_rect().size / cam.zoom
	var visible_center := cam.get_screen_center_position()
	var visible_rect := Rect2(visible_center - visible_size * 0.5, visible_size)

	var box_global_pos := global_position + _unclamped_box_position
	var offset := Vector2.ZERO

	if box_global_pos.x < visible_rect.position.x:
		offset.x = visible_rect.position.x - box_global_pos.x
	elif box_global_pos.x + box.size.x > visible_rect.end.x:
		offset.x = visible_rect.end.x - (box_global_pos.x + box.size.x)

	if box_global_pos.y < visible_rect.position.y:
		offset.y = visible_rect.position.y - box_global_pos.y
	elif box_global_pos.y + box.size.y > visible_rect.end.y:
		offset.y = visible_rect.end.y - (box_global_pos.y + box.size.y)

	box.position = _unclamped_box_position + offset

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
