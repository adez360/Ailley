class_name MoneyPopup
extends Node2D

## 花錢／賺錢／吃喝等造成數值變動時，頭上飄出的「欄位 +數值」提示（issue #951）。
## 跟 bubble.gd／work_progress.gd 同一種「頭上飄一塊 UI」掛法。
##
## show_change(label_key, amount) 每呼叫一次就生一塊 Label、往上飄、淡出，
## 動畫跑完自己 queue_free()——呼叫端不用收尾。同一瞬間多筆變動（例如一份
## 食物同時補飽足感和水分）各自往上錯開，不會疊在一起。
##
## 節點名維持 MoneyPopup、位置由 character.tscn 給（(0, -18)）；不再依賴場景裡
## 的子節點，Label 全部在這裡用程式建。

const RISE_DISTANCE := 12.0
const DURATION := 0.9
const SLOT_HEIGHT := 11.0			# 同時多筆時，每筆往上錯開的間距
const LABEL_WIDTH := 72.0			# 固定寬度，position.x = -一半 讓文字置中對齊錨點
const SPEND_COLOR := Color("8B1F14")	# Ember，警示／危險：花錢、數值往下
const EARN_COLOR := Color("5D6145")	# Moss，正面／成功：賺錢、數值往上


# amount 正數 → Moss 綠、顯示 "+N"；負數 → Ember 紅、顯示 "-N"。
# 0 沒有視覺變化，直接跳過。label_key 是翻譯 key（金錢用 "UI_STATUS_MONEY"，
# 數值用 Stats.SPEC[key]["label"]，例如 "STAT_SATIETY"）
func show_change(label_key: String, amount: int) -> void:
	if amount == 0:
		return

	var label := Label.new()
	label.text = "%s %+d" % [tr(label_key), amount]
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_color_override("font_color", EARN_COLOR if amount > 0 else SPEND_COLOR)
	label.custom_minimum_size.x = LABEL_WIDTH
	label.size.x = LABEL_WIDTH
	# 目前還在飄的其他 Label 數量——新的一塊從它們上方開始，避免同幀多筆疊住
	var start_y := -SLOT_HEIGHT * get_child_count()
	label.position = Vector2(-LABEL_WIDTH * 0.5, start_y)
	add_child(label)

	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(label, "position:y", start_y - RISE_DISTANCE, DURATION)
	tween.tween_property(label, "modulate:a", 0.0, DURATION)
	tween.chain().tween_callback(label.queue_free)
