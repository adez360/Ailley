class_name Relationships
extends Node

## 這個角色對其他角色的關係（好感度等）。
##
## key 用對方的 character_id 而不是 character_name —— name 是玩家可以隨時改的，
## 拿它當 key 會讓改名等於失憶。
##
## 每一筆存成 Dictionary 而不是單一數值，是為了留擴充空間：之後要加熟悉度、
## 最後見面時間、印象標籤，都只是在 DEFAULT_RECORD 多一個 key，
## 既有的 get_affinity / add_affinity 呼叫端完全不用改。
##
## 讀與寫分開，這條是硬規則：**查詢不可以建立紀錄**。
## 曾經 get_affinity() 走的是「沒有就當場建一筆」的 get_record()，於是
## conversation.gd 開場問一次好感度，就讓 has_met() 從此為真而 met_count 還是 0 ——
## 「認識」這件事被「問過」給污染掉了。
## 對外的查詢一律唯讀，只有 add_affinity() / note_meeting() 這種明確的寫入
## 才走 _ensure_record()。

const AFFINITY_MIN := -100.0
const AFFINITY_MAX := 100.0

const DEFAULT_RECORD := {
	"affinity": 0.0,		# 好感度，負值是討厭
	"met_count": 0,			# 真的互動過幾次（只有 note_meeting() 會加）
}

var records := {}


# ---- 唯讀查詢（不會改變任何狀態）----

# 真的互動過。note_meeting() 是唯一的來源 ——
# 只是被查過好感度不算認識，否則 agent.gd 的「第一次看到陌生人」永遠不會成立
func has_met(other_id: String) -> bool:
	return records.has(other_id) and int(records[other_id]["met_count"]) > 0

# 有沒有這個人的紀錄。has_met() 為假但這裡為真是正常的：
# 見過面但還沒好好講完一場話（例如對話被打斷）就是這個狀態
func has_record(other_id: String) -> bool:
	return records.has(other_id)

# 整筆紀錄的**副本**。回副本不回本體，呼叫端改它不會動到內部狀態 ——
# 想改就得走下面的寫入函式，不會有人不小心把顯示用的程式碼寫成修改
func get_record(other_id: String) -> Dictionary:
	if not records.has(other_id):
		return DEFAULT_RECORD.duplicate(true)
	return (records[other_id] as Dictionary).duplicate(true)

func get_affinity(other_id: String) -> float:
	if not records.has(other_id):
		return float(DEFAULT_RECORD["affinity"])
	return float(records[other_id]["affinity"])

func get_met_count(other_id: String) -> int:
	if not records.has(other_id):
		return 0
	return int(records[other_id]["met_count"])

func known_ids() -> Array:
	return records.keys()


# ---- 寫入 ----

func add_affinity(other_id: String, delta: float) -> float:
	var record := _ensure_record(other_id)
	record["affinity"] = clampf(record["affinity"] + delta, AFFINITY_MIN, AFFINITY_MAX)
	return record["affinity"]

func note_meeting(other_id: String) -> void:
	var record := _ensure_record(other_id)
	record["met_count"] += 1

# 唯一會建立紀錄的地方，所以是私有的。回傳的是本體不是副本
func _ensure_record(other_id: String) -> Dictionary:
	if not records.has(other_id):
		records[other_id] = DEFAULT_RECORD.duplicate(true)
	return records[other_id]
