class_name Inventory
extends Node

## 角色的物品容器。快捷欄與主背包共用同一個陣列——「把快捷欄的東西丟進背包」
## 是搬 index，不是跨容器搬移。掛在 Character 基底而不是 Player：
## 核心約束「Player 能做到的，Agent 也必須能做到」，Agent 沒有 UI 也要查得到背包。
##
## 一格的資料照規格書 08 §1：{item_id, count, decay, durability}，空格是 {}。
## 堆疊規則見 §4，_add_stackable() / _add_unstackable() 各自對應規則 #1 #2。
##
## 金錢也在這裡：規格書 01 §3-3 把 money 與 inventory 同樣歸在 economy 底下，
## 為了一個 int 另外開一個節點，換到的只是多一個 get_node_or_null 要防。
##
## 物品使用（use_item()）不查 DatabaseManager——Character 負責從 item definition
## （ItemDatabase.get_item()）整包讀出 effect_* 與 is_consumable，再呼叫
## inventory.use_item(item_id, stats, effects, is_consumable)。effect_* 的
## key 是 "effect_" + Stats.SPEC 的欄位名，跟著 SPEC 走、不寫死清單——SPEC
## 未來加一項數值，這裡不用跟著改。人格特質（personality_delta）不算在內：
## 那是 Character 自己的欄位，Inventory 不需要知道人格是什麼，由呼叫端
## （Character.eat()/drink()）另外呼叫 apply_personality_delta() 處理。
## Inventory 只負責：1. 確認物品存在 2. 確認是否可消耗 3. 套用 Stats 效果
## 4. 成功後消耗 1 個物品

## 格子或金錢真的變了才發。只在成功的異動上發——失敗是原子的、什麼都沒動，
## 發出去只會讓顯示端白刷一次。
##
## 有這個訊號，UI 才不用每幀輪詢：36 個格子按鈕各自 _process() 重讀一次，
## 60fps 下光是 get_slot() 的 duplicate() 就兩千多次配置／秒，而資料只在
## 買東西或工作時才變。攜帶參數刻意留白——顯示端要的是「重讀一次」，
## 不是「哪一格變了」，帶了反而每個顯示端都要判斷這則跟自己有沒有關係
signal changed

## 外部直接覆蓋 slots（例如存檔載入）後用來補發變更通知，
## 讓 InventorySlotButton / Hotbar / InventoryPanel 同步刷新。
## 外部不要直接 emit_signal("changed")。
func notify_changed() -> void:
	changed.emit()

const HOTBAR_SIZE := 9
const MAIN_SIZE := 27
const SIZE := HOTBAR_SIZE + MAIN_SIZE		# index 0..8 快捷欄，9..35 主背包
const MAX_STACK := 30

## 同 item_id 且 decay 差距在這個範圍內才能疊進同一格。08 §4 規則 #1
const STACK_DECAY_TOLERANCE := 10

## add_item() 的失敗原因碼。比照 character.gd 的 TALK_*——
## 計畫 §5.3 要求每個動作都要能講出為什麼失敗，AI 才有辦法重排行程
const ADD_OK := ""
const ADD_NO_SPACE := "NO_SPACE"
const ADD_INVALID_COUNT := "INVALID_COUNT"

## remove_item() 的失敗原因碼
const REMOVE_OK := ""
const REMOVE_NOT_FOUND := "NOT_FOUND"
const REMOVE_INVALID_COUNT := "INVALID_COUNT"

## use_item() 的回傳原因碼
const USE_OK := ""
const USE_NOT_FOUND := "NOT_FOUND"
const USE_NOT_CONSUMABLE := "NOT_CONSUMABLE"
const USE_INVALID_STATS := "INVALID_STATS"
const USE_INVALID_EFFECT := "INVALID_EFFECT"
const USE_REMOVE_FAILED := "REMOVE_FAILED"

## 開局身上有多少錢。規格書 01 §3-3
const DEFAULT_MONEY := 300

## add_money() / spend() 的失敗原因碼
const MONEY_OK := ""
const MONEY_NOT_ENOUGH := "NOT_ENOUGH"
const MONEY_INVALID_AMOUNT := "INVALID_AMOUNT"

var slots: Array[Dictionary] = []

# 快捷欄選到第幾格。這是資料層狀態不是 UI 狀態——UI 只是顯示它，
# Agent 沒有 UI 也要有「手上拿著什麼」這個概念
var _selected_index := 0

