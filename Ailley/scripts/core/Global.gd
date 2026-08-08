extends Node

## 遊戲模式，MainMenu 選的模式存在這裡，其他系統（如 state machine）讀這個做分流。
## 目前 npc/state_machine.gd 那套邏輯已經被 Character 基底取代，這裡先只留 MainMenu 需要的部分。

enum GameMode {
	PLAYER_VS_AI,
	PLAYER_AI_VS_AI,
}

var current_mode: GameMode = GameMode.PLAYER_VS_AI

func load_game() -> void:
	# 存檔邏輯還沒做，先印出來讓 MainMenu 測得到
	print("已載入存檔，當前模式為：", current_mode)

func save_game() -> void:
	pass
