extends Node2D

@onready var box = $BubbleBox
@onready var label = $BubbleBox/BubbleLabel
@onready var tail = $Tail

func say(text:String, duration:=2.5):

	label.text = text

	# 固定大小（先不要自動縮放）
	box.size = Vector2(120, 48)

	# 讓 BubbleBox 置中在 NPC 頭上
	box.position = Vector2(
		-box.size.x / 2,
		0
	)

	# Tail 放在右下角
	tail.position = Vector2(
		box.position.x + box.size.x - 8,
		box.position.y + box.size.y - 2
	)

	visible = true

	await get_tree().create_timer(duration).timeout

	visible = false