# 私有而不是像 slots 那樣公開：金錢只有「進帳」與「扣款」兩種合法異動，
# 兩者都要驗證。公開欄位讓呼叫端寫得出 inventory.money -= price，
# 那條路繞過餘額檢查，扣成負數之後不會有任何地方報錯
var _money := DEFAULT_MONEY


# 在 _init() 而不是 _ready() 配置，這樣 Inventory.new() 出來的實例還沒進場景樹
# 就已經是合法容器。Agent 沒有 UI 也要查得到背包，查詢時機不該綁在入樹之後
func _init() -> void:
	slots.resize(SIZE)
	for i in SIZE:
		slots[i] = {}


# ---- 查詢 ----

# 該格內容的副本，空格回空 Dictionary。索引越界一律當空格不拋錯——
# 呼叫端（debug 指令、日後的 UI）常常是先算出索引才驗證，越界不該是例外路徑
func get_slot(index: int) -> Dictionary:
	if index < 0 or index >= SIZE:
		return {}
	return slots[index].duplicate()

# 空格要先跳過再比對 item_id——空格的 get("item_id", "") 回空字串，
# 拿 "" 來查會match到每一個空格，然後存取它們沒有的 count 鍵
func count_item(item_id: String) -> int:
	var total := 0
	for slot in slots:
		if slot.is_empty():
			continue
		if slot["item_id"] == item_id:
			total += int(slot["count"])
	return total

# count 非正數一律回 false，跟 remove_item() 的驗證對齊——
# 呼叫端常寫成 if has_item(id, n): remove_item(id, n)，
# 這裡若對 n <= 0 回 true，就會走進一個必定失敗的 remove
func has_item(item_id: String, count: int = 1) -> bool:
	if count <= 0:
		return false
	return count_item(item_id) >= count

func find_first_empty() -> int:
	for i in SIZE:
		if slots[i].is_empty():
			return i
	return -1


# ---- 異動 ----

# 加入物品。成功回傳 ADD_OK（空字串），沒位置回傳 ADD_NO_SPACE，且不動任何格——
# 失敗是原子的，不會半途占掉一部分槽位又回報失敗。
#
# durability 留 -1（預設）代表這批物品用 decay 追蹤，會嘗試疊進相容的既有格；
# 傳 0 以上代表 carry 類，08 §4 規則 #2 一件佔一格、不可疊。
# 物品定義檔不在這則範圍內，呼叫端目前得自己講清楚這批是哪一種。
#
# count 非正數擋在這裡而不是各自的 _add_*()：放行的話 _add_stackable() 會建出
# count 為 0 的格子（非空所以 find_first_empty() 跳過，count_item() 又算成 0，
# 於是 remove_item() 清不掉它），_add_unstackable() 的蒐集迴圈則永遠比不到
# empties.size() == count，把整個背包填滿
# notify=false 給 give_to() 這種「一次轉移要拆好幾個 chunk 加」的呼叫端用——
# 每個 chunk 各發一次 changed 的話，訂閱者會在轉移途中看到目標背包只收到
# 一部分物品的暫態；呼叫端自己決定「全部 chunk 都進去了」才發那一次
# （CodeRabbit review 抓到）
func add_item(item_id: String, count: int = 1, decay: int = 0, durability: int = -1, notify: bool = true) -> String:
	if count <= 0:
		return ADD_INVALID_COUNT
	# 兩條路各有好幾個 return，所以 changed 在這裡發一次就好，不用兩邊各自散落
	var reason := _add_unstackable(item_id, count, decay, durability) if durability >= 0 \
			else _add_stackable(item_id, count, decay)
	if reason == ADD_OK and notify:
		changed.emit()
	return reason

