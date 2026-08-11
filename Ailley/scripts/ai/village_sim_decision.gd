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
## 回傳 {"ok": bool, "data": Dictionary, "error": String}——形狀跟
## VillageSimClient.decide() 一樣，`error` 在這一層新增的失敗（角色不是
## Agent、地點翻譯不出來）也會以同樣形狀回傳，呼叫端不用分兩種方式判斷。
static func decide_and_act(character: Node, poc_character_id: String, base_url: String = DEFAULT_BASE_URL) -> Dictionary:
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
			var other_poc_id: String = VillageSimLocale.GODOT_NAME_TO_POC_ID.get(other.character_name, "")
			if other_poc_id.is_empty():
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

	var client := VillageSimClient.new()
	var result: Dictionary = await client.decide(base_url, payload)
	if not result["ok"]:
		return result

	var data: Dictionary = result["data"]
	var output: Dictionary = data.get("output", {})

	# 說話跟動作是不是 move_to 無關，理由同 _cmd_village_ai_act 原本的註解：
	# poc_village_sim 的設計原則是「說話跟 intent.action 是兩件事，可以同時發生」
	var speech = output.get("speech")
	if speech != null and str(speech) != "":
		character.say(str(speech))

	if str(data.get("action_en", "")) == "move_to":
		var target_place := VillageSimLocale.poc_location_to_godot_place(
			data.get("location", {}), poc_character_id
		)
		if not target_place.is_empty():
			var places := (character as Node).get_tree().get_first_node_in_group("place_anchors")
			if places != null and places.has(target_place):
				character.move_to(places.resolve(target_place))
			# 目的地翻譯不出來或找不到錨點：安靜跳過，不執行移動。呼叫端如果
			# 想知道有沒有真的移動，可以自己比對 result.data.action_en 跟事後
			# 角色是不是真的在動——這裡不额外加一個「有沒有執行」的旗標，
			# 保持回傳形狀跟 VillageSimClient.decide() 一致

	return result


static func _fail(error: String) -> Dictionary:
	return {"ok": false, "data": {}, "error": error}
