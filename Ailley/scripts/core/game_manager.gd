extends Node

## 目前只有一個世界，MVP 沒有建立/選擇世界的流程，先固定一個 id 頂著——
## 真的要支援多世界時，這裡才需要變成可選清單
const DEFAULT_WORLD_ID := "world_001"

## 這個世界允不允許 player 加入，建立世界時就該決定的旗標（見
## note/技術/存檔.md「允不允許 player 加入，也屬於世界」）。MVP 沒有建立
## 世界的流程，先固定 true；問的是「允不允許」不是「現在有沒有人」，
## 後者是角色層的事，不在這裡算
var allow_player_join := true

## 主選單按下「繼續遊戲」時設為 true，main.tscn 的 MainScene._ready() 讀到
## true 才會套用世界／角色存檔，讀完立刻重設回 false（見 scripts/core/main_scene.gd）。
## GameManager 是 autoload，換場景不會重置，這個旗標是唯一分辨「這次進
## main.tscn 是繼續遊戲還是開新遊戲」的方式——兩條路徑進場景後場景本身
## 完全一樣，差別只在要不要套用存檔
var continue_requested := false

## main_scene.gd 發現「主選單檢查時還在」的世界存檔在轉場後消失或讀不出來時
## 設為 true。這種情況下 continue_requested 已經被清成 false，主選單只靠
## has_world()/is_world_data_valid() 重新檢查會誤判成「本來就沒有存檔」，
## 玩家只看得到開始遊戲、看不到明確的讀檔失敗提示——這個旗標讓主選單分辨
## 這兩種情況。跟 continue_requested 一樣是一次性的，main_menu.gd 讀過一次
## 就要重設回 false（見 main_scene.gd::_apply_continue()）
var continue_load_failed := false

## 目前被玩家操控的 character_id，跟 allow_player_join 同一層世界存檔資料
## （見 note/技術/存檔.md、issue #373）。存檔時從場景 "player" 分組即時算出來
## （見 get_world_save_data()），不是這裡手動維護的即時狀態——這個變數只在
## 讀檔時被寫入，放在這裡讓其他系統之後有地方可以查。
##
## 目前沒有任何呼叫端會依這個值重新指派化身：真正的「換身」需要 #371（化身者
## 投放路由）先把「投放時選擇由玩家操控」這個機制做出來，這裡只先接上存讀路徑，
## 跟 #381 墓碑欄位那次同一種「欄位形狀先確定，行為留給依賴的 issue」處理方式
var embodied_character_id := ""

var npc_data = {}

# 節點名 -> schedule_template。行程模板是「用哪份資料」，而它跟角色的對應
# 屬於資料不屬於場景：agent.tscn 的 @export 預設值是所有 instance 共用的，
# 兩隻 Agent 就必然拿到同一份行程。要讓它們不一樣，對應關係得寫在這裡
#
# key 用節點名不用 character_id —— id 是生成的 UUID，人在 json 裡手寫不出來
var schedule_assignments = {}

# 節點名 -> {character_id, character_name, hexaco, character}。場景裡固定的 NPC，
# 身分（id/顯示名/人格）是設計時決定好的資料，不是執行期才生、需要被記住的
# 狀態——寫死在這裡才能讓 character_id 跨場次穩定（relationships 拿它當 key，
# 變了等於失憶），也讓兩隻 Agent 有各自不同的人格而不是共用場景預設值。
# 跟 schedule_assignments 一樣用節點名查表，跟它分兩塊是因為「用哪份行程」與
# 「我是誰」是兩件不同的事（見 agent.gd schedule_template 的註解）。
#
# hexaco 六維與 character 自述怎麼變成 personality 十項與 system_prompt，
# 見 scripts/character/personality.gd（#117，《01-1》§3～§5）
var identity_assignments = {}

# template_id -> 模板資料（character_name/system_prompt/words_to_creator）。
# #73 的角色庫：先用記憶體清單，不等存檔系統——模板資料是寫死的 json，
# 重開遊戲不會消失，不需要真的存檔
var character_templates = {}

# 玩家自建角色（#122）：靈魂庫，記錄已建立的完整角色紀錄與 deployed 狀態。跟著
# 世界存檔一起存讀（#342，見 get_world_save_data()/apply_world_save_data()）——
# 這份清單不屬於任何一個場上節點，沒有 Character.get_save_data() 可以掛，只能
# 收在世界層這一包裡
const CHARACTER_LIBRARY_CAP := 15

# 世界內同時投放上限（《10》B21，預設 5、房主可下修，這次先固定預設值）
const DEPLOY_CAP := 5

var character_library: Array[Dictionary] = []

func _ready():
	load_npc_data()
	load_character_templates()
	# 跨遊戲日自動存檔（#359），見下方 _on_day_changed_autosave() 的時序說明
	GameClock.day_changed.connect(_on_day_changed_autosave)

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

	var identities_raw = data.get("identities", {})
	if identities_raw is Dictionary:
		identity_assignments = identities_raw
	else:
		push_error("npc_schedule.json identities 不是 Dictionary")
		identity_assignments = {}

# 查詢NPC行程
func get_npc(id:String):
	return npc_data.get(id, null)

# 這個角色該用哪份行程模板。沒有指定就回空字串，由呼叫端決定怎麼退回
func get_schedule_template(node_name:String)->String:
	return str(schedule_assignments.get(node_name, ""))

