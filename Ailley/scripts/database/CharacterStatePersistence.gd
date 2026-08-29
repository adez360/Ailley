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


# =====================================================
# Lifecycle
# =====================================================

func _ready() -> void:
	call_deferred("_sync_all_characters")

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

	var success_count := 0

	for node in characters:

		var character := node as Character

		if character == null:
			continue

		if _save_character_state_only(character):
			success_count += 1

	print(
		"[CharacterStatePersistence] 定期同步完成（僅 state/wallet）：%d / %d"
		% [
			success_count,
			characters.size()
		]
	)


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

		if state_ok:

			_log_state(
				"INSERT",
				character,
				state_data
			)

		else:

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

		if state_ok:

			_log_state(
				"UPDATE",
				character,
				state_data
			)

		else:

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
	# 嘗試載入 DB inventory。
	# -------------------------------------------------

	_load_inventory_once(character)


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

		if state_ok:

			_log_state(
				"INSERT",
				character,
				state_data
			)

		else:

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

		if state_ok:

			_log_state(
				"UPDATE",
				character,
				state_data
			)

		else:

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
		# 那一次跑，這裡不重新分配，只是把權威值（DB）同步回來
		if character.home_location_id.is_empty():
			character.home_location_id = db_home_location_id
			return true

		# 記憶體值（可能來自讀檔還原的存檔）跟 DB 現存值不一致：DB 才是
		# _occupied_home_location_ids() 判斷占用的依據，兩邊沒同步會讓
		# round-robin 的占用判斷跟實際分配脫鉤（例如兩人各自「以為」分到
		# 同一間）。用 _resolve_home_location() 驗證／必要時重分配，
		# 結果寫回 DB，不能只在記憶體端悄悄接受讀檔帶回來的值
		# （code review 抓到，PR #727）
		if character.home_location_id != db_home_location_id:
			var resolved_home_location_id := _resolve_home_location(character)
			character.home_location_id = resolved_home_location_id
			if resolved_home_location_id != db_home_location_id:
				DatabaseManager.update(
					NPC_TABLE,
					{"home_location_id": resolved_home_location_id},
					"npc_id = '%s'"
					% DatabaseManager.escape_sql_string(character_id)
				)

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

## 地圖上固定的家數量。MVP／Phase 2 拍板固定 5 間（見 issue #370 決策），
## 不支援依人數上限動態生成，見《99》P-58
const HOME_LOCATION_COUNT := 5
const HOME_LOCATION_PREFIX := "loc_home_"


func _resolve_home_location(
	character: Character
) -> String:

	# seed 一定要排在沿用檢查之前：新 DB（例如剛建立、還沒跑過任何一次
	# _ensure_npc_record()）讀舊存檔時 location 表是空的，沿用檢查若先跑
	# 會查不到任何一列、誤判存檔帶回來的 loc_home_0N 無效，靜默重分配一個
	# 新的——先 seed 好，沿用檢查才有東西可以比對（code review 抓到，PR #727）
	_ensure_home_locations_seeded()


	var value := character.home_location_id


	# 值本身也要驗證是這一批 loc_home_01～loc_home_05 命名，不能只驗證
	# location 表裡「有沒有這一列」——舊 fallback（issue #391 之前）寫的
	# home_001 那類值在 location 表裡也確實有一列，會通過純存在性檢查，
	# 但場景裡沒有同名錨點，has_for()/resolve_for() 永遠解析不到、每次都
	# push_error，而且沒有任何自我修復路徑。這裡驗證命名格式，格式不對的
	# 舊值一律當無效值處理，落到下面重新分配（code review 抓到，PR #727）
	if _is_valid_home_location_id(value):

		var requested_rows := (
			DatabaseManager.select_where(
				"location",
				"location_id = ?",
				[
					value
				],
				[
					"location_id"
				]
			)
		)


		if not requested_rows.is_empty():
			return value


	return _assign_next_home_location()


## value 是不是這一批 loc_home_01～loc_home_05 其中一個合法命名——只檢查
## 格式，不查 DB（DB 存在性由呼叫端另外查）。用來擋掉 issue #391 之前的
## 舊 fallback 值（例如 home_001）與其他任何不屬於這批命名的殘留值
func _is_valid_home_location_id(value: String) -> bool:

	if value.is_empty():
		return false

	if not value.begins_with(HOME_LOCATION_PREFIX):
		return false

	var suffix := value.substr(HOME_LOCATION_PREFIX.length())

	if not suffix.is_valid_int():
		return false

	var index := int(suffix)

	return index >= 1 and index <= HOME_LOCATION_COUNT


