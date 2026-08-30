class_name Conversation
extends Node

## 兩個角色之間的一場對話。
##
## 刻意做成獨立物件，不把狀態塞進任一方的 Character：對話是「兩個角色之間」的東西，
## 塞進其中一方會讓另一方每次都要反查，而且結束時要同步清乾淨兩邊，
## 狀態分散在兩個節點很容易漏掉一邊。
##
## 生命週期：Character.talk_to() 設好 initiator / target 後加進場景，
## 講完自己 queue_free()。
##
## Step 1：輪流講話改成非同步——`_run()` 是唯一的協程，每一輪呼叫
## `speaker.next_line()`（見 character.gd），可能要等 LLM 回應或等玩家打字，
## 都不阻塞 `_process()` 的距離/中斷判定。開場白（turn 0）也一律經過
## `next_line()`，見下方 `_run()` 的說明。

signal finished(reason: String)

## 工程安全閥。理由見 note/技術/LLM 串接與 AI 服務層.md 的「對話由 Agent 自己決定何時結束」§界線
const SAFETY_MAX_TURNS := 10

const TURN_GAP := 0.5			# 一句講完到下一句之間的空檔（秒）
const MAX_DISTANCE := 48.0		# 講到一半離這麼遠就散場，比搭話門檻寬鬆

## 結束原因。這些是「正常結束」，不是失敗 ——
## 失敗原因碼在 Character.TALK_*，兩者不可混用，
## 否則 AI 會把正常結束的對話當成錯誤而反覆重試
##
## REASON_ENDED_BY_SPEAKER 取代了原本的 REASON_TURN_LIMIT：正常結束＝有人
## （LLM 判斷該收尾，或 fallback 收尾）決定結束，不再是「講滿幾輪就散」
const REASON_ENDED_BY_SPEAKER := "ENDED_BY_SPEAKER"
const REASON_TOO_FAR := "TOO_FAR"
const REASON_INTERRUPTED := "INTERRUPTED"

## 被搭話的一方在 turn 0 選擇不理會（engage=false）：跟 REASON_ENDED_BY_SPEAKER
## 分開，因為一句話都沒講——不能算「認識」（_apply_rewards() 只認
## REASON_ENDED_BY_SPEAKER），事實句也要誠實反映「沒有回應」而不是「講完話了」
## （複審 PR #667 抓到：原本兩者共用同一個 reason，誤觸發 note_meeting()）
const REASON_IGNORED := "IGNORED"

## 聽者主動決定不再繼續聽（issue #691，《99》P-31）：跟 REASON_ENDED_BY_SPEAKER
## 分開，因為結束的決定權在聽者，不是講話那一方
const REASON_ENDED_BY_LISTENER := "ENDED_BY_LISTENER"

var initiator: Character
var target: Character

var _turns: Array[Dictionary] = []
var _finished := false


func _ready() -> void:
	initiator.enter_conversation(self)
	target.enter_conversation(self)
	_run()

# 只做距離/有效性檢查，不驅動輪次——輪次現在完全由 _run() 的 await 鏈推進。
# 這裡呼叫 _finish() 是安全的：_finished 從 false 變 true 的當下，_run()
# 一定卡在某個 await 上（GDScript 單執行緒，_process() 能跑到這裡就代表
# _run() 這一刻沒有在執行），所以不會有「兩邊同時搶著收尾」的問題，
# _run() 之後恢復執行時自己會看到 _finished 是 true 並收尾、釋放節點
func _process(_delta: float) -> void:
	if _finished:
		return

	if not is_instance_valid(initiator) or not is_instance_valid(target):
		_finish(REASON_INTERRUPTED)
		return

	if initiator.get_body_position().distance_to(target.get_body_position()) > MAX_DISTANCE:
		_finish(REASON_TOO_FAR)
		return

## 唯一的協程，整場對話的輪次都在這裡推進。
##
## 開場白一律過 LLM（issue #630／《99》P-67）：不再由發起方（目前只有玩家會
## 呼叫 talk_to()）冒一句寫死的招呼，turn 0 直接問被搭話的一方要不要理——
## 對方可以選擇不理會、逕自去做自己的事（engage=false，見
## AISchema.validate_dialogue_open()），跟真實社交一樣，不由引擎規定「按 E
## 就一定會被回應」。next_line() 一開頭就會顯示「…」，等待期間不是空畫面
func _run() -> void:
	var turn := 0
	while turn < SAFETY_MAX_TURNS:
		var speaker := target if turn % 2 == 0 else initiator
		var listener := initiator if turn % 2 == 0 else target

		# 聽者的對稱退出點（issue #691）：turn 0 跳過——turn 0 的「listener」
		# 是發起對話的那一方，他都主動按下 talk 了，問他「還想不想聽」沒有
		# 意義；turn 0 的「要不要理會」已經是 next_line() 的 engage 欄位在管
		# （見下方）。放在 speaker.next_line() 之前問，退出決定優先於等待
		# 對方回話的逾時——聽者不想聽了就不用等 next_line() 那最長 8 秒的
		# 逾時（2026-08-30 拍板，見《99》P-31）
		if turn > 0:
			var wants_to_continue: bool = await listener.wants_to_continue(speaker, _turns)
			if _bail_if_finished():
				return
			if not wants_to_continue:
				_finish(REASON_ENDED_BY_LISTENER)
				queue_free()
				return

		var result: Dictionary = await speaker.next_line(listener, _turns, SAFETY_MAX_TURNS)
		if _bail_if_finished():
			return

		if not result.get("ok", false):
			_finish_with_fallback(speaker, listener, turn == 0)
			return

		# 被搭話的一方選擇不理會（issue #630）：只有 turn 0 才可能出現，之後
		# 已經在聊，不會再有「要不要理」這個選項——安靜結束，沒有台詞可顯示，
		# 把 next_line() 開頭顯示的「…」收掉
		if turn == 0 and not result.get("engage", true):
			if speaker.bubble != null:
				speaker.bubble.clear()
			_finish(REASON_IGNORED)
			queue_free()
			return

		var line: String = result.get("line", "")
		# next_line() 內部（agent.gd）自己顯示過「…」，interrupt=true 立刻換成
		# 真正的台詞，不用等「…」的顯示時間跑完
		_speak(speaker, line, true)
		_turns.append(PromptBuilder.turn_entry(speaker.character_name, line))

		if result.get("end", false):
			_finish(REASON_ENDED_BY_SPEAKER)
			queue_free()
			return

		turn += 1
		if await _wait_for_read(speaker, line):
			return

	# 撞到安全閥：不算失敗，正常收尾即可，但不额外補一句收尾台詞——
	# 這種情況下最後一句已經是某一方剛講完的話，硬塞一句「先走了」反而突兀
	_finish(REASON_ENDED_BY_SPEAKER)
	queue_free()