# 這個節點名對應的固定身分（{character_id, character_name, hexaco, character}）。沒指派就回空字典，
# 由呼叫端（character.gd::_ready()）退回生成 UUID／節點名。Player 與動態生成的
# 角色節點名都查不到，自然落回原本行為
func get_npc_identity(node_name:String)->Dictionary:
	var entry = identity_assignments.get(node_name, {})
	if entry is Dictionary:
		return entry
	else:
		push_error("npc_schedule.json identities[%s] 不是 Dictionary" % node_name)
		return {}

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
		var template_id: String = template["template_id"]
		# 撞號靜默覆蓋會讓前一筆模板悄悄從角色庫消失，跟
		# character.gd::_ensure_unique_id() 撞 id 一律報錯的原則不一致
		if character_templates.has(template_id):
			push_warning("character_templates.json: template_id 重複 %s，後面那筆蓋掉前面" % template_id)
		character_templates[template_id] = template

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

	# words_to_creator 只有角色庫投放這條路徑會給（那份是建角當下就生成好、
	# 可能已人工檢閱過的內容）。要在 add_child() 觸發 _ready() 之前設好——
	# Agent._ready() 呼叫的 _generate_words_to_creator() 一看到欄位已經有內容
	# 就不會再打一次多餘的 AI 呼叫（見那邊的 is_empty() 防呆，CodeRabbit review
	# 抓到「角色庫已生成的內容會被非同步回應蓋掉」，這裡才是真正補上傳遞路徑）。
	# 用 get()/set() 而不是型別轉型：這欄只有 Agent 才有，spawn_character() 收的
	# 是泛型 Character，不該假設一定是 Agent
	if identity.has("words_to_creator") and character.get("words_to_creator") != null:
		character.set("words_to_creator", identity["words_to_creator"])

	character.name = (
		character.character_id if not character.character_id.is_empty()
		else Character.generate_id()
	)

	# agent.tscn 根節點的 schedule_template 匯出值烘焙成 "npc001"，不是
	# agent.gd 原始碼寫的空字串預設值（見 issue #132）。Agent/Agent2 不受
	# 影響——assignments 查表命中一律覆蓋這個欄位；但動態生成的角色節點名
	# 是 UUID，assignments 必然查不到，_load_schedule() 會退回這個殘留值，
	# 讓每一隻動態角色都載入同一份 npc001 行程。這裡只清掉這個 instance
	# 自己的值，不改場景檔——場景檔本身要不要清是 #132 的範圍，不是這裡。
	# 用 get()/set() 而不是型別轉型：schedule_template 是 agent.gd 才有的
	# 欄位，spawn_character() 收的是泛型 Character，不該假設一定是 Agent
	if character.get("schedule_template") != null:
		character.set("schedule_template", "")

	get_tree().current_scene.add_child(character, true)
	character.name = character.character_id

	# _ready() 期間 character_name 的 fallback 撿到的是上面那個臨時節點名，
	# 跟自己最終的 character_id 對不上——用最終節點名重算一次補回正確值
	if not name_given:
		character.character_name = character.name.to_lower()

	# 動態生成的角色在這之前一律停在 Node2D 預設座標 (0, 0)，跟玩家的實際
	# 出生點是兩個互不相關的座標，導致 vision 幾乎必然偵測不到玩家、
	# LLM 決策收到「附近沒有任何人」而只能回傳 idle（issue #685）。落點選
	# 涼亭（`pavilion`）——規格書裡本來就是社交聚集地，語意上最合理。
	# 錨點需要透過 "place_anchors" 群組取得（見 places.gd），找不到就維持
	# 原點，不讓投放整個失敗
	var anchors := get_tree().get_first_node_in_group("place_anchors")
	if anchors != null and anchors.has("pavilion"):
		character.global_position = anchors.resolve("pavilion")

	return character


# ---- 角色庫（#122，玩家自建角色）----

