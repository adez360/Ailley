extends CanvasLayer

## 遊戲中的 debug 指令輸入框。按 ` 開關，Esc 關閉，上下鍵翻指令歷史。
##
## 輸出的文字在 res://locale/console.csv（CON_* 與 HELP_*）。指令名稱、參數語法、
## 失敗代碼這些是識別字，不進翻譯表 —— 玩家打的字不能隨語系變。

## 同一行裡並排欄位用的分隔符。不用全形空格：那是 CJK 專用的，
## 在 Latin 語系底下會變成一個突兀的大洞
const SEP := "   "

@onready var root: Control = $Root
@onready var output: RichTextLabel = $Root/VBoxContainer/Output
@onready var input: LineEdit = $Root/VBoxContainer/Input

var _commands := {}
var _history: Array[String] = []
var _history_index := 0


func _ready() -> void:
	# 一個指令的 run／usage／help 放同一列，help 留空代表不列進 `help` 指令的輸出
	# （目前只有 help 自己是這樣）。順序就是 `help` 印出來的順序。
	_commands = {
		"goto": {"run": _cmd_goto, "usage": "goto <name> <x> <y>", "help": "HELP_GOTO"},
		"talk": {"run": _cmd_talk, "usage": "talk <name> / talk <a> <b>", "help": "HELP_TALK"},
		"status": {"run": _cmd_status, "usage": "status [name]", "help": "HELP_STATUS"},
		"debug": {"run": _cmd_debug, "usage": "debug [layer] [on|off]", "help": "HELP_DEBUG"},
		"stop": {"run": _cmd_stop, "usage": "stop", "help": "HELP_STOP"},
		"pos": {"run": _cmd_pos, "usage": "pos", "help": "HELP_POS"},
		"nav": {"run": _cmd_nav, "usage": "nav rebuild", "help": "HELP_NAV"},
		"inv": {"run": _cmd_inv, "usage": "inv [name] / inv give <item_id> [count]", "help": "HELP_INV"},
		"money": {"run": _cmd_money, "usage": "money <amount>", "help": "HELP_MONEY"},
		# 同上，help 留空：#116 手動設定 emotion 用的 debug 入口，正式的角色資訊
		# 面板（《15》）不做 emotion 手動編輯，這是唯一的手動設定方式
		"emotion": {"run": _cmd_emotion, "usage": "emotion <name> <type> [intensity]", "help": ""},
		"ai": {"run": _cmd_ai, "usage": "ai [dialogue] [@provider] [text]", "help": "HELP_AI"},
		"locale": {"run": _cmd_locale, "usage": "locale [code]", "help": "HELP_LOCALE"},
		# help 留空：先不進 locale/console.csv，避免動到翻譯資源匯入（這台機器上
		# 曾經卡住），純 debug 用途，之後真的要收進正式指令表再補翻譯
		"tasks": {"run": _cmd_tasks, "usage": "tasks <name>", "help": ""},
		# 同上，help 留空：#112 驗證 nap/rest/wash/idle 執行邏輯用的 debug 入口
		"act": {"run": _cmd_act, "usage": "act <name> <action> [place|target]", "help": ""},
		# 同上，help 留空：#167 驗證記憶結構用的 debug 入口，之後有正式的
		# 角色資訊面板（《15》）接上之後再收進正式指令表
		"memory": {"run": _cmd_memory, "usage": "memory <name>", "help": ""},
		# 同上，help 留空：#117 驗證人格注入用的 debug 入口。system_prompt 是
		# 唯一送進 LLM 的人格表達，肉眼看不到它就沒辦法判斷人格有沒有真的接上
		"persona": {"run": _cmd_persona, "usage": "persona <name>", "help": ""},
		# 同上，help 留空：#168 手動觸發睡眠反思的 debug 入口。真正的睡眠動作
		# （#112）落地前，這是端到端測試整條反思管線唯一的方式
		"reflect": {"run": _cmd_reflect, "usage": "reflect <name>", "help": ""},
		# 同上，help 留空：#73 驗證 GameManager.spawn_character() 管線用的
		# debug 入口，之後有正式的建角面板/角色庫 UI（#122）接上之後再收進
		# 正式指令表
		"spawn": {"run": _cmd_spawn, "usage": "spawn <template_id>", "help": ""},
		# 同上，help 留空：#122 玩家自建角色的入口。建角面板／角色庫首頁本身
		# 沒有任何 HUD 按鈕可以點開（規格書 05 沒有定義掛點），比照 spawn 的
		# 先例走 debug 指令打通管線，不等一個像素風的開場選單
		"charnew": {"run": _cmd_charnew, "usage": "charnew", "help": ""},
		"charlib": {"run": _cmd_charlib, "usage": "charlib", "help": ""},
		# 同上，help 留空：#371 化身者投放路由的唯一入口，正式的「由我操控」
		# 按鈕還沒做（角色庫首頁的視覺任務），先靠指令打通管線驗證 #374
		# 快捷欄/背包接線正確——見 note/技術/建角面板.md
		"embody": {"run": _cmd_embody, "usage": "embody <id>", "help": ""},
		# 同上，help 留空：#21 驗證 SaveService 讀寫進出點用的 debug 入口，
		# 真正的存讀時機（睡前自動存檔等）是後續 issue 才接
		"save": {"run": _cmd_save, "usage": "save", "help": ""},
		"load": {"run": _cmd_load, "usage": "load", "help": ""},
		# 同上，help 留空：#282 驗證 LLM 決策迴圈用的 debug 入口，讓沒接觸過
		# 程式碼的組員能直接切換某隻角色的 llm_decision_enabled，不用進編輯器
		# 改場景。之後有正式的角色資訊面板接上這個開關再收進正式指令表
		"ai_decision": {"run": _cmd_ai_decision, "usage": "ai_decision <name> [on|off]", "help": ""},
		"help": {"run": _cmd_help, "usage": "help", "help": ""},
		"clear": {"run": _cmd_clear, "usage": "clear", "help": "HELP_CLEAR"},
	}
	input.text_submitted.connect(_on_text_submitted)
	_set_open(false)
	_print("[color=888888]%s[/color]" % L10n.t("CON_HINT"))

# 在 _input 攔截，LineEdit 才不會先把這些鍵吃掉（例如把 ` 打進輸入框）
func _input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return

	match event.keycode:
		KEY_QUOTELEFT:
			_set_open(not root.visible)
			get_viewport().set_input_as_handled()
		KEY_ESCAPE:
			if root.visible:
				_set_open(false)
				get_viewport().set_input_as_handled()
		KEY_UP:
			if input.has_focus():
				_recall_history(-1)
				get_viewport().set_input_as_handled()
		KEY_DOWN:
			if input.has_focus():
				_recall_history(1)
				get_viewport().set_input_as_handled()

