class_name VendingMachine
extends StaticBody2D

## 販賣機：站到範圍內按 E 開商品選單（見 vending_menu.gd／player.gd），
## 花錢買東西。距離判定跟 workstation.gd 同一招，走 Character.BUY_RANGE 的
## 簡單距離比較，這裡自己不查距離。
##
## 庫存與現金視為無限（規格書 08 §5 規則 #4，不做商鋪經營模擬）——
## 不像 Workstation 有 occupant 卡位，好幾個角色可以同時買。
##
## StaticBody2D + CollisionShape2D 純粹是給 NavGrid 用的障礙判定
## （見 nav_grid.gd 開頭註解、workstation.gd 同一段說明），角色走路會繞過去，
## 跟互動判定本身無關。

## {item_id: price}，價格抄《規格書 08》§0／§3-1／§3-2 的售價欄。
## Dictionary 照插入順序回傳 keys()，選單的顯示順序跟這裡定義的順序一致。
##
## @export 而不是 const（#166）：藥草鋪與餐酒館兩台販賣機共用同一支腳本
## （`vending_machine.tscn`），但賣的東西不一樣——const 是腳本層級，兩台
## 只會共用同一份；@export 是節點層級，各自的場景實例可以在編輯器裡設定
## 各自的清單。預設值是餐酒館的（MVP 5 項裡的 3 項，見《08》§0），因為
## `main.tscn` 裡先有的那台就是餐酒館；藥草鋪那台在場景裡另外覆寫。
## 之後真的要資料驅動再搬進 data/
@export var catalog: Dictionary = {
	"ale": 10,
	"cooked_meat": 25,
	"water": 2,
}

## E 鍵現在會打到誰的即時提示（issue #81），跟 workstation.gd 同一招——見它
## 的 highlight 欄位註解
@onready var highlight: Line2D = get_node_or_null("Highlight")


func _ready() -> void:
	add_to_group("vending_machines")

func set_highlighted(on: bool) -> void:
	if highlight != null:
		highlight.visible = on

# 找不到的 item_id 回 -1，不是 0——0 是合法的免費商品價格，不能拿來當「沒有」的哨兵值
func get_price(item_id: String) -> int:
	return catalog.get(item_id, -1)

func list_items() -> Array:
	return catalog.keys()