# 把建角面板 collect() 出來的資料轉成角色庫的一筆紀錄並存進去。面板只負責
# 蒐集資料（character_create.gd 的既有原則），存檔驗證→角色生成→角色庫這段
# 管線接在這裡，由 character_create.gd 開場連的 character_saved 訊號觸發
func receive_created_character(data: Dictionary) -> void:
	# collect() 帶 "id" 代表面板走的是 edit()（規格書 05 §7-1「編輯」），
	# 要原地覆蓋既有那筆，不是新增——不然編輯一次角色庫就多一筆同名孤兒紀錄，
	# 而且會再打一次一次性的 words_to_creator（CodeRabbit review 抓到）
	var editing_id := str(data.get("id", ""))
	var existing := get_library_entry(editing_id) if not editing_id.is_empty() else {}

	# 已投放的不可編輯（《05》§7-1）。面板端 edit() 只讀不到已投放的？不，
	# 面板本身不擋——角色庫首頁才擋（編輯按鈕對已投放者 disabled），這裡是
	# 資料層最後一道防線，跟 remove_from_library() 對已投放者的擋法一致
	if not existing.is_empty() and existing.get("deployed", false):
		push_warning("GameManager: %s 已投放，不能編輯" % existing["character_name"])
		return

	if existing.is_empty() and character_library.size() >= CHARACTER_LIBRARY_CAP:
		push_warning("GameManager: 角色庫已滿（上限 %d），%s 沒有存進去" % [CHARACTER_LIBRARY_CAP, data.get("character_name", "")])
		return

	var hexaco := {}
	for key in ["hex_honesty", "hex_emotionality", "hex_extraversion", "hex_agreeableness", "hex_conscientiousness", "hex_openness"]:
		hexaco[key] = data.get(key, 50)
	var description := str(data.get("character", ""))

	var id: String = existing["id"] if not existing.is_empty() else Character.generate_id()
	var persona := Personality.from_identity({"hexaco": hexaco, "character": description}, id)

	var entry := {
		"id": id,
		"character_name": str(data.get("character_name", "")),
		"age": int(data.get("age", 30)),
		"gender": str(data.get("gender", "other")),
		"decision_source": str(data.get("decision_source", "human")),
		"model_name": str(data.get("model_name", "")),
		"hexaco": hexaco,
		"character": description,
		"appearance": data.get("appearance", []),
		# 選中哪一格造型組的索引（appearance[] 內容本身待《99》P-38 填）。
		# 編輯既有角色時要能還原這個選擇，不然 character_create.gd::_load_entry()
		# 每次都被迫重置成 -1、鎖住存檔鈕直到重新手動選一次（issue #683）
		"appearance_style_index": int(data.get("appearance_style_index", -1)),
		"personality": persona["personality"],
		"system_prompt": persona["system_prompt"],
		# 編輯時沿用既有的 words_to_creator——人格改了不代表要重打一次
		# 只在建立當下才有意義的一次性 AI 呼叫
		"words_to_creator": str(existing.get("words_to_creator", "")),
		"deployed": false,
	}

	if existing.is_empty():
		character_library.append(entry)
		_generate_words_to_creator(entry)
	else:
		character_library[character_library.find(existing)] = entry


# 建角完成當下打一次的 AI 呼叫（規格書 05 流程圖 ⑤），跟 plan/dialogue/
# reflection 平行的第四種信封類型，只在這一刻打一次。fire-and-forget：
# 存檔本身不等這通請求，跟 workstation.gd::_run_work() 同一種協程模式——
# 角色已經進角色庫，AI 回應晚到只補 words_to_creator 這一個欄位。
# requester_id 用角色自己的 id，走 Policy.CREATION——跟這隻角色之後投放時
# 第一次 plan 決策（Policy.SCHEDULED）是各自獨立的冷卻池，這通不會佔掉
# 那邊的額度（issue #682）
func _generate_words_to_creator(entry: Dictionary) -> void:
	var envelope := PromptBuilder.build_creation_envelope(entry["system_prompt"])
	var result: Dictionary = await AIService.request(envelope, entry["id"], AIService.Policy.CREATION)
	if not result["ok"]:
		return
	var parsed := AISchema.parse_completion(result["data"])
	if not parsed["ok"]:
		return
	var validated := AISchema.validate_creation(parsed["data"])
	if not validated["ok"]:
		return
	entry["words_to_creator"] = validated["data"]["words_to_creator"]


func get_library_entry(id: String) -> Dictionary:
	for entry in character_library:
		if entry["id"] == id:
			return entry
	return {}


# deploy_from_library() 直接索引 id／character_name／hexaco／character／
# decision_source／model_name，缺欄位或型別不對的紀錄留到投放當下才炸，
# 不如讀檔時就跳過——這幾個欄位跟其他「缺了用預設值補」的欄位不同，
# 是 deploy_from_library() 沒有防呆能力的必要欄位（CodeRabbit review 抓到）
func _is_valid_library_entry(entry) -> bool:
	if not entry is Dictionary:
		return false
	var id = entry.get("id", null)
	if not (id is String) or id.is_empty():
		return false
	if not entry.get("character_name", null) is String:
		return false
	if not entry.get("hexaco", null) is Dictionary:
		return false
	if not entry.get("character", null) is String:
		return false
	if not entry.get("decision_source", null) is String:
		return false
	if not entry.get("model_name", null) is String:
		return false
	# deployed 缺欄位是舊存檔相容（視同 false），但存在就要是 bool——
	# deploy_from_library() 的投放人數計算跟 character_library.gd 的
	# var deployed: bool 都會拿它當條件用，型別不對會在別處才炸
	if entry.has("deployed") and not entry["deployed"] is bool:
		return false
	return true


# 已投放的角色不能刪——刪了場上生出來的 Character 節點會變孤兒（沒有任何
# 紀錄指向它），deploy_from_library() 的 deployed_count 也只掃
# character_library，刪掉之後計數會下降，變成可以無視 DEPLOY_CAP 重複投放
# （CodeRabbit review 抓到）。要收回一隻已投放角色，先做的是撤回（見《05》
# §7-3，這則不含撤回機制的實作），不是直接刪角色庫紀錄
func remove_from_library(id: String) -> bool:
	for i in character_library.size():
		if character_library[i]["id"] == id:
			if character_library[i].get("deployed", false):
				push_warning("GameManager: %s 已投放，先收回才能刪除" % character_library[i]["character_name"])
				return false
			identity_assignments.erase(id)
			character_library.remove_at(i)
			return true
	return false


# 複製一份，新 id、名字加後綴、投放狀態重置（《05》§7-1「複製」）
func duplicate_library_entry(id: String) -> Dictionary:
	var source := get_library_entry(id)
	if source.is_empty() or character_library.size() >= CHARACTER_LIBRARY_CAP:
		return {}

	var copy := source.duplicate(true)
	copy["id"] = Character.generate_id()
	copy["character_name"] = source["character_name"] + L10n.t("UI_CL_COPY_SUFFIX")
	copy["deployed"] = false
	character_library.append(copy)
	return copy


