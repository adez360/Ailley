class_name Relationships
extends Node

## 這個角色對其他角色的關係。對每個認識的人各有一組 4 維數值——
## affinity（好感）／trust（信任）／familiarity（熟悉）／debt（虧欠），
## 外加 met_count（真的互動過幾次）。規格《01_角色數值規格書》3-1：單一好感度
## 做不出「我討厭他，但我信任他的專業」這種區分，所以拆成四維而不是一個綜合分數。
##
## key 用對方的 character_id 而不是 character_name —— name 是玩家可以隨時改的，
## 拿它當 key 會讓改名等於失憶。
##
## 每一筆存成 Dictionary 而不是單一數值，方便繼續擴充：多一維只要在
## DEFAULT_RECORD 多一個 key，既有的 get_affinity / add_affinity 呼叫端不用改。
##
## 讀與寫分開，這條是硬規則：**查詢不可以建立紀錄**。
## 曾經 get_affinity() 走的是「沒有就當場建一筆」的 get_record()，於是
## conversation.gd 開場問一次好感度，就讓 has_met() 從此為真而 met_count 還是 0 ——
## 「認識」這件事被「問過」給污染掉了。
## 對外的查詢一律唯讀，只有 add_affinity() / add_trust() / add_familiarity() /
## add_debt() / note_meeting() 這種明確的寫入才走 _ensure_record()。
##
## trust／familiarity／debt 實際被哪些行動讀寫（persuade 用 trust、give 影響
## debt……）不在這裡接線——那是對應行動各自的 issue，這裡只確保欄位存在、
## 遵守查詢/寫入分離的既有規則。三者的預設值與範圍照《01》3-1 表定死。

const AFFINITY_MIN := -100.0
const AFFINITY_MAX := 100.0

const TRUST_MIN := 0.0
const TRUST_MAX := 100.0

const FAMILIARITY_MIN := 0.0
const FAMILIARITY_MAX := 100.0

const DEBT_MIN := -100.0
const DEBT_MAX := 100.0

const DEFAULT_RECORD := {
	"affinity": 0.0,		# 好感度，負值是討厭
	"trust": 20.0,			# 信任，規格 01 3-1 表定預設 20，不是 0——初識不是完全不信任
	"familiarity": 0.0,		# 熟悉，只升不降（緩慢衰減留給之後接線的 issue）
	"debt": 0.0,			# 虧欠，正 = 我欠他，負 = 他欠我
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

func get_trust(other_id: String) -> float:
	if not records.has(other_id):
		return float(DEFAULT_RECORD["trust"])
	return float(records[other_id]["trust"])

func get_familiarity(other_id: String) -> float:
	if not records.has(other_id):
		return float(DEFAULT_RECORD["familiarity"])
	return float(records[other_id]["familiarity"])

func get_debt(other_id: String) -> float:
	if not records.has(other_id):
		return float(DEFAULT_RECORD["debt"])
	return float(records[other_id]["debt"])

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

func add_trust(other_id: String, delta: float) -> float:
	var record := _ensure_record(other_id)
	record["trust"] = clampf(record["trust"] + delta, TRUST_MIN, TRUST_MAX)
	return record["trust"]

func add_familiarity(other_id: String, delta: float) -> float:
	var record := _ensure_record(other_id)
	record["familiarity"] = clampf(record["familiarity"] + delta, FAMILIARITY_MIN, FAMILIARITY_MAX)
	return record["familiarity"]

func add_debt(other_id: String, delta: float) -> float:
	var record := _ensure_record(other_id)
	record["debt"] = clampf(record["debt"] + delta, DEBT_MIN, DEBT_MAX)
	return record["debt"]

func note_meeting(other_id: String) -> void:
	var record := _ensure_record(other_id)
	record["met_count"] += 1

# 唯一會建立紀錄的地方，所以是私有的。回傳的是本體不是副本
func _ensure_record(other_id: String) -> Dictionary:
	if not records.has(other_id):
		records[other_id] = DEFAULT_RECORD.duplicate(true)
	return records[other_id]
