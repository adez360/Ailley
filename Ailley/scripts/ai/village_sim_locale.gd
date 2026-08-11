class_name VillageSimLocale
extends RefCounted

## Godot 的地點錨點名稱 ↔ poc_village_sim 的中文地點名稱，兩邊互相翻譯。
##
## 只對照「兩邊都真的存在、意義對得上」的地點，對不上的一律回傳空字串，
## 呼叫端要自己檢查空字串、不要假裝有對應——這份對照表本來就不完整：
## - `farm`（main 的打工地點）在 poc_village_sim 沒有對應（POC 沒有種田機制）
## - `shop`／`temple` 對應到 poc 哪個具體地點是模糊的（服裝鋪？藥草鋪？甘道夫石？
##   概念都不完全一樣），先不亂猜，留空
## - `home_002`~`home_005` 這幾個錨點目前根本不存在於 main.tscn（見
##   note/ai/api.md「已知缺口」），resolve 會失敗，不在這份對照表處理範圍內
##
## 這份對照表是 demo 驗證用途，不是正式資料欄位對齊方案——正式方案要等
## 「中文名字/地點 → Godot character_id/location_id」那層轉換定案再重做
## （見 note/技術/LLM 串接與 AI 服務層.md）。

## server.py 目前綁死的 POC 固定 5 人名單：內部 id -> 中文顯示名。
## 對照 poc_village_sim/characters.py 的角色資料，人一多或名單改了要手動同步——
## 這是 demo 用的暫時對照表，不是長期方案（見檔頭說明）。
const POC_CHARACTER_NAMES := {
	"alan": "阿蘭",
	"zhou": "老周",
	"mei": "小梅",
	"tie": "鐵牛",
	"aji": "阿吉",
}

## Godot 場景裡的角色顯示名 -> poc_village_sim 內部 id，demo 用的暫時對照，
## 只給「視野內其他角色要不要塞進 visible 清單」這件事用。目前場景只有
## agent／agent2 兩隻，其他名字一律查不到（回傳空字串），呼叫端要略過查不到的人，
## 不要假造一個 id 塞進去——幻想出一個查不到對應的人，比讓 AI 不知道有這個人更糟
## （grammar 會把它當合法候選值，AI 可能因此做出指向根本不存在的對象的決策）。
const GODOT_NAME_TO_POC_ID := {
	"agent": "aji",
	"agent2": "alan",
}

## Godot 地點錨點名稱 -> poc_village_sim 中文地點名稱（SharedLocation 那幾個，
## 不含「家」——家是每個角色專屬的，見 godot_home_to_poc_zh()）
const GODOT_TO_POC_SHARED := {
	"restaurant": "餐酒館",
	"square": "村莊廣場",
}

## poc_village_sim 的英文 shared_location 代號（enums.SharedLocation 的
## member 名稱）-> Godot 地點錨點名稱。跟上面那份互為反向，但用不同的 key
## 空間（一邊是中文顯示名，一邊是英文代號），故意分開寫兩份不共用，
## 避免中間再插一層中英對照徒增追蹤難度
const POC_EN_TO_GODOT_SHARED := {
	"tavern": "restaurant",
	"square": "square",
}


## Godot 地點錨點名稱 -> poc_village_sim 的中文地點名稱。
## home_anchor 只有「這個角色自己的家」才翻得對——main 目前只有一個通用的
## home_001 錨點，不是每個角色專屬，所以「別人的家」这裡沒有意義，
## 呼叫端要自己確保 anchor_name 是這個角色自己的家再呼叫
static func godot_place_to_poc_zh(anchor_name: String, is_own_home: bool, poc_character_name: String) -> String:
	if is_own_home:
		return "%s家" % poc_character_name
	return GODOT_TO_POC_SHARED.get(anchor_name, "")


## server.py 回傳的 location 物件（{"kind","shared_location","owner_id"}）
## -> Godot 地點錨點名稱。owner_id 是 poc 內部 id（"aji"這種），不是 Godot
## character_id，只有「決策的就是這個角色自己」時 owner_id 才可能等於
## 自己的 poc_character_id，此時視為「回自己家」
static func poc_location_to_godot_place(location: Dictionary, poc_character_id: String) -> String:
	var kind := str(location.get("kind", ""))
	if kind == "HOME":
		if str(location.get("owner_id", "")) == poc_character_id:
			return "home_001"
		return ""  # 別人的家，main 沒有對應錨點
	if kind == "SHARED":
		return POC_EN_TO_GODOT_SHARED.get(str(location.get("shared_location", "")), "")
	return ""