# 投放：把角色庫的靈魂生成這個世界的肉體副本（《05》§7-2、§7-3）。已投放的
# 不能重複投放——一份靈魂同時只該有一具肉體，是《05》§7-1「已投放的角色
# 不可編輯」規則的自然延伸
func deploy_from_library(id: String, as_player: bool = false) -> Character:
	var entry := get_library_entry(id)
	if entry.is_empty() or entry.get("deployed", false):
		return null

	var deployed_count := 0
	for e in character_library:
		if e.get("deployed", false):
			deployed_count += 1
	if deployed_count >= DEPLOY_CAP:
		push_warning("GameManager: 世界投放上限已滿（%d），%s 沒有投放" % [DEPLOY_CAP, entry["character_name"]])
		return null

	# 借用既有的 identity_assignments 查表機制：spawn_character() 會把節點名
	# 設成 character_id，Character._ready() 讀 GameManager.get_npc_identity(name)
	# 組 system_prompt/personality——註冊在這張表下，_ready() 不用改就能撿到
	# 這隻角色真正的人格資料，而不是撿到空字典、退回沒有人格的最小版 system_prompt。
	# 化身者（as_player）一樣註冊，六維人格保留當角色履歷/存檔用途（#372）
	identity_assignments[entry["id"]] = {
		"character_id": entry["id"],
		"character_name": entry["character_name"],
		"hexaco": entry["hexaco"],
		"character": entry["character"],
	}

	# 同一時間只該有一個真人操控的身體——main.tscn 設計時期擺的測試用 Player
	# 節點、或先前已投放的化身角色，都跟即將投放的這隻搶「player」分組，
	# get_first_node_in_group("player")（hotbar.gd／follow_camera.gd 等一律
	# 靠這個查表）撈到的永遠是先加進場景那個，新投放的等於白投（實測重現過：
	# 兩個節點同時掛在 player 分組，查表撈到舊的）
	if as_player:
		for node in get_tree().get_nodes_in_group("player"):
			var old_player := node as Character
			if old_player != null:
				var old_entry := get_library_entry(old_player.character_id)
				if not old_entry.is_empty():
					old_entry["deployed"] = false
			node.remove_from_group("player")
			node.queue_free()

	var scene := preload("res://scenes/player.tscn") if as_player else preload("res://scenes/agent.tscn")
	var character := spawn_character(scene, {
		"character_id": entry["id"],
		"character_name": entry["character_name"],
		"words_to_creator": entry.get("words_to_creator", ""),
	})

	# decision_source／model_name 是 agent.gd 的 @export 欄位，player.gd 沒有
	# 這兩個欄位（Player extends Character，不是 Agent）——get() 對化身者一定
	# 回傳 null，這個判斷式本來就會自動跳過，不需要另外用 as_player 分支
	if character.get("decision_source") != null:
		character.set("decision_source", entry["decision_source"])
		character.set("model_name", entry["model_name"])
		# spawn_character() 內的 add_child() 已經觸發過 _ready()，_provider
		# 那時候是照 @export 預設值（"local"）建的——上面兩行剛套上去的值
		# 要重建一次 provider 才會生效，不然角色庫選的來源形同沒選
		# （CodeRabbit review 抓到的時序 bug）
		if character.has_method("rebuild_provider"):
			character.rebuild_provider()

	entry["deployed"] = true
	activate_llm_decision_if_ready(character)

	return character


# main_scene.gd::_apply_startup_ai_state() 只在開機時跑一次，只認開機當下
# 已經在 agents group 裡的節點——不管是投放（deploy_from_library()）、還原
# 存檔（_respawn_character()）或 debug 主控台直接生成（debug_console.gd
# ::_cmd_spawn），生出來的角色那時候都還不存在，永遠不會被那個迴圈打開
# llm_decision_enabled，會是完全靜止、不做任何決策的殭屍角色（issue #598）。
# 這裡比照它的 readiness 判斷，在生成當下決定要不要開，讓每條會動態生成
# 角色的路徑都共用同一道關卡，不用各自補一份。
#
# 一定要先 await AIService.await_readiness_settled()：_respawn_character()
# 是從 main_scene.gd::_apply_continue() 呼叫的，而那一步發生在
# _apply_startup_ai_state() 自己的 await_readiness_settled() 之前——這個
# 時間點探測可能根本還沒跑完，直接查 get_readiness() 會抓到假的「未就緒」
# 快照，而且沒有人會重試（CodeRabbit review 抓到）。await_readiness_settled()
# 本身在探測已結算時會立刻回、不會多等，所以投放／debug 生成這些「早就
# 結算完畢」的路徑呼叫這裡不會感覺到延遲。await 期間節點可能被場景換掉
# 或角色本身被移除（is_instance_valid 防呆）。呼叫時機要在
# decision_source／rebuild_provider() 都設定完之後，不然 get_provider_name()
# 撈到的還是預設值。化身者（as_player）是 Player 節點、沒有這個欄位，
# as Agent 轉型會是 null 自然跳過
func activate_llm_decision_if_ready(character: Character) -> void:
	var agent := character as Agent
	if agent == null:
		return
	await AIService.await_readiness_settled()
	if not is_instance_valid(agent):
		return
	var readiness := AIService.get_readiness(agent.get_provider_name())
	if not readiness.get("ready", false):
		return

	# agent.gd::_ready() 剛剛可能已經 fire-and-forget 打過一次
	# _generate_words_to_creator()（words_to_creator 沒預填才會真的送）——
	# 那通走 AIService.Policy.CREATION，跟這裡即將發起的第一次決策
	# （Policy.SCHEDULED）是各自獨立的冷卻池，不用像 issue #682 之前那樣
	# 等一輪冷卻才能開決策
	agent.debug_set_llm_decision(true)