# 等這句話讀完的時間，讓下一句不會緊接著跳出來。回傳 true 代表等待期間
# 對話已經被 _process() 結束（走遠/失效），呼叫端要立刻 return，不要再往下做
func _wait_for_read(speaker: Character, line: String) -> bool:
	await get_tree().create_timer(speaker.speech_duration(line) + TURN_GAP).timeout
	return _bail_if_finished()

# _finished 若已經被 _process() 設成 true，代表這個協程重新拿回控制權的
# 這一刻，就是唯一安全能真正釋放這個節點的時機——見上面 _process() 的說明
func _bail_if_finished() -> bool:
	if not _finished:
		return false
	queue_free()
	return true

func _speak(speaker: Character, line: String, interrupt: bool = false) -> void:
	speaker.face_towards(target if speaker == initiator else initiator)
	speaker.say(line, interrupt)

# LLM 停用/逾時/驗證失敗，next_line() 統一回 ok=false，這裡收尾：說一句
# DialogueLines 的模板句（唯一還在用它的地方，正常結束的台詞是 LLM 自己
# 那句，不再另外補一句），然後正常結束——對玩家來說這場對話看起來很正常，
# 差別只在收尾早了幾輪，不是任何看得出來的「壞掉」。is_opening=true（turn 0
# 就失敗）時换成 opening()：這時候連第一句都還沒有，講「再見」不合理，
# 比照 opening() 自己宣告的 fallback 定位（issue #630／《99》P-67）
func _finish_with_fallback(speaker: Character, listener: Character, is_opening: bool = false) -> void:
	# next_line() 裡的 await 讓出過控制權，speaker/listener 理論上可能在這段
	# 期間被移出場景（跟 _process() 的 is_instance_valid 檢查是同一種顧慮）
	if is_instance_valid(speaker) and is_instance_valid(listener):
		var line := (
			DialogueLines.opening(listener.character_name) if is_opening
			else DialogueLines.closing()
		)
		_speak(speaker, line, true)
		# fallback 這句也是真的說出口的一句，沒算進 _turns 的話，
		# 之後任何依對話輪數／內容做的判定都會少算這一句
		# （CodeRabbit review 抓到）
		_turns.append(PromptBuilder.turn_entry(speaker.character_name, line))

	_finish(REASON_ENDED_BY_SPEAKER)
	queue_free()

# 被外部打斷（例如玩家走開、角色要去做別的事）
func interrupt() -> void:
	_finish(REASON_INTERRUPTED)

# 只負責標記狀態、發獎勵、通知雙方離開對話、發訊號——不在這裡 queue_free()。
# 呼叫端可能是 _process()（此時 _run() 還卡在某個 await 上，此刻 free 掉
# self 會讓 _run() 之後恢復執行時操作一個已釋放的節點而炸掉），
# 也可能是 _run() 自己（此時它自己緊接著呼叫 queue_free() 是安全的）
func _finish(reason: String) -> void:
	if _finished:
		return
	_finished = true

	if reason == REASON_ENDED_BY_SPEAKER or reason == REASON_ENDED_BY_LISTENER:
		_apply_rewards()

	for character in [initiator, target]:
		if is_instance_valid(character):
			character.exit_conversation(reason)

	finished.emit(reason)

func _apply_rewards() -> void:
	for pair in [[initiator, target], [target, initiator]]:
		var character: Character = pair[0]
		var other: Character = pair[1]

		if not is_instance_valid(character) or not is_instance_valid(other):
			continue

		if character.relationships != null:
			character.relationships.note_meeting(other.character_id)
			# 只記「見過面」，不對這場對話做任何關係定性——跟
			# _on_attacked()／_on_rescued() 同一個原則：固定公式幫「深度對話」
			# 算出該加多少好感/信任，AI 沒機會表態（《00》原則二／三，
			# relations 的引擎數值已於 2026-08-16～#601 全部拿掉）。這裡甚至
			# 不需要額外記事實句：對話內容本身就在 AI 自己的上下文裡
