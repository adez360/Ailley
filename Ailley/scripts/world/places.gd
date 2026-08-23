extends Node2D

## 地點名稱→座標的單一事實來源。
##
## 座標就是場景裡這個節點底下同名 Marker2D 錨點的位置，不再有 data/places.json
## 那份寫死在舊 village 場景尺寸上的第二份座標——兩份資料只要有一份忘記同步
## 就會兜不起來，agent.gd 過去就是因為這樣才需要一個「錨點找不到就退回 json」
## 的 fallback，而 fallback 本身正是兩份資料互相矛盾時最先暴露問題的地方。
## 現在只有一份，找不到就是真的沒有這個地點，不用假裝有座標。


func has(place_name: String) -> bool:
	return has_node(NodePath(place_name))


func resolve(place_name: String) -> Vector2:
	var marker: Node2D = get_node_or_null(NodePath(place_name))
	if marker == null:
		push_error("PlaceAnchors: 沒有這個地點 %s" % place_name)
		return Vector2.ZERO
	return marker.global_position


# 反向解析（issue #426）：給一個世界座標，回傳它落在哪個地點的錨點半徑內，
# 都不在的話回傳空字串——「在地點之間」是合法值，不是錯誤，呼叫端不用另外
# 判斷。跟 resolve() 相反方向，只給事實句這類「記錄當下實際位置」的用途用，
# 不取代 current_place（那個欄位對「移動任務進行中，目的地是哪」仍然是對的
# 語意，見 agent.gd 的呼叫端）。多個地點錨點重疊的話回傳最近的一個
func resolve_from_position(position: Vector2, radius: float) -> String:
	var nearest_name := ""
	var nearest_distance := INF
	for child in get_children():
		if not (child is Node2D):
			continue
		var anchor := child as Node2D
		var distance: float = position.distance_to(anchor.global_position)
		if distance <= radius and distance < nearest_distance:
			nearest_distance = distance
			nearest_name = child.name
	return nearest_name


# 給主控台指令與 LLM prompt 列可用地點名稱用
func list() -> PackedStringArray:
	var names := PackedStringArray()
	for child in get_children():
		names.append(child.name)
	return names


## 地點 key → 玩家看得懂的顯示名稱翻譯表（issue #179）。
## LLM prompt／主控台仍然用 key 本身，不要在那些地方呼叫這個——
## 見 note/技術/在地化.md「刻意沒有翻譯的東西」：外來文字一律視為資料。
const DISPLAY_NAME_KEYS := {
	"home": "UI_LOC_HOME",
	"herb_shop": "UI_LOC_HERB_SHOP",
	"tavern": "UI_LOC_TAVERN",
	"pavilion": "UI_LOC_PAVILION",
	"god_stone": "UI_GOD_STONE_TITLE",
}


func display_name(place_name: String) -> String:
	var l10n_key: String = DISPLAY_NAME_KEYS.get(place_name, "")
	if l10n_key.is_empty():
		return place_name
	return L10n.t(l10n_key)
