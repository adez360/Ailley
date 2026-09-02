class_name ThinkingIndicator
extends Sprite2D

## 角色頭上的「系統正在等」指示（issue #949 B 類）。兩種情境共用同一個動畫：
##   - AI 正在想（等 LLM 回台詞或回決策）
##   - 對話中輪到玩家，NPC 正在等玩家打字
##
## 這**不是台詞**——以前用 bubble.hold("…")／hold("？") 塞在對話氣泡裡，看起來
## 像角色在說「…」或「？」。改成獨立的動畫圖示，明確跟 say() 出來的話分開。
## 不觸發 speech_heard 廣播（本來就不會，這裡連 bubble 都沒碰）。
##
## 素材 assets/ui/thinking_sprite.png（96×16＝6 幀 16×16），hframes=6。
## 掛在 character.tscn 的 UI 底下，位置由場景給。

const FRAME_SECONDS := 0.12			# 每幀停留時間
## 安全上限：show() 之後最多撐這麼久就自己收掉。對得上 ai_config.gd 的
## provider 逾時天花板——真的等超過這個時間多半是卡住了，留著只會誤導
const MAX_VISIBLE_SECONDS := 12.0

var _frame_elapsed := 0.0
var _hide_at := 0.0


func _ready() -> void:
	visible = false
	set_process(false)


func _process(delta: float) -> void:
	if Time.get_ticks_msec() * 0.001 >= _hide_at:
		hide_indicator()
		return

	_frame_elapsed += delta
	if _frame_elapsed >= FRAME_SECONDS:
		_frame_elapsed = 0.0
		frame = (frame + 1) % hframes


## 開始顯示。max_seconds 到了會自己收掉，但正常情況下 hide_indicator() 會先
## 被呼叫（角色開口說話、對話結束、玩家送出打字…）
func show_indicator(max_seconds: float = MAX_VISIBLE_SECONDS) -> void:
	_hide_at = Time.get_ticks_msec() * 0.001 + max_seconds
	_frame_elapsed = 0.0
	frame = 0
	visible = true
	set_process(true)


func hide_indicator() -> void:
	visible = false
	set_process(false)
