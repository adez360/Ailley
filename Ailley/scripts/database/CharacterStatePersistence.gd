extends Node


## =====================================================
## CharacterStatePersistence
##
## 將目前遊戲中的 Player + NPC
## 統一同步到 SQLite：
##
##   npc
##   npc_state
##   npc_inventory
##   npc_wallet
##
## Inventory 同步策略：
##
##   1. 第一次遇到 Character 時：
##      嘗試從 SQLite 載入 inventory。
##
##   2. SQLite 沒有 inventory：
##      保留 runtime 初始 inventory。
##
##   3. Inventory.changed 發生：
##      不在 signal callback 裡直接寫 SQLite。
##
##      改成：
##
##          Inventory.changed
##                ↓
##          標記待同步
##                ↓
##          call_deferred()
##                ↓
##          _flush_pending_inventory_sync()
##                ↓
##          _save_inventory()
##
##      這樣可以避免在 Inventory.add_item()
##      尚未完整結束時直接進 Persistence。
##
##   4. 每個 Character 只連接自己的 Inventory 一次。
##
##   5. 如果同一 character_id 換了新的 Inventory instance，
##      會先斷開舊 instance，再連接新的 instance。
##
##   6. 同步 inventory 時：
##      先 SELECT 舊資料。
##      有舊資料才 DELETE。
##      再寫入目前 runtime snapshot。
##
##   7. 「DELETE 0 筆」視為正常狀態。
##
## Wallet 同步策略跟 Inventory 的第 1、2 點一樣（第一次遇到 Character 時
## 從 npc_wallet 載入、沒有既有資料就沿用 runtime 初始值），但用自己一組
## _wallet_loaded／_wallet_loading guard，不搭 Inventory.changed 訊號——
## money 異動走 add_money()／spend()，不像 slots 有專門的「覆寫整包」入口，
## 沒有對應的訊號可以掛；wallet 的持續同步交給既有的定期 state 同步
## （_sync_all_characters_periodic()）覆蓋寫入。
##
## =====================================================


const STATE_TABLE := "npc_state"
const NPC_TABLE := "npc"
const INVENTORY_TABLE := "npc_inventory"
const WALLET_TABLE := "npc_wallet"


## -----------------------------------------------------
## Inventory connection / loading state
## -----------------------------------------------------

# npc_id -> {
#     "inventory_id": int,
#     "inventory": Inventory,
#     "callback": Callable
# }
var _inventory_connected: Dictionary = {}

# npc_id -> true
var _inventory_loaded: Dictionary = {}

# npc_id -> true
#
# 避免 LOAD 過程中的 changed signal
# 觸發 SAVE。
var _inventory_loading: Dictionary = {}

# npc_id -> Character
#
# Inventory.changed 發生後先放在這裡，
# 下一個 deferred frame 再真正寫 SQLite。
var _inventory_sync_pending: Dictionary = {}

# 是否已經排程 _flush_pending_inventory_sync()
var _inventory_sync_deferred := false


## -----------------------------------------------------
## Wallet loading state
## -----------------------------------------------------

# npc_id -> true
#
# 跟 _inventory_loaded 分開追蹤：wallet 是獨立的表，
# 不能沿用 inventory 那組 guard，否則其中一個先讀完
# 會讓另一個誤判成「已經載入過」而跳過。
var _wallet_loaded: Dictionary = {}

# npc_id -> true
var _wallet_loading: Dictionary = {}


# =====================================================
# Lifecycle
# =====================================================

func _ready() -> void:
	call_deferred("_sync_all_characters")
	call_deferred("_rebuild_dynamic_homes")

	if GameClock != null:
		if not GameClock.time_changed.is_connected(
			_on_time_changed
		):
			GameClock.time_changed.connect(
				_on_time_changed
			)


func _on_time_changed(
	_hour: int,
	_minute: int
) -> void:

	_sync_all_characters_periodic()


# =====================================================
# Global Sync
# =====================================================

func _sync_all_characters() -> bool:

	if not DatabaseManager.is_ready:
		return false

	var characters := get_tree().get_nodes_in_group(
		"characters"
	)

	if characters.is_empty():
		return true

	var success_count := 0
	# "characters" group 目前只會有 Character 節點（Character._ready() 自己
	# add_to_group()），as Character 轉型失敗理論上不會發生，但這裡的分母要用
	# 實際處理過的數量，不是 characters.size()——否則萬一哪天真的混進非
	# Character 節點，每一隻 Character 都同步成功，還是會回報假失敗
	var processed_count := 0

	for node in characters:

		var character := node as Character

		if character == null:
			continue

		processed_count += 1

		if _save_character(character):
			success_count += 1

	print(
		"[CharacterStatePersistence] 同步完成：%d / %d"
		% [
			success_count,
			processed_count
		]
	)

	return success_count == processed_count


func _sync_all_characters_periodic() -> void:

	if not DatabaseManager.is_ready:
		return

	var characters := get_tree().get_nodes_in_group(
		"characters"
	)

	if characters.is_empty():
		return

	for node in characters:

		var character := node as Character

		if character == null:
			continue

		_save_character_state_only(character)


func _save_character_state_only(
	character: Character
) -> bool:

	if character == null:
		push_error(
			"[CharacterStatePersistence] "
			+ "Character 或 Stats 不存在。"
		)
		return false

	if character.stats == null:
		push_error(
			"[CharacterStatePersistence] "
			+ "%s Stats 不存在。"
			% character.name
		)
		return false

	if character.character_id.is_empty():

		push_warning(
			"[CharacterStatePersistence] "
			+ "%s 沒有 character_id。"
			% character.name
		)

		return false

	var character_id := character.character_id


	# -------------------------------------------------
	# NPC record
	# -------------------------------------------------

	if not _ensure_npc_record(character):

		push_error(
			"[CharacterStatePersistence] "
			+ "%s 同步失敗：npc record 無法建立。"
			% character_id
		)

		return false


	# -------------------------------------------------
	# State
	# -------------------------------------------------

	var state_data := {
		"npc_id": character_id,

		"satiety": _stat(
			character,
			"satiety",
			100.0
		),

		"hydration": _stat(
			character,
			"hydration",
			80.0
		),

		"stamina": _stat(
			character,
			"stamina",
			80.0
		),

		"wakefulness": _stat(
			character,
			"wakefulness",
			90.0
		),

		"hygiene": _stat(
			character,
			"hygiene",
			70.0
		),

		"alcohol": _stat(
			character,
			"alcohol",
			0.0
		),

		"health": _stat(
			character,
			"health",
			100.0
		),

		"injury": _stat(
			character,
			"injury",
			0.0
		)
	}


	for key in state_data:

		if key == "npc_id":
			continue

		state_data[key] = clampf(
			float(state_data[key]),
			0.0,
			100.0
		)


	var existing := DatabaseManager.select_where(
		STATE_TABLE,
		"npc_id = ?",
		[
			character_id
		],
		[
			"npc_id"
		]
	)


	var state_ok := false


	if existing.is_empty():

		state_ok = DatabaseManager.insert(
			STATE_TABLE,
			state_data
		)

		if not state_ok:

			push_error(
				"[CharacterStatePersistence] "
				+ "npc_state INSERT 失敗：%s | DB=%s"
				% [
					character_id,
					DatabaseManager.db.error_message
				]
			)

	else:

		state_ok = DatabaseManager.update(
			STATE_TABLE,
			state_data,
			"npc_id = '%s'"
			% DatabaseManager.escape_sql_string(character_id)
		)

		if not state_ok:

			push_error(
				"[CharacterStatePersistence] "
				+ "npc_state UPDATE 失敗：%s | DB=%s"
				% [
					character_id,
					DatabaseManager.db.error_message
				]
			)


	if not state_ok:

		push_error(
			"[CharacterStatePersistence] "
			+ "%s STATE = FAIL"
			% character_id
		)

		return false


	# -------------------------------------------------
	# Wallet
	# -------------------------------------------------

	var wallet_ok := _save_wallet(
		character
	)

	if not wallet_ok:

		push_error(
			"[CharacterStatePersistence] "
			+ "%s WALLET = FAIL"
			% character_id
		)


	return (
		state_ok
		and wallet_ok
	)


# =====================================================
# Character
# =====================================================