func _set_open(open: bool) -> void:
	root.visible = open
	if open:
		input.clear()
		input.grab_focus()
	else:
		input.release_focus()

func _recall_history(step: int) -> void:
	if _history.is_empty():
		return

	_history_index = clampi(_history_index + step, 0, _history.size())
	input.text = "" if _history_index == _history.size() else _history[_history_index]
	input.caret_column = input.text.length()

func _print(line: String) -> void:
	output.append_text(line + "\n")

func _on_text_submitted(text: String) -> void:
	input.clear()

	var line := text.strip_edges()
	if line.is_empty():
		return

	_history.append(line)
	_history_index = _history.size()
	_print("[color=888888]> %s[/color]" % line)

	var parts := line.split(" ", false)
	var command := parts[0].to_lower()
	if not _commands.has(command):
		_error(L10n.tf("CON_UNKNOWN_COMMAND", {"cmd": command}))
		return

	_commands[command]["run"].call(parts.slice(1))

func _error(line: String) -> void:
	_print("[color=ff6666]%s[/color]" % line)

func _get_player() -> Character:
	var player := get_tree().get_first_node_in_group("player")
	if player == null:
		_error(L10n.t("CON_NO_PLAYER"))
	return player

func _get_nav() -> Node:
	var nav := get_tree().get_first_node_in_group("nav_grid")
	if nav == null:
		_error(L10n.t("CON_NO_NAVGRID"))
	return nav

# 指令一律用玩家取的 name 指名角色。name 可以撞名，撞到才需要改用 character_id，
# 所以這裡先比對 name，找不到再退回 id
func _get_character(token: String) -> Character:
	var characters := get_tree().get_nodes_in_group("characters")
	var wanted := token.to_lower()
	var matched: Array[Character] = []

	for node in characters:
		if node.character_name.to_lower() == wanted:
			matched.append(node as Character)

	if matched.size() == 1:
		return matched[0]

	if matched.size() > 1:
		var ids: Array[String] = []
		for character in matched:
			ids.append(_short_id(character.character_id))
		_error(L10n.tf("CON_AMBIGUOUS_NAME", {
			"count": matched.size(), "name": token, "ids": ", ".join(ids)
		}))
		return null

	# id 是 36 個字元的 UUID，而且每次開遊戲都不一樣，要人整串打完不切實際 ——
	# 接受前綴。前綴太短撞到多隻就要求打長一點，不要替他猜是哪一隻
	var by_id: Array[Character] = []
	if not token.is_empty():
		for node in characters:
			if node.character_id.begins_with(token):
				by_id.append(node as Character)

	if by_id.size() == 1:
		return by_id[0]

	if by_id.size() > 1:
		_error(L10n.tf("CON_AMBIGUOUS_ID", {"count": by_id.size(), "id": token}))
		return null

	var known: Array[String] = []
	for node in characters:
		known.append("%s (%s)" % [node.character_name, _short_id(node.character_id)])

	_error(L10n.tf("CON_CHARACTER_NOT_FOUND", {"name": token, "known": ", ".join(known)}))
	return null

# UUID 的前 8 碼。足以分辨同一場裡的幾隻，又短到人願意動手打
func _short_id(id: String) -> String:
	return id.substr(0, 8)

func _cmd_goto(args: PackedStringArray) -> void:
	if args.size() != 3 or not args[1].is_valid_int() or not args[2].is_valid_int():
		_error(L10n.t("CON_USAGE_GOTO"))
		return

	var character := _get_character(args[0])
	if character == null:
		return

	var nav := _get_nav()
	if nav == null:
		return

	var cell := Vector2i(args[1].to_int(), args[2].to_int())
	var target: Vector2 = nav.cell_to_world(cell)

	# 目標格不可走時 NavGrid 會自己吸附到最近的可走格，先講清楚免得以為指令沒生效
	if not nav.is_cell_free(cell):
		_print("[color=ffcc66]%s[/color]" % L10n.tf("CON_CELL_BLOCKED", {"cell": cell}))

	if not character.move_to(target):
		_error(L10n.tf("CON_NO_PATH", {"name": character.character_name, "cell": cell}))
		return

	_print(L10n.tf("CON_MOVING_TO", {
		"name": character.character_name,
		"cell": cell,
		"pos": target,
		"points": character.get_path_points().size(),
	}))

	# 綁上角色本身，抵達訊息才會報對人；重複 goto 同一角色不會疊接
	var on_finished := _on_move_finished.bind(character)
	if not character.move_finished.is_connected(on_finished):
		character.move_finished.connect(on_finished)

func _on_move_finished(reached: bool, character: Character) -> void:
	if reached:
		_print(L10n.tf("CON_ARRIVED", {
			"name": character.character_name, "pos": character.get_body_position()
		}))
	else:
		_error(L10n.tf("CON_MOVE_ABORTED", {
			"name": character.character_name, "pos": character.get_body_position()
		}))

func _cmd_stop(_args: PackedStringArray) -> void:
	var player := _get_player()
	if player == null:
		return
	player.stop_moving()
	_print(L10n.t("CON_STOPPED"))

func _cmd_pos(_args: PackedStringArray) -> void:
	var player := _get_player()
	if player == null:
		return

	# pos / cell 是指令名跟資料欄位，不翻
	var line := "pos = %s" % player.get_body_position()
	var nav := get_tree().get_first_node_in_group("nav_grid")
	if nav != null:
		line += SEP + "cell = %s" % nav.world_to_cell(player.get_body_position())
	_print(line)

# 一個參數是玩家對誰搭話；兩個參數是指定發起方，Phase 2 測 Agent 對 Agent 用
func _cmd_talk(args: PackedStringArray) -> void:
	if args.is_empty() or args.size() > 2:
		_error(L10n.t("CON_USAGE_TALK"))
		return

	var speaker: Character
	var listener: Character

	if args.size() == 1:
		speaker = _get_player()
		listener = _get_character(args[0])
	else:
		speaker = _get_character(args[0])
		listener = _get_character(args[1])

	if speaker == null or listener == null:
		return

	var failure: String = speaker.talk_to(listener)
	if failure != Character.TALK_OK:
		# failure 是 TALK_* 代碼，原樣印出。要人話得另做代碼→翻譯 key 的對照
		_error(L10n.tf("CON_TALK_FAILED", {
			"speaker": speaker.character_name,
			"listener": listener.character_name,
			"reason": failure,
		}))
		return

	_print(L10n.tf("CON_TALK_OK", {
		"speaker": speaker.character_name, "listener": listener.character_name
	}))

