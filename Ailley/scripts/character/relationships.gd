class_name Relationships
extends Node

## 這個角色對其他角色的關係。對每個認識的人只有 met_count（真的互動過幾次）、
## appearance_cache（初次相遇注入過的對方外觀描述，≤20 字）與 last_seen
## （issue #497，上次好好講完一場話當下的 GameClock.day）三個引擎欄位。
##
## 規格《01_角色數值規格書》3-1：好感／熟悉／虧欠／信任(trust) 都不留成引擎
## 欄位——它們從沒被任何公式讀過，只被寫入再餵給 AI 看，不符合《00》原則三
## 「引擎自己有沒有拿它算東西」。`trust` 是最後一個拿掉的：`persuade` 原本
## 被認為是它的消費者，但 issue #177（原則四）已經把 persuade 改成不擲骰、
## 完全交給被說服者自己的模型判斷，從沒真的讀過 trust；PR #489 把僅存的
## 三個固定公式加減（深度對話／被攻擊／被救助）也改成事實句陳述，`trust`
## 徹底變成只寫不讀的死欄位（見《99》P-60）。這四件事全部改交給《03》
## 記憶系統自己記、自己判斷、自己演，不用另一組數值重複做同一件事。
##
## key 用對方的 character_id 而不是 character_name —— name 是玩家可以隨時改的，
## 拿它當 key 會讓改名等於失憶。
##
## 每一筆存成 Dictionary 而不是單一數值，方便繼續擴充：多一個欄位只要在
## DEFAULT_RECORD 多一個 key，既有的呼叫端不用改。
##
## 讀與寫分開，這條是硬規則：**查詢不可以建立紀錄**。
## 曾經查詢走的是「沒有就當場建一筆」的 get_record()，於是
## conversation.gd 開場問一次關係，就讓 has_met() 從此為真而 met_count 還是 0 ——
## 「認識」這件事被「問過」給污染掉了。
## 對外的查詢一律唯讀，只有 set_appearance_cache() / note_meeting()
## 這種明確的寫入才走 _ensure_record()。

## 《99》P-08：外觀快取限 20 字，超過截掉。有上限才不會讓「初次相遇注入一次、
## 之後改帶快取」省下來的 token 被一段長描述反過來吃回去
const APPEARANCE_MAX_CHARS := 20

const DEFAULT_RECORD := {
	"met_count": 0,			# 真的互動過幾次（只有 note_meeting() 會加）
	"appearance_cache": "",	# 初次相遇注入過的對方外觀，之後隨關係一起帶出，不重注
	"last_seen": -1,		# 上次 note_meeting() 當下的 GameClock.day，-1 = 從沒見過（issue #497）
}

var records := {}


# ---- 唯讀查詢（不會改變任何狀態）----

# 真的互動過。note_meeting() 是唯一的來源 ——
# 只是被查過關係不算認識，否則 agent.gd 的「第一次看到陌生人」永遠不會成立
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

func get_met_count(other_id: String) -> int:
	if not records.has(other_id):
		return 0
	return int(records[other_id]["met_count"])

func get_appearance_cache(other_id: String) -> String:
	if not records.has(other_id):
		return String(DEFAULT_RECORD["appearance_cache"])
	return String(records[other_id]["appearance_cache"])

## 上次 note_meeting() 當下的 GameClock.day。-1 = 從沒好好講完一場話——
## 跟 has_met() 同一個判斷依據（met_count > 0），呼叫端要判斷「有沒有
## 上次見面」該查 has_met()，不要拿 -1 當合法天數去算差值
func get_last_seen(other_id: String) -> int:
	if not records.has(other_id):
		return int(DEFAULT_RECORD["last_seen"])
	return int(records[other_id]["last_seen"])

func known_ids() -> Array:
	return records.keys()


# ---- 寫入 ----

# 初次相遇時把對方外觀描述存起來（《99》P-08）。超過上限直接截斷而不是拒收——
# 呼叫端拿到的是 LLM 或資料檔給的字串，長度不保證，截斷至少還留得住前面那幾個字
func set_appearance_cache(other_id: String, text: String) -> void:
	var record := _ensure_record(other_id)
	record["appearance_cache"] = text.substr(0, APPEARANCE_MAX_CHARS)

func note_meeting(other_id: String) -> void:
	var record := _ensure_record(other_id)
	record["met_count"] += 1
	record["last_seen"] = GameClock.day

# 唯一會建立紀錄的地方，所以是私有的。回傳的是本體不是副本
func _ensure_record(other_id: String) -> Dictionary:
	if not records.has(other_id):
		records[other_id] = DEFAULT_RECORD.duplicate(true)
	return records[other_id]


# ---- 存檔 ----

func get_save_data() -> Dictionary:
	return records.duplicate(true)

# 只收 DEFAULT_RECORD 認得的欄位，缺的用預設值補，多的丟掉——舊存檔裡還留著
# 已經拿掉的 affinity／familiarity／debt，整包 merge 進來的話那三個欄位會在
# 跑過舊檔的存檔裡復活，「欄位已經移除」就只在新開的遊戲成立。
# 直接寫進 records 本體，不經 _ensure_record()——這裡在還原存檔，不是查詢，
# 「查詢不可以建立紀錄」那條規則管的是別的事
func load_save_data(data: Dictionary) -> void:
	records.clear()
	for other_id in data:
		# 壞掉的存檔可能把某筆值存成非 Dictionary——records 已經 clear() 過，
		# 這裡直接當 Dictionary 用會是執行期型別錯誤，中斷整個迴圈，讓後面
		# 沒處理到的紀錄全部遺失。單筆型別不對就跳過那一筆，不影響其他筆
		if not data[other_id] is Dictionary:
			push_error("Relationships: %s 的紀錄不是 Dictionary，跳過" % other_id)
			continue
		var saved: Dictionary = data[other_id]
		var record: Dictionary = DEFAULT_RECORD.duplicate(true)
		# 逐欄驗證型別，不是 has(key) 就直接收——壞掉的存檔可能把 met_count 存成
		# []，直接指定會在 note_meeting() 做算術時才炸（跟 character.gd::
		# load_save_data() 同一套規則）。型別不對就沿用 DEFAULT_RECORD 的
		# 預設值，不是跳過整筆——其他欄位仍然有效。舊存檔可能還留著已經拿掉的
		# trust 欄位，DEFAULT_RECORD 已經沒有這個 key，get()/duplicate() 自然
		# 不會把它復活，不用另外過濾
		var saved_met_count: Variant = saved.get("met_count")
		if saved_met_count is int:
			record["met_count"] = maxi(0, saved_met_count)
		var saved_appearance: Variant = saved.get("appearance_cache")
		if saved_appearance is String:
			record["appearance_cache"] = saved_appearance
		# 存檔繞過 set_appearance_cache()，20 字上限要在這裡再夾一次，
		# 否則手改過的存檔可以把任意長度的描述帶進 payload
		record["appearance_cache"] = String(record["appearance_cache"]).substr(0, APPEARANCE_MAX_CHARS)
		# 缺席（舊存檔沒有這個欄位）沿用 DEFAULT_RECORD 的 -1，跟其餘欄位
		# 「型別不對就沿用預設值」同一套規則——-1 本身就是合法的「從沒見過」
		var saved_last_seen: Variant = saved.get("last_seen")
		if saved_last_seen is int:
			record["last_seen"] = maxi(-1, saved_last_seen)
		records[other_id] = record