func _save_character(
	character: Character
) -> bool:

	if character == null:
		push_error(
			"[CharacterStatePersistence] "
			+ "Character 或 Stats 不存在。"
		)
		return false

	if character.stats == null:
		push_error(
			"[CharacterStatePersistence] "
			+ "%s Stats 不存在。"
			% character.name
		)
		return false

	if character.character_id.is_empty():

		push_warning(
			"[CharacterStatePersistence] "
			+ "%s 沒有 character_id。"
			% character.name
		)

		return false

	var character_id := character.character_id


	# -------------------------------------------------
	# NPC record
	# -------------------------------------------------

	if not _ensure_npc_record(character):

		push_error(
			"[CharacterStatePersistence] "
			+ "%s 同步失敗：npc record 無法建立。"
			% character_id
		)

		return false


	# -------------------------------------------------
	# 第一次遇到 Character：
	# 嘗試載入 DB inventory 與 wallet。
	#
	# 順序要在下面組 state_data／呼叫 _save_wallet() 之前——
	# _save_wallet() 讀的是 character.inventory.get_money()，載入沒先做完
	# 就存，存進去的會是 runtime 的初始值（DEFAULT_MONEY），把 DB 裡原本
	# 累積的金額覆蓋掉，跟這個載入沒做時 inventory 會被清空是同一種問題。
	# -------------------------------------------------

	_load_inventory_once(character)
	_load_wallet_once(character)


	# -------------------------------------------------
	# State
	# -------------------------------------------------

	var state_data := {
		"npc_id": character_id,

		"satiety": _stat(
			character,
			"satiety",
			100.0
		),

		"hydration": _stat(
			character,
			"hydration",
			80.0
		),

		"stamina": _stat(
			character,
			"stamina",
			80.0
		),

		"wakefulness": _stat(
			character,
			"wakefulness",
			90.0
		),

		"hygiene": _stat(
			character,
			"hygiene",
			70.0
		),

		"alcohol": _stat(
			character,
			"alcohol",
			0.0
		),

		"health": _stat(
			character,
			"health",
			100.0
		),

		"injury": _stat(
			character,
			"injury",
			0.0
		)
	}


	for key in state_data:

		if key == "npc_id":
			continue

		state_data[key] = clampf(
			float(state_data[key]),
			0.0,
			100.0
		)


	var existing := DatabaseManager.select_where(
		STATE_TABLE,
		"npc_id = ?",
		[
			character_id
		],
		[
			"npc_id"
		]
	)


	var state_ok := false


	if existing.is_empty():

		state_ok = DatabaseManager.insert(
			STATE_TABLE,
			state_data
		)

		if not state_ok:

			push_error(
				"[CharacterStatePersistence] "
				+ "npc_state INSERT 失敗：%s | DB=%s"
				% [
					character_id,
					DatabaseManager.db.error_message
				]
			)

	else:

		state_ok = DatabaseManager.update(
			STATE_TABLE,
			state_data,
			"npc_id = '%s'"
			% DatabaseManager.escape_sql_string(character_id)
		)

		if not state_ok:

			push_error(
				"[CharacterStatePersistence] "
				+ "npc_state UPDATE 失敗：%s | DB=%s"
				% [
					character_id,
					DatabaseManager.db.error_message
				]
			)


	if not state_ok:

		push_error(
			"[CharacterStatePersistence] "
			+ "%s STATE = FAIL"
			% character_id
		)

		return false


	print(
		"[CharacterStatePersistence] "
		+ "%s STATE = PASS"
		% character_id
	)


	# -------------------------------------------------
	# Inventory
	# -------------------------------------------------

	var inventory_ok := _save_inventory(
		character
	)

	if inventory_ok:

		print(
			"[CharacterStatePersistence] "
			+ "%s INVENTORY = PASS"
			% character_id
		)

	else:

		push_error(
			"[CharacterStatePersistence] "
			+ "%s INVENTORY = FAIL"
			% character_id
		)


	# -------------------------------------------------
	# Wallet
	# -------------------------------------------------

	var wallet_ok := _save_wallet(
		character
	)

	if wallet_ok:

		print(
			"[CharacterStatePersistence] "
			+ "%s WALLET = PASS"
			% character_id
		)

	else:

		push_error(
			"[CharacterStatePersistence] "
			+ "%s WALLET = FAIL"
			% character_id
		)


	return (
		state_ok
		and inventory_ok
		and wallet_ok
	)


# =====================================================
# Inventory Load
# =====================================================

func _load_inventory_once(
	character: Character
) -> void:

	if character == null:
		return

	if character.inventory == null:

		print(
			"[CharacterStatePersistence] "
			+ "Inventory 不存在：%s"
			% character.character_id
		)

		return


	var npc_id := character.character_id

	if npc_id.is_empty():
		return


	# 已經正在 LOAD。
	if _inventory_loading.has(npc_id):
		return


	# 已經完成 LOAD。
	if _inventory_loaded.has(npc_id):
		return


	_inventory_loading[npc_id] = true


	var rows := DatabaseManager.select_where(
		INVENTORY_TABLE,
		"npc_id = ?",
		[
			npc_id
		],
		[
			"slot",
			"item_id",
			"count",
			"decay",
			"durability"
		]
	)


	if rows.is_empty():

		print(
			"[CharacterStatePersistence] "
			+ "Inventory 無既有 DB 資料：%s"
			% npc_id
		)

		_inventory_loaded[npc_id] = true

		_inventory_loading.erase(
			npc_id
		)

		_connect_inventory_changed(
			character
		)

		return


	# -------------------------------------------------
	# 有 DB 資料：
	# 用 DB snapshot 覆蓋 runtime。
	# -------------------------------------------------

	character.inventory.slots.resize(
		Inventory.SIZE
	)


	for i in Inventory.SIZE:
		character.inventory.slots[i] = {}


	for row in rows:

		var slot := int(
			row.get(
				"slot",
				-1
			)
		)

		if slot < 0 or slot >= Inventory.SIZE:

			push_error(
				"[CharacterStatePersistence] "
				+ "忽略無效 inventory slot：%d | npc=%s"
				% [
					slot,
					npc_id
				]
			)

			continue


		var item_id := str(
			row.get(
				"item_id",
				""
			)
		)


		if item_id.is_empty():

			push_error(
				"[CharacterStatePersistence] "
				+ "忽略空 item_id | slot=%d | npc=%s"
				% [
					slot,
					npc_id
				]
			)

			continue


		var count := clampi(
			int(
				row.get(
					"count",
					0
				)
			),
			0,
			Inventory.MAX_STACK
		)


		if count <= 0:
			continue


		var decay := maxi(
			0,
			int(
				row.get(
					"decay",
					0
				)
			)
		)


		var durability := clampi(
			int(
				row.get(
					"durability",
					0
				)
			),
			0,
			100
		)


		character.inventory.slots[slot] = {
			"item_id": item_id,
			"count": count,
			"decay": decay,
			"durability": durability
		}


	print(
		"[CharacterStatePersistence] "
		+ "Inventory LOAD %s：%d slot"
		% [
			npc_id,
			rows.size()
		]
	)


	_inventory_loaded[npc_id] = true

	_inventory_loading.erase(
		npc_id
	)


	character.inventory.notify_changed()


	_connect_inventory_changed(
		character
	)


# =====================================================
# Wallet Load
# =====================================================

func _load_wallet_once(
	character: Character
) -> void:

	if character == null:
		return

	if character.inventory == null:
		return


	var npc_id := character.character_id

	if npc_id.is_empty():
		return


	# 已經正在 LOAD。
	if _wallet_loading.has(npc_id):
		return


	# 已經完成 LOAD。
	if _wallet_loaded.has(npc_id):
		return


	_wallet_loading[npc_id] = true


	var rows := DatabaseManager.select_where(
		WALLET_TABLE,
		"npc_id = ?",
		[
			npc_id
		],
		[
			"money"
		]
	)


	if rows.is_empty():

		print(
			"[CharacterStatePersistence] "
			+ "Wallet 無既有 DB 資料，沿用 runtime 初始值：%s"
			% npc_id
		)

		_wallet_loaded[npc_id] = true

		_wallet_loading.erase(
			npc_id
		)

		return


	# -------------------------------------------------
	# 有 DB 資料：
	# 用 DB snapshot 覆蓋 runtime。
	# -------------------------------------------------

	var money := int(
		rows[0].get(
			"money",
			character.inventory.get_money()
		)
	)

	character.inventory.set_money(money)

	print(
		"[CharacterStatePersistence] "
		+ "Wallet LOAD %s：money=%d"
		% [
			npc_id,
			money
		]
	)

	_wallet_loaded[npc_id] = true

	_wallet_loading.erase(
		npc_id
	)

	character.inventory.notify_changed()


# =====================================================
# Inventory Signal Connection
# =====================================================