# ---- 存檔 ----

# 世界存檔資料：日曆、每個角色在這個世界裡的位置與行程狀態、允不允許
# player 加入。角色「是誰」（身分／數值／關係）屬於角色層，見
# character.gd::get_save_data()——這裡只收位置這類「只對這個世界有意義」的
# 東西（見 note/技術/存檔.md「位置屬於世界，不屬於角色」）
func get_world_save_data() -> Dictionary:
	var characters := {}
	for node in get_tree().get_nodes_in_group("characters"):
		var character := node as Character
		# 存 character.global_position（節點自己的座標），不是
		# get_body_position()（碰撞體的世界座標，兩者差一個 collider 偏移）——
		# 寫入跟讀回都用同一個點，才不用另外還原 collider 偏移的反運算。
		# JSON 沒有 Vector2 型別，存成 [x, y] 而不是直接塞 Vector2：
		# JSON.stringify() 對它只會呼叫 str()，讀回來的是格式化字串不是座標
		var entry := {
			# 場景裡目前找不到這個 character_id 時，apply_world_save_data() 要靠
			# 這欄決定重新生成該用 agent.tscn 還是 player.tscn（#344）
			"type": "agent" if character is Agent else "player",
			"position": [character.global_position.x, character.global_position.y],
		}
		# current_place／current_state 只有 Agent（行程仲裁器）才有意義，
		# Player 沒有這兩個欄位——用 get() 而不是型別轉型，跟
		# spawn_character() 判斷 schedule_template 同一種寫法
		if character.get("current_place") != null:
			entry["current_place"] = character.get("current_place")
			entry["current_state"] = character.get("current_state")
		# following_id 跟 current_place／current_state 同一種條件——只有
		# Agent 才有這個欄位（issue #576），Player 沒有。空字串代表沒在
		# 跟隨任何人，跟 GameManager/SqliteSaveService 對 current_place
		# 的空字串規則一致，不用另外判斷 null
		if character.get("following_id") != null:
			var following_id: String = character.get("following_id")
			if not following_id.is_empty():
				entry["following_id"] = following_id
		characters[character.character_id] = entry

	# "player" 分組只會有玩家目前操控的那一個節點（player.gd::_ready() 裡
	# add_to_group("player")），沒有玩家在場（觀察者模式）就是空的——跟
	# characters 一樣即時從場景算，不吃快取的 embodied_character_id
	var player_node := get_tree().get_first_node_in_group("player") as Character

	return {
		"day": GameClock.day,
		"hour": GameClock.hour,
		"minute": GameClock.minute,
		"allow_player_join": allow_player_join,
		"embodied_character_id": player_node.character_id if player_node != null else "",
		"characters": characters,
		# deep duplicate：character_library 裡的巢狀 hexaco/personality 字典
		# 不能跟目前記憶體裡那份共用參照，否則存檔之後繼續玩，字典被原地改到
		# 會連已經寫出去的這包也跟著變
		"character_library": character_library.duplicate(true),
	}

# 存下目前世界裡每個角色 + 這個世界本身，回傳結果供呼叫端自行決定怎麼呈現
# ——debug console 的 save 指令（#21）、跨遊戲日自動存檔、離開遊戲時的自動存檔
# （#359）都走這裡，避免「存哪些東西、順序為何」在三個呼叫端各自維護一份、
# 之後改一處忘了改另一處
func save_all() -> Dictionary:
	var character_count := 0
	var character_failures: Array[String] = []
	for node in get_tree().get_nodes_in_group("characters"):
		var character := node as Character
		if SaveService.save_character(character.character_id, character.get_save_data()):
			character_count += 1
		else:
			character_failures.append(character.character_name)

	return {
		"character_count": character_count,
		"character_failures": character_failures,
		"world_ok": SaveService.save_world(DEFAULT_WORLD_ID, get_world_save_data()),
	}

# 場上一個角色都沒有代表現在停在主選單，不是真的在玩——GameClock 是 autoload，
# 換回主選單也不會停止跑動，day_changed／WM_CLOSE_REQUEST 兩條自動存檔路徑都要
# 擋這個情況，否則會拿一份空的世界狀態去蓋掉玩家還沒讀進來、原本有效的存檔
func _has_active_game_session() -> bool:
	return not get_tree().get_nodes_in_group("characters").is_empty()

