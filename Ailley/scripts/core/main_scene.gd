extends Node

## main.tscn 根節點腳本。issue #343：開場讀檔的實際套用時機。
##
## GameManager.continue_requested 由主選單「繼續遊戲」按鈕設定，這裡是唯一
## 讀取並清除它的地方。子節點（Player/Agent 等）的 _ready() 在這個節點的
## _ready() 之前就跑完（Godot 由下而上呼叫 _ready），所以這裡執行時
## get_tree().get_nodes_in_group("characters") 已經拿得到場上全部角色。
##
## 套用邏輯直接對齊 debug_console.gd 的 _cmd_load()（#21 驗證過的讀檔進出點），
## 差別是這裡額外用 SaveService.has_world()/has_character() 分辨「本來就沒有
## 存檔」（正常新角色，不是錯誤）跟「存過但讀不出來」（存檔損毀，要 push_error
## 讓人看得到，不能悄悄退回預設值卻不留痕跡）。


func _ready() -> void:
	if not GameManager.continue_requested:
		return
	GameManager.continue_requested = false
	_apply_continue()


func _apply_continue() -> void:
	if not SaveService.has_world(GameManager.DEFAULT_WORLD_ID):
		push_error("main_scene: continue_requested 但世界存檔 %s 不存在，維持新遊戲狀態" % GameManager.DEFAULT_WORLD_ID)
		return

	var world_data := SaveService.get_world(GameManager.DEFAULT_WORLD_ID)
	if world_data.is_empty():
		push_error("main_scene: 世界存檔 %s 讀取失敗（存在但無法解析，可能已損毀），維持新遊戲狀態" % GameManager.DEFAULT_WORLD_ID)
		return
	GameManager.apply_world_save_data(world_data)

	for node in get_tree().get_nodes_in_group("characters"):
		var character := node as Character
		if not SaveService.has_character(character.character_id):
			continue # 這個角色本身還沒存過（例如存檔當時場上沒有它），不是錯誤

		var data := SaveService.get_character(character.character_id)
		if data.is_empty():
			push_error("main_scene: 角色存檔 %s（%s）讀取失敗（存在但無法解析，可能已損毀），該角色維持預設狀態" % [character.character_id, character.character_name])
			continue

		character.load_save_data(data)