func _connect_inventory_changed(
	character: Character
) -> void:

	if character == null:
		return

	if character.inventory == null:
		return


	var npc_id := character.character_id

	if npc_id.is_empty():
		return


	var inventory := character.inventory

	var inventory_id := inventory.get_instance_id()


	# -------------------------------------------------
	# 已經連到相同 Inventory instance。
	# -------------------------------------------------

	if _inventory_connected.has(npc_id):

		var old_data: Dictionary = (
			_inventory_connected[npc_id]
		)

		var old_inventory_id := int(
			old_data.get(
				"inventory_id",
				-1
			)
		)

		if old_inventory_id == inventory_id:
			return


		# -------------------------------------------------
		# 同 character_id 但 Inventory instance 已經換掉。
		# 先斷舊連線。
		# -------------------------------------------------

		_disconnect_inventory_changed(
			npc_id
		)


	var callback := Callable(
		self,
		"_on_inventory_changed"
	).bind(character)


	if not inventory.changed.is_connected(
		callback
	):

		inventory.changed.connect(
			callback
		)


	_inventory_connected[npc_id] = {
		"inventory_id": inventory_id,
		"inventory": inventory,
		"callback": callback
	}


	var exit_callback := Callable(
		self,
		"_on_character_tree_exited"
	).bind(npc_id)

	if not character.tree_exited.is_connected(
		exit_callback
	):

		character.tree_exited.connect(
			exit_callback
		)


	print(
		"[CharacterStatePersistence] "
		+ "Inventory.changed 已連線：%s | instance=%d"
		% [
			npc_id,
			inventory_id
		]
	)


# =====================================================
# Character Removed：清理追蹤字典
#
# 角色節點釋放後，_inventory_connected 裡的 inventory
# 參照會變成失效 instance；_inventory_loaded／_loading
# 也會殘留無用的 npc_id 項目。統一在這裡清掉。
#
# 注意：不清 _inventory_sync_pending。tree_exited 觸發時
# 節點通常還沒真的被釋放（queue_free 要等到下一個 idle
# frame），這裡若有還沒 flush 的 inventory 異動，直接清掉
# 會讓最後一次改動遺失存檔；_flush_pending_inventory_sync()
# 本來就會用 is_instance_valid() 檢查，node 真的釋放後自然
# 跳過，不需要在這裡搶先清。
# =====================================================

func _on_character_tree_exited(
	npc_id: String
) -> void:

	_disconnect_inventory_changed(
		npc_id
	)

	_inventory_loaded.erase(
		npc_id
	)

	_inventory_loading.erase(
		npc_id
	)

	# wallet 跟 inventory 用同一個 npc_id 生命週期：這個節點離開場景樹之後，
	# 同 id 的角色若重新進場（例如換身），要重新從 npc_wallet 讀一次，
	# 不能沿用舊節點留下的「已載入過」標記
	_wallet_loaded.erase(
		npc_id
	)

	_wallet_loading.erase(
		npc_id
	)

	# issue #751：角色節點真的離開世界時，若牠住的是動態成長出來的家，
	# 拆除對應的場景表現。跟上面幾行同一個「節點離場即清理」的觸發點
	_release_home_if_dynamic(
		npc_id
	)


# =====================================================
# Inventory Signal Disconnect
# =====================================================

func _disconnect_inventory_changed(
	npc_id: String
) -> void:

	if not _inventory_connected.has(
		npc_id
	):
		return


	var data: Dictionary = (
		_inventory_connected[npc_id]
	)


	var inventory = data.get(
		"inventory",
		null
	)

	var callback = data.get(
		"callback",
		Callable()
	)


	if inventory != null:

		if is_instance_valid(
			inventory
		):

			if callback is Callable:

				if inventory.changed.is_connected(
					callback
				):

					inventory.changed.disconnect(
						callback
					)


	_inventory_connected.erase(
		npc_id
	)


# =====================================================
# Inventory Changed
#
# 重要：
#
# 這裡「絕對不直接寫 SQLite」。
#
# 只把 Character 放進 pending。
# 真正的 SAVE 在 deferred frame 執行。
# =====================================================

func _on_inventory_changed(
	character: Character
) -> void:

	if character == null:

		push_error(
			"[CharacterStatePersistence] "
			+ "Inventory.changed 收到 null Character。"
		)

		return


	if character.inventory == null:

		push_error(
			"[CharacterStatePersistence] "
			+ "Inventory.changed：%s 沒有 Inventory。"
			% character.character_id
		)

		return


	var npc_id := character.character_id


	if npc_id.is_empty():

		push_error(
			"[CharacterStatePersistence] "
			+ "Inventory.changed：Character 沒有 character_id。"
		)

		return


	if _inventory_loading.has(
		npc_id
	):

		print(
			"[CharacterStatePersistence] "
			+ "Inventory.changed 忽略："
			+ "目前正在 LOAD %s"
			% npc_id
		)

		return


	if not DatabaseManager.is_ready:

		push_error(
			"[CharacterStatePersistence] "
			+ "Inventory.changed：Database 尚未 Ready。"
		)

		return


	# -------------------------------------------------
	# 只記錄 pending。
	# -------------------------------------------------

	_inventory_sync_pending[npc_id] = character


	print(
		"[CharacterStatePersistence] "
		+ "Inventory.changed 收到：%s | runtime_slots=%d"
		% [
			npc_id,
			_count_runtime_inventory_slots(
				character
			)
		]
	)


	# -------------------------------------------------
	# 只排一次 deferred。
	# -------------------------------------------------

	if _inventory_sync_deferred:
		return


	_inventory_sync_deferred = true


	call_deferred(
		"_flush_pending_inventory_sync"
	)


# =====================================================
# Deferred Inventory Sync
# =====================================================

func _flush_pending_inventory_sync() -> void:

	_inventory_sync_deferred = false


	if _inventory_sync_pending.is_empty():
		return


	var pending := (
		_inventory_sync_pending.duplicate()
	)


	_inventory_sync_pending.clear()


	for npc_id in pending:

		var character = pending[npc_id]


		if character == null:
			continue


		if not is_instance_valid(
			character
		):
			continue


		if character.inventory == null:
			continue


		if not DatabaseManager.is_ready:
			continue


		print(
			"[CharacterStatePersistence] "
			+ "開始 deferred Inventory SAVE：%s | runtime_slots=%d"
			% [
				npc_id,
				_count_runtime_inventory_slots(
					character
				)
			]
		)


		var ok := _save_inventory(
			character
		)


		if ok:

			print(
				"[CharacterStatePersistence] "
				+ "Inventory.changed SAVE PASS：%s"
				% npc_id
			)

		else:

			push_error(
				"[CharacterStatePersistence] "
				+ "Inventory.changed SAVE FAIL：%s"
				% npc_id
			)


# =====================================================
# Runtime Inventory Slot Count
# =====================================================

func _count_runtime_inventory_slots(
	character: Character
) -> int:

	if character == null:
		return 0

	if character.inventory == null:
		return 0


	var count := 0


	for slot in character.inventory.slots:

		if not slot.is_empty():
			count += 1


	return count


# =====================================================
# Inventory SAVE
# =====================================================

