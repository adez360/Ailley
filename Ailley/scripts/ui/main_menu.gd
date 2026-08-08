extends Control

## 開場選單：選遊戲模式或讀檔，切去主場景。
## MOD1/MOD2/LOADING 三顆按鈕的 pressed signal 在 MainMenu.tscn 裡已經接到這幾個方法。

const GAME_SCENE_PATH := "res://scenes/main.tscn"

func _on_mod_1_pressed() -> void:
	Global.current_mode = Global.GameMode.PLAYER_VS_AI
	get_tree().change_scene_to_file(GAME_SCENE_PATH)

func _on_mod_2_pressed() -> void:
	Global.current_mode = Global.GameMode.PLAYER_AI_VS_AI
	get_tree().change_scene_to_file(GAME_SCENE_PATH)

func _on_loading_pressed() -> void:
	Global.load_game()
	get_tree().change_scene_to_file(GAME_SCENE_PATH)