# 跨遊戲日自動存檔（#359 拍板：存檔時機是每遊戲日結束時＋離開遊戲時）。用
# call_deferred 而不是在這裡直接存，是因為記憶衰減（memory.gd::_on_day_changed
# 的 decay_all()）也掛在同一個 GameClock.day_changed 上——同一次 emit() 裡，
# 各個 handler 依連線順序同步執行，GameManager 是 autoload、_ready() 比場上
# 角色的 memory 元件更早跑，連線順序早不代表執行順序也該早。deferred call
# 排在這次訊號廣播的所有同步 handler 都跑完之後才執行，不管連線順序是誰先誰後
# 都能保證存到的是衰減「之後」的結算狀態，不是半結算狀態。
#
# 睡眠反思（agent.gd::request_sleep_reflection()）不是掛在這個訊號上，而是
# 角色自己進入 sleep 狀態時各自觸發、且是不等待的 fire-and-forget 非同步 AI
# 呼叫——deferred call 這招只能確保「同一顆呼叫堆疊內的同步工作」都做完，
# 換不到「還在飛的網路請求」。所以真正存檔前另外呼叫
# _wait_for_sleep_reflections_to_settle()，靠 Agent.is_sleep_reflection_settled()
# 把場上角色的反思都等到套用完成（#468），不管連線順序是誰先誰後，在未逾時的
# 情況下都能保證存到的是反思「之後」的狀態；逾時則依下方規則放棄等待、照樣
# 存檔（見 note/技術/存檔.md）
func _on_day_changed_autosave(_day: int) -> void:
	call_deferred("_autosave_on_day_change")

# #468：30 秒是抓寬的 best-effort 窗口，不是精確算出的完整最壞情況上限——
# AIService.RETRY_LIMIT（1 次重試）只套用在逾時以外的可重試錯誤，逾時本身
# 不重試（見 ai_service.gd::_interpret()）；provider.timeout 可能被設定檔
# 覆寫，不保證等於 AIConfig.DEFAULT_TIMEOUT（10 秒）；_decide_with_retry() 的驗證
# 重試（provider.max_validation_retries()）與撞期補跑
# （_sleep_reflection_pending）都可能讓實際等待時間超過這個窗口。這裡不
# 無限等——逾時就放棄等待、照樣存檔：存到的是反思套用前的狀態，跟完全不等
# 的舊行為一樣，不會比現在更差，只是把「等得到」的大多數情況從已知殘留
# 限制裡拿掉
const SLEEP_REFLECTION_WAIT_TIMEOUT_SEC := 30.0

func _autosave_on_day_change() -> void:
	if not _has_active_game_session():
		return
	await _wait_for_sleep_reflections_to_settle()
	if not _has_active_game_session():
		return
	var result := save_all()
	for character_name in result["character_failures"]:
		push_error("跨日自動存檔失敗：%s" % character_name)
	if not result["world_ok"]:
		push_error("跨日自動存檔失敗：世界 %s" % DEFAULT_WORLD_ID)

# 只有 Agent 有睡眠反思（Player 沒有 request_sleep_reflection()），逐幀輪詢
# 而不是額外接訊號——反思本身已經用 _sleep_reflection_in_flight／
# _sleep_reflection_pending 兩個旗標完整表達狀態，process_frame 輪詢比另開一組
# 「反思完成」訊號＋在等待期間可能中途離場的角色收/退訂邏輯簡單
func _wait_for_sleep_reflections_to_settle() -> void:
	var deadline_msec := Time.get_ticks_msec() + int(SLEEP_REFLECTION_WAIT_TIMEOUT_SEC * 1000.0)
	while true:
		var pending_names: Array[String] = []
		for node in get_tree().get_nodes_in_group("characters"):
			var agent := node as Agent
			if agent != null and not agent.is_sleep_reflection_settled():
				pending_names.append(agent.character_name)
		if pending_names.is_empty():
			return
		if Time.get_ticks_msec() >= deadline_msec:
			push_warning(
				"跨日自動存檔：等待睡眠反思逾時（%.0f 秒），以下角色的反思可能還沒套用就存檔了：%s"
				% [SLEEP_REFLECTION_WAIT_TIMEOUT_SEC, ", ".join(pending_names)]
			)
			return
		await get_tree().process_frame

# 離開遊戲時存檔（#359）。要接得到這個通知，project settings 的
# application/config/auto_accept_quit 要先設為 false（見
# note/技術/存檔.md），否則 Godot 預設關窗會直接結束，這裡完全收不到
# NOTIFICATION_WM_CLOSE_REQUEST。存檔（不論成功與否）之後都要自己呼叫
# get_tree().quit()——設 auto_accept_quit=false 之後引擎不會再自動關閉，
# 不呼叫的話關閉按鈕會變得完全沒反應。save_before_leaving() 內部會 await
# 睡眠反思結算，這裡也要 await，quit() 才不會搶在存檔完成前執行
func _notification(what: int) -> void:
	if what != NOTIFICATION_WM_CLOSE_REQUEST:
		return
	await save_before_leaving()
	get_tree().quit()

# 離開目前對局共用的存檔收尾——關視窗（上面的 _notification）、Esc 選單
# 「回主選單」都算「離開遊戲」（#359 存檔時機之一），走同一條路避免兩處
# 各自維護一份存檔＋錯誤處理。回傳是否全部存檔成功——關視窗那條路不看這個值
# （視窗都要關了擋不住），但 Esc 選單「回主選單」要靠它決定能不能真的切場景，
# 不然存檔失敗會悄悄弄丟進度（CodeRabbit review on #587 抓到）。
#
# 存檔前跟 _autosave_on_day_change() 一樣 await _wait_for_sleep_reflections_to_settle()——
# 離場前一刻角色可能才剛進入睡眠、反思還沒套用 personality_delta／today_plan，
# 不等的話這兩條離場路徑會存到反思套用「前」的舊狀態（CodeRabbit review on #587 抓到）
func save_before_leaving() -> bool:
	if not _has_active_game_session():
		return true
	await _wait_for_sleep_reflections_to_settle()
	if not _has_active_game_session():
		return true
	var result := save_all()
	for character_name in result["character_failures"]:
		push_error("離開遊戲存檔失敗：%s" % character_name)
	if not result["world_ok"]:
		push_error("離開遊戲存檔失敗：世界 %s" % DEFAULT_WORLD_ID)
	return result["world_ok"] and result["character_failures"].is_empty()