func _save_inventory(
	character: Character
) -> bool:

	if character == null:
		return false


	if character.inventory == null:
		return true


	if not DatabaseManager.is_ready:
		return false


	var npc_id := character.character_id


	print(
		"[CharacterStatePersistence] "
		+ "_save_inventory START：%s | runtime_slots=%d"
		% [
			npc_id,
			_count_runtime_inventory_slots(
				character
			)
		]
	)


	# -------------------------------------------------
	# 先查詢既有資料。
	# -------------------------------------------------

	var existing_rows := DatabaseManager.select_where(
		INVENTORY_TABLE,
		"npc_id = ?",
		[
			npc_id
		],
		[
			"slot"
		]
	)


	print(
		"[CharacterStatePersistence] "
		+ "_save_inventory SELECT：%s | existing_rows=%d"
		% [
			npc_id,
			existing_rows.size()
		]
	)


	# -------------------------------------------------
	# 開始事務
	# -------------------------------------------------

	if not DatabaseManager.begin_transaction():

		push_error(
			"[CharacterStatePersistence] "
			+ "Inventory BEGIN TRANSACTION 失敗：%s"
			% npc_id
		)

		return false


	# -------------------------------------------------
	# 只有真的有舊資料才 DELETE。
	#
	# 因此第一次保存 0 rows 不會被當成錯誤。
	# -------------------------------------------------

	if not existing_rows.is_empty():

		var deleted := DatabaseManager.delete(
			INVENTORY_TABLE,
			"npc_id = '%s'"
			% DatabaseManager.escape_sql_string(npc_id)
		)


		if not deleted:

			push_error(
				"[CharacterStatePersistence] "
				+ "Inventory DELETE 失敗：%s | DB=%s"
				% [
					npc_id,
					DatabaseManager.db.error_message
				]
			)

			DatabaseManager.rollback_transaction()
			return false


		print(
			"[CharacterStatePersistence] "
			+ "_save_inventory DELETE OK：%s | rows=%d"
			% [
				npc_id,
				existing_rows.size()
			]
		)


	var saved_count := 0


	# -------------------------------------------------
	# 寫入 runtime snapshot。
	# -------------------------------------------------

	for slot_index in Inventory.SIZE:

		if slot_index >= character.inventory.slots.size():
			break


		var slot: Dictionary = (
			character.inventory.slots[
				slot_index
			]
		)


		if slot.is_empty():
			continue


		var item_id := str(
			slot.get(
				"item_id",
				""
			)
		)


		var count := int(
			slot.get(
				"count",
				0
			)
		)


		if item_id.is_empty():
			continue


		if count <= 0:
			continue


		# -------------------------------------------------
		# Persistence 不偷偷修正超過 Inventory.MAX_STACK 的資料。
		# Runtime Inventory 自己必須保證 <= 30。
		# -------------------------------------------------

		if count > Inventory.MAX_STACK:

			push_error(
				"[CharacterStatePersistence] "
				+ "Inventory stack 超過上限："
				+ "npc=%s slot=%d item=%s count=%d max=%d"
				% [
					npc_id,
					slot_index,
					item_id,
					count,
					Inventory.MAX_STACK
				]
			)

			DatabaseManager.rollback_transaction()
			return false


		var durability := clampi(
			int(
				slot.get(
					"durability",
					0
				)
			),
			0,
			100
		)


		var decay := maxi(
			0,
			int(
				slot.get(
					"decay",
					0
				)
			)
		)


		var data := {
			"npc_id": npc_id,
			"slot": slot_index,
			"item_id": item_id,
			"count": count,
			"decay": decay,
			"durability": durability
		}


		var inserted := DatabaseManager.insert(
			INVENTORY_TABLE,
			data
		)


		if not inserted:

			push_error(
				"[CharacterStatePersistence] "
				+ "Inventory INSERT 失敗："
				+ "npc=%s slot=%d item=%s | DB=%s"
				% [
					npc_id,
					slot_index,
					item_id,
					DatabaseManager.db.error_message
				]
			)

			DatabaseManager.rollback_transaction()
			return false


		# -------------------------------------------------
		# insert_row() 成功回傳後，再確認 row 真的存在——
		# 這是 npc_inventory 自己的驗證需求，不放在通用
		# DatabaseManager.insert() 裡（那裡不該知道特定
		# table 的欄位形狀）。
		# -------------------------------------------------

		var verify_rows := DatabaseManager.select_where(
			INVENTORY_TABLE,
			"npc_id = ? AND slot = ?",
			[
				npc_id,
				slot_index
			],
			[
				"npc_id"
			]
		)


		if verify_rows.is_empty():

			push_error(
				"[CharacterStatePersistence] "
				+ "Inventory INSERT 回傳成功，但 SELECT 驗證不到資料："
				+ "npc=%s slot=%d"
				% [
					npc_id,
					slot_index
				]
			)

			DatabaseManager.rollback_transaction()
			return false


		saved_count += 1


		print(
			"[CharacterStatePersistence] "
			+ "_save_inventory INSERT："
			+ "%s | slot=%d | item=%s | count=%d"
			% [
				npc_id,
				slot_index,
				item_id,
				count
			]
		)


	# -------------------------------------------------
	# 提交事務
	# -------------------------------------------------

	if not DatabaseManager.commit_transaction():

		push_error(
			"[CharacterStatePersistence] "
			+ "Inventory COMMIT 失敗：%s"
			% npc_id
		)

		DatabaseManager.rollback_transaction()
		return false


	print(
		"[CharacterStatePersistence] "
		+ "Inventory SAVE %s：%d slot"
		% [
			npc_id,
			saved_count
		]
	)


	return true


# =====================================================
# Wallet Persistence
# =====================================================

func _save_wallet(
	character: Character
) -> bool:

	if character == null:
		return false


	if character.inventory == null:
		return true


	var npc_id := character.character_id


	var money := maxi(
		0,
		character.inventory.get_money()
	)


	var existing := DatabaseManager.select_where(
		WALLET_TABLE,
		"npc_id = ?",
		[
			npc_id
		],
		[
			"npc_id"
		]
	)


	var data := {
		"npc_id": npc_id,
		"money": money
	}


	if existing.is_empty():

		var inserted := DatabaseManager.insert(
			WALLET_TABLE,
			data
		)


		if not inserted:

			push_error(
				"[CharacterStatePersistence] "
				+ "Wallet INSERT 失敗：%s | DB=%s"
				% [
					npc_id,
					DatabaseManager.db.error_message
				]
			)


		return inserted


	var updated := DatabaseManager.update(
		WALLET_TABLE,
		data,
		"npc_id = '%s'"
		% DatabaseManager.escape_sql_string(npc_id)
	)


	if not updated:

		push_error(
			"[CharacterStatePersistence] "
			+ "Wallet UPDATE 失敗：%s | DB=%s"
			% [
				npc_id,
				DatabaseManager.db.error_message
			]
		)


	return updated


# =====================================================
# Stats
# =====================================================

func _stat(
	character: Character,
	key: String,
	fallback: float
) -> float:

	if character.stats == null:
		return fallback


	if character.stats.SPEC.has(
		key
	):

		return clampf(
			float(
				character.stats.get_value(
					key
				)
			),
			0.0,
			100.0
		)


	return fallback


# =====================================================
# NPC Record
# =====================================================

func _ensure_npc_record(
	character: Character
) -> bool:

	var character_id := (
		character.character_id
	)


	var existing := DatabaseManager.select_where(
		NPC_TABLE,
		"npc_id = ?",
		[
			character_id
		],
		[
			"npc_id",
			"home_location_id"
		]
	)


	if not existing.is_empty():

		var db_home_location_id := str(
			existing[0].get(
				"home_location_id",
				""
			)
		)

		# 舊 Character 節點重新進場（例如讀檔後重生）時，把 DB 裡已經
		# 分配過的家同步回記憶體欄位——round-robin 只在建立新 npc 記錄
		# 那一次跑，這裡不重新分配。但 DB 值本身也可能是 issue #391 之前
		# 的舊 fallback（home_001 這類），直接信任會讓這個值繞過格式驗證
		# 一路留到 has_for()/resolve_for() 才發現解不開——一樣要走
		# _reconcile_home_location() 驗證（CodeRabbit review 抓到，PR #727）
		if character.home_location_id.is_empty():
			character.home_location_id = db_home_location_id
			return _reconcile_home_location(character, db_home_location_id, character_id)

		# 記憶體值（可能來自讀檔還原的存檔）跟 DB 現存值不一致：DB 才是
		# _occupied_home_location_ids() 判斷占用的依據，兩邊沒同步會讓
		# round-robin 的占用判斷跟實際分配脫鉤（例如兩人各自「以為」分到
		# 同一間）。用 _resolve_home_location() 驗證／必要時重分配，
		# 結果寫回 DB，不能只在記憶體端悄悄接受讀檔帶回來的值
		# （code review 抓到，PR #727）
		if character.home_location_id != db_home_location_id:
			return _reconcile_home_location(character, db_home_location_id, character_id)

		return true


	var home_location_id := (
		_resolve_home_location(
			character
		)
	)


	if home_location_id.is_empty():

		push_error(
			(
				"[CharacterStatePersistence] "
				+ "%s 無法建立 npc："
				+ "沒有可用的 home_location_id。"
			) % character_id
		)

		return false


	var npc_data := {
		"npc_id": character_id,
		"name": character.character_name,
		"age": 30,
		"gender": "other",
		"village_id": "default_village",
		"character": "",
		"reputation": 0,
		"system_prompt": "",
		"words_to_creator": "",
		"is_spoken": 0,
		"generated_at": null,
		"spoken_at": null,
		"trigger": null,
		"home_location_id": home_location_id,
		"decision_source": "local",
		"model_name": "",
		"is_active": 1
	}


	var inserted := DatabaseManager.insert(
		NPC_TABLE,
		npc_data
	)


	if not inserted:

		push_error(
			"[CharacterStatePersistence] "
			+ "建立 npc 失敗：%s | DB=%s"
			% [
				character_id,
				DatabaseManager.db.error_message
			]
		)

		return false


	character.home_location_id = home_location_id


	return true


# =====================================================
# Home Location（issue #391，《規格書07_地點/家》round-robin 分配）
# =====================================================

## 家的供給完全動態（issue #825）：地圖上沒有任何畫死的家，每個進場的角色
## 由引擎替他長一間、離場時拆掉。編號 loc_home_NN 的 N 是正整數、沒有上限，
## 拆掉後編號會被下一個角色復用（見 _reactivatable_home_location_id()）
const HOME_LOCATION_PREFIX := "loc_home_"

