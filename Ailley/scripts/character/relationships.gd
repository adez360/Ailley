class_name Relationships
extends Node

## 這個角色對其他角色的關係。對每個認識的人存一筆紀錄：trust（信任）、
## met_count（真的互動過幾次）、appearance_cache（初次相遇注入一次的外觀描述）。
## 規格《01_角色數值規格書》3-1：關係只留 trust——它是 persuade 成功率修正的
## 唯一引擎消費者。affinity／familiarity／debt 從沒被任何公式讀取過，只被寫入、
## 餵給 AI 看，違反《00》原則三「沒有引擎消費者的欄位不留」，整組移除。
## 「初始觀感」改由 reputation 附形容詞讓 AI 自己判斷，不再由引擎算一個 affinity。
##
## key 用對方的 character_id 而不是 character_name —— name 是玩家可以隨時改的，
## 拿它當 key 會讓改名等於失憶。
##
## 每一筆存成 Dictionary 而不是單一數值，方便繼續擴充：多一個欄位只要在
## DEFAULT_RECORD 多一個 key，既有的 get_trust 呼叫端不用改。
##
## 讀與寫分開，這條是硬規則：**查詢不可以建立紀錄**。
## 曾經查詢走的是「沒有就當場建一筆」的 get_record()，於是 conversation.gd
## 開場問一次，就讓 has_met() 從此為真而 met_count 還是 0 ——「認識」這件事
## 被「問過」給污染掉了。對外的查詢一律唯讀，只有 add_trust() /
## set_appearance_cache() / note_meeting() 這種明確的寫入才走 _ensure_record()。
##
## trust 實際被哪些行動讀寫（persuade 用 trust……）不在這裡接線——那是對應
## 行動各自的 issue，這裡只確保欄位存在、遵守查詢/寫入分離的既有規則。
## 預設值與範圍照《01》3-1 表定死。

const TRUST_MIN := 0.0
const TRUST_MAX := 100.0

## 初次相遇注入一次的他人外觀描述快取上限（《99》P-08：≤20 字）
const APPEARANCE_CACHE_MAX_LEN := 20

const DEFAULT_RECORD := {
	"trust": 20.0,			# 信任，規格 01 3-1 表定預設 20，不是 0——初識不是完全不信任
	"met_count": 0,			# 真的互動過幾次（只有 note_meeting() 會加）
	"appearance_cache": "",	# 初次相遇注入一次的他人外觀描述（≤20 字，《99》P-08）
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

func get_trust(other_id: String) -> float:
	if not records.has(other_id):
		return float(DEFAULT_RECORD["trust"])
	return float(records[other_id]["trust"])

func get_appearance_cache(other_id: String) -> String:
	if not records.has(other_id):
		return str(DEFAULT_RECORD["appearance_cache"])
	return str(records[other_id]["appearance_cache"])

func get_met_count(other_id: String) -> int:
	if not records.has(other_id):
		return 0
	return int(records[other_id]["met_count"])

func known_ids() -> Array:
	return records.keys()


# ---- 寫入 ----

func add_trust(other_id: String, delta: float) -> float:
	var record := _ensure_record(other_id)
	record["trust"] = clampf(record["trust"] + delta, TRUST_MIN, TRUST_MAX)
	return record["trust"]

# 初次相遇注入一次即可，之後不再覆寫（外觀不會每次見面就變）。超過上限直接截斷，
# 而不是拒絕——來源是 AI 產的描述，寧可截短也不要整筆遺失
func set_appearance_cache(other_id: String, text: String) -> void:
	var record := _ensure_record(other_id)
	record["appearance_cache"] = text.left(APPEARANCE_CACHE_MAX_LEN)

func note_meeting(other_id: String) -> void:
	var record := _ensure_record(other_id)
	record["met_count"] += 1

# 唯一會建立紀錄的地方，所以是私有的。回傳的是本體不是副本
func _ensure_record(other_id: String) -> Dictionary:
	if not records.has(other_id):
		records[other_id] = DEFAULT_RECORD.duplicate(true)
	return records[other_id]