# data 缺欄位一律用預設值補，不當成錯誤（跟 character.gd 同一條規則）。
# 場景裡目前找到的角色直接套用；存檔裡有記載但場景沒有的角色會被重新生成
# 再套用（#344，見 _respawn_character()）——只處理反向情況（場景有、存檔沒有）
# 一律不動，不主動移除任何節點，留給之後真的需要時再決定
func apply_world_save_data(data: Dictionary) -> void:
	GameClock.day = int(data.get("day", GameClock.day))
	# 存檔損毀／手改可能塞進超出時鐘實際範圍的值（例如 hour: 99）——GameClock._process()
	# 本身只會遞增到 24/60 就回捲，從沒檢查過賦值當下的範圍，讀檔這裡守住，不合法就
	# 保留目前值並 push_error，跟下面 position 的驗證同一種規則。JSON.parse_string()
	# 對所有數字一律回傳 TYPE_FLOAT（沒有 int/float 之分），只認 TYPE_INT 會讓正常
	# JSON 存檔的 hour/minute 每次都被判定成無效——改成接受整數值的 float（例如
	# 17.0），只擋真正帶小數的值（例如 17.5）
	var raw_hour = data.get("hour", GameClock.hour)
	if (typeof(raw_hour) == TYPE_INT or typeof(raw_hour) == TYPE_FLOAT) and float(raw_hour) == floor(float(raw_hour)) and int(raw_hour) >= 0 and int(raw_hour) < 24:
		GameClock.hour = int(raw_hour)
	else:
		push_error("apply_world_save_data: hour 不是 0-23 範圍內的整數，保留目前值")
	var raw_minute = data.get("minute", GameClock.minute)
	if (typeof(raw_minute) == TYPE_INT or typeof(raw_minute) == TYPE_FLOAT) and float(raw_minute) == floor(float(raw_minute)) and int(raw_minute) >= 0 and int(raw_minute) < 60:
		GameClock.minute = int(raw_minute)
	else:
		push_error("apply_world_save_data: minute 不是 0-59 範圍內的整數，保留目前值")
	allow_player_join = bool(data.get("allow_player_join", allow_player_join))
	# 缺欄位代表「這份存檔沒有記錄化身角色」（SQLite 的 world 表目前還沒有這個
	# 欄位、或是 #373 之前存的舊 JSON 存檔），不能沿用 GameManager 目前記憶體裡
	# 殘留的值——那個值可能是別份世界存檔留下的，繼續沿用會讓下面的 mismatch
	# 判定跟其他之後讀這個欄位的系統看到錯誤的化身角色
	embodied_character_id = str(data.get("embodied_character_id", ""))

	# 場景裡目前的 player 節點如果不是存檔記錄的那一個，代表需要換身——但
	# 換身機制（#371）還沒做，這裡只能示警，不能真的動。不視為錯誤：MVP
	# 現在場景裡固定只有一個 player 節點，兩者本來就該一致，只有先前手動
	# 換過場景或存檔跨場次挪用時才會觸發。「沒有 player 節點」正規化成空字串
	# 再比較，涵蓋「存檔記錄空但場景有 player」與「存檔記錄有 id 但場景沒
	# player」兩種原本會被漏掉的不一致
	var player_node := get_tree().get_first_node_in_group("player") as Character
	var current_embodied_character_id := player_node.character_id if player_node != null else ""
	if current_embodied_character_id != embodied_character_id:
		push_warning("apply_world_save_data: 存檔記錄的化身角色 %s 跟場景目前的 player 節點 %s 不同，尚無自動換身機制（見 #371），需要手動處理" % [embodied_character_id, current_embodied_character_id])

	var library_data = data.get("character_library", [])
	# clear() 在型別檢查之前——存檔壞掉、library_data 不是 Array 時，也不該
	# 讓上一個世界殘留的 character_library 繼續留在記憶體裡（CodeRabbit review 抓到）
	character_library.clear()
	if library_data is Array:
		var seen_ids := {}
		for entry in library_data:
			if not _is_valid_library_entry(entry):
				push_error("apply_world_save_data: character_library 有一筆紀錄格式不完整或缺必要欄位，跳過")
				continue
			var id: String = entry["id"]
			if seen_ids.has(id):
				push_error("apply_world_save_data: character_library 有重複 id %s，跳過" % id)
				continue
			seen_ids[id] = true
			# 深複製隔離存檔載入來源的巢狀參照，跟 get_world_save_data() 存出去
			# 時 duplicate(true) 同一個理由
			character_library.append(entry.duplicate(true))
	else:
		push_error("apply_world_save_data: character_library 不是 Array，跳過角色庫載入")

	var characters = data.get("characters", {})
	# 驗證 characters 必須是 Dictionary，不是就跳過整個角色載入流程
	if not characters is Dictionary:
		push_error("apply_world_save_data: characters 不是 Dictionary，跳過角色資料載入")
		return

	var found_ids := {}
	for node in get_tree().get_nodes_in_group("characters"):
		var character := node as Character
		found_ids[character.character_id] = true
		var entry = characters.get(character.character_id, {})
		# 驗證每個 entry 必須是 Dictionary
		if not entry is Dictionary:
			push_error("apply_world_save_data: %s 的資料不是 Dictionary，跳過" % character.character_id)
			continue
		if entry.is_empty():
			continue
		_apply_character_entry(character, entry)

	# 存檔裡有記載、但場景裡目前沒有對應節點的角色——重新生成（#344）
	for character_id in characters.keys():
		if found_ids.has(character_id):
			continue
		var entry = characters[character_id]
		if not entry is Dictionary:
			push_error("apply_world_save_data: %s 的資料不是 Dictionary，跳過" % character_id)
			continue
		_respawn_character(character_id, entry)

