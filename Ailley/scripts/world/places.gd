extends Node2D

## 地點名稱→座標的單一事實來源。
##
## 座標就是場景裡這個節點底下同名 Marker2D 錨點的位置，不再有 data/places.json
## 那份寫死在舊 village 場景尺寸上的第二份座標——兩份資料只要有一份忘記同步
## 就會兜不起來，agent.gd 過去就是因為這樣才需要一個「錨點找不到就退回 json」
## 的 fallback，而 fallback 本身正是兩份資料互相矛盾時最先暴露問題的地方。
## 現在只有一份，找不到就是真的沒有這個地點，不用假裝有座標。


## 站位避讓半徑（issue #657）：多個角色被排到同一個地點錨點時，長時間停留
## 下來會完全疊在同一個像素上，視覺上分不清有幾個角色在場。抓 8px（半格）——
## 夠讓角色視覺上分得開，又不會偏出 TALK_RANGE（32px，見 character.gd）讓
## 角色明明站在「同一個地點」卻搭不到話
const OVERLAP_AVOID_RADIUS := 8.0

## AI 決策／`current_place`／`npc_schedule.json` 看到的抽象地點名（issue #391，
## 《規格書07_地點/家》）。場景裡沒有一個叫這個名字的錨點——每個角色實際
## 分到的是 `loc_home_01`～`loc_home_05` 其中一個，has_for()／resolve_for()
## 依角色的 home_location_id 轉譯這個抽象名，has()／resolve() 本身不認得它
const HOME_PLACE_NAME := "home"

## 5 間家在 PlaceAnchors 底下的節點名稱字首（跟 CharacterStatePersistence.gd
## 的 location_id 前綴刻意同一個字串，直接拿來當 Marker2D 名稱查）。
## list() 用它把這 5 個物理錨點從列表濾掉——見 list() 的說明
const HOME_LOCATION_PREFIX := "loc_home_"


func has(place_name: String) -> bool:
	return has_node(NodePath(place_name))


## 純座標查詢：回傳錨點原座標本身，不帶任何站位偏移。給手上沒有「這是誰
## 要去的」Character 的呼叫端用——debug 主控台、建角流程的一次性座標查詢、
## 販賣機選單的距離判斷（vending_menu.gd）這類只問「這個地點在哪」、不問
## 「誰站在這裡」的情境。要問「某個角色在這個地點的站位」一律走 resolve_for()，
## 兩個函式的差別只有那裡有沒有偏移，不要在呼叫端自己手動加
func resolve(place_name: String) -> Vector2:
	var marker: Node2D = get_node_or_null(NodePath(place_name))
	if marker == null:
		push_error("PlaceAnchors: 沒有這個地點 %s" % place_name)
		return Vector2.ZERO
	return marker.global_position


## 用 character_id 的雜湊值算一個固定方向的偏移，半徑固定 OVERLAP_AVOID_RADIUS。
## 同一個角色每次呼叫都拿到同一個偏移——不能每次都不同，否則移動中的抵達
## 判定（_has_arrived_at()）會追著一個一直在動的目標跑，永遠判定不了「到了」。
## 不同角色的雜湊值大機率不同、偏移方向也跟著不同，多角色排到同一個錨點時
## 自然散開，不需要引擎去追蹤「這個地點現在站了幾個人、該讓下一個站哪裡」
## 這種主動式排位邏輯——跟這個檔案「座標就是場景裡的單一事實來源」一致，
## 不額外維護一份佔位狀態
##
## 已知取捨（code review 抓到，PR #721）：hash() % 360 只有 360 個離散角度，
## 角色一多（5–10 個擠同一錨點）就有機率抽到相同或相近（角差 20° 內兩點
## 距離 < 2.8px）的角度，視覺上仍然貼近甚至重疊。這是「純函式、無狀態」
## 換來的——要徹底分開就得維護佔位狀態做主動排位，這個設計已拍板不做。
## 屬已知取捨，不是 bug，之後看到不要當缺陷回報
func _overlap_offset(character_id: String) -> Vector2:
	var angle: float = (hash(character_id) % 360) * TAU / 360.0
	return Vector2.RIGHT.rotated(angle) * OVERLAP_AVOID_RADIUS


## 偏移落點的可走性驗證（code review 抓到，PR #721）：8px 是半格，錨點又
## 不一定在格心，雜湊方向跨格時落點可能落在鄰格——包括販賣機 StaticBody2D
## 佔掉的障礙格。落點格 solid 的話，find_path() 會把終點 snap 到別格、
## _has_arrived_at() 兩個判定（2px 距離／同格）都永不成立，任務被誤報
## 「走不到」還不重試（重現 #670 修掉的結構性死鎖）。所以偏移產生後一律
## 用 NavGrid 驗證，不可走就退回錨點原座標——寧可重疊也不要走不到。
## NavGrid 跟 PlaceAnchors 一樣走場景群組取得（get_first_node_in_group，
## 見 character.gd／agent.gd 的既有慣例），不在樹上或還沒建完時一律視為
## 不可走、退回錨點，跟「寧可重疊」同一個方向
func _offset_position_walkable(position: Vector2) -> bool:
	var nav = get_tree().get_first_node_in_group("nav_grid")
	if nav == null:
		return false
	return nav.is_cell_free(nav.world_to_cell(position))