# 每一格最多疊 MAX_STACK。先算總容量（相容既有格的剩餘空間 + 空格 * MAX_STACK）
# 不夠就整批擋下，不會半途占掉一部分槽位又回報 ADD_NO_SPACE
func _add_stackable(item_id: String, count: int, decay: int) -> String:
	var total_capacity := 0
	for slot in slots:
		if slot.is_empty():
			total_capacity += MAX_STACK
			continue
		if slot["item_id"] != item_id or int(slot["durability"]) >= 0:
			continue
		if absi(int(slot["decay"]) - decay) > STACK_DECAY_TOLERANCE:
			continue
		total_capacity += MAX_STACK - int(slot["count"])
	if total_capacity < count:
		return ADD_NO_SPACE

	# 先填相容的既有格，每格補到 MAX_STACK 為止
	var remaining := count
	for i in SIZE:
		if remaining <= 0:
			break
		var slot: Dictionary = slots[i]
		if slot.is_empty() or slot["item_id"] != item_id or int(slot["durability"]) >= 0:
			continue
		if absi(int(slot["decay"]) - decay) > STACK_DECAY_TOLERANCE:
			continue
		var space := MAX_STACK - int(slot["count"])
		if space <= 0:
			continue
		var add_count := mini(remaining, space)
		slot["count"] = int(slot["count"]) + add_count
		slot["decay"] = maxi(int(slot["decay"]), decay)		# 取較差（較高）的 decay
		remaining -= add_count

	# 還有剩的就開新格，每個新格一樣上限 MAX_STACK
	while remaining > 0:
		var empty := find_first_empty()
		if empty == -1:
			return ADD_NO_SPACE
		var add_count := mini(remaining, MAX_STACK)
		slots[empty] = {"item_id": item_id, "count": add_count, "decay": decay, "durability": -1}
		remaining -= add_count

	return ADD_OK

func _add_unstackable(item_id: String, count: int, decay: int, durability: int) -> String:
	var empties: Array[int] = []
	for i in SIZE:
		if slots[i].is_empty():
			empties.append(i)
			if empties.size() == count:
				break

	if empties.size() < count:
		return ADD_NO_SPACE

	for i in empties:
		slots[i] = {"item_id": item_id, "count": 1, "decay": decay, "durability": durability}
	return ADD_OK

# 移除物品，成功回傳 REMOVE_OK，數量不足回傳 REMOVE_NOT_FOUND 且不動任何格——
# 同樣是原子的，不會先扣掉一部分才發現不夠。
# count 非正數是呼叫端的錯，不是「拿掉 0 個成功了」，所以回原因碼而不是 REMOVE_OK
func remove_item(item_id: String, count: int = 1) -> String:
	return _remove_item_detailed(item_id, count)["reason"]

# 跟 remove_item() 同一套規則與原子性保證，但額外回傳實際扣除的每一筆
# {count, decay, durability}——give_to() 這類「把東西原封不動搬進別的容器」
# 的呼叫端少了這份細節，只能送出全新狀態（decay=0、durability=-1），原本的
# 腐壞／耐久資訊會直接消失（CodeRabbit review 抓到，#158）。失敗時 "removed"
# 是空陣列，不動任何格
#
# notify=false 給 give_to() 這種「先扣、可能還要整批回滾」的呼叫端用——扣的
# 當下發 changed 的話，訂閱者會在轉移還沒確定成功前就看到來源背包少了東西，
# 送禮失敗回滾後淨變化是 0，卻讓訂閱者觀察到一次騙人的暫態（CodeRabbit
# review 抓到）。呼叫端自己決定「真的確定了」才發那一次
func remove_item_detailed(item_id: String, count: int = 1, notify: bool = true) -> Dictionary:
	return _remove_item_detailed(item_id, count, notify)

func _remove_item_detailed(item_id: String, count: int, notify: bool = true) -> Dictionary:
	if count <= 0:
		return {"reason": REMOVE_INVALID_COUNT, "removed": []}
	if count_item(item_id) < count:
		return {"reason": REMOVE_NOT_FOUND, "removed": []}

	var removed: Array[Dictionary] = []
	var remaining := count
	for i in SIZE:
		if remaining <= 0:
			break

		var slot: Dictionary = slots[i]
		if slot.is_empty() or slot["item_id"] != item_id:
			continue

		var take := mini(remaining, int(slot["count"]))
		removed.append({"count": take, "decay": int(slot["decay"]), "durability": int(slot["durability"])})
		slot["count"] = int(slot["count"]) - take
		remaining -= take
		if int(slot["count"]) <= 0:
			slots[i] = {}

	if notify:
		changed.emit()
	return {"reason": REMOVE_OK, "removed": removed}


# ---- 使用 ----