## 5 間 loc_home_01~05 是這個 issue 新加的 location 列，只在缺的時候補——
## 已存在（例如上次啟動已經建過）就不動它，避免覆寫掉未來可能加上的
## 客製欄位（名稱／danger 等）
func _ensure_home_locations_seeded() -> void:

	for i in range(1, HOME_LOCATION_COUNT + 1):

		var location_id := (
			"%s%02d" % [HOME_LOCATION_PREFIX, i]
		)

		var rows := DatabaseManager.select_where(
			"location",
			"location_id = ?",
			[location_id],
			["location_id"]
		)

		if rows.is_empty():

			DatabaseManager.insert(
				"location",
				{
					"location_id": location_id,
					"name": "Home %d" % i,
					"description": "",
					"location_type": "home",
					"capacity": 1,
					"danger": 0,
					"is_active": 1
				}
			)


## round-robin：從游標位置沿固定順序找第一間沒有任何現存 npc 記錄佔用的家，
## 分配後游標移到它的下一個位置（mod N）。刪除角色騰出的家會在下一輪
## 巡覽時自然被撿回來，游標本身不回退（《規格書07_地點/家》拍板細節）
func _assign_next_home_location() -> String:

	var cursor := _get_home_cursor()
	var occupied := _occupied_home_location_ids()

	for offset in range(HOME_LOCATION_COUNT):

		var index := (cursor + offset) % HOME_LOCATION_COUNT
		var location_id := (
			"%s%02d" % [HOME_LOCATION_PREFIX, index + 1]
		)

		if not occupied.has(location_id):
			_set_home_cursor((index + 1) % HOME_LOCATION_COUNT)
			return location_id

	# 溢出安全閥，不是刻意設計的同居功能：5 間全滿在 DEPLOY_CAP=5 的
	# 世界人數上限下「理論上」不會發生（見《規格書07_地點/家》），但玩家
	# 本身也會走這條路徑要一間家（見 _ensure_npc_record()），main.tscn
	# 目前仍留有一個沒走 deploy_from_library() 的設計期測試用 Player 節點
	# （見 note/技術/村莊地圖.md），會把實際需求推到 6，讓這裡真的碰得到。
	# home_location_id 在 NPCSchema 是 NOT NULL，回傳空字串會讓
	# _ensure_npc_record() 整筆失敗、state/wallet/inventory 同步永久卡死
	# ——寧可讓這個角色暫時跟游標當下那一間共用，也不要讓整套同步斷掉。
	# 同居本身不是這則拍板的功能（留待《99》P-58 Phase 3/4），這裡只是
	# 容量耗盡時的防呆，push_warning 不是 push_error（code review 抓到，
	# PR #727）
	var overflow_location_id := (
		"%s%02d" % [HOME_LOCATION_PREFIX, cursor + 1]
	)

	_set_home_cursor((cursor + 1) % HOME_LOCATION_COUNT)

	push_warning(
		"[CharacterStatePersistence] "
		+ "5 間家全滿，%s 溢出共用（容量安全閥，非刻意同居設計，見《99》P-58）。"
		% overflow_location_id
	)

	return overflow_location_id


func _occupied_home_location_ids() -> Dictionary:

	var rows := DatabaseManager.select(
		NPC_TABLE,
		"",
		["home_location_id"]
	)

	var occupied := {}

	for row in rows:

		var location_id := str(
			row.get("home_location_id", "")
		)

		if not location_id.is_empty():
			occupied[location_id] = true

	return occupied


func _get_home_cursor() -> int:

	var rows := DatabaseManager.select(
		"home_assignment",
		"id = 1",
		["next_index"]
	)

	if rows.is_empty():
		return 0

	return int(rows[0].get("next_index", 0))


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
# Log
# =====================================================

func _log_state(
	operation: String,
	character: Character,
	state_data: Dictionary
) -> void:

	var message := (
		"[CharacterStatePersistence] %s %s | "
		+ "satiety=%.1f hydration=%.1f stamina=%.1f "
		+ "wakefulness=%.1f hygiene=%.1f alcohol=%.1f "
		+ "health=%.1f injury=%.1f"
	)


	print(
		message
		% [
			operation,
			character.character_name,
			float(
				state_data["satiety"]
			),
			float(
				state_data["hydration"]
			),
			float(
				state_data["stamina"]
			),
			float(
				state_data["wakefulness"]
			),
			float(
				state_data["hygiene"]
			),
			float(
				state_data["alcohol"]
			),
			float(
				state_data["health"]
			),
			float(
				state_data["injury"]
			)
		]
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