# 省略 id 就看玩家自己。蒐集資料交給 Character.get_state_snapshot()——
# 這裡只負責把那份純資料的 Dictionary 排版成 BBCode，不重新蒐集一次
func _cmd_status(args: PackedStringArray) -> void:
	if args.size() > 1:
		_error(L10n.t("CON_USAGE_STATUS"))
		return

	var character: Character = _get_player() if args.is_empty() else _get_character(args[0])
	if character == null:
		return

	var snapshot := character.get_state_snapshot()

	_print("[color=88ccff]%s[/color][color=888888]  id %s[/color]" % [
		snapshot["name"], snapshot["id"]
	])

	var where := "%s" % snapshot["position"]
	var nav := get_tree().get_first_node_in_group("nav_grid")
	if nav != null:
		where += SEP + "%s %s" % [L10n.t("CON_FIELD_CELL"), nav.world_to_cell(snapshot["position"])]
	_field("CON_FIELD_POS", where)

	if snapshot["moving"]:
		# 完整路徑點不進 snapshot（那批資料要進 LLM payload，路徑點太瑣碎）——
		# 這裡是主控台自己的顯示需求，直接問 character
		var path := character.get_path_points()
		_field("CON_FIELD_MOVE", L10n.tf("CON_MOVE_TOWARD", {
			"pos": path[path.size() - 1], "points": path.size()
		}))
	else:
		_field("CON_FIELD_MOVE", L10n.t("CON_MOVE_IDLE"))

	_field("CON_FIELD_LOOK", L10n.tf("CON_LOOK_BODY", {
		"facing": snapshot["facing"], "anim": snapshot["animation"]
	}))

	# 兩個欄位共用同一個字串 key。原本是 CON_TALK_ACTIVE 與 CON_WORK_ACTIVE
	# 兩個一字不差的條目——那種必須永遠一致的重複，翻譯者改了其中一個就會不同步
	if snapshot["in_conversation"]:
		_field("CON_FIELD_TALK", L10n.t("CON_STATE_ACTIVE"))

	if snapshot["working"]:
		_field("CON_FIELD_WORK", L10n.t("CON_STATE_ACTIVE"))

	var emotion: Dictionary = snapshot["emotion"]
	_field("CON_FIELD_EMOTION", "%s (intensity %d, %d tick)" % [
		emotion["type"], emotion["intensity"], emotion["duration_left"]
	])

	var conditions: Array = snapshot["conditions"]
	if not conditions.is_empty():
		var parts: Array[String] = []
		for c in conditions:
			parts.append(str(c["type"]))
		_field("CON_FIELD_CONDITIONS", SEP.join(parts))

	# 直接掃 Stats.SPEC，所以之後加數值不用回來改這裡。
	# SPEC 的 label 存的是翻譯 key，翻譯在這個顯示端做
	if snapshot.has("stats"):
		var needs: Array[String] = []
		var others: Array[String] = []

		for key in Stats.SPEC:
			var text := "%s %d" % [L10n.t(Stats.SPEC[key]["label"]), int(snapshot["stats"][key])]
			if character.stats.is_need(key):
				needs.append(text)
			else:
				others.append(text)

		_field("CON_FIELD_NEEDS", SEP.join(needs))
		if not others.is_empty():
			_field("CON_FIELD_STATE", SEP.join(others))

	if snapshot.has("money"):
		_field("CON_FIELD_MONEY", "%d" % int(snapshot["money"]))

	if snapshot.has("relations"):
		var lines: Array[String] = []
		for other_id in snapshot["relations"]:
			var record: Dictionary = snapshot["relations"][other_id]
			lines.append(L10n.tf("CON_RELATION_ENTRY", {
				"id": other_id,
				"trust": "%.1f" % record["trust"],
				"count": record["met_count"],
			}))
		_field("CON_FIELD_RELATIONS", SEP.join(lines))

	if snapshot.has("schedule"):
		_field("CON_FIELD_SCHEDULE", L10n.tf("CON_SCHEDULE_BODY", {
			"place": snapshot["schedule"]["place"],
			"state": snapshot["schedule"]["state"],
			"count": snapshot["schedule"]["size"],
		}))

# status 的一列。欄名寬度不補空白對齊 —— 主控台用的是預設比例字型，
# 補空白只在中文那種等寬的情況下看起來像對齊，換成英文就散掉，
# 不如老實地讓欄名靠左、用顏色區分
func _field(label_key: String, body: String) -> void:
	_print("  [color=888888]%s[/color]  %s" % [L10n.t(label_key), body])

# tasks <name>
#
# 印出這隻 Agent 的任務池：每筆的 source/action/params/window/分數拆項，
# 標出目前執行中的那筆跟它已經跑了幾個遊戲分鐘。分數仲裁選出來的結果肉眼
# 看不出理由，沒有這個指令沒辦法 debug「它為什麼跑去那裡」——
# 見 [[行程佇列與任務仲裁]]。
#
# name 是必填的，不像 status／inv 那樣可以省略：那兩個省略就看玩家自己，
# 而玩家不可能有任務池（只有 Agent 進 "agents" 群組），預設值會是個永遠失敗的死路
func _cmd_tasks(args: PackedStringArray) -> void:
	if args.size() != 1:
		_error("tasks <name>")
		return

	var character := _get_character(args[0])
	if character == null:
		return

	if not character.is_in_group("agents"):
		_error("%s 不是 Agent，沒有任務池" % character.character_name)
		return

	var infos: Array = character.get_task_debug_info()
	if infos.is_empty():
		_print("[color=888888]（空池）[/color]")
		return

	_print("[color=88ccff]%s[/color][color=888888]  目前這筆已執行 %d 遊戲分鐘[/color]" % [
		character.character_name, character.get_current_task_elapsed_minutes()
	])

	for info in infos:
		var task: Dictionary = info["task"]
		var score: Dictionary = info["score"]
		var marker := "→" if info["is_current"] else " "
		var window_note := "" if info["in_window"] else "[color=888888]（窗外）[/color]"

		# 一律 .get()：仲裁器本身允許任務沒有 window（`_in_window_or_unwindowed`
		# 直接當成隨時可選），硬取 task["window"]["start"] 會在第一筆這種任務上
		# 崩掉整個指令——而這個指令存在的理由就是拿來看任務池
		var window = task.get("window")
		var window_text := "隨時" if window == null else "%s..%s" % [window["start"], window["end"]]

		_print("[color=888888]%s %s[/color]  %s  params=%s  window=%s%s" % [
			marker, task.get("source", "?"), task.get("action", "?"),
			JSON.stringify(task.get("params", {})), window_text, window_note,
		])
		_print("[color=888888]    score=%.1f = base %.1f + time %.1f + need %.1f + age %.1f[/color]" % [
			score["total"], score["base"], score["time"], score["need"], score["age"],
		])

