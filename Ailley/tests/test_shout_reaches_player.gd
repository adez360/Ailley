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
## 需要真的 instantiate scenes/player.tscn（而不是像 give/attack 測試那樣
## 手動組一個 Player.new()）：反應會不會冒出來要看 Bubble 子節點，
## 這個節點只有走過 _ready() 才會由 @onready 解析出來。

const PLAYER_SCENE_PATH := "res://scenes/player.tscn"

var _scene_root: Node


func suite_name() -> String:
	return "shout_reaches_player"


func suite_setup(_ctx: Dictionary) -> void:
	_scene_root = EditorInterface.get_edited_scene_root()
	if _scene_root == null:
		skip_suite("沒有開啟任何場景，無法把 player.tscn 掛進場景樹測 _ready() 之後的行為")


func _spawn_player() -> Player:
	var player_scene := load(PLAYER_SCENE_PATH) as PackedScene
	if player_scene == null:
		fail_setup("讀不到 %s" % PLAYER_SCENE_PATH)
		return null
	var player := track(player_scene.instantiate()) as Player
	_scene_root.add_child(player)
	return player


func test_player_shows_alert_bubble_on_noise_heard() -> void:
	var player := _spawn_player()
	if player == null:
		return

	var source := track(Character.new()) as Character
	player.noise_heard.emit(source)

	assert_true(player.bubble.is_speaking(), "聽到聲音後應該顯示反應泡泡")
	assert_eq(player.bubble.label.text, L10n.t("DLG_NOISE_ALERT"), "反應內容應跟 NPC 排程模式的 fallback 一致")


func test_player_suppresses_alert_bubble_during_conversation() -> void:
	var player := _spawn_player()
	if player == null:
		return

	player.enter_conversation(track(Node.new()) as Node)
	var source := track(Character.new()) as Character
	player.noise_heard.emit(source)

	assert_false(player.bubble.is_speaking(), "對話中不該被聽到的聲音打斷、冒出反應泡泡")
