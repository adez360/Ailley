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
## 驗證失敗重試次數上限。出處是 remote_llm_provider.gd::max_validation_retries()
## （《12》§3.4「RemoteLLM 必須實作驗證失敗重試」，上限 2 次，P-22 #3）——那裡
## 是實例方法、不是 const，const 運算式引用不到，只能用具名常數鏡像一份；
## 改動重試次數時兩邊要一起改
const VALIDATION_RETRIES := 2

## 逐次重試之間的排隊／解析／驗證開銷餘裕
const TIMEOUT_MARGIN_SECONDS := 5.0

## 安全上限：show() 之後最多撐這麼久就自己收掉。正常收點是 await 結束的
## hide_indicator()（AI 回了台詞／決策、玩家送出打字）與 exit_conversation()／
## force_interrupt() 的統一收斂——這個上限只是洩漏防護，真的撐超過它才收，
## 代表請求卡死了，留著只會誤導。推導：最壞情況是 provider 逾時後驗證失敗
## 重試——1 次逾時＋VALIDATION_RETRIES 次重試，每次都吃滿 ai_config.gd 的
## DEFAULT_TIMEOUT（#852 已從 10 秒調到 20 秒），再加 TIMEOUT_MARGIN_SECONDS：
## 20 ×（1＋2）＋5 = 65 秒
const MAX_VISIBLE_SECONDS := AIConfig.DEFAULT_TIMEOUT * (1.0 + VALIDATION_RETRIES) + TIMEOUT_MARGIN_SECONDS

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
