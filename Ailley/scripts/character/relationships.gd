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

const AFFINITY_MIN := -100.0
const AFFINITY_MAX := 100.0

const DEFAULT_RECORD := {
	"affinity": 0.0,		# 好感度，負值是討厭
	"met_count": 0,			# 互動過幾次
}

var records := {}


func has_met(other_id: String) -> bool:
	return records.has(other_id)

# 沒有紀錄就當場建一筆，呼叫端不用自己判斷有沒有見過
func get_record(other_id: String) -> Dictionary:
	if not records.has(other_id):
		records[other_id] = DEFAULT_RECORD.duplicate(true)
	return records[other_id]

func get_affinity(other_id: String) -> float:
	return get_record(other_id)["affinity"]

func add_affinity(other_id: String, delta: float) -> float:
	var record := get_record(other_id)
	record["affinity"] = clampf(record["affinity"] + delta, AFFINITY_MIN, AFFINITY_MAX)
	return record["affinity"]

func note_meeting(other_id: String) -> void:
	var record := get_record(other_id)
	record["met_count"] += 1

func known_ids() -> Array:
	return records.keys()