# entry 的 position／current_place／current_state 驗證與套用，既有節點更新
# 與 _respawn_character() 剛生出來的新節點共用同一套規則
func _apply_character_entry(character: Character, entry: Dictionary) -> void:
	var pos_array = entry.get("position", [])
	# 驗證 position 必須是 Array，包含剛好 2 個元素，且都是數字
	if not pos_array is Array:
		push_error("apply_world_save_data: %s 的 position 不是 Array，跳過" % character.character_id)
		return
	if pos_array.size() != 2:
		push_error("apply_world_save_data: %s 的 position 大小不是 2，跳過" % character.character_id)
		return
	if not (typeof(pos_array[0]) in [TYPE_INT, TYPE_FLOAT] and typeof(pos_array[1]) in [TYPE_INT, TYPE_FLOAT]):
		push_error("apply_world_save_data: %s 的 position 元素不是數字，跳過" % character.character_id)
		return
	character.global_position = Vector2(pos_array[0], pos_array[1])

	if entry.has("current_place") and character.get("current_place") != null:
		character.set("current_place", entry.get("current_place", ""))
		character.set("current_state", entry.get("current_state", "idle"))

	# following_id 讀回（CodeRabbit review 抓到）：不能只在 entry 有這個欄位
	# 時才套用——場上已經存在的 Agent（debug console 的 load 指令套用到
	# 目前還活著的角色）可能在讀檔前正在跟隨某人，缺欄位代表存檔當下沒在
	# 跟隨任何人，這裡要主動清成空字串，不是維持讀檔前殘留的舊值。型別不是
	# String 的髒資料一律當作沒在跟隨，不把不明型別的 Variant 直接塞進去
	if character.get("following_id") != null:
		var raw_following_id: Variant = entry.get("following_id", "")
		if raw_following_id is String:
			character.set("following_id", raw_following_id)
		else:
			if entry.has("following_id"):
				push_error(
					"apply_world_save_data: %s 的 following_id 不是字串，已清空"
					% character.character_id
				)
			character.set("following_id", "")

# 存檔裡有記載、但場景裡目前沒有對應節點的角色——重新生成後套用存檔資料
# （#344）。只有角色庫（character_library）還記得住身分的角色會被生出來：
# npc_schedule.json 那批固定 NPC 是 main.tscn 寫死的節點，本來就不會缺席；
# player 目前 MVP 也是 main.tscn 固定節點，同樣不會走到這裡——這條路徑
# 實際只服務「角色庫投放後重開遊戲」這種情況，type 欄位留給以後真的有
# player 加入世界流程時使用
func _respawn_character(character_id: String, entry: Dictionary) -> void:
	var is_agent := str(entry.get("type", "agent")) != "player"
	var scene: PackedScene = (
		preload("res://scenes/agent.tscn") if is_agent
		else preload("res://scenes/player.tscn")
	)

	if not is_agent:
		var player_character := spawn_character(scene, {"character_id": character_id})
		_apply_character_entry(player_character, entry)
		activate_llm_decision_if_ready(player_character)
		return

	var library_entry := get_library_entry(character_id)
	if library_entry.is_empty():
		push_warning("apply_world_save_data: %s 不在角色庫，用最小身分重新生成" % character_id)
		var minimal_character := spawn_character(scene, {"character_id": character_id})
		_apply_character_entry(minimal_character, entry)
		activate_llm_decision_if_ready(minimal_character)
		return

	# 跟 deploy_from_library() 同一套：identity_assignments 讓 _ready() 撿到
	# 正確的人格資料，而不是退回沒有人格的最小版 system_prompt
	identity_assignments[character_id] = {
		"character_id": character_id,
		"character_name": library_entry.get("character_name", ""),
		"hexaco": library_entry.get("hexaco", {}),
		"character": library_entry.get("character", ""),
	}

	var character := spawn_character(scene, {
		"character_id": character_id,
		"character_name": library_entry.get("character_name", ""),
		"words_to_creator": library_entry.get("words_to_creator", ""),
	})

	# decision_source／model_name 是投放後不可改的欄位（《06》），還原時要跟著
	# 設回去——跟 deploy_from_library() 同一個時序坑：spawn_character() 的
	# add_child() 已經觸發過 _ready()，_provider 是照 @export 預設值
	# （"local"）建的，這裡剛套上去的值要重建一次 provider 才會生效
	if character.get("decision_source") != null:
		character.set("decision_source", library_entry.get("decision_source", "local"))
		character.set("model_name", library_entry.get("model_name", ""))
		if character.has_method("rebuild_provider"):
			character.rebuild_provider()

	_apply_character_entry(character, entry)
	activate_llm_decision_if_ready(character)
