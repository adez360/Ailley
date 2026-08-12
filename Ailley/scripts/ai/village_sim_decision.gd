class_name VillageSimDecision
extends RefCounted

## 「抓真實狀態 → 打 poc_village_sim/server.py → 執行動作/說話」這一整套流程，
## 從 debug_console.gd 的 _cmd_village_ai_act 抽出來，讓自動觸發（例如玩家靠近
## 時）跟手動指令共用同一份邏輯，不要各寫一份——這正是 [[LLM 串接與 AI 服務層]]
## 記錄過的那種「兩份邏輯分岔」風險，這裡先避開。

const DEFAULT_BASE_URL := "http://127.0.0.1:8100"


## character 必須是 Agent（is_in_group("agents")，要讀 current_place）。
## poc_character_id 只能是 VillageSimLocale.POC_CHARACTER_NAMES 裡的那 5 個。
##
## 只負責「問 AI、拿答案」，**不執行任何動作**——要不要把決策套用到角色身上
## 是呼叫端自己的事，見下面的 apply()。這樣分開是為了對齊組長發的協作規範
## 裡「向下呼叫、向上發信號」的精神：這支工具類不該直接伸手去動角色狀態，
## 副作用要留在角色自己的程式碼路徑裡才看得到、才好追蹤。
##
## 回傳 {"ok": bool, "data": Dictionary, "error": String}——形狀跟
## VillageSimClient.decide() 一樣，`error` 在這一層新增的失敗（角色不是
## Agent、地點翻譯不出來）也會以同樣形狀回傳，呼叫端不用分兩種方式判斷。
static func decide(character: Node, poc_character_id: String, base_url: String = DEFAULT_BASE_URL) -> Dictionary:
	var poc_character_name: String = VillageSimLocale.POC_CHARACTER_NAMES.get(poc_character_id, "")
	if poc_character_name.is_empty():
		return _fail("unknown_poc_character_id:%s" % poc_character_id)

	if not character.is_in_group("agents"):
		return _fail("not_an_agent")

	var current_place: String = character.get("current_place")
	var is_own_home := current_place == "home_001"
	var poc_location := VillageSimLocale.godot_place_to_poc_zh(current_place, is_own_home, poc_character_name)
	if poc_location.is_empty():
		return _fail("location_unmapped:%s" % current_place)

	var visible: Array = []
	if character.vision != null:
		for other in character.vision.get_visible_characters():
			# 問這隻角色自己「你在 poc 那邊是誰」，不要在這裡放一張場景專屬的
			# 對照表——那等於替 Godot 角色發第二組身分，而且表裡的值跟場景一改
			# 就靜默對不上。沒有這個欄位（Player、沒設定的 Agent）就略過：
			# 假造一個 id 塞進去比讓 AI 不知道有這個人更糟，grammar 會把它當合法
			# 候選值，AI 可能因此做出指向根本不存在的對象的決策
			var raw_poc_id = other.get("poc_character_id")
			var other_poc_id: String = "" if raw_poc_id == null else str(raw_poc_id)
			if not VillageSimLocale.POC_CHARACTER_NAMES.has(other_poc_id):
				continue
			# 防呆：兩個不同的 Godot 節點被設定成同一個 poc_character_id 時
			# （操作者設定錯誤，程式不驗證這件事），視野清單不能把「跟自己
			# 同一個 poc 身分」的人算進去——poc_village_sim 那邊沒有「自己對
			# 自己的好感度」這種紀錄，送出去會讓 server.py 直接 500。
			# 這裡擋掉比讓它送出去 crash 再回頭查穩妥
			if other_poc_id == poc_character_id:
				continue
			visible.append({"id": other_poc_id, "activity": "在附近"})

	var half_day := "夜晚" if (GameClock.hour < 6 or GameClock.hour >= 18) else "白天"
	var current_time := "第 %d 天 %02d:%02d（%s）" % [GameClock.day, GameClock.hour, GameClock.minute, half_day]

	var payload := {
		"character_id": poc_character_id,
		"current_time": current_time,
		"location": poc_location,
		"visible": visible,
		"recent_event": "上一刻村子裡各自在忙自己的事，沒有人特別找你",
		"last_emotion": "neutral",
		"current_goal": "",
		"last_action_result": "",
		"recent_memory": "",
	}

	var physiology_override := _build_physiology_override(character)
	if not physiology_override.is_empty():
		payload["physiology_override"] = physiology_override

	var client := VillageSimClient.new()
	return await client.decide(base_url, payload)