## 動態家用的房屋場景，依 loc_home_NN 的編號奇偶交替 instantiate——奇數用
## house_001、偶數用 house_002，兩種格局讓村莊看起來有變化。重開遊戲後靠
## 同一個編號推回同一棟（_home_scene_path()）。用 load() 而不是 preload()：
## 這個檔案處理全部角色的 state/wallet/inventory 同步，流量遠比家的動態
## 成長高，房屋場景檔萬一被搬移或壞掉，只該讓成長這條路徑失敗，不該連累
## 其他完全不相干的同步邏輯
const HOME_SCENE_ODD := "res://scenes/houses/house_001.tscn"
const HOME_SCENE_EVEN := "res://scenes/houses/house_002.tscn"

## 兩間家之間的最小間距。房子本體 128x112px（house_001/002 的 wall 圖層
## 8x7 格），加上 resolve_from_position() 反查要距離 > character.gd 的
## ACTUAL_PLACE_RADIUS 32px（見 note/技術/村莊地圖.md 的 PR #727 postmortem）
## ——160px 讓兩棟房子中間留一格走道、反查也不會誤判到隔壁那間
const HOME_MIN_SEPARATION := 160.0

## _find_home_placement() 的落點搜尋半徑上界（單位：格）：從搜尋起點一圈圈
## 往外掃，掃到這個半徑還找不到就回 Vector2.INF、走溢出共用安全閥。遠大於
## 現實需求（NavGrid 可走範圍不可能被家占滿到這個程度），只是給搜尋一條
## 明確的停止線
const HOME_PLACEMENT_MAX_RADIUS := 60

## 房屋 wall 圖層足跡（house_001/002 都是 8x7 格＝128x112px）與它相對錨點
## （門口可走格）的中心偏移。錨點對齊房屋的 Door 子節點正下方（見
## _spawn_home_scene()），房屋因此整體落在錨點的西北側：中心約在錨點西 32px、
## 北 56px。_find_home_placement() 的落點足跡檢查用這組值抓一個略大的方框，
## 避免把家蓋在牆上；房屋改尺寸時這裡跟著改
const DYNAMIC_HOME_ANCHOR_TO_HOUSE := Vector2(-32.0, -56.0)
const DYNAMIC_HOME_FOOTPRINT := Vector2(144.0, 128.0)

## 新家的落點（＝門口錨點）要離「其他既有地點錨點」（涼亭、酒館、藥草鋪、
## 墓園…）多遠。房屋足跡最寬處相對落點約 104px（往西北），128 讓那些地點的
## 錨點格落在房屋碰撞箱外、還留一點視覺間距。不能設太大：village 地圖不大，
## 7 個地點錨點散在中央，實測（project_run + game_eval）>150 時就找不到同時
## 滿足所有錨點的落點，_grow_home_supply() 會退回共用、失去每人一間
const PLACE_ANCHOR_CLEARANCE := 128.0


## _ensure_npc_record() 的共用收尾：用 _resolve_home_location() 驗證／必要時
## 重新分配 character 目前的 home_location_id，寫回記憶體；若跟 DB 現存值不同
## 才寫回 DB。回傳值就是「這次同步算不算成功」——DB 寫入失敗時要往上傳，不能
## 悄悄吞掉：吞掉的話記憶體已經換成新值、DB 還停在舊值，
## _occupied_home_location_ids()（讀 DB）跟實際分配會分歧，跟不寫回 DB 是
## 同一種脫鉤（CodeRabbit review 抓到，PR #727）
func _reconcile_home_location(
	character: Character,
	db_home_location_id: String,
	character_id: String
) -> bool:

	var resolved_home_location_id := _resolve_home_location(character)
	character.home_location_id = resolved_home_location_id

	if resolved_home_location_id == db_home_location_id:
		return true

	var update_ok := DatabaseManager.update(
		NPC_TABLE,
		{"home_location_id": resolved_home_location_id},
		"npc_id = '%s'"
		% DatabaseManager.escape_sql_string(character_id)
	)

	if not update_ok:
		push_error(
			"[CharacterStatePersistence] %s home_location_id 同步失敗（%s → %s）"
			% [character_id, db_home_location_id, resolved_home_location_id]
		)

	return update_ok


## _ensure_npc_record() 兩條路徑（新建立／DB 既有值 reconcile）共用的入口：
## 世界名冊在這裡取一次，沿用檢查跟重分配看同一份占用快照
func _resolve_home_location(
	character: Character
) -> String:

	return _resolve_home_location_for(
		character.home_location_id,
		character.character_id,
		_world_character_ids()
	)


## _resolve_home_location() 的核心。世界名冊收成參數：名冊是場景狀態、不是
## DB 狀態，收進來之後這條路徑就能在純 DatabaseManager 層測試
## （tests/test_home_assignment.gd），不用為了測試造場景節點
func _resolve_home_location_for(
	current_value: String,
	character_id: String,
	world_character_ids: Dictionary
) -> String:

	# 占用集合要排除自己：沿用檢查問的是「這間有沒有被『別人』佔走」，自己
	# 既有 npc 列上的 home_location_id 不算占用，否則自己的舊值永遠過不了
	# 檢查（code review 抓到，PR #727）
	var occupied := _occupied_home_location_ids(
		world_character_ids,
		character_id
	)


	# 值本身也要驗證是 loc_home_NN（正整數編號，動態成長後沒有固定上限）
	# 命名，不能只驗證
	# location 表裡「有沒有這一列」——舊 fallback（issue #391 之前）寫的
	# home_001 那類值在 location 表裡也確實有一列，會通過純存在性檢查，
	# 但場景裡沒有同名錨點，has_for()/resolve_for() 永遠解析不到、每次都
	# push_error，而且沒有任何自我修復路徑。這裡驗證命名格式，格式不對的
	# 舊值一律當無效值處理，落到下面重新分配（code review 抓到，PR #727）
	if _is_valid_home_location_id(current_value):

		var requested_rows := (
			DatabaseManager.select_where(
				"location",
				"location_id = ? AND is_active = 1",
				[
					current_value
				],
				[
					"location_id"
				]
			)
		)

		# 除了「格式合法＋location 表有這一列且仍是 active」，還要「沒有被別的
		# 還在世界的角色佔走」——記憶體值可能來自讀檔還原的存檔，跟 DB 現況
		# 分歧（存檔值與 DB 值打架、或 _ensure_unique_id() 換過 character_id
		# 後照抄舊存檔）時，只驗格式跟存在性會讓兩個角色同時「以為」自己分到
		# 同一間，而且完全靜默（code review 抓到，PR #727）。is_active 這道
		# 篩選是 issue #751 新加的：這間家若已被 _release_home_if_dynamic()
		# 標記拆除（is_active=0），沿用檢查在這裡自然失敗，逼這個角色走下面
		# 的全新分配——「重進不保留分配權」不需要另外去清 npc.home_location_id
		# 這個欄位（也不能清，NOT NULL 加 FK RESTRICT，硬清會撞資料庫）
		if not requested_rows.is_empty() and not occupied.has(current_value):
			return current_value


	return _assign_next_home_location(occupied)


## value 是不是 loc_home_ 開頭的合法命名——只檢查格式，不查 DB（DB
## 存在性／is_active 由呼叫端另外查）。用來擋掉 issue #391 之前的舊
## fallback 值（例如 home_001）與其他任何不屬於這批命名的殘留值。
## 沒有編號上限：供給完全動態，只要是正整數編號就是合法格式
func _is_valid_home_location_id(value: String) -> bool:

	if value.is_empty():
		return false

	if not value.begins_with(HOME_LOCATION_PREFIX):
		return false

	var suffix := value.substr(HOME_LOCATION_PREFIX.length())

	if not suffix.is_valid_int():
		return false

	return int(suffix) >= 1


## loc_home_NN 的 N，不是合法命名回傳 -1
func _home_location_index(location_id: String) -> int:

	if not _is_valid_home_location_id(location_id):
		return -1

	return int(location_id.substr(HOME_LOCATION_PREFIX.length()))


## 動態家的房屋場景：編號奇數用 house_001、偶數用 house_002。純函式，
## _spawn_home_scene() 生成與 _rebuild_dynamic_homes() 重建都靠它推回同一棟
func _home_scene_path(location_id: String) -> String:

	if _home_location_index(location_id) % 2 == 1:
		return HOME_SCENE_ODD

	return HOME_SCENE_EVEN


