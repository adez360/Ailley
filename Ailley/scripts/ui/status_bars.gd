extends MarginContainer

## 四條狀態列（生命值／飽食度／水分值／體力）。status_panel_expand.tscn（狀態
## 彈窗）跟 character_row.tscn（側欄展開）共用同一份場景，數值綁定寫在這裡，
## 兩邊呼叫 set_character() 就好，不用各自接一套。ProgressBar 預設 min/max
## 剛好是 0/100，跟 Stats.MIN／Stats.MAX 一致，不用另外設。
##
## Stats 沒有 value_changed 訊號（drift／扣點頻率遠高於任何 UI 需要的更新
## 頻率，見 stats.gd），所以逐幀在 _process() 裡主動讀，不是被動等通知。
## 只有 is_visible_in_tree() 時才真的讀值，收合/彈窗關閉時跳過，不白算。
##
## set_character() 只存參照，不碰節點：character_sidebar.gd 會在
## instantiate() 後、add_child() 前就呼叫它（row 還沒進場景樹），這時
## @onready 還是 null，只有 _process()（保證 _ready() 之後才跑）會真的
## 去動 ProgressBar

@onready var _health: ProgressBar = $StatusBars/生命值/ProgressBar
@onready var _satiety: ProgressBar = $StatusBars/飽食度/ProgressBar
@onready var _hydration: ProgressBar = $StatusBars/水分值/ProgressBar
@onready var _stamina: ProgressBar = $StatusBars/體力/ProgressBar

var _character: Character


func _process(_delta: float) -> void:
	if not is_visible_in_tree() or not is_instance_valid(_character):
		return
	_health.value = _character.stats.get_value("health")
	_satiety.value = _character.stats.get_value("satiety")
	_hydration.value = _character.stats.get_value("hydration")
	_stamina.value = _character.stats.get_value("stamina")


func set_character(character: Character) -> void:
	_character = character
