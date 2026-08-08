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


# 給主控台指令與 LLM prompt 列可用地點名稱用
func list() -> PackedStringArray:
	var names := PackedStringArray()
	for child in get_children():
		names.append(child.name)
	return names
