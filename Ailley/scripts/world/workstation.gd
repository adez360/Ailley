class_name Workstation
extends StaticBody2D

## 可以工作賺錢的地點。候選偵測交給 player.gd（Area2D 範圍 + 面向判定），
## 距離的最終把關在 work_at()（跟 TALK_RANGE 同一種簡單距離檢查，見 character.gd 的
## "---- 工作 ----" 那節），這裡自己不查距離，只管「誰現在佔用著」。
##
## StaticBody2D + CollisionShape2D 同時做兩件事：NavGrid 的 rebuild() 是物理
## 查詢，場景裡隨手擺的 StaticBody2D 會自動被算成障礙（見 nav_grid.gd 開頭
## 註解），角色不會穿過桌子走位；collision_layer 另外掛了 interactable，
## player.gd 的 InteractArea 就是靠偵測到這層才把工作站納入候選（issue #109）。
##
## 同時最多 MAX_OCCUPANTS 個角色能用同一張工作站，各自佔一個名額（issue #663：
## MVP 只有一台工作站，NPC 排程整天佔著會讓玩家實質搶不到）。work_at() 呼叫
## try_occupy() 找不到空名額就回 Character.WORK_OCCUPIED。名額釋放後進入
## COOLDOWN_MINUTES 冷卻，但冷卻只對「剛釋放這個名額的那位角色」生效，其他人
## （含玩家）當下就能入座——冷卻若擋所有人，空窗根本不存在：Agent 排程重試
## 緊跟在時間結算後面，名額一空出來立刻被下一筆排程任務搶回，玩家永遠排在
## 最後面，淨效果只剩吞吐量減半。

const MAX_OCCUPANTS := 3
const COOLDOWN_MINUTES := Character.WORK_DURATION_MINUTES		# 跟工作時長一樣長，拍板值

## 每個名額一份狀態：occupant 非 null 代表正在工作；occupant 是 null 但
## _remaining_minutes 還沒歸零代表冷卻中，只鎖 _last_released_ids 記的那位
## 角色（release() 寫入，其他人入座不受影響）；兩者都空代表誰都能用。
## _remaining_minutes 在工作中是「預估還要幾分鐘做完」，純粹給 UI 用——
## try_occupy() 當下假設完整 Character.WORK_DURATION_MINUTES，跟
## Character._run_work() 各自倒數、不是同一份計時器，角色提早離開工作站會
## 提前呼叫 release()，這裡的數字只是粗略 ETA，不影響任何判定
var _occupants: Array[Character] = [null, null, null]
var _remaining_minutes: Array[int] = [0, 0, 0]
var _last_released_ids: Array[int] = [0, 0, 0]

## E 鍵現在會打到誰的即時提示（issue #81）——player.gd 每幀算一次「E 會先試
## 誰」，是這個工作站就打開它。不是 Character，沒有 character_outline.gdshader
## 那套可用（shader 靠 sprite 圖集的 alpha 邊界抓輪廓，這裡的 Polygon2D 是
## 純色填滿，沒有邊界可抓），改用場景裡另外擺的 Line2D 描一圈白框
@onready var highlight: Line2D = get_node_or_null("Highlight")

## 客滿時飄在工作站上方的提示，跟 work_progress.gd 同一種「平常隱藏、有事才
## 顯示」的頭上飄字做法。有空名額就藏起來，避免每張工作站平常就掛著字
@onready var status_label: Label = get_node_or_null("StatusLabel")


func _ready() -> void:
	add_to_group("workstations")
	GameClock.time_changed.connect(_on_time_changed)
	_update_status_label()

func set_highlighted(on: bool) -> void:
	if highlight != null:
		highlight.visible = on

# 「全部名額都有還在的角色在工作中」。冷卻中的名額不算佔用——它是空的，
# 只是鎖著釋放它的那位，對其他人來說現在就能用
func is_occupied() -> bool:
	_sweep_invalid_occupants()
	for i in MAX_OCCUPANTS:
		if _occupants[i] == null:
			return false
	return true