# persona <name>：印出這隻角色的 system_prompt（送給 LLM 的那一段）與 10 項
# personality（引擎自己算成功率用的，不進 prompt）。#117 驗證用。
#
# 兩個都印是刻意的：這則的重點就是「同一份 HEXACO 輸入產出兩種表達，讀者不同」，
# 只印一個看不出它們是同一份資料的兩面
func _cmd_persona(args: PackedStringArray) -> void:
	if args.size() != 1:
		_error("persona <name>")
		return

	var character := _get_character(args[0])
	if character == null:
		return

	_print("[color=88ccff]%s[/color][color=888888]  system_prompt（送進 LLM 的 system 段）[/color]" % character.character_name)
	# system_prompt 的來源是 npc_schedule.json 的 character 欄位，那是人在資料檔
	# 裡編輯的自由文字——進 RichTextLabel 前一律 escape，理由同 _cmd_memory()
	_print("[color=888888]%s[/color]" % _escape_bbcode(character.system_prompt))

	if character.personality.is_empty():
		_print("[color=888888]personality：（沒有人格資料，成功率公式的人格項當 0）[/color]")
		return

	var parts: Array[String] = []
	for key in character.personality:
		parts.append("%s=%d" % [key, character.personality[key]])
	_print("[color=888888]personality（引擎用，不進 prompt）：%s[/color]" % "  ".join(parts))

# act <name> <action> [place|target]
#
# #112 驗證用：直接推一筆任務進 Agent 的池子，看它真的去做那個動作。走的是
# agent.gd::debug_push_task()，跟 LLM 決策回應同一條路徑。
#
# 只收 IMPLEMENTED_ACTIONS 裡的動作——白名單上但還沒接執行層的動作推進去
# 只會讓角色靜靜地站著，看起來像指令壞了。三十遊戲分鐘夠看出 stamina 有沒有
# 在回，又不會長到要等半個遊戲日才還角色自由
const ACT_DURATION := 30.0

func _cmd_act(args: PackedStringArray) -> void:
	if args.size() < 2 or args.size() > 3:
		_error("act <name> <action> [place|target]")
		return

	var character := _get_character(args[0])
	if character == null:
		return

	if not character.is_in_group("agents"):
		_error("%s 不是 Agent，沒有任務池" % character.character_name)
		return

	var action := args[1]
	if not AISchema.is_implemented_action(action):
		_error("%s 還沒有執行邏輯，目前可下：%s" % [
			action, ", ".join(AISchema.IMPLEMENTED_ACTIONS)
		])
		return

	# talk／attack 的參數是人不是地點（見 agent.gd::_pursue_talk_task()／
	# _pursue_attack_task()），其餘動作一律吃 place。這裡照 action 分流，
	# 不要求下指令的人自己記得填哪個 key
	var params := {}
	if args.size() == 3:
		params["target" if ["talk", "attack"].has(action) else "place"] = args[2]

	# is_in_group("agents") 不會幫 GDScript 縮窄靜態型別，顯式轉型才能讓
	# debug_push_task()（Agent-only）這個呼叫真的是型別安全的
	(character as Agent).debug_push_task(action, params, ACT_DURATION)
	_print("[color=888888]%s 收到任務 %s params=%s，%d 遊戲分鐘後自動退場[/color]" % [
		character.character_name, action, JSON.stringify(params), int(ACT_DURATION)
	])

# ai_decision <name> [on|off]：切換某隻角色的 llm_decision_enabled（#282）。
# 給沒接觸過程式碼的組員用的入口——不用進編輯器改場景，一行指令就能讓
# NPC 開始／停止自己問地端模型該做什麼。
#
# 開啟時 await 一次真正的決策、印出 reasoning／inner_monologue——這兩項是
# 模型當次回應的自由文字，不是任何固定文案，印得出來就是「這隻角色真的問過
# 地端模型」的可視覺驗證，不用另外去看 Godot 編輯器的 Output 面板（
# _request_next_decision() 那行 print() 只印在那裡，debug 主控台看不到）。
# 完整任務池（含 priority/score）另外用既有的 tasks 指令看，這裡不重複印。
func _cmd_ai_decision(args: PackedStringArray) -> void:
	if args.size() < 1 or args.size() > 2:
		_error("ai_decision <name> [on|off]")
		return

	var character := _get_character(args[0])
	if character == null:
		return

	if not character.is_in_group("agents"):
		_error("%s 不是 Agent，沒有決策迴圈" % character.character_name)
		return

	var turn_on := true
	if args.size() == 2:
		match args[1].to_lower():
			"on":
				turn_on = true
			"off":
				turn_on = false
			_:
				_error("ai_decision <name> [on|off]")
				return

	# is_in_group("agents") 不會幫 GDScript 縮窄靜態型別，顯式轉型才能讓
	# debug_set_llm_decision()（Agent-only）這個呼叫真的是型別安全的
	var agent := character as Agent

	if not turn_on:
		await agent.debug_set_llm_decision(false)
		_print("[color=888888]%s 的 llm_decision_enabled 關閉[/color]" % character.character_name)
		return

	# 呼叫前先問一次是不是已經有一份請求在飛——只有真的要送出新請求時才印
	# 「正在問...」，不然舊 config／額度／逾時的等待訊息會蓋到一個其實沒有
	# 真的送出請求的情況上
	if not agent.is_decision_in_flight():
		_print("[color=888888]%s 正在問地端模型...[/color]" % character.character_name)

	var result: Dictionary = await agent.debug_set_llm_decision(true)

	# triggered=false 代表根本沒送出新請求（已經有一份在飛，見
	# Agent._awaiting_decision），不是模型端出了什麼問題——跟下面驗證/逾時
	# 失敗的訊息要分開講，不然會誤導人去查 config 或重試一個其實沒壞的東西
	if not result.get("triggered", false):
		_error("%s 已經有一次決策請求在進行中，稍後再試" % character.character_name)
		return

	if not result.get("ok", false):
		_error("這次沒問到——可能是 AI 停用／逾時／驗證失敗，走了 fallback。可以再打一次 ai_decision %s on 重試，或先用 ai 指令確認 config 有沒有生效" % character.character_name)
		return

	_print("[color=88ccff]%s[/color][color=888888] 這次新增了 %d 筆任務[/color]" % [
		character.character_name, result["tasks_added"]
	])
	_print("[color=888888]  reasoning: %s[/color]" % _escape_bbcode(str(result.get("reasoning", ""))))
	_print("[color=888888]  inner_monologue: %s[/color]" % _escape_bbcode(str(result.get("inner_monologue", ""))))
	_print("[color=888888]  完整任務池：tasks %s[/color]" % character.character_name)

