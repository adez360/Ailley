extends Node

## 兩個角色之間的一場對話。
##
## 刻意做成獨立物件，不把狀態塞進任一方的 Character：對話是「兩個角色之間」的東西，
## 塞進其中一方會讓另一方每次都要反查，而且結束時要同步清乾淨兩邊，
## 狀態分散在兩個節點很容易漏掉一邊。
##
## 生命週期：Character.talk_to() 設好 initiator / target 後加進場景，
## 講完自己 queue_free()。內容從 DialogueLines 拿，換成 LLM 時這個檔不用動。

signal finished(reason: String)

## 一場對話最多幾輪（雙方各講一次算兩輪）。對齊系統分析計畫 §6 的上限
const MAX_TURNS := 6
const TURN_GAP := 0.5			# 一句講完到下一句之間的空檔（秒）
const MAX_DISTANCE := 48.0		# 講到一半離這麼遠就散場，比搭話門檻寬鬆

## 結束原因。這些是「正常結束」，不是失敗 ——
## 失敗原因碼在 Character.TALK_*，兩者不可混用，
## 否則 AI 會把正常結束的對話當成錯誤而反覆重試
const REASON_TURN_LIMIT := "TURN_LIMIT"
const REASON_TOO_FAR := "TOO_FAR"
const REASON_INTERRUPTED := "INTERRUPTED"

# 好好講完一場之後雙方各自的收穫
const SOCIAL_GAIN := 25.0
const MOOD_GAIN := 5.0
const AFFINITY_GAIN := 3.0

var initiator: Character
var target: Character

var _turn := 0
var _timer := 0.0
var _finished := false


func _ready() -> void:
	initiator.enter_conversation(self)
	target.enter_conversation(self)

	_speak(initiator, DialogueLines.opening(
		target.character_name,
		initiator.stats,
		initiator.relationships.get_affinity(target.character_id)
	))

func _process(delta: float) -> void:
	if _finished:
		return

	# 任一方在對話中被移出場景就直接收掉
	if not is_instance_valid(initiator) or not is_instance_valid(target):
		_finish(REASON_INTERRUPTED)
		return

	if initiator.get_body_position().distance_to(target.get_body_position()) > MAX_DISTANCE:
		_finish(REASON_TOO_FAR)
		return

	_timer -= delta
	if _timer > 0.0:
		return

	if _turn >= MAX_TURNS:
		_finish(REASON_TURN_LIMIT)
		return

	_take_turn()

# 輪流講。偶數輪是被搭話的一方回話，奇數輪換發起方
func _take_turn() -> void:
	var speaker := target if _turn % 2 == 0 else initiator
	var listener := initiator if _turn % 2 == 0 else target

	_speak(speaker, DialogueLines.reply(
		speaker.stats,
		speaker.relationships.get_affinity(listener.character_id),
		_turn
	))
	_turn += 1

func _speak(speaker: Character, line: String) -> void:
	speaker.face_towards(target if speaker == initiator else initiator)
	speaker.say(line)
	_timer = speaker.speech_duration(line) + TURN_GAP

# 被外部打斷（例如玩家走開、角色要去做別的事）
func interrupt() -> void:
	_finish(REASON_INTERRUPTED)

func _finish(reason: String) -> void:
	if _finished:
		return
	_finished = true

	# 好好講完才有收穫；被打斷或走散不算
	if reason == REASON_TURN_LIMIT:
		_apply_rewards()
		if is_instance_valid(initiator) and is_instance_valid(target):
			initiator.say(DialogueLines.closing(
				target.character_name,
				initiator.relationships.get_affinity(target.character_id)
			))

	for character in [initiator, target]:
		if is_instance_valid(character):
			character.exit_conversation()

	finished.emit(reason)
	queue_free()

func _apply_rewards() -> void:
	for pair in [[initiator, target], [target, initiator]]:
		var character: Character = pair[0]
		var other: Character = pair[1]

		if not is_instance_valid(character) or not is_instance_valid(other):
			continue

		if character.stats != null:
			character.stats.add("social", SOCIAL_GAIN)
			character.stats.add("mood", MOOD_GAIN)

		if character.relationships != null:
			character.relationships.add_affinity(other.character_id, AFFINITY_GAIN)
			character.relationships.note_meeting(other.character_id)
