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

## {item_id: price}，先寫死一份小清單，價格抄《規格書 08》§3-1／§3-2 的售價欄
## （食物與飲品，符合販賣機的定位——刀、衣物那些隨身用品不放這裡賣）。
## Dictionary 照插入順序回傳 keys()，選單的顯示順序跟這裡定義的順序一致。
## 之後真的要資料驅動再搬進 data/
const CATALOG := {
	"bread": 12,
	"water": 2,
	"wild_fruit": 8,
	"ale": 10,
}


func _ready() -> void:
	add_to_group("vending_machines")

# 找不到的 item_id 回 -1，不是 0——0 是合法的免費商品價格，不能拿來當「沒有」的哨兵值
func get_price(item_id: String) -> int:
	return CATALOG.get(item_id, -1)

func list_items() -> Array:
	return CATALOG.keys()
