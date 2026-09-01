extends Node2D
class_name GraveMarker

## 安葬完成後取代石化屍體的墓碑造型（issue #832，《規格書09》§1）。純程式繪製——
## 專案目前沒有任何墓碑／墓園美術素材（assets/ 搜尋確認過），先用最小可辨識的
## 剪影頂上；之後有美術資源時直接把這支腳本換成 Sprite2D 即可，呼叫端
## （character.gd::_apply_grave_visual()）不用跟著改。

const STONE_COLOR := Color(0.58, 0.56, 0.52)
const STONE_OUTLINE := Color(0.32, 0.3, 0.28)
const PLAQUE_COLOR := Color(0.72, 0.7, 0.64)

## 墓碑本體：拱頂石板剪影，座標以底部中心為原點。PackedVector2Array 建構子
## 呼叫不是編譯期常數運算式，const 會炸 Parser Error，改用一般變數
var BODY_POINTS := PackedVector2Array([
	Vector2(-7, 2), Vector2(-7, -6), Vector2(-5, -10), Vector2(5, -10),
	Vector2(7, -6), Vector2(7, 2),
])

func _draw() -> void:
	draw_colored_polygon(BODY_POINTS, STONE_COLOR)
	draw_polyline(BODY_POINTS + PackedVector2Array([BODY_POINTS[0]]), STONE_OUTLINE, 1.0)
	# 碑面銘牌，跟本體顏色拉開層次，讓輪廓在小尺寸下也看得出「這是一塊碑」
	draw_rect(Rect2(-4, -6, 8, 5), PLAQUE_COLOR)