## round-robin：從游標位置沿固定順序找第一間沒有被「目前還在世界上的角色」
## 佔用的 active 家，分配後游標移到它的下一個位置（mod 目前家的總數）。
## occupied 由呼叫端傳入（_resolve_home_location_for() 已經算好一份排除自己
## 的占用快照，沿用檢查跟重分配看同一份，中途世界人數變動也不會前後不一致）。
## 佔用＝還在世界上的角色的 npc 列（見 _occupied_home_location_ids()）：
## 角色離開世界後那間家即視為空出，下一輪巡覽自然會排到它；游標本身不回退。
##
## 現有家全滿時不再走溢出共用安全閥（issue #751 拿掉這個機制）——改成呼叫
## _grow_home_supply() 真的長一間新的出來，不需要犧牲「每人一間」這個保證
func _assign_next_home_location(occupied: Dictionary) -> String:

	var active_ids := _active_home_location_ids()
	var count := active_ids.size()

	if count > 0:

		var cursor := _get_home_cursor() % count

		for offset in range(count):

			var index := (cursor + offset) % count
			var location_id: String = active_ids[index]

			if not occupied.has(location_id):
				_set_home_cursor((index + 1) % count)
				return location_id

	return _grow_home_supply()


## 目前所有 is_active=1 的 loc_home_* location_id，依編號排序——round-robin
## 掃描的候選清單。跟舊版「固定 0..HOME_LOCATION_COUNT-1」的差別是這份清單
## 長度會隨供給成長變動，且編號可能有缺口（拆除後 is_active=0 的家被排除，
## 直到 _grow_home_supply() 復活它才會重新出現在這裡）
func _active_home_location_ids() -> Array[String]:

	var rows := DatabaseManager.select_where(
		"location",
		"location_id LIKE ? AND is_active = 1",
		[HOME_LOCATION_PREFIX + "%"],
		["location_id"]
	)

	var ids: Array[String] = []
	for row in rows:
		ids.append(str(row.get("location_id", "")))

	ids.sort()
	return ids


## 現有的家全部被占用時成長供給（issue #751）：優先復活一間先前被
## _release_home_if_dynamic() 拆除、目前 is_active=0 的家（重用編號，
## 避免拆了又長無止盡往後加號碼），沒有可復活的才真的開一個新編號。
## 兩種情況都要重新搜尋一次落點——復活的家原本的座標不一定還適用（可能
## 已經被別的東西占走，或單純想避免每次都長在同一點造成視覺群聚）
func _grow_home_supply() -> String:

	var location_id := _reactivatable_home_location_id()
	if location_id.is_empty():
		location_id = _next_new_home_location_id()

	var position := _find_home_placement()

	if position == Vector2.INF:
		# 地圖找不到落點（理論上不會發生，NavGrid 範圍遠大於目前的家數量）：
		# 寧可跟目前游標指到的家共用，也不要讓 home_location_id 留空撞
		# NPCSchema 的 NOT NULL——跟舊版溢出安全閥同一個「不能讓整套同步
		# 卡死」的理由，只是現在只在真正找不到地方時才會走到這裡
		var active_ids := _active_home_location_ids()
		if not active_ids.is_empty():
			push_warning(
				"[CharacterStatePersistence] 找不到新家的落點，%s 溢出共用。"
				% active_ids[0]
			)
			return active_ids[0]
		push_error("[CharacterStatePersistence] 一間家都沒有、也找不到新落點，無法分配。")
		return ""

	if not _create_or_reactivate_home(location_id, position):
		# DB 寫入失敗：不能回傳 location 表裡不存在的 id——npc.home_location_id
		# 的 FK 會擋下整筆角色同步（CodeRabbit review on #825）。退回共用現有
		# 的 active 家，跟上面找不到落點的溢出共用同一個「不能讓整套同步卡死」
		# 的理由
		var fallback_ids := _active_home_location_ids()
		if not fallback_ids.is_empty():
			push_warning(
				"[CharacterStatePersistence] 動態家 %s 建立／復活失敗，%s 溢出共用。"
								% [location_id, fallback_ids[0]]
			)
			return fallback_ids[0]
		push_error("[CharacterStatePersistence] 動態家建立失敗且沒有任何現成的家可共用，無法分配。")
		return ""
	return location_id


## 挑一個目前 is_active=0（先前被拆除）的家來復活，依編號取最小的那個；
## 沒有可復活的回傳空字串
func _reactivatable_home_location_id() -> String:

	var rows := DatabaseManager.select_where(
		"location",
		"location_id LIKE ? AND is_active = 0",
		[HOME_LOCATION_PREFIX + "%"],
		["location_id"]
	)

	var ids: Array[String] = []
	for row in rows:
		ids.append(str(row.get("location_id", "")))

	if ids.is_empty():
		return ""

	ids.sort()
	return ids[0]


## 挑一個沒被用過的新編號：掃現有全部 loc_home_*（不論 active/inactive）的
## 編號，取最小的缺口——缺口用完才往上加，避免拆了又長把編號一路推高
func _next_new_home_location_id() -> String:

	var rows := DatabaseManager.select_where(
		"location",
		"location_id LIKE ?",
		[HOME_LOCATION_PREFIX + "%"],
		["location_id"]
	)

	var used := {}
	for row in rows:
		var index := _home_location_index(str(row.get("location_id", "")))
		if index > 0:
			used[index] = true

	var candidate := 1
	while used.has(candidate):
		candidate += 1

	return "%s%02d" % [HOME_LOCATION_PREFIX, candidate]


## 幫一間新家找位置：錨點格與房屋足跡在 NavGrid 上都可走、跟現有每一間家的
## 距離：跟每一間現有的家 > HOME_MIN_SEPARATION，跟每一個其他既有地點錨點
##（涼亭、酒館…）> PLACE_ANCHOR_CLEARANCE——不然會長在涼亭之類的地點上面
##（實測踩到）。搜尋起點用第一間現有的家；一間都還沒有（第一個進場的角色）
## 就從涼亭錨點起（角色本來就都投放在涼亭，見 GameManager.spawn_character()），
## 起點只是搜尋原點，PLACE_ANCHOR_CLEARANCE 會把實際落點推離涼亭。一圈圈往外
## 找（跟 NavGrid.nearest_free_cell() 同一套「掃外框」手法）。找不到回傳 Vector2.INF
func _find_home_placement() -> Vector2:

	var nav = get_tree().get_first_node_in_group("nav_grid")
	if nav == null:
		return Vector2.INF

	var anchors = get_tree().get_first_node_in_group("place_anchors")
	if anchors == null:
		return Vector2.INF

	var existing_homes := _existing_home_positions()
	var other_places := _other_place_anchor_positions(anchors)

	var seed_world: Vector2
	if not existing_homes.is_empty():
		seed_world = existing_homes[0]
	elif anchors.has("pavilion"):
		seed_world = anchors.resolve("pavilion")
	else:
		return Vector2.INF

	var seed_cell: Vector2i = nav.world_to_cell(seed_world)

	for radius in range(0, HOME_PLACEMENT_MAX_RADIUS + 1):
		for y in range(-radius, radius + 1):
			for x in range(-radius, radius + 1):

				if radius > 0 and absi(x) != radius and absi(y) != radius:
					continue

				var cell: Vector2i = seed_cell + Vector2i(x, y)
				if not _home_footprint_free(nav, cell):
					continue
				var candidate: Vector2 = nav.cell_to_world(cell)
				if not _far_enough_from_all(candidate, existing_homes, HOME_MIN_SEPARATION):
					continue
				if not _far_enough_from_all(candidate, other_places, PLACE_ANCHOR_CLEARANCE):
					continue
				return candidate

	return Vector2.INF


func _far_enough_from_all(candidate: Vector2, positions: Array, min_dist: float) -> bool:

	for pos in positions:
		if candidate.distance_to(pos) < min_dist:
			return false

	return true


## PlaceAnchors 底下所有「不是家」的錨點世界座標（涼亭、酒館、藥草鋪、墓園、
## 藥草叢、森林、天神之石）。家的錨點名字都是 loc_home_ 開頭，排除掉——那些
## 由 _existing_home_positions() 另外用 HOME_MIN_SEPARATION 這條較寬鬆的距離管
func _other_place_anchor_positions(anchors) -> Array:

	var positions := []

	for child in anchors.get_children():
		if child is Node2D and not str(child.name).begins_with(HOME_LOCATION_PREFIX):
			positions.append((child as Node2D).global_position)

	return positions