## has()／resolve() 的角色感知版本：呼叫端手上如果有目的地是誰要去的
## Character（不一定是自己——見 agent.gd 說服玩家去某地點那條路徑），
## 一律改用這兩個，place_name 才能正確處理 HOME_PLACE_NAME 這個抽象值
func has_for(character: Character, place_name: String) -> bool:
	if place_name == HOME_PLACE_NAME:
		return (
			not character.home_location_id.is_empty()
			and has(character.home_location_id)
		)
	return has(place_name)


## 回傳「這個角色在這個地點的站位」：錨點座標外加一個依角色 id 雜湊算出的
## 固定方向偏移（見 _overlap_offset()），多角色排到同一錨點時自然散開，
## 不會完全疊在同一個像素上。偏移是掛在這裡而不是 resolve()——resolve()
## 要維持純座標查詢，而且 resolve_for() 內部解析 home（resolve
## (character.home_location_id)）也會經過這裡，家的站位避讓才不會被繞過
## （code review 抓到，PR #721 跟 #727 的簽名衝突）。
##
## 玩家不吃偏移（明確決定，PR #721 review nit-2）：玩家是自由行動、人手
## 控制，沒有 _has_arrived_at() 這種要跟移動目標對齊的自動抵達判定；而且
## 玩家站錨點原座標、NPC 固定偏移 8px 離開錨點，玩家跟任一 NPC 的距離
## 恆為 8px、永遠不會疊——這是當初 PR #721 拍板「player.gd 不改」時驗過
## 的性質，偏移若也套到玩家身上，玩家跟 NPC 就有機會抽到相近角度而疊站，
## 這個性質就沒了。所以 player（"player" 群組，跟 agent.gd 的識別慣例
## 同一套）一律回錨點原座標——包括 agent.gd 說服流程的 waypoint indicator
## （resolve_for(player, place)，#415）：指標指向錨點本身，引導玩家去
## 「這個地點」，不是去某個 NPC 的偏移站位
func resolve_for(character: Character, place_name: String) -> Vector2:
	if place_name == HOME_PLACE_NAME:
		if character.home_location_id.is_empty():
			push_error(
				"PlaceAnchors: %s 還沒有 home_location_id，無法解析 %s"
				% [character.character_id, HOME_PLACE_NAME]
			)
			return Vector2.ZERO
		place_name = character.home_location_id
	if not has(place_name):
		push_error("PlaceAnchors: 沒有這個地點 %s" % place_name)
		return Vector2.ZERO
	var anchor := resolve(place_name)
	if character.is_in_group("player"):
		return anchor
	var offset_position: Vector2 = anchor + _overlap_offset(character.character_id)
	if _offset_position_walkable(offset_position):
		return offset_position
	return anchor


## resolve_from_position() 回傳的是物理錨點名稱；current_place／AI 看到的
## 是抽象詞彙集合，兩者在「家」這裡不對稱（5 個 loc_home_0N 收斂成 1 個
## HOME_PLACE_NAME）。事實句要秀給 AI 看、或拿來跟 current_place 比對是否
## 同地點（例如約定機制判斷「人到了沒」、L3 記憶用地點篩選相關記憶）的
## 呼叫端，一律用這個把物理名稱收斂回抽象值，不要直接用 resolve_from_position()
## 的原始回傳值——不收斂的話 AI 會看到一串內部 DB id，記憶篩選也會因為
## 「當下抽象地點」跟「記憶存的物理地點」字串對不起來而永遠比對失敗。
##
## 唯一例外：character.gd::_resolve_death_location() 刻意保留原始回傳值。
## death_location_id 是《規格書09》§2 的存檔記錄欄位（範例值 loc_forest 就是
## 物理 location_id），只進存檔／屍體記錄、不進 AI 視野，也不拿來跟抽象地點
## 做字串比對——死在家裡存 loc_home_03（物理名）跟死在森林存 loc_forest 是
## 同一套語意，這裡是對的，不要「修」成收斂值（code review 抓到，PR #727）
func to_ai_place_name(place_name: String) -> String:
	if place_name.begins_with(HOME_LOCATION_PREFIX):
		return HOME_PLACE_NAME
	return place_name


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


# 給主控台指令與 LLM prompt 列可用地點名稱用。目前唯一的呼叫端是「約定」
# 功能（agent.gd _normalize_place()／prompt_builder.gd 的約定地點清單，
# issue #479）：5 間 loc_home_0N 是每個角色各自的私人地點，兩個角色互相
# 「約在家見」在物理上兜不起來（各自解析到不同座標），issue #391 把每人
# 一間家落地時故意把它們從這份清單濾掉，不讓 AI 選它當約定地點——不是
# 遺漏，見 note/技術/村莊地圖.md
func list() -> PackedStringArray:
	var names := PackedStringArray()
	for child in get_children():
		if String(child.name).begins_with(HOME_LOCATION_PREFIX):
			continue
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
	"cemetery": "UI_LOC_CEMETERY",
	"forest": "UI_LOC_FOREST",
}


func display_name(place_name: String) -> String:
	var l10n_key: String = DISPLAY_NAME_KEYS.get(place_name, "")
	if l10n_key.is_empty():
		return place_name
	return L10n.t(l10n_key)
