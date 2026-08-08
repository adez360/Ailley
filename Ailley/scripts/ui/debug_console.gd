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
	_commands = {
		"goto": _cmd_goto,
		"talk": _cmd_talk,
		"stop": _cmd_stop,
		"pos": _cmd_pos,
		"status": _cmd_status,
		"debug": _cmd_debug,
		"nav": _cmd_nav,
		"ai": _cmd_ai,
		"locale": _cmd_locale,
		"help": _cmd_help,
		"clear": _cmd_clear,
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

	_commands[command].call(parts.slice(1))

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

# 省略 id 就看玩家自己
func _cmd_status(args: PackedStringArray) -> void:
	if args.size() > 1:
		_error(L10n.t("CON_USAGE_STATUS"))
		return

	var character: Character = _get_player() if args.is_empty() else _get_character(args[0])
	if character == null:
		return

	var body := character.get_body_position()
	_print("[color=88ccff]%s[/color][color=888888]  id %s[/color]" % [
		character.character_name, character.character_id
	])

	var where := "%s" % body
	var nav := get_tree().get_first_node_in_group("nav_grid")
	if nav != null:
		where += SEP + "%s %s" % [L10n.t("CON_FIELD_CELL"), nav.world_to_cell(body)]
	_field("CON_FIELD_POS", where)

	if character.is_moving():
		var path := character.get_path_points()
		_field("CON_FIELD_MOVE", L10n.tf("CON_MOVE_TOWARD", {
			"pos": path[path.size() - 1], "points": path.size()
		}))
	else:
		_field("CON_FIELD_MOVE", L10n.t("CON_MOVE_IDLE"))

	_field("CON_FIELD_LOOK", L10n.tf("CON_LOOK_BODY", {
		"facing": character.facing, "anim": character.sprite.animation
	}))

	if character.is_in_conversation():
		_field("CON_FIELD_TALK", L10n.t("CON_TALK_ACTIVE"))

	# 直接掃 Stats.SPEC，所以之後加數值不用回來改這裡。
	# SPEC 的 label 存的是翻譯 key，翻譯在這個顯示端做
	if character.stats != null:
		var needs: Array[String] = []
		var others: Array[String] = []

		for key in Stats.SPEC:
			var text := "%s %d" % [
				L10n.t(Stats.SPEC[key]["label"]), int(character.stats.get_value(key))
			]
			if character.stats.is_need(key):
				needs.append(text)
			else:
				others.append(text)

		_field("CON_FIELD_NEEDS", SEP.join(needs))
		if not others.is_empty():
			_field("CON_FIELD_STATE", SEP.join(others))

	if character.relationships != null and not character.relationships.known_ids().is_empty():
		var lines: Array[String] = []
		for other_id in character.relationships.known_ids():
			var record: Dictionary = character.relationships.get_record(other_id)
			lines.append(L10n.tf("CON_AFFINITY_ENTRY", {
				"id": other_id,
				"affinity": "%.1f" % record["affinity"],
				"count": record["met_count"],
			}))
		_field("CON_FIELD_AFFINITY", SEP.join(lines))

	# 行程表是 Agent 才有的東西，Player 沒有這一段
	if character.is_in_group("agents"):
		_field("CON_FIELD_SCHEDULE", L10n.tf("CON_SCHEDULE_BODY", {
			"place": character.current_place,
			"state": character.current_state,
			"count": character.schedule.size(),
		}))

# status 的一列。欄名寬度不補空白對齊 —— 主控台用的是預設比例字型，
# 補空白只在中文那種等寬的情況下看起來像對齊，換成英文就散掉，
# 不如老實地讓欄名靠左、用顏色區分
func _field(label_key: String, body: String) -> void:
	_print("  [color=888888]%s[/color]  %s" % [L10n.t(label_key), body])

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
		_print("[color=ffcc66]%s[/color]" % L10n.tf("CON_AI_DISABLED", {"reason": config.status_reason}))
		return

	# 第一個參數是 dialogue 就切成對話政策，其餘參數仍然是探針句
	var policy := AIService.Policy.SCHEDULED
	var rest := args
	if args.size() > 0 and args[0].to_lower() == "dialogue":
		policy = AIService.Policy.CONVERSATION
		rest = args.slice(1)

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

	_print("[color=888888]→ [%s] %s[/color]" % [
		L10n.t("CON_POLICY_CONVERSATION" if policy == AIService.Policy.CONVERSATION else "CON_POLICY_SCHEDULED"),
		JSON.stringify(envelope["payload"]),
	])

	var result: Dictionary = await AIService.request(envelope, AI_REQUESTER_ID, policy)
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
func _cmd_help(_args: PackedStringArray) -> void:
	_help_line("goto <name> <x> <y>", "HELP_GOTO")
	_help_line("talk <name> / talk <a> <b>", "HELP_TALK")
	_help_line("status [name]", "HELP_STATUS")
	_help_line("debug [layer] [on|off]", "HELP_DEBUG")
	_help_line("stop", "HELP_STOP")
	_help_line("pos", "HELP_POS")
	_help_line("nav rebuild", "HELP_NAV")
	_help_line("ai [text]", "HELP_AI")
	_help_line("ai dialogue [text]", "HELP_AI_DIALOGUE")
	_help_line("locale [code]", "HELP_LOCALE")
	_help_line("clear", "HELP_CLEAR")

# usage 欄的方括號要轉義成 [lb]，否則會被當成 BBCode 標籤吃掉 ——
# 「locale [code]」裡的 [code] 剛好是 RichTextLabel 真的認得的標籤，
# 不轉義的話整行會渲染成「locale [/color]」。這裡一律轉義，
# 之後加指令就不必去記哪些字剛好撞名
func _help_line(usage: String, key: String) -> void:
	_print("[color=88ccff]%s[/color]\n  [color=888888]%s[/color]" % [
		usage.replace("[", "[lb]"), L10n.t(key)
	])

func _cmd_clear(_args: PackedStringArray) -> void:
	output.clear()