# memory <name>：印出 L1 短期工作記憶 + L2/L3/L4 分級記憶。#167 驗證用，
# 形狀比照 _cmd_tasks()——一律 .get()，記憶欄位不該因為指令本身崩掉
func _cmd_memory(args: PackedStringArray) -> void:
	if args.size() != 1:
		_error("memory <name>")
		return

	var character := _get_character(args[0])
	if character == null:
		return

	if character.memory == null:
		_error("%s 沒有掛 Memory 元件" % character.character_name)
		return

	var m := character.memory
	_print("[color=88ccff]%s[/color][color=888888]  L1 %d/%d 條[/color]" % [
		character.character_name, m.l1.size(), Memory.L1_CAP
	])
	for entry in m.l1:
		_print("[color=888888]  · %s[/color]" % _escape_bbcode(str(entry.get("content", ""))))

	for level in [4, 3, 2]:
		var level_entries := m.get_by_level(level)
		if level_entries.is_empty():
			continue
		_print("[color=88ccff]L%d[/color][color=888888]（%d 條）[/color]" % [level, level_entries.size()])
		for entry in level_entries:
			# content 是 LLM 輸出（memory.add_candidate() 的呼叫端來自 LLM 反思
			# 結果），進 RichTextLabel 前一定要 _escape_bbcode()——不然 LLM 回應
			# 塞 BBCode 標籤可以截斷或偽造主控台輸出（max 等級 code review 抓到）
			_print("[color=888888]  · [%s] importance=%d decay=%.1f  %s[/color]" % [
				entry.get("valence", "?"), entry.get("importance", 0),
				entry.get("decay_value", 0), _escape_bbcode(str(entry.get("content", ""))),
			])

# reflect <name>：手動觸發一次睡眠反思（#168）。印出反思前的事件緩衝區
# 內容、await 完成、再印出反思後的記憶列表，方便一次看到「送了什麼、
# 分到哪一層」的完整前後對照
func _cmd_reflect(args: PackedStringArray) -> void:
	if args.size() != 1:
		_error("reflect <name>")
		return

	var character := _get_character(args[0])
	if character == null:
		return

	if not character.is_in_group("agents"):
		_error("%s 不是 Agent，沒有反思機制" % character.character_name)
		return

	# get_daily_events()／request_sleep_reflection() 只存在於 Agent，不在
	# Character 基底——is_in_group("agents") 不會幫 GDScript 縮窄靜態型別，
	# 上面那行只是執行期檢查。顯式轉型才能讓底下這兩個呼叫真的是型別安全的
	# （max 等級 code review 抓到：先前直接在 Character 型別變數上呼叫這兩個
	# Agent-only 方法，能跑是因為 GDScript 對未宣告方法只降級成警告，不是
	# 真的型別安全）
	var agent := character as Agent

	var daily_events: Array[String] = agent.get_daily_events()
	if daily_events.is_empty():
		_print("[color=888888]（今天還沒發生任何事，沒東西可以反思）[/color]")
		return

	_print("[color=88ccff]%s[/color][color=888888]  反思前，今天發生了 %d 件事[/color]" % [
		character.character_name, daily_events.size()
	])
	for event in daily_events:
		_print("[color=888888]  · %s[/color]" % _escape_bbcode(event))

	var result := await agent.request_sleep_reflection()
	if not result["ok"]:
		# queued=true 不是失敗——只是這隻角色剛好已經有一份反思請求在飛，這次
		# 已經排進 _sleep_reflection_pending，等前一份做完會自動補跑一次，不用
		# 使用者自己重打指令（CodeRabbit review 抓到：原本跟真正的失敗混在一起
		# 印同一句錯誤訊息，會讓人誤以為今天的事白費了）
		if result.get("queued", false):
			_print("[color=888888]這隻角色已經有一份反思在等回應，這次的請求已經排隊，會在那份做完後自動補跑[/color]")
		else:
			_error("反思沒有成功（AI 未啟用／逾時／驗證失敗等），今天的事留著，下次再試")
		return

	_print("[color=888888]反思完成，當日摘要：%s[/color]" % _escape_bbcode(agent.last_reflection_summary))
	_print("[color=888888]記憶列表：[/color]")
	_cmd_memory(args)

# spawn <template_id>
#
# #73 驗證用：從 GameManager 的角色庫模板動態生成一隻角色、投放進場景樹。
# 沿用 agent.tscn（跟 Agent/Agent2 同一份場景）——動態生成的角色目前沒有
# schedule 來源，_load_schedule() 查不到節點名對應的 assignments 會噴一次
# 警告一次錯誤，那是誠實反映「這隻角色還沒有行程表」，不是這個指令壞了
const AGENT_SCENE := preload("res://scenes/agent.tscn")

func _cmd_spawn(args: PackedStringArray) -> void:
	if args.size() != 1:
		_error("spawn <template_id>")
		return

	var template = GameManager.get_character_template(args[0])
	if template == null:
		_error("找不到模板 %s" % args[0])
		return

	var identity := {"character_name": template.get("character_name", "")}
	var character := GameManager.spawn_character(AGENT_SCENE, identity)

	_print("[color=88ff88]生成角色 %s[/color][color=888888]  id %s[/color]" % [
		character.character_name, character.character_id
	])

# charnew / charlib   開啟建角面板／角色庫首頁（#122）。兩個面板都用
# group 找節點，本檔不持有直接參照——跟找角色用 get_tree() 找節點同一個理由
func _cmd_charnew(_args: PackedStringArray) -> void:
	var panel := get_tree().get_first_node_in_group("character_create_panel")
	if panel == null:
		_error("找不到建角面板")
		return
	panel.open()

func _cmd_charlib(_args: PackedStringArray) -> void:
	var panel := get_tree().get_first_node_in_group("character_library_panel")
	if panel == null:
		_error("找不到角色庫面板")
		return
	panel.open()