## 把 decide() 的結果套用到角色身上——說話跟移動。呼叫端自己決定要不要呼叫
## 這個函式（例如 result["ok"] 是 false 就不會有人呼叫它），這裡不重複做
## ok 檢查，假設呼叫端已經確認過。
##
## character 跟傳給 decide() 的必須是同一個角色，poc_character_id 也要
## 對應同一次呼叫——這裡不重新驗證兩者是否一致，職責已經在 decide() 那層
## 檢查過一次。
##
## poc 的動作白名單有 30 幾種（見 poc_village_sim/enums.py 的 Action），
## Godot 這邊目前只有 move_to 有對應的執行邏輯——不是還沒接線，是其餘動作
## 背後的玩法系統（種田／戰鬥／買賣……）本身還不存在。沒有執行邏輯的動作
## 不能就這樣悄悄無視：AI 決定了什麼，測試/除錯的人要看得到，不然「決策
## 失敗」「決策成功但剛好沒事發生」「根本沒觸發」三種情況畫面上會一模一樣。
static func apply(character: Node, poc_character_id: String, result: Dictionary) -> void:
	var data: Dictionary = result.get("data", {})
	var output: Dictionary = data.get("output", {})

	# 說話跟動作是不是 move_to 無關，理由同前——
	# poc_village_sim 的設計原則是「說話跟 intent.action 是兩件事，可以同時發生」
	var speech = output.get("speech")
	if speech != null and str(speech) != "":
		character.say(str(speech))

	var action_en := str(data.get("action_en", ""))

	if action_en == "move_to":
		var target_place := VillageSimLocale.poc_location_to_godot_place(
			data.get("location", {}), poc_character_id
		)
		if not target_place.is_empty():
			var places := (character as Node).get_tree().get_first_node_in_group("place_anchors")
			if places != null and places.has(target_place):
				character.move_to(places.resolve(target_place))
			# 目的地翻譯不出來或找不到錨點：安靜跳過，不執行移動。呼叫端如果
			# 想知道有沒有真的移動，可以自己比對 data.action_en 跟事後角色是不是
			# 真的在動——這裡不額外加一個「有沒有執行」的旗標，保持單純
	elif not action_en.is_empty():
		# 借用既有的 Bubble 顯示，跟真的說話排在同一個佇列裡——刻意用方括號
		# 跟「尚未實作」字樣，讓人一眼分得出這不是角色台詞，是除錯用的動作提示
		character.say("［%s：尚未實作，僅供除錯查看］" % action_en)


static func _fail(error: String) -> Dictionary:
	return {"ok": false, "data": {}, "error": error}


## Godot Stats.SPEC -> poc_village_sim physiology 的部分對照，只轉得出來
## 這幾項就送這幾項——physiology_override 是淺層合併，沒送的欄位（thirst/
## health/money）會自動沿用 poc 那邊角色檔案原本的值，不用湊齊全部欄位。
## 對照表跟方向反轉的理由見 [[LLM 串接與 AI 服務層]]：
##
##   hunger（100=飽→0=餓） -> hunger（0=飽→100=餓）：方向相反，要反轉
##   energy（100=飽滿→0=沒力） -> stamina（同方向）：直接映射
##   fun（100=不無聊→0=無聊） -> boredom（方向相反）：要反轉
##   social／mood：poc 沒有對應欄位，不送
##
## character.get_state_snapshot() 抓到的是這隻角色到目前為止**持續模擬
## 出來**的真實數值（Stats 元件本來就有 drift 速率、隨真實時間累積變化，
## 不是這裡才臨時生出來的一次性快照），每次呼叫都重新抓一次最新值。
static func _build_physiology_override(character: Node) -> Dictionary:
	var snapshot: Dictionary = character.get_state_snapshot()
	var stats: Dictionary = snapshot.get("stats", {})
	if stats.is_empty():
		return {}

	var override := {}
	if stats.has("hunger"):
		override["hunger"] = 100.0 - float(stats["hunger"])
	if stats.has("energy"):
		override["stamina"] = float(stats["energy"])
	if stats.has("fun"):
		override["boredom"] = 100.0 - float(stats["fun"])
	return override
