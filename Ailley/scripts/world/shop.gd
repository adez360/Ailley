class_name Shop
extends RefCounted

## 商店目錄（issue #572）：純資料查表，不掛場景樹、沒有物理存在。取代原本
## `VendingMachine`（StaticBody2D 場景物件）的角色——互動觸發方式從「走到
## 一台機台前按 E」改成「站在餐酒館／藥草鋪這個地點本身按 E」，商店因此不
## 再需要是一個佔格子的實體道具，純粹是「這個地點賣什麼」的資料。
##
## 庫存與現金視為無限（規格書 08 §5 規則 #4，不做商鋪經營模擬）——好幾個
## 角色可以同時買，不用像 Workstation 那樣卡位。
##
## {place: {item_id: price}}，價格抄《規格書 08》§0／§3-1／§3-2 的售價欄。
## Dictionary 照插入順序回傳 keys()，選單的顯示順序跟這裡定義的順序一致。
## 之後真的要資料驅動再搬進 data/，目前 8 項不值得。
const CATALOGS := {
	"tavern": {
		"ale": 10,
		"cooked_meat": 25,
		"water": 2,
		"spirit": 22,
		"fish_dish": 20,
		"bread": 12,
	},
	"herb_shop": {
		"medicine": 45,
		"herb_soup": 15,
	},
}


static func has_shop(place: String) -> bool:
	return CATALOGS.has(place)

# 找不到的 item_id 回 -1，不是 0——0 是合法的免費商品價格，不能拿來當「沒有」的哨兵值
static func get_price(place: String, item_id: String) -> int:
	return CATALOGS.get(place, {}).get(item_id, -1)

static func list_items(place: String) -> Array:
	return CATALOGS.get(place, {}).keys()