# embody <id>   投放角色庫裡的一筆為玩家操控的化身角色（deploy_from_library
# 的 as_player=true 分支，#371）。角色庫 id 沒有其他地方會印出來，沒帶參數
# 或 id 錯誤時列出目前未投放的清單，不用先開 charlib 面板肉眼找
func _cmd_embody(args: PackedStringArray) -> void:
	if args.size() == 1:
		var character := GameManager.deploy_from_library(args[0], true)
		if character != null:
			_print("[color=88ff88]化身角色 %s[/color][color=888888]  id %s[/color]" % [
				_escape_bbcode(character.character_name), character.character_id
			])
			return
		_error("投放失敗（id 不存在／已投放／世界投放上限已滿）")

	var listed := false
	for entry in GameManager.character_library:
		if entry.get("deployed", false):
			continue
		if not listed:
			_error("embody <id>，可用：")
			listed = true
		_print("  [color=888888]%s[/color]  %s" % [entry["id"], _escape_bbcode(entry["character_name"])])
	if not listed:
		_error("embody <id>（角色庫沒有未投放的角色，先用 charnew 建一個）")

# save   存下目前世界裡每個角色 + 這個世界本身。驗證 SaveService 的讀寫
# 進出點確實接得起來（#21）——真正該在什麼時機自動存檔（睡前等）是後續 issue
func _cmd_save(_args: PackedStringArray) -> void:
	var count := 0
	for node in get_tree().get_nodes_in_group("characters"):
		var character := node as Character
		if SaveService.save_character(character.character_id, character.get_save_data()):
			count += 1
		else:
			_error("存檔失敗：%s" % character.character_name)

	if not SaveService.save_world(GameManager.DEFAULT_WORLD_ID, GameManager.get_world_save_data()):
		_error("世界存檔失敗：%s" % GameManager.DEFAULT_WORLD_ID)
		return

	_print("[color=88ff88]已存檔[/color]  %d 個角色 + 世界 %s" % [count, GameManager.DEFAULT_WORLD_ID])

# load   讀回世界本身 + 場景裡目前每個角色各自的存檔。只套用場景裡找得到的
# 角色——存檔裡有記載但場景沒有的角色不會被生出來，那是 player 加入世界
# 那條流程的範圍，不在這則骨架內（見 issue #21 範圍界線）
func _cmd_load(_args: PackedStringArray) -> void:
	var world_data := SaveService.get_world(GameManager.DEFAULT_WORLD_ID)
	if world_data.is_empty():
		_error("沒有世界存檔 %s" % GameManager.DEFAULT_WORLD_ID)
		return
	GameManager.apply_world_save_data(world_data)

	var count := 0
	for node in get_tree().get_nodes_in_group("characters"):
		var character := node as Character
		var data := SaveService.get_character(character.character_id)
		if data.is_empty():
			continue
		# 跟 main_scene.gd 同一套邊界檢查：character_id 一定要存在、是
		# String、且跟查詢用的 id 對得上，缺欄位／型別不對／對不上都不套用
		var stored_id: Variant = data.get("character_id")
		if not (stored_id is String and stored_id == character.character_id):
			_error("角色存檔 %s 內容缺少或 character_id 不符（%s），可能已損毀，跳過" % [character.character_id, stored_id])
			continue
		character.load_save_data(data)
		count += 1

	_print("[color=88ff88]已讀檔[/color]  %d 個角色 + 世界 %s（第 %d 天）" % [
		count, GameManager.DEFAULT_WORLD_ID, GameClock.day
	])

func _get_overlay() -> Node:
	var overlay := get_tree().get_first_node_in_group("debug_overlay")
	if overlay == null:
		_error(L10n.t("CON_NO_OVERLAY"))
	return overlay

# debug            列出所有項目與開關狀態
# debug <項目>     切換
# debug <項目> on  明確指定
# debug off        全關
func _cmd_debug(args: PackedStringArray) -> void:
	var overlay := _get_overlay()
	if overlay == null:
		return

	if args.is_empty():
		_print_overlay_states(overlay)
		return

	var layer := args[0].to_lower()

	if layer == "off":
		for name in overlay.layers.keys():
			overlay.set_layer(name, false)
		_print(L10n.t("CON_OVERLAY_ALL_OFF"))
		return

	if not overlay.layers.has(layer):
		_error(L10n.tf("CON_OVERLAY_NO_LAYER", {"layer": layer}))
		_print_overlay_states(overlay)
		return

	# 沒帶 on/off 就是切換
	if args.size() == 1:
		_print("%s = %s" % [layer, "on" if overlay.toggle(layer) else "off"])
		return

	var on: bool = args[1].to_lower() in ["on", "1", "true"]
	overlay.set_layer(layer, on)
	_print("%s = %s" % [layer, "on" if on else "off"])

func _print_overlay_states(overlay: Node) -> void:
	var parts: Array[String] = []
	for name in overlay.layers:
		var on: bool = overlay.layers[name]
		parts.append("[color=%s]%s[/color]" % ["88ff88" if on else "888888", name])

	_print(L10n.tf("CON_OVERLAY_STATES", {"layers": SEP.join(parts)}))
	_print("[color=888888]%s[/color]" % L10n.t("CON_OVERLAY_USAGE"))

func _cmd_nav(args: PackedStringArray) -> void:
	if args.size() != 1 or args[0] != "rebuild":
		_error(L10n.t("CON_USAGE_NAV"))
		return

	var nav := _get_nav()
	if nav == null:
		return

	nav.rebuild()
	_print(L10n.tf("CON_NAV_REBUILT", {"region": nav.astar.region, "solid": nav.solid_count}))

# inv [name]                  列出背包，省略就看玩家自己
# inv give <item_id> [count]  塞測試物品給玩家（decay 類，見下方 add_item 呼叫）
func _cmd_inv(args: PackedStringArray) -> void:
	if not args.is_empty() and args[0].to_lower() == "give":
		_cmd_inv_give(args.slice(1))
		return

	if args.size() > 1:
		_error(L10n.t("CON_USAGE_INV"))
		return

	var character: Character = _get_player() if args.is_empty() else _get_character(args[0])
	if character == null:
		return

	if character.inventory == null:
		_error(L10n.tf("CON_NO_INVENTORY", {"name": character.character_name}))
		return

	var selected := character.inventory.get_selected_index()
	var selected_text := (
		L10n.t("CON_INV_NONE_SELECTED") if selected < 0
		else L10n.tf("CON_INV_SELECTED", {"index": selected})
	)
	_print("[color=88ccff]%s[/color][color=888888]  %s[/color]" % [
		character.character_name,
		selected_text,
	])

	var entries := character.inventory.get_summary()
	if entries.is_empty():
		_print("  " + L10n.t("CON_INV_EMPTY"))
		return

	for entry in entries:
		var durability: int = entry["durability"]
		var detail := (
			L10n.tf("CON_INV_DURABILITY", {"durability": durability}) if durability >= 0
			else L10n.tf("CON_INV_DECAY", {"decay": entry["decay"]})
		)
		_print("  [color=888888][%02d][/color]  %s x%d%s%s" % [
			entry["slot"], _escape_bbcode(entry["item_id"]), entry["count"], SEP, detail
		])

