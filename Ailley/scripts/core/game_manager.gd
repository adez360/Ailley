extends Node

var npc_data = {}

# 節點名 -> schedule_template。行程模板是「用哪份資料」，而它跟角色的對應
# 屬於資料不屬於場景：agent.tscn 的 @export 預設值是所有 instance 共用的，
# 兩隻 Agent 就必然拿到同一份行程。要讓它們不一樣，對應關係得寫在這裡
#
# key 用節點名不用 character_id —— id 是生成的 UUID，人在 json 裡手寫不出來
var schedule_assignments = {}

# template_id -> 模板資料（character_name/system_prompt/words_to_creator）。
# #73 的角色庫：先用記憶體清單，不等存檔系統——模板資料是寫死的 json，
# 重開遊戲不會消失，不需要真的存檔
var character_templates = {}

func _ready():
	load_npc_data()
	load_character_templates()

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
	return str(schedule_assignments.get(node_name, ""))

# 讀取角色庫模板（#73）。格式與 load_npc_data() 同一套防呆：檔案不存在或
# JSON 壞掉都只 push_error 不炸開機，模板資料目前是佔位資料，不是關鍵路徑
func load_character_templates():
	var file = FileAccess.open(
		"res://data/character_templates.json",
		FileAccess.READ
	)
	if file == null:
		push_error("找不到 character_templates.json")
		return

	var data = JSON.parse_string(file.get_as_text())
	file.close()

	if data == null or not data is Dictionary:
		push_error("character_templates.json 不是合法的 JSON 物件")
		return

	character_templates.clear()
	for template in data.get("templates", []):
		character_templates[template["template_id"]] = template

# 查詢角色庫模板，沒有回 null 讓呼叫端自己判斷要不要報錯
func get_character_template(template_id: String):
	return character_templates.get(template_id, null)

# 動態生成一個角色、投放進世界（#73）。identity 有給的欄位直接設到節點上，
# 沒給的留空讓 character.gd::_ready() 既有的 fallback／去重生效——這次只開
# character_id、character_name 兩個 key，ai_provider 之類的等對應功能真的
# 要做時再加，不預留空欄位
#
# 節點名一定要在 add_child() 之前換掉，不能等它生效後再改：add_child() 內
# 同步觸發的 _ready() 會呼叫 agent.gd::_load_schedule()，那裡是用「當下
# 節點名」去查 npc_schedule.json 的 assignments 表——場景檔預設的節點名
# （agent.tscn 是 "Agent"）剛好會撞到真正那隻 Agent 的節點名，讓動態生成
# 的角色在 _ready() 期間就悄悄查表命中、繼承 npc001 的整份行程，而且是
# 每一隻動態角色都會撞到同一筆，不是個案（實測踩過，不是預防性註解）。
# agent.gd::_warn_if_node_name_shared() 的存在理由就是要擋這個情況。
#
# 用 character_id（有給就用，沒給就先生一個）當節點名可以保證不會撞進
# assignments 表。沒給 character_id 時，這裡生成的只是暫時的節點名，
# 跟 _ready() 稍後替 character_id 生成的值不是同一個，所以 add_child()
# 之後要再同步一次
func spawn_character(scene: PackedScene, identity: Dictionary) -> Character:
	var character := scene.instantiate() as Character

	# identity 沒給（或給空字串）character_name 時，character.gd::_ready() 會
	# 用「當下節點名」fallback——但那時候節點名還是下面那個臨時值，不是這裡
	# add_child() 之後才同步回去的最終 character_id，記下來給重算用
	var name_given := not str(identity.get("character_name", "")).is_empty()

	if identity.has("character_id"):
		character.character_id = identity["character_id"]
	if identity.has("character_name"):
		character.character_name = identity["character_name"]

	character.name = (
		character.character_id if not character.character_id.is_empty()
		else Character.generate_id()
	)

	get_tree().current_scene.add_child(character, true)
	character.name = character.character_id

	# _ready() 期間 character_name 的 fallback 撿到的是上面那個臨時節點名，
	# 跟自己最終的 character_id 對不上——用最終節點名重算一次補回正確值
	if not name_given:
		character.character_name = character.name.to_lower()

	return character
