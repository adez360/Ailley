extends CanvasLayer

## 遊戲中的 debug 指令輸入框。按 ` 開關，Esc 關閉，上下鍵翻指令歷史。

@onready var root: Control = $Root
@onready var output: RichTextLabel = $Root/VBoxContainer/Output
@onready var input: LineEdit = $Root/VBoxContainer/Input

var _commands := {}
var _history: Array[String] = []
var _history_index := 0


func _ready() -> void:
	_commands = {
		"goto": _cmd_goto,
		"talk": _cmd_talk,
		"stop": _cmd_stop,
		"pos": _cmd_pos,
		"status": _cmd_status,
		"debug": _cmd_debug,
		"nav": _cmd_nav,
		"ai": _cmd_ai,
		"help": _cmd_help,
		"clear": _cmd_clear,
	}
	input.text_submitted.connect(_on_text_submitted)
	_set_open(false)
	_print("[color=888888]按 ` 開關主控台，打 help 看指令[/color]")

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
		_error("未知指令：%s（打 help 看清單）" % command)
		return

	_commands[command].call(parts.slice(1))

func _error(line: String) -> void:
	_print("[color=ff6666]%s[/color]" % line)

func _get_player() -> Character:
	var player := get_tree().get_first_node_in_group("player")
	if player == null:
		_error("場景裡找不到 player group 的節點")
	return player

func _get_nav() -> Node:
	var nav := get_tree().get_first_node_in_group("nav_grid")
	if nav == null:
		_error("場景裡找不到 NavGrid")
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
			ids.append(character.character_id)
		_error("有 %d 個角色都叫 %s，改用 id 指定：%s" % [matched.size(), token, ", ".join(ids)])
		return null

	for node in characters:
		if node.character_id == token:
			return node

	var known: Array[String] = []
	for node in characters:
		known.append("%s (%s)" % [node.character_name, node.character_id])

	_error("找不到角色 %s（現有：%s）" % [token, ", ".join(known)])
	return null

func _cmd_goto(args: PackedStringArray) -> void:
	if args.size() != 3 or not args[1].is_valid_int() or not args[2].is_valid_int():
		_error("用法：goto <name> <x> <y>（x y 是格座標，可為負）")
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
		_print("[color=ffcc66]格 %s 不可走，將走到最近的可走格[/color]" % cell)

	if not character.move_to(target):
		_error("找不到 %s 到格 %s 的路徑" % [character.character_name, cell])
		return

	_print("%s 前往格 %s = %s（路徑 %d 點）" % [
		character.character_name, cell, target, character.get_path_points().size()
	])

	# 綁上角色本身，抵達訊息才會報對人；重複 goto 同一角色不會疊接
	var on_finished := _on_move_finished.bind(character)
	if not character.move_finished.is_connected(on_finished):
		character.move_finished.connect(on_finished)

func _on_move_finished(reached: bool, character: Character) -> void:
	if reached:
		_print("%s 已抵達 %s" % [character.character_name, character.get_body_position()])
	else:
		_error("%s 移動中止於 %s（被地形卡住）" % [
			character.character_name, character.get_body_position()
		])

func _cmd_stop(_args: PackedStringArray) -> void:
	var player := _get_player()
	if player == null:
		return
	player.stop_moving()
	_print("已停止移動")

func _cmd_pos(_args: PackedStringArray) -> void:
	var player := _get_player()
	if player == null:
		return

	var line := "pos = %s" % player.get_body_position()
	var nav := get_tree().get_first_node_in_group("nav_grid")
	if nav != null:
		line += "   cell = %s" % nav.world_to_cell(player.get_body_position())
	_print(line)

# 一個參數是玩家對誰搭話；兩個參數是指定發起方，Phase 2 測 Agent 對 Agent 用
func _cmd_talk(args: PackedStringArray) -> void:
	if args.is_empty() or args.size() > 2:
		_error("用法：talk <name>（玩家搭話）或 talk <from> <to>")
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
		_error("%s 搭話 %s 失敗：%s" % [
			speaker.character_name, listener.character_name, failure
		])
		return

	_print("%s 對 %s 搭話" % [speaker.character_name, listener.character_name])

# 省略 id 就看玩家自己
func _cmd_status(args: PackedStringArray) -> void:
	if args.size() > 1:
		_error("用法：status [name]（省略就看玩家自己）")
		return

	var character: Character = _get_player() if args.is_empty() else _get_character(args[0])
	if character == null:
		return

	var body := character.get_body_position()
	_print("[color=88ccff]%s[/color][color=888888]  id %s[/color]" % [
		character.character_name, character.character_id
	])

	var where := "  位置 %s" % body
	var nav := get_tree().get_first_node_in_group("nav_grid")
	if nav != null:
		where += "   格 %s" % nav.world_to_cell(body)
	_print(where)

	if character.is_moving():
		var path := character.get_path_points()
		_print("  移動  前往 %s（路徑 %d 點）" % [path[path.size() - 1], path.size()])
	else:
		_print("  移動  靜止")

	_print("  外觀  面向 %s／動畫 %s" % [character.facing, character.sprite.animation])

	if character.is_in_conversation():
		_print("  對話  進行中")

	# 直接掃 Stats.SPEC，所以之後加數值不用回來改這裡
	if character.stats != null:
		var needs: Array[String] = []
		var others: Array[String] = []

		for key in Stats.SPEC:
			var text := "%s %d" % [Stats.SPEC[key]["label"], int(character.stats.get_value(key))]
			if character.stats.is_need(key):
				needs.append(text)
			else:
				others.append(text)

		_print("  需求  %s" % "　".join(needs))
		if not others.is_empty():
			_print("  狀態  %s" % "　".join(others))

	if character.relationships != null and not character.relationships.known_ids().is_empty():
		var lines: Array[String] = []
		for other_id in character.relationships.known_ids():
			var record: Dictionary = character.relationships.get_record(other_id)
			lines.append("%s %.1f（%d 次）" % [other_id, record["affinity"], record["met_count"]])
		_print("  好感  %s" % "　".join(lines))

	# 行程表是 Agent 才有的東西，Player 沒有這一段
	if character.is_in_group("agents"):
		_print("  行程  %s／%s（共 %d 筆）" % [
			character.current_place, character.current_state, character.schedule.size()
		])