# 使用一個消耗品。effects 格式（通常直接整包傳 ItemDatabase.get_item() 的結果）：
# {"effect_satiety": 40, "effect_hydration": 20, ...}，key 是 "effect_" + Stats.SPEC
# 的欄位名，8 項都能寫、沒寫的視為 0。Stats.add() 會負責將數值限制在 0~100。
# 只有效果套用成功，才會消耗背包中的 1 個物品——順序反過來的話，remove 失敗會讓
# 效果套用了卻沒扣物品，兩邊帳對不上
func use_item(item_id: String, stats: Stats, effects: Dictionary, is_consumable: bool = true) -> String:
	if stats == null:
		push_warning("[Inventory] 使用物品失敗：Stats 不存在。")
		return USE_INVALID_STATS

	if not has_item(item_id, 1):
		push_warning("[Inventory] 使用物品失敗：背包沒有 %s。" % item_id)
		return USE_NOT_FOUND

	if not is_consumable:
		push_warning("[Inventory] %s 不是可消耗物品。" % item_id)
		return USE_NOT_CONSUMABLE

	var deltas := {}
	for key in Stats.SPEC:
		var value := float(effects.get("effect_%s" % key, 0.0))
		if not is_finite(value):
			push_error("[Inventory] %s 的 effect_%s 不是有效數值。" % [item_id, key])
			return USE_INVALID_EFFECT
		if value != 0.0:
			deltas[key] = value

	for key in deltas:
		stats.add(key, deltas[key])

	var remove_reason := remove_item(item_id, 1)
	if remove_reason != REMOVE_OK:
		push_error("[Inventory] 使用 %s 後移除物品失敗：%s" % [item_id, remove_reason])
		return USE_REMOVE_FAILED

	var log_parts := PackedStringArray()
	for key in deltas:
		log_parts.append("%s=%+.1f" % [key, deltas[key]])
	print("[Inventory] 使用物品：%s | %s" % [item_id, " ".join(log_parts)])
	return USE_OK


# ---- 搬移 ----

# 搬到空格；目的地非空就失敗，不覆蓋。要交換兩個已佔用的格用 swap_slot()
func move_slot(from: int, to: int) -> bool:
	if from < 0 or from >= SIZE or to < 0 or to >= SIZE or from == to:
		return false
	if slots[from].is_empty() or not slots[to].is_empty():
		return false

	slots[to] = slots[from]
	slots[from] = {}
	changed.emit()
	return true

func swap_slot(a: int, b: int) -> bool:
	if a < 0 or a >= SIZE or b < 0 or b >= SIZE or a == b:
		return false

	var tmp := slots[a]
	slots[a] = slots[b]
	slots[b] = tmp
	changed.emit()
	return true


# ---- 快捷欄選格 ----

func get_selected_index() -> int:
	return _selected_index

# -1 是「沒有選取任何格」的哨兵值（#304：點兩下同一格取消選擇），
# 其餘值夾限在快捷欄範圍內。跟一格的 durability=-1 是同一種寫法：
# 落在合法範圍之外，用來跟「真的選到第 0 格」區分開來
func set_selected_index(index: int) -> void:
	_selected_index = -1 if index < 0 else clampi(index, 0, HOTBAR_SIZE - 1)


# ---- 金錢 ----

func get_money() -> int:
	return _money

# 從存檔覆寫金額（CharacterStatePersistence 載入 npc_wallet 用）。跳過
# add_money()／spend() 的正負向驗證——存檔值是要直接覆蓋現有金額，不是
# 相對異動，跟 slots 存檔載入時直接覆寫陣列是同一種做法。呼叫端自己決定
# 要不要接著呼叫 notify_changed() 通知 UI
func set_money(amount: int) -> void:
	_money = maxi(0, amount)

# 進帳。amount 非正數回原因碼而不是默默放行——要扣錢的呼叫端該用 spend()，
# 讓 add_money(-50) 成立的話，「收入」與「支出」就會走同一條沒有餘額檢查的路
func add_money(amount: int) -> String:
	if amount <= 0:
		return MONEY_INVALID_AMOUNT

	_money += amount
	changed.emit()
	return MONEY_OK

# 扣款。餘額不足時一毛都不扣，跟 remove_item() 的原子性一致——
# 呼叫端拿到 MONEY_NOT_ENOUGH 就知道這筆交易整個沒發生，不必自己回滾
func spend(amount: int) -> String:
	if amount <= 0:
		return MONEY_INVALID_AMOUNT
	if _money < amount:
		return MONEY_NOT_ENOUGH

	_money -= amount
	changed.emit()
	return MONEY_OK


# ---- Agent 查詢 ----

# 不含空格的密集摘要，給行為判定與日後的 AI payload 用。
# 每筆補一個 slot 索引，回傳的是副本，改它不會動到內部狀態
func get_summary() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for i in SIZE:
		if not slots[i].is_empty():
			var entry := slots[i].duplicate()
			entry["slot"] = i
			result.append(entry)
	return result