## 落點足跡檢查：錨點那格可走，且房屋罩住的方框（DYNAMIC_HOME_FOOTPRINT
## 對 16px 格換算，中心在 DYNAMIC_HOME_ANCHOR_TO_HOUSE）全部可走。房子生成
## 後這些格會變成 solid（_spawn_home_scene() 生成後會重建 NavGrid），只驗
## 錨點單一格會把家蓋在牆上／其他靜態障礙上（CodeRabbit review on #825）
func _home_footprint_free(nav, anchor_cell: Vector2i) -> bool:

	if not nav.is_cell_free(anchor_cell):
		return false

	var house_cell: Vector2i = anchor_cell + Vector2i(
		int(DYNAMIC_HOME_ANCHOR_TO_HOUSE.x / 16.0),
		int(DYNAMIC_HOME_ANCHOR_TO_HOUSE.y / 16.0)
	)
	var half_cells := Vector2i(
		int(DYNAMIC_HOME_FOOTPRINT.x / 32.0),
		int(DYNAMIC_HOME_FOOTPRINT.y / 32.0)
	)

	for dy in range(-half_cells.y, half_cells.y + 1):
		for dx in range(-half_cells.x, half_cells.x + 1):
			if not nav.is_cell_free(house_cell + Vector2i(dx, dy)):
				return false

	return true

## 現有每一間 active 家的世界座標。座標存在 location.pos_x/pos_y（見
## migration 12）。只算 is_active=1：拆除的家足跡已還給 NavGrid，不該再擋
## 新家的落點；復活流程呼叫 _find_home_placement() 時被復活的那間仍是
## is_active=0，也因此不會拿它自己的舊座標當「現有的家」
func _existing_home_positions() -> Array:

	var positions := []

	var rows := DatabaseManager.select_where(
		"location",
		"location_id LIKE ? AND is_active = 1 AND pos_x IS NOT NULL",
		[HOME_LOCATION_PREFIX + "%"],
		["pos_x", "pos_y"]
	)

	for row in rows:
		positions.append(Vector2(float(row.get("pos_x", 0.0)), float(row.get("pos_y", 0.0))))

	return positions


## 建立或復活一筆動態家的 DB 資料列＋場景節點。回傳成敗：DB 寫入失敗時
## 呼叫端不能拿著一個 location 表裡不存在的 id 去寫 npc.home_location_id
##（FK 會擋下整筆角色同步），要退回共用現有的家
func _create_or_reactivate_home(location_id: String, position: Vector2) -> bool:

	var existing := DatabaseManager.select_where(
		"location", "location_id = ?", [location_id], ["location_id"]
	)

	if existing.is_empty():

		if not DatabaseManager.insert("location", {
			"location_id": location_id,
			"name": location_id,
			"description": "",
			"location_type": "home",
			"capacity": 1,
			"danger": 0,
			"is_active": 1,
			"pos_x": position.x,
			"pos_y": position.y,
		}):
			push_error(
				"[CharacterStatePersistence] 動態家 %s 建立失敗 | DB=%s"
				% [location_id, DatabaseManager.db.error_message]
			)
			return false

	else:

		if not DatabaseManager.update(
			"location",
			{"is_active": 1, "pos_x": position.x, "pos_y": position.y},
			"location_id = '%s'" % DatabaseManager.escape_sql_string(location_id)
		):
			push_error(
				"[CharacterStatePersistence] 動態家 %s 復活失敗 | DB=%s"
				% [location_id, DatabaseManager.db.error_message]
			)
			return false

	_spawn_home_scene(location_id, position)
	return true


## 動態家的場景表現：房屋場景掛在 Level 底下（＝ PlaceAnchors 的父節點），
## 跟 level.tscn 裡原本手擺的房屋節點同一個父節點、同一套 y-sort／z 排序
## 脈絡——掛在 world 群組（跟角色一起）底下時，house_001/002 的 floor 圖層
## z_index=-1 會被地圖蓋掉，房子看起來沒地板（實測踩到）。同時在
## PlaceAnchors 底下加一個同名 Area2D 錨點——resolve()／has() 靠 PlaceAnchors
## 底下的同名子節點查，resolve_from_position() 反查則要錨點底下有
## CollisionShape2D（靜態家當初也是 Area2D+Shape，死在家裡才能反查出
## loc_home_NN）。兩邊都先檢查存不存在（同幀已排刪除的殘骸不算，見底下
## guard）才建立，讀檔重建
##（_rebuild_dynamic_homes()）跟成長路徑可能對同一個 location_id 各呼叫
## 一次，不該疊出兩份
##
## position 是錨點（門口可走格）的世界座標，也是 DB pos_x/pos_y 存的值；
## 房屋擺成 Door 子節點正好落在錨點北邊一格——house_001/002 的門在不同
## 高度，讀實例的 Door.position 對齊，不用兩套寫死偏移。生成後 deferred
## 重建 NavGrid（見 _schedule_nav_rebuild()）
func _spawn_home_scene(location_id: String, position: Vector2) -> void:

	if not _is_valid_home_location_id(location_id):
		push_error(
			"[CharacterStatePersistence] %s 不是合法的家編號，跳過場景生成"
			% location_id
		)
		return

	var anchors = get_tree().get_first_node_in_group("place_anchors")
	if anchors == null:
		push_error("[CharacterStatePersistence] 場景沒有 place_anchors 群組節點，%s 沒有座標可用" % location_id)
		return

	var existing_anchor := anchors.get_node_or_null(NodePath(location_id))
	# 同一幀內「拆了又蓋」（CodeRabbit review on #995）：_demolish_home_scene()
	# 用 queue_free()，同名節點要幀末才真正離樹。已排刪除的舊錨點先摘出樹，
	# 讓名字立刻讓出來——不解開的話底下 add_child() 撞名會被 Godot 自動改名
	#（結尾加 @2），之後 resolve()／has_node() 都查不到正名節點；節點本身
	# 不用另外 free()，幀末仍會被 queue_free 回收
	if existing_anchor != null and existing_anchor.is_queued_for_deletion():
		anchors.remove_child(existing_anchor)
		existing_anchor = null

	if existing_anchor == null:
		var anchor := Area2D.new()
		anchor.name = location_id
		anchor.position = position
		anchor.collision_layer = 0
		anchor.collision_mask = 0
		anchor.monitoring = false
		anchor.monitorable = false
		var shape := CollisionShape2D.new()
		var rect := RectangleShape2D.new()
		rect.size = Vector2(24.0, 24.0)
		shape.shape = rect
		anchor.add_child(shape)
		anchors.add_child(anchor)

	var level = anchors.get_parent()
	if level == null:
		push_error("[CharacterStatePersistence] PlaceAnchors 沒有父節點，%s 沒有地方掛房屋" % location_id)
		return

	var house_name := "DynamicHome_%s" % location_id
	var existing_house := level.get_node_or_null(NodePath(house_name))
	if existing_house != null and not existing_house.is_queued_for_deletion():
		return

	# 同一幀內「拆了又蓋」（CodeRabbit review on #995）：_demolish_home_scene()
	# 用 queue_free()，舊房屋要幀末才真正離樹——guard 若只看 has_node() 會把
	# 它當成現役節點提前 return，幀末殘骸釋放後，剛標回 is_active=1 的列就
	# 沒有任何對應節點。已排刪除的先摘出樹讓名字讓出來（底下 add_child() 才
	# 不會撞名被自動改名成 @2 後綴，之後 has_node()／resolve() 查不到正名
	# 節點）；節點本身幀末仍會被 queue_free 回收，不用另外 free()
	if existing_house != null:
		level.remove_child(existing_house)

	var house_scene: PackedScene = load(_home_scene_path(location_id))
	if house_scene == null:
		push_error("[CharacterStatePersistence] 載入 %s 失敗，%s 沒有房屋可看" % [_home_scene_path(location_id), location_id])
		return

	var house := house_scene.instantiate()
	house.name = house_name
	var door := house.get_node_or_null("Door")
	var door_local: Vector2 = door.position if door != null else Vector2(88.0, -8.0)
	# 門對齊錨點北邊一格：Door 全域座標 = 錨點正上方 16px
	house.global_position = position - Vector2(0.0, 16.0) - door_local
	level.add_child(house)

	# 新的碰撞體要等一個物理幀才會反映到物理空間，deferred 重建 NavGrid
	# 讓房子底下的格子立刻變 solid，find_path() 不會把終點算進房裡
	_schedule_nav_rebuild()


## 拆除一間家的場景表現（issue #825：角色離場即拆）。location 列本身不刪，
## 改成 is_active=0，等下次 _grow_home_supply() 復活它——刪列會去撞
## npc.home_location_id 的 FOREIGN KEY ... ON DELETE RESTRICT（離場角色的
## 舊值還留著，是無害的殘留：下次牠重新解析時 is_active=0 會讓「沿用檢查」
## 自然失敗，逼牠走全新分配，不需要另外去改 npc 那筆的 home_location_id）
func _demolish_home_scene(location_id: String) -> void:

	var anchors = get_tree().get_first_node_in_group("place_anchors")
	if anchors != null and anchors.has_node(NodePath(location_id)):
		anchors.get_node(NodePath(location_id)).queue_free()

	var level = anchors.get_parent() if anchors != null else null
	if level != null:
		var house_name := "DynamicHome_%s" % location_id
		if level.has_node(NodePath(house_name)):
			level.get_node(NodePath(house_name)).queue_free()

	if not DatabaseManager.update(
		"location", {"is_active": 0},
		"location_id = '%s'" % DatabaseManager.escape_sql_string(location_id)
	):
		push_error(
			"[CharacterStatePersistence] %s 標記 is_active=0 失敗 | DB=%s"
			% [location_id, DatabaseManager.db.error_message]
		)

	# 房子拆掉了，它的格子要還回來——同樣 deferred 一幀（queue_free() 的
	# 節點要等幀末才真的離開樹）
	_schedule_nav_rebuild()