func _get_overlay() -> Node:
	var overlay := get_tree().get_first_node_in_group("debug_overlay")
	if overlay == null:
		_error("場景裡找不到 debug_overlay group 的節點")
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
		_print("已關閉全部 debug 疊圖")
		return

	if not overlay.layers.has(layer):
		_error("沒有這個項目：%s" % layer)
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

	_print("疊圖：%s" % "　".join(parts))
	_print("[color=888888]debug <項目> [on|off]　debug off 全關[/color]")

func _cmd_nav(args: PackedStringArray) -> void:
	if args.size() != 1 or args[0] != "rebuild":
		_error("用法：nav rebuild")
		return

	var nav := _get_nav()
	if nav == null:
		return

	nav.rebuild()
	_print("NavGrid 已重建：region = %s，障礙格 %d" % [nav.astar.region, nav.solid_count])

# 主控台自己算一個呼叫方，用固定 id 才吃得到 AIService 的速率限制 ——
# 手動測試如果不受限，就測不出正式呼叫端會遇到的行為
const AI_REQUESTER_ID := "debug_console"
const AI_PROBE_SYSTEM := "You are a connection probe. Reply with JSON only, no prose, no code fence: {\"ok\": true, \"echo\": \"<the text field you were given>\"}"
const AI_PROBE_TEXT := "hello from ailley"

# ai                    用預設探針句打一次（走 SCHEDULED，吃 30 秒冷卻）
# ai <文字>             改用這段文字當探針
# ai dialogue [<文字>]  走 CONVERSATION，驗證對話輪次確實豁免冷卻與配額
#
# 兩種都留著才測得出差別：連打兩次 ai 第二次應該被擋，
# 連打兩次 ai dialogue 應該兩次都過
#
# 每次都先 reload_config()，玩家剛寫完 user://ai_config.json 不用重開遊戲
func _cmd_ai(args: PackedStringArray) -> void:
	AIService.reload_config()
	var config: AIConfig = AIService.config

	# config 的 _to_string() 只會吐遮蔽過的金鑰，這裡不另外碰 api_key
	_print("[color=88ccff]%s[/color]" % config)

	if not config.enabled:
		_print("[color=ffcc66]AI 未啟用：%s[/color]" % config.status_reason)
		return

	# 第一個參數是 dialogue 就切成對話政策，其餘參數仍然是探針句
	var policy := AIService.Policy.SCHEDULED
	var rest := args
	if args.size() > 0 and args[0].to_lower() == "dialogue":
		policy = AIService.Policy.CONVERSATION
		rest = args.slice(1)

	var usage: Dictionary = AIService.get_usage(AI_REQUESTER_ID)
	_print("[color=888888]  第 %d 遊戲日　行程 %d/%d 次　對話 %d 次（%s）　冷卻剩 %.0fs　佇列 %d　飛行中 %d[/color]" % [
		usage["game_day"], usage["calls_today"], usage["max_calls"],
		usage["dialogue_today"], "豁免" if usage["dialogue_exempt"] else "不豁免",
		usage["cooldown_left"], usage["queued"], usage["in_flight"],
	])

	var text := " ".join(rest) if not rest.is_empty() else AI_PROBE_TEXT
	var envelope := {
		"system": AI_PROBE_SYSTEM,
		"payload": {"type": "ping", "text": text},
	}

	_print("[color=888888]→ [%s] %s[/color]" % [
		"對話" if policy == AIService.Policy.CONVERSATION else "行程",
		JSON.stringify(envelope["payload"]),
	])

	var result: Dictionary = await AIService.request(envelope, AI_REQUESTER_ID, policy)
	if not result["ok"]:
		_error("← 失敗：%s" % result["error"])
		return

	_print("[color=888888]← %s[/color]" % JSON.stringify(result["data"]))

	# 走一次 AISchema，確認防注入那層真的擋得住／放得過
	var parsed: Dictionary = AISchema.parse_completion(result["data"])
	if parsed["ok"]:
		_print("[color=88ff88]  內容 %s[/color]" % JSON.stringify(parsed["data"]))
	else:
		_print("[color=ffcc66]  內容未通過驗證：%s[/color]" % parsed["error"])

func _cmd_help(_args: PackedStringArray) -> void:
	_print("goto <name> <x> <y>           指定角色走到該格（格座標，A* 尋徑）")
	_print("talk <name> / talk <a> <b>    搭話。單一參數是玩家對誰講")
	_print("status [name]                 顯示角色狀態（省略就看玩家自己）")
	_print("debug [項目] [on|off]         疊圖開關：grid coord solid path vision collision")
	_print("stop                          停止玩家目前的移動")
	_print("pos                           顯示玩家座標與所在格")
	_print("nav rebuild                   重建尋徑網格（改完地圖用）")
	_print("ai [文字]                     對 LLM 打一次測試請求（行程政策，吃冷卻）")
	_print("ai dialogue [文字]            同上但走對話政策（豁免冷卻與每日配額）")
	_print("clear                         清空輸出")

func _cmd_clear(_args: PackedStringArray) -> void:
	output.clear()
