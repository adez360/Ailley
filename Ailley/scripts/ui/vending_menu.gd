class_name VendingMenu
extends CanvasLayer

## 販賣機商品選單。E 鍵在販賣機旁開啟（見 player.gd 的候選偵測），
## 點一項商品就呼叫 buyer.buy_from(machine, item_id)——真正的購買邏輯在
## character.gd，這裡只負責「選哪一項」的介面，跟 InventoryPanel 對 27 格
## 主背包的分工是同一種：UI 不碰資料，只轉發使用者的選擇。
##
## 沒有數字鍵快捷選——`hotbar.gd` 的 hotbar_1-9 也在監聽同一批數字鍵，
## 兩邊都用 _unhandled_input 搶同一個按鍵，誰先誰後不保證，容易「買東西
## 的同時把快捷欄也選到同一格」。純滑鼠點擊，商品數量目前也就 4 個，
## 不差這個快捷鍵。
##
## 開關的職責切法：player.gd 負責「開」（先確認附近有機器才呼叫 open()），
## 這裡自己負責「關」（E 再按一次或 Esc）——跟 InventoryPanel 用 Tab 開關
## 不同，販賣機沒有一個固定的「開關鍵」，是 E 鍵在情境判斷之後才決定要不要開，
## player.gd 那條 _unhandled_input 因此在選單開著時直接跳過、不搶這個 E。

@onready var panel: Panel = $Panel
@onready var title_label: Label = $Panel/VBox/TitleLabel
@onready var item_list: VBoxContainer = $Panel/VBox/ItemList
@onready var hint_label: Label = $Panel/VBox/HintLabel

var _machine: VendingMachine = null
var _buyer: Character = null


func _ready() -> void:
	add_to_group("vending_menu")
	panel.hide()
	set_process(false)		# 只在選單開著時才需要量距離
	title_label.text = L10n.t("UI_VENDING_TITLE")
	hint_label.text = L10n.t("UI_VENDING_CLOSE_HINT")

# 走出 BUY_RANGE 就自己關掉。選單擋不住移動（方向鍵照樣走），沒有這段的話
# 玩家可以邊開著選單邊走到地圖另一頭，價格照顯示、每次點都回 BUY_TOO_FAR
# 而且只有 push_warning 看不到，同時 player.gd 又因為「選單開著」放掉 E，
# 等於整個卡住。跟對話走遠自然散場是同一種收法
func _process(_delta: float) -> void:
	if not is_instance_valid(_machine) or not is_instance_valid(_buyer) \
			or _buyer.get_body_position().distance_to(_machine.global_position) > Character.BUY_RANGE:
		close()

func is_open() -> bool:
	return panel.visible

func _unhandled_input(event: InputEvent) -> void:
	if not panel.visible:
		return

	if event.is_action_pressed("interact") or event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()

func open(machine: VendingMachine, buyer: Character) -> void:
	_machine = machine
	_buyer = buyer

	# 先 remove_child() 再 queue_free()：queue_free() 是幀末才真的刪，光是
	# queue_free() 的話重開選單的那一幀 item_list 同時掛著 4 個舊按鈕與 4 個
	# 新按鈕，VBox 排 8 列會撐破固定 130×134 的面板
	for child in item_list.get_children():
		item_list.remove_child(child)
		child.queue_free()

	for item_id in machine.list_items():
		var button := Button.new()
		button.text = "%s　%d" % [item_id, machine.get_price(item_id)]
		button.focus_mode = Control.FOCUS_NONE		# 理由跟 hotbar.gd 的格子按鈕同一段註解
		button.pressed.connect(_buy.bind(item_id))
		item_list.add_child(button)

	panel.show()
	set_process(true)

func close() -> void:
	panel.hide()
	set_process(false)
	_machine = null
	_buyer = null

func _buy(item_id: String) -> void:
	if _machine == null or _buyer == null:
		return

	var reason := _buyer.buy_from(_machine, item_id)
	if reason != Character.BUY_OK:
		_buyer.report_action_failure("buy_from", reason)
