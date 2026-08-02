extends Node2D

# 一行最大字數 10 個字
const MAX_CHAR := 10
const BOX_HEIGHT := 36
const PADDING_X := 24
const MIN_WIDTH := 48

@onready var box: NinePatchRect = $BubbleBox
@onready var label: Label = $BubbleBox/Label

func _ready():
	visible = false

func say(message:String, duration := 2.0):
	if message.length() > MAX_CHAR:
		message = message.left(MAX_CHAR) + "……"

	label.text = message

	await get_tree().process_frame

	# 取得 Label 實際需要的尺寸
	var text_size = label.get_minimum_size()

	var bubble_width = max(
		text_size.x + PADDING_X,
		MIN_WIDTH
	)

	box.size = Vector2(
		bubble_width,
		BOX_HEIGHT
	)
	
	box.position = Vector2(
		-bubble_width / 2,
		0
	)

	visible = true

	await get_tree().create_timer(duration).timeout

	visible = false