# 一律塞給玩家，測試用不需要指名角色。塞出來的是 decay 類（durability 用預設 -1）——
# 要測 carry 類不可疊的行為得直接呼叫 Inventory.add_item()，這條指令先求夠用
func _cmd_inv_give(args: PackedStringArray) -> void:
	if args.is_empty() or args.size() > 2:
		_error(L10n.t("CON_USAGE_INV_GIVE"))
		return

	var player := _get_player()
	if player == null:
		return

	if player.inventory == null:
		_error(L10n.tf("CON_NO_INVENTORY", {"name": player.character_name}))
		return

	var item_id := args[0]
	var count := 1
	if args.size() == 2:
		# is_valid_int() 對 "0" 和 "-5" 都成立，數量還要自己驗正數
		if not args[1].is_valid_int() or args[1].to_int() <= 0:
			_error(L10n.t("CON_USAGE_INV_GIVE"))
			return
		count = args[1].to_int()

	# 顯示用的 item_id 要轉義，傳給 add_item() 的那份保持原樣
	var shown_id := _escape_bbcode(item_id)

	var reason := player.inventory.add_item(item_id, count)
	if reason != Inventory.ADD_OK:
		_error(L10n.tf("CON_INV_GIVE_FAILED", {"item": shown_id, "reason": reason}))
		return

	_print(L10n.tf("CON_INV_GIVE_OK", {
		"name": player.character_name, "count": count, "item": shown_id
	}))

# money <amount>   正數走 add_money()，負數走 spend()
#
# 沒有查詢用法：金錢已經在 status 的輸出裡，任何角色都查得到。
# 這條指令只做「改」，而且刻意兩個方向都能走——扣款那條路有餘額檢查，
# 只能加錢的話 MONEY_NOT_ENOUGH 就沒有辦法從主控台測到
func _cmd_money(args: PackedStringArray) -> void:
	# is_valid_int() 對 "0" 成立，但 0 兩邊都不是合法異動，要自己擋
	if args.size() != 1 or not args[0].is_valid_int() or args[0].to_int() == 0:
		_error(L10n.t("CON_USAGE_MONEY"))
		return

	var player := _get_player()
	if player == null:
		return

	if player.inventory == null:
		_error(L10n.tf("CON_NO_INVENTORY", {"name": player.character_name}))
		return

	var amount := args[0].to_int()
	var reason := (
		player.inventory.add_money(amount) if amount > 0
		else player.inventory.spend(-amount)
	)
	if reason != Inventory.MONEY_OK:
		_error(L10n.tf("CON_MONEY_FAILED", {"reason": reason}))
		return

	_print(L10n.tf("CON_MONEY_OK", {
		"name": player.character_name, "money": player.inventory.get_money()
	}))

# 主控台自己算一個呼叫方，用固定 id 才吃得到 AIService 的速率限制 ——
# 手動測試如果不受限，就測不出正式呼叫端會遇到的行為
const AI_REQUESTER_ID := "debug_console"
const AI_PROBE_SYSTEM := "You are a connection probe. Reply with JSON only, no prose, no code fence: {\"ok\": true, \"echo\": \"<the text field you were given>\"}"
const AI_PROBE_TEXT := "hello from ailley"

# ai                          用預設探針句打一次（走 SCHEDULED，吃 30 秒冷卻）
# ai <文字>                   改用這段文字當探針
# ai dialogue [<文字>]        走 CONVERSATION，驗證對話輪次確實豁免冷卻與配額
# ai @<provider> [<文字>]     指定要測哪個 provider（不指定用 default_provider）
# ai dialogue @<provider> [<文字>]  兩者可以並用，順序固定：dialogue 在前
#
# @provider 這個記法是為了不跟探針文字本身混淆——文字通常是一句話，
# 用 @ 開頭這種明顯不像自然語言開頭的記法，判斷「這個 token 是不是指定
# provider」不用去猜文字內容像不像 provider 名稱
#
# dialogue／SCHEDULED 兩種都留著才測得出差別：連打兩次 ai 第二次應該被擋，
# 連打兩次 ai dialogue 應該兩次都過
#
# 每次都先 reload_config()，玩家剛寫完 user://ai_config.json 不用重開遊戲
# emotion <name> <type> [intensity]
#
# #116 AC 要求要有 debug 方式「手動設定/觀察」emotion；status 已經做了觀察，
# 這裡補上設定的一半。intensity 省略時用 60（中等強度，好觀察 duration_left
# 倒數而不用每次都手動打數字）
func _cmd_emotion(args: PackedStringArray) -> void:
	if args.size() < 2 or args.size() > 3:
		_error(L10n.t("CON_USAGE_EMOTION"))
		return

	var character := _get_character(args[0])
	if character == null:
		return

	var type := args[1]
	if not Character.EMOTION_TYPES.has(type):
		_error(L10n.tf("CON_EMOTION_INVALID_TYPE", {
			"type": type, "valid": ", ".join(Character.EMOTION_TYPES)
		}))
		return

	var intensity := 60
	if args.size() == 3:
		if not args[2].is_valid_int():
			_error(L10n.t("CON_USAGE_EMOTION"))
			return
		intensity = args[2].to_int()

	character.set_emotion(type, intensity)
	_print(L10n.tf("CON_EMOTION_OK", {
		"name": character.character_name,
		"type": character.emotion["type"],
		"intensity": character.emotion["intensity"],
		"duration": character.emotion["duration_left"],
	}))