func try_occupy(character: Character) -> bool:
	var idx := _free_slot_index(character)
	if idx == -1:
		return false
	_occupants[idx] = character
	_remaining_minutes[idx] = Character.WORK_DURATION_MINUTES
	_last_released_ids[idx] = 0
	_update_status_label()
	return true

# 忽略不是目前佔用者的呼叫——角色重複呼叫、或工作中途被打斷後又收到一次
# release，都不該把別人剛卡上的位子清掉
func release(character: Character) -> void:
	var idx := _occupants.find(character)
	if idx == -1:
		return
	_occupants[idx] = null
	_remaining_minutes[idx] = COOLDOWN_MINUTES
	_last_released_ids[idx] = character.get_instance_id()
	_update_status_label()

# 掃掉 occupant 已被 free 的名額。三個讀取端（is_occupied() / _free_slot_index() /
# _update_status_label()）共用：用 is_instance_valid() 不用 `occ != null`——Godot 4
# 裡被 free 掉的物件 `!= null` 仍然成立，所以佔用者被移除（換場景、日後的
# despawn）之後，這個名額會永遠回報「有人在用」，而 release() 比對的是一個
# 已經不存在的角色，永遠清不掉。掃到失效的 occupant 就直接清空、不套冷卻——
# 沒有人真的用滿，這裡也是「角色工作到一半被 free」時唯一會把名額放出來的地方
func _sweep_invalid_occupants() -> void:
	for i in MAX_OCCUPANTS:
		var occ := _occupants[i]
		if occ != null and not is_instance_valid(occ):
			_occupants[i] = null
			_remaining_minutes[i] = 0
			_last_released_ids[i] = 0

# 找第一個「這個角色能用」的名額。冷卻中的名額只對 _last_released_ids 記的
# 那位角色關門——同一個名額不被釋放者無縫接力，剛來的人（玩家）不受影響
func _free_slot_index(character: Character) -> int:
	_sweep_invalid_occupants()
	var requester_id := character.get_instance_id()
	for i in MAX_OCCUPANTS:
		if _occupants[i] == null and (_remaining_minutes[i] == 0 or _last_released_ids[i] != requester_id):
			return i
	return -1

func _on_time_changed(_hour: int, _minute: int) -> void:
	var changed := false
	for i in MAX_OCCUPANTS:
		if _remaining_minutes[i] > 0:
			_remaining_minutes[i] -= 1
			changed = true
	if changed:
		_update_status_label()

# 只在客滿時顯示，答 issue #663 玩家最想知道的那句：大概還要多久。
# 「客滿」＝所有名額都有還在的角色在工作中。冷卻中的名額是空的、只鎖釋放它的
# 那位角色，剛來的人當下就能入座，所以不算客滿——有一個名額沒有正在工作的
# 角色（空著或冷卻中）就把飄字藏起來。
# ETA 取工作中名額剩餘分鐘數的最小值，**不另加 COOLDOWN_MINUTES**：release
# 之後冷卻只鎖釋放者，看著飄字等的人在名額釋放的當下就入得了座，把冷卻加進
# 去反而會報出一個根本不用等的時間。唯一的邊角：玩家自己剛釋放、還在冷卻的
# 名額也會讓飄字隱藏，但玩家按 E 仍會被擋——飄字不知道讀者是誰，維持簡單
func _update_status_label() -> void:
	if status_label == null:
		return
	_sweep_invalid_occupants()
	var soonest := -1
	for i in MAX_OCCUPANTS:
		if _occupants[i] == null:
			status_label.visible = false
			return
		if soonest == -1 or _remaining_minutes[i] < soonest:
			soonest = _remaining_minutes[i]
	status_label.visible = true
	status_label.text = "客滿・約 %d 分鐘後有空位" % soonest
