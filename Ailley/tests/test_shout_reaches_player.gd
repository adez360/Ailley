@tool
class_name TestShoutReachesPlayer
extends McpTestSuite

## 驗證 shout／make_noise() 範圍內的玩家會收到廣播效果（issue #376）。
## 拍板結果：玩家跟 NPC 排程模式的 fallback 走同一條路——冒 !?，
## 見 player.gd::_on_noise_heard()。
##
## make_noise() 本身怎麼把 noise_heard 廣播給範圍內每個角色是既有、沒改動
## 的機制（見 note/技術/聽覺感測.md），這裡不重測那段——直接對 noise_heard
## 訊號 emit()，只驗證這次新接上的 player.gd 反應邏輯本身。
##
## 跟 give/attack 測試一樣手動組 Player.new()，不 instantiate scenes/player.tscn
## ——test_run 跑在編輯器 @tool 環境，PackedScene.instantiate() 對非 @tool 腳本
## 一律回傳 placeholder instance，跟開哪個場景、掛不掛進場景樹無關，
## instantiate() 那一刻就已經是 placeholder（見 note/技術/自動化測試.md，issue #624）。
## bubble／noise_heard 訊號連線是原本靠 player.tscn 走過 _ready() 才會有的東西，
## 這裡手動補齊卡位，換取能在 test_run 裡測到反應邏輯本身。

const BUBBLE_SCRIPT_PATH := "res://scripts/ui/bubble.gd"


func suite_name() -> String:
	return "shout_reaches_player"


## bubble 是 Node2D 手動組（沒有 class_name，見 bubble.gd），box／label 兩個
## @onready 子節點也手動塞值卡位——跟 bubble 本身同一個理由，都是靠 player.tscn
## 場景樹的 _ready() 才會解析出來的東西，這裡繞過去。visible 也要手動蓋成 false：
## CanvasItem 預設是 true，Bubble._ready() 平常會蓋成 false，這裡沒走 _ready()
## 的話 say() 的「還沒顯示才要 _show_next()」判斷一開始就會誤判成「已經在顯示」，
## 訊息只進佇列、永遠不會真的被渲染出來
func _make_bubble() -> Node2D:
	var bubble_script := load(BUBBLE_SCRIPT_PATH) as GDScript
	var bubble := track(bubble_script.new()) as Node2D
	bubble.box = track(NinePatchRect.new())
	bubble.label = track(Label.new())
	bubble.visible = false
	return bubble


## noise_heard.connect(_on_noise_heard) 原本是 player.gd::_ready() 做的事，
## 這裡手動補上，讓測試能維持「對 noise_heard emit() 訊號」的呼叫方式，
## 而不是直接呼叫 _on_noise_heard()——盡量貼近原本的驗證意圖
func _make_player() -> Player:
	var player := track(Player.new()) as Player
	player.bubble = _make_bubble()
	player.noise_heard.connect(player._on_noise_heard)
	return player


func test_player_shows_alert_bubble_on_noise_heard() -> void:
	var player := _make_player()

	var source := track(Character.new()) as Character
	player.noise_heard.emit(source)

	assert_true(player.bubble.is_speaking(), "聽到聲音後應該顯示反應泡泡")
	assert_eq(player.bubble.label.text, "!?", "反應內容應跟 NPC 排程模式的 fallback 一致")


func test_player_suppresses_alert_bubble_during_conversation() -> void:
	var player := _make_player()

	player.enter_conversation(track(Node.new()) as Node)
	var source := track(Character.new()) as Character
	player.noise_heard.emit(source)

	assert_false(player.bubble.is_speaking(), "對話中不該被聽到的聲音打斷、冒出反應泡泡")
