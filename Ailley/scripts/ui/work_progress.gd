class_name WorkProgress
extends Node2D

## 角色頭上的工作進度條。跟 bubble.gd 同一種「頭上飄一塊 UI」的做法——
## 平常隱藏，`Character._run_work()` 進行中才顯示，跑完立刻收起來。
##
## 純色 ColorRect 疊兩層（底＋填色），不是 Godot 內建的 ProgressBar/
## TextureProgressBar——那兩個是 Control 的完整元件，帶一堆這裡用不到的
## 樣式/主題邏輯，兩塊 ColorRect 疊起來就是全部需要的視覺。

const WIDTH := 14.0
const HEIGHT := 2.0
const BG_COLOR := Color("2F2522")	# Bark
const FILL_COLOR := Color("C96C23")	# Amber，跟 hotbar.gd／inventory_panel.gd 的選中色同一個「進行中」語意

@onready var background: ColorRect = $Background
@onready var fill: ColorRect = $Fill


func _ready() -> void:
	visible = false

	background.color = BG_COLOR
	background.position = Vector2(-WIDTH / 2.0, 0.0)
	background.size = Vector2(WIDTH, HEIGHT)

	fill.color = FILL_COLOR
	fill.position = background.position
	fill.size = Vector2(0.0, HEIGHT)

# ratio 夾在 0-1，呼叫端（Character._run_work()）自己算「做了幾分之幾」，
# 這裡只負責畫，不知道工作站或計時器是什麼
func show_progress(ratio: float) -> void:
	visible = true
	fill.size.x = WIDTH * clampf(ratio, 0.0, 1.0)

func hide_progress() -> void:
	visible = false
	fill.size.x = 0.0