## 角色節點離開場景樹時拆除牠的家（issue #825：重進不保留分配權）。所有
## 家都是動態的，一律拆
func _release_home_if_dynamic(npc_id: String) -> void:

	# 整個世界卸載（Esc「回主選單」的 change_scene_to_file()、關視窗的 quit()）
	# 也會讓場上每個角色 tree_exited——那是整樹拆除，不是「這個角色被從世界中
	# 移除」。這個節點掛在 DatabaseManager（autoload）底下，比當前場景晚釋放、
	# DB 還活著，回呼照樣執行：不擋的話每次離開世界，所有動態家都會被標
	# is_active=0，下次進場 _rebuild_dynamic_homes() 查不到任何 active 的動態列，
	# 「讀檔原樣重建」變死碼（CodeRabbit review on #825 抓到）。只有單一角色
	# 退場才拆除動態家；世界卸載中一律跳過，旗標由 GameManager 管理
	# （離開流程起點設 true，進場／deploy 時重置）
	if GameManager._world_unloading:
		return

	var rows := DatabaseManager.select_where(
		NPC_TABLE, "npc_id = ?", [npc_id], ["home_location_id"]
	)
	if rows.is_empty():
		return

	var location_id := str(rows[0].get("home_location_id", ""))
	if _is_valid_home_location_id(location_id):
		_demolish_home_scene(location_id)


## 進世界時把 DB 裡每一筆仍是 active 的家重新 instantiate 一次（issue #825
## 「讀檔時重建」）。家的錨點與房屋節點都是純執行期產物，重開遊戲／回選單
## 再進場後場景樹裡什麼都沒有，只剩 DB 的 pos_x/pos_y。
##
## 呼叫時機：autoload 開機的 deferred 那次撞的是主選單場景（沒有世界可掛），
## 真正的重建入口在世界進場點 main_scene.gd::_ready()——每次進世界（新遊戲／
## 繼續／回選單再進）都會呼叫（CodeRabbit review on #825 抓到進世界後沒有
## 任何重建路徑）。場景沒有 place_anchors 就直接跳過：主選單開機不噴錯
func _rebuild_dynamic_homes() -> void:

	if not DatabaseManager.is_ready:
		return

	if get_tree().get_first_node_in_group("place_anchors") == null:
		return

	var rows := DatabaseManager.select_where(
		"location",
		"location_id LIKE ? AND is_active = 1 AND pos_x IS NOT NULL",
		[HOME_LOCATION_PREFIX + "%"],
		["location_id", "pos_x", "pos_y"]
	)

	for row in rows:
		var location_id := str(row.get("location_id", ""))
		var position := Vector2(float(row.get("pos_x", 0.0)), float(row.get("pos_y", 0.0)))
		_spawn_home_scene(location_id, position)

## 生成／拆除動態家之後重建 NavGrid（CodeRabbit review on #825）：房子底下
## 的格子要變 solid、拆掉的要還回來。新加／剛移除的碰撞體要等一個物理幀
## 才會反映到物理空間（NavGrid._ready() 開場建置同樣的理由），所以 await
## 一幀再 rebuild。同一拍多次生成／拆除只重建一次——rebuild() 是整張網格
## 重掃，沒必要逐棟各掃一遍
var _nav_rebuild_pending := false

func _schedule_nav_rebuild() -> void:

	if _nav_rebuild_pending:
		return

	var tree := get_tree()
	if tree == null:
		return

	_nav_rebuild_pending = true
	await tree.physics_frame
	_nav_rebuild_pending = false

	if not is_inside_tree():
		return

	var nav = tree.get_first_node_in_group("nav_grid")
	if nav != null:
		nav.rebuild()


## 占用集合＝「目前還在世界上的角色」的 character_id 對到的 npc 列所占的家。
## 場上 characters 群組就是世界名冊（Player 的基底 Character._ready() 也會進
## 這個群組，所以玩家的家一樣算占用）。不能拿 npc 表全部列當占用——npc 列
## 沒有任何刪除路徑（remove_from_library() 只動記憶體角色庫、is_active 從沒
## 有人改成 0），同一份 DB 只要曾經同步過 5 個以上不同 character_id（開第二輪
## 新遊戲、debug console spawn、角色庫換一批），占用就永遠滿 5 間，之後每個
## 新角色都掉進溢出安全閥共用同一間，per-character home 等於失效。
## 不在世界名冊裡的列不算占用：那間家即釋出；角色重新進場時若它還沒被別人
## 拿走，會經 _reconcile_home_location() 沿用回原本那間（code review 抓到，
## PR #727）
## 世界名冊與「排除自己」都收成參數：exclude_character_id 是查「自己能不能
## 沿用」時把自己那列排除，否則自己的舊值會被自己擋下來；名冊收參數的理由
## 見 _resolve_home_location_for()
func _occupied_home_location_ids(
	world_character_ids: Dictionary,
	exclude_character_id: String = ""
) -> Dictionary:

	var rows := DatabaseManager.select(
		NPC_TABLE,
		"",
		["npc_id", "home_location_id"]
	)

	var occupied := {}

	for row in rows:

		var npc_id := str(row.get("npc_id", ""))

		if npc_id == exclude_character_id:
			continue

		if not world_character_ids.has(npc_id):
			continue

		var location_id := str(
			row.get("home_location_id", "")
		)

		if not location_id.is_empty():
			occupied[location_id] = true

	return occupied


## 目前還在世界上的角色 id 集合（characters 群組）。用 node.get() 而不是轉型
## 成 Character 再索引：轉型失敗（null）跟缺欄位是同一種「拿不到 id」，一個
## str() 加空字串檢查就涵蓋，不必在迴圈裡做兩層 null 判斷
func _world_character_ids() -> Dictionary:

	var ids := {}

	for node in get_tree().get_nodes_in_group("characters"):

		var id := str(node.get("character_id"))

		if not id.is_empty():
			ids[id] = true

	return ids


func _get_home_cursor() -> int:

	var rows := DatabaseManager.select(
		"home_assignment",
		"id = 1",
		["next_index"]
	)

	if rows.is_empty():
		return 0

	# 不在這裡收斂上界了（issue #751 之前是 % HOME_LOCATION_COUNT）——供給
	# 動態成長後沒有固定的家數量，收斂交給呼叫端（_assign_next_home_location()
	# 用當下真正的 active 家數量取 %，那裡才知道真正的界在哪）
	return maxi(0, int(rows[0].get("next_index", 0)))


func _set_home_cursor(value: int) -> void:

	if DatabaseManager.select(
		"home_assignment", "id = 1", ["id"]
	).is_empty():

		DatabaseManager.insert(
			"home_assignment",
			{"id": 1, "next_index": value}
		)

	else:

		DatabaseManager.update(
			"home_assignment",
			{"next_index": value},
			"id = 1"
		)


# =====================================================
# Public
# =====================================================

func sync_now() -> bool:

	return _sync_all_characters()


## Inventory.changed 觸發的 deferred SAVE 是否還沒真正寫進 SQLite。
## 給測試用：call_deferred() 何時真正執行不保證落在固定幀數內，
## 靠這個 poll 到「真的存完了」，不要用猜測的 await frame 次數。
func has_pending_inventory_sync() -> bool:

	return (
		_inventory_sync_deferred
		or not _inventory_sync_pending.is_empty()
	)


func sync_character(
	character: Character
) -> bool:

	if character == null:
		return false


	if not DatabaseManager.is_ready:
		return false


	print(
		"[CharacterStatePersistence] "
		+ "手動同步 Character：%s | runtime_slots=%d"
		% [
			character.character_id,
			_count_runtime_inventory_slots(
				character
			)
		]
	)


	return _save_character(
		character
	)


func get_all_states() -> Array:

	if not DatabaseManager.is_ready:
		return []


	return DatabaseManager.select(
		STATE_TABLE,
		"",
		[
			"npc_id",
			"satiety",
			"hydration",
			"stamina",
			"wakefulness",
			"hygiene",
			"alcohol",
			"health",
			"injury",
			"location_id"
		]
	)


