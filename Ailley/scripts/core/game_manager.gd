extends Node

var places = {}
var npc_data = {}

# 節點名 -> {schedule_template, character_id, character_name}。這三樣都是
# 「用哪份資料／我是誰」，屬於資料不屬於場景：agent.tscn 的 @export 預設值
# 是所有 instance 共用的，兩隻 Agent 就必然拿到同一份行程、同一個身分。
# 要讓它們不一樣，對應關係得寫在這裡。
#
# key 用節點名不用 character_id —— character_id 沒指定的話是執行期生成的
# UUID，人在 json 裡手寫不出來；這裡指定的 character_id 反過來是給場景裡
# 固定的 demo NPC 用的穩定值，不受這個限制（見 character.gd 的用法）
var schedule_assignments = {}

func _ready():
	load_places()
	load_npc_data()

func load_places():
	var file = FileAccess.open(
		"res://data/places.json",
		FileAccess.READ
	)
	if file == null:
		print("找不到 places.json")
		return

	var data = JSON.parse_string(file.get_as_text())
	file.close()
	places = data["places"]

# 讀取NPC行程
func load_npc_data():
	var file = FileAccess.open(
		"res://data/npc_schedule.json",
		FileAccess.READ
	)
	if file == null:
		push_error("找不到 npc_schedule.json")
		return
		
	var data = JSON.parse_string(file.get_as_text())
	file.close()

	# 解析失敗會回 null，直接索引 data["villagers"] 會在開機期炸掉整個 autoload
	if data == null or not data is Dictionary:
		push_error("npc_schedule.json 不是合法的 JSON 物件")
		return

	npc_data.clear()
	for npc in data.get("villagers", []):
		npc_data[npc["id"]] = npc

	schedule_assignments = data.get("assignments", {})

# 查詢NPC行程
func get_npc(id:String):
	return npc_data.get(id, null)

# 這個角色該用哪份行程模板。沒有指定就回空字串，由呼叫端決定怎麼退回
func get_schedule_template(node_name:String)->String:
	return str(schedule_assignments.get(node_name, {}).get("schedule_template", ""))

# 這個角色的固定身分。沒有指定就回空字串，呼叫端退回執行期生成的值——
# 只有場景裡固定的 demo NPC 會有指定，Player 跟未指派的角色本來就不該有
func get_character_id(node_name:String)->String:
	return str(schedule_assignments.get(node_name, {}).get("character_id", ""))

func get_character_name(node_name:String)->String:
	return str(schedule_assignments.get(node_name, {}).get("character_name", ""))

func get_place_data(place_name:String):
	if !places.has(place_name):
		return null
	return places[place_name]