func _cmd_ai(args: PackedStringArray) -> void:
	# 用等待版：reload_config() 本身刻意不等探測完成（開機時呼叫不能卡住
	# 遊戲啟動），但這裡是玩家主動下指令要看結果，值得等探測真的做完才印，
	# 不然十之八九會印出 AI_READY_NOT_CHECKED 這種還沒測完的假象
	# （CodeRabbit review 抓到）
	await AIService.reload_config_and_wait()
	var config: AIConfig = AIService.config

	# config 的 _to_string() 只會吐遮蔽過的金鑰，這裡不另外碰 api_key
	_print("[color=88ccff]%s[/color]" % config)

	if not config.enabled:
		_print("[color=ffcc66]%s[/color]" % L10n.tf("CON_AI_DISABLED", {"reason": config.status_reason}))
		return

	# 就緒狀態逐 provider 印，不是只印 default_provider 一個——地端沒開、
	# 雲端連得上這種情況，取單一代表值會蓋掉另一邊的資訊（issue #345）
	for name in config.providers.keys():
		var readiness: Dictionary = AIService.get_readiness(name)
		var marker := " (default)" if name == config.default_provider else ""
		var color := "88ff88" if readiness["ready"] else "ff8888"
		_print("[color=%s]%s[/color]" % [color, L10n.tf("CON_AI_READY_LINE", {
			"ready": L10n.t("CON_AI_READY_YES" if readiness["ready"] else "CON_AI_READY_NO"),
			"name": name,
			"default_marker": marker,
			"reason": readiness["reason"],
		})])

	# 第一個參數是 dialogue 就切成對話政策，其餘參數仍然是探針句
	var policy := AIService.Policy.SCHEDULED
	var rest := args
	if rest.size() > 0 and rest[0].to_lower() == "dialogue":
		policy = AIService.Policy.CONVERSATION
		rest = rest.slice(1)

	# @provider 記法指定要測哪個 provider，不指定就用 default_provider——
	# 順序固定排在 dialogue 之後，跟 usage 註解裡寫的一樣
	var provider_name := ""
	if rest.size() > 0 and rest[0].begins_with("@"):
		provider_name = rest[0].substr(1)
		rest = rest.slice(1)

		# 光打一個 @ 要當成打錯，不能放行：has_provider("") 會因為退回
		# default_provider 而回 true，等於一個明顯的手誤被靜默送去預設服務
		if provider_name.is_empty():
			_error("@ 後面要接 provider 名稱，設定檔裡有：%s" % ", ".join(config.providers.keys()))
			return

		if not config.has_provider(provider_name):
			_error("找不到 provider「%s」，設定檔裡有：%s" % [
				provider_name, ", ".join(config.providers.keys())
			])
			return

	var usage: Dictionary = AIService.get_usage(AI_REQUESTER_ID)
	_print("[color=888888]  %s[/color]" % L10n.tf("CON_AI_USAGE", {
		"day": usage["game_day"],
		"calls": usage["calls_today"],
		"max": usage["max_calls"],
		"dialogue": usage["dialogue_today"],
		"exempt": L10n.t("CON_AI_EXEMPT" if usage["dialogue_exempt"] else "CON_AI_NOT_EXEMPT"),
		"cooldown": "%.0f" % usage["cooldown_left"],
		"queued": usage["queued"],
		"inflight": usage["in_flight"],
	}))

	var text := " ".join(rest) if not rest.is_empty() else AI_PROBE_TEXT
	var envelope := {
		"system": AI_PROBE_SYSTEM,
		"payload": {"type": "ping", "text": text},
	}

	_print("[color=888888]→ [%s → %s] %s[/color]" % [
		L10n.t("CON_POLICY_CONVERSATION" if policy == AIService.Policy.CONVERSATION else "CON_POLICY_SCHEDULED"),
		provider_name if not provider_name.is_empty() else config.default_provider,
		JSON.stringify(envelope["payload"]),
	])

	var result: Dictionary = await AIService.request(envelope, AI_REQUESTER_ID, policy, provider_name)
	if not result["ok"]:
		_error("← " + L10n.tf("CON_AI_FAILED", {"error": result["error"]}))
		return

	_print("[color=888888]← %s[/color]" % JSON.stringify(result["data"]))

	# 走一次 AISchema，確認防注入那層真的擋得住／放得過
	var parsed: Dictionary = AISchema.parse_completion(result["data"])
	if parsed["ok"]:
		_print("[color=88ff88]  %s %s[/color]" % [L10n.t("CON_AI_CONTENT"), JSON.stringify(parsed["data"])])
	else:
		_print("[color=ffcc66]  %s[/color]" % L10n.tf("CON_AI_INVALID", {"error": parsed["error"]}))

# locale        顯示目前語系與可用清單
# locale <code> 切換（zh_TW / en）
#
# 有這個指令才驗證得了翻譯，不然要換語系得改 project settings 重開遊戲
func _cmd_locale(args: PackedStringArray) -> void:
	var available := TranslationServer.get_loaded_locales()

	if args.is_empty():
		_print(L10n.tf("CON_LOCALE_CURRENT", {
			"locale": TranslationServer.get_locale(), "available": SEP.join(available)
		}))
		return

	if args.size() > 1:
		_error(L10n.t("CON_USAGE_LOCALE"))
		return

	# 比對 loaded locales 而不是直接吞下去：set_locale() 對不存在的語系不會抱怨，
	# 只會靜靜地全部 fallback，看起來就像指令沒生效
	var wanted := args[0]
	if not available.has(wanted):
		_error(L10n.tf("CON_LOCALE_UNKNOWN", {"locale": wanted}))
		_print(L10n.tf("CON_LOCALE_CURRENT", {
			"locale": TranslationServer.get_locale(), "available": SEP.join(available)
		}))
		return

	TranslationServer.set_locale(wanted)
	_print(L10n.tf("CON_LOCALE_SWITCHED", {"locale": wanted}))

# 指令語法那一欄是識別字，不翻；說明另起一行 ——
# 舊版靠字面空格把說明對齊成一欄，但主控台用的是比例字型，
# 那個對齊本來就只是近似，換成英文說明就整排歪掉
#
# 直接照 _commands 的順序印，help 欄留空的（目前只有 help 自己）跳過不印。
# ai dialogue 是 ai 底下的子指令，_commands 沒有它自己的 entry，緊接在 ai 後面手動補一行
func _cmd_help(_args: PackedStringArray) -> void:
	for name in _commands:
		var entry: Dictionary = _commands[name]
		if entry["help"] != "":
			_help_line(entry["usage"], entry["help"])
		if name == "ai":
			_help_line("ai dialogue [text]", "HELP_AI_DIALOGUE")

# 方括號要轉義成 [lb]，否則會被當成 BBCode 標籤吃掉 ——
# 「locale [code]」裡的 [code] 剛好是 RichTextLabel 真的認得的標籤，
# 不轉義的話整行會渲染成「locale [/color]」。凡是要進 _print() 的
# 非固定字串（usage 欄、使用者打進來的參數）都經過這裡，
# 就不必去記哪些字剛好撞名
func _escape_bbcode(text: String) -> String:
	return text.replace("[", "[lb]")

func _help_line(usage: String, key: String) -> void:
	_print("[color=88ccff]%s[/color]\n  [color=888888]%s[/color]" % [
		_escape_bbcode(usage), L10n.t(key)
	])

func _cmd_clear(_args: PackedStringArray) -> void:
	output.clear()
