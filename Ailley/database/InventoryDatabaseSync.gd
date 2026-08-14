class_name InventoryDatabaseSync
extends Node


## ============================================================
## InventoryDatabaseSync
##
## 正式遊戲：
##
## 販賣機
##   ↓
## VendingMenu
##   ↓
## Character.buy_from()
##   ↓
## Inventory.spend()
## Inventory.add_item()
##   ↓
## Inventory.changed
##   ↓
## InventoryDatabaseSync
##   ↓
## DatabaseManager
##   ↓
## SQLite / npc_inventory
##
## 同時負責：
##
## SQLite → Inventory
##
## 遊戲重新啟動時：
##
## SQLite
##   ↓
## npc_inventory
##   ↓
## InventoryDatabaseSync
##   ↓
## Player.Inventory
## ============================================================


const PLAYER_NPC_ID := "player"


## ------------------------------------------------------------
## 目前販賣機使用的商品
##
## 這些 item_id 必須先存在 item table，
## npc_inventory 才能寫入。
## ------------------------------------------------------------

const VENDING_ITEMS := {
	"bread": {
		"name": "bread",
		"item_type": "food",
		"description": "販賣機出售的麵包",
		"base_price": 12,
		"max_stack": 99,
		"is_consumable": 1,
		"is_perishable": 1,
		"is_active": 1
	},

	"water": {
		"name": "water",
		"item_type": "drink",
		"description": "販賣機出售的水",
		"base_price": 2,
		"max_stack": 99,
		"is_consumable": 1,
		"is_perishable": 0,
		"is_active": 1
	},

	"wild_fruit": {
		"name": "wild_fruit",
		"item_type": "food",
		"description": "販賣機出售的野果",
		"base_price": 8,
		"max_stack": 99,
		"is_consumable": 1,
		"is_perishable": 1,
		"is_active": 1
	},

	"ale": {
		"name": "ale",
		"item_type": "drink",
		"description": "販賣機出售的啤酒",
		"base_price": 10,
		"max_stack": 99,
		"is_consumable": 1,
		"is_perishable": 0,
		"is_active": 1
	}
}


## ------------------------------------------------------------
## Runtime references
## ------------------------------------------------------------

var database_manager: Node
var player: Character
var inventory: Inventory

var _save_queued := false


## ============================================================
## Ready
## ============================================================

func _ready() -> void:

	print(
		"[InventoryDatabaseSync] Initializing..."
	)

	# --------------------------------------------------------
	# 找 Main/SQLite
	# --------------------------------------------------------

	database_manager = get_parent().get_node_or_null(
		"SQLite"
	)

	if database_manager == null:

		push_error(
			"[InventoryDatabaseSync] "
			+ "找不到 Main/SQLite。"
		)

		return

	# --------------------------------------------------------
	# 等 DatabaseManager 完成 _ready()
	# --------------------------------------------------------

	await get_tree().process_frame

	if not bool(
		database_manager.get("is_ready")
	):

		push_error(
			"[InventoryDatabaseSync] "
			+ "DatabaseManager 尚未 Ready。"
		)

		return

	# --------------------------------------------------------
	# 確保 item
	# --------------------------------------------------------

	if not _ensure_items():

		push_error(
			"[InventoryDatabaseSync] "
			+ "Item initialization failed."
		)

		return

	# --------------------------------------------------------
	# 找 Player
	# --------------------------------------------------------

	player = get_tree().get_first_node_in_group(
		"characters"
	) as Character

	if player == null:

		# 如果 characters group 找不到，
		# 再直接找 Player 節點。

		var player_node := get_parent().get_node_or_null(
			"Node2D/Player"
		)

		if player_node is Character:
			player = player_node as Character

	if player == null:

		push_error(
			"[InventoryDatabaseSync] "
			+ "找不到 Player。"
		)

		return

	# --------------------------------------------------------
	# 取得 Player.Inventory
	# --------------------------------------------------------

	inventory = player.inventory

	if inventory == null:

		push_error(
			"[InventoryDatabaseSync] "
			+ "Player 沒有 Inventory。"
		)

		return

	# --------------------------------------------------------
	# 建立 player NPC
	# --------------------------------------------------------

	if not _ensure_player():

		push_error(
			"[InventoryDatabaseSync] "
			+ "Player NPC initialization failed."
		)

		return

	# --------------------------------------------------------
	# 監聽 Inventory.changed
	# --------------------------------------------------------

	if not inventory.changed.is_connected(
		_on_inventory_changed
	):

		inventory.changed.connect(
			_on_inventory_changed
		)

	print(
		"[InventoryDatabaseSync] "
		+ "Player Inventory connected."
	)

	# --------------------------------------------------------
	# 啟動時從 SQLite 還原
	# --------------------------------------------------------

	_load_inventory()

	print(
		"[InventoryDatabaseSync] Ready."
	)


## ============================================================
## 建立販賣機商品
## ============================================================

func _ensure_items() -> bool:

	for item_id in VENDING_ITEMS:

		# ----------------------------------------------------
		# 注意：
		# database_manager 是 Node，
		# 因此這裡一定要明確指定 Array。
		# ----------------------------------------------------

		var rows: Array = database_manager.select(
			"""
			SELECT item_id
			FROM item
			WHERE item_id = '%s';
			"""
			% _escape(item_id)
		)

		if not rows.is_empty():
			continue

		var data: Dictionary = VENDING_ITEMS[item_id]

		var insert_success: bool = database_manager.insert(
			"item",
			{
				"item_id": item_id,
				"name": data["name"],
				"item_type": data["item_type"],
				"description": data["description"],
				"base_price": data["base_price"],
				"max_stack": data["max_stack"],
				"is_consumable": data["is_consumable"],
				"is_perishable": data["is_perishable"],
				"is_active": data["is_active"]
			}
		)

		if not insert_success:

			push_error(
				"[InventoryDatabaseSync] "
				+ "建立 item 失敗: "
				+ item_id
			)

			return false

		print(
			"[InventoryDatabaseSync] "
			+ "Created item: "
			+ item_id
		)

	return true


## ============================================================
## 建立 Player NPC
## ============================================================

func _ensure_player() -> bool:

	var rows: Array = database_manager.select(
		"""
		SELECT npc_id
		FROM npc
		WHERE npc_id = '%s';
		"""
		% _escape(PLAYER_NPC_ID)
	)

	if not rows.is_empty():
		return true

	var player_name := player.character_name

	if player_name.is_empty():
		player_name = "player"

	var insert_success: bool = database_manager.insert(
		"npc",
		{
			"npc_id": PLAYER_NPC_ID,
			"name": player_name,
			"age": 18,
			"gender": "other",
			"village_id": "default_village",
			"character": "Player",
			"reputation": 0,
			"system_prompt": "",
			"words_to_creator": "",
			"is_spoken": 1,
			"is_active": 1
		}
	)

	if insert_success:

		print(
			"[InventoryDatabaseSync] "
			+ "Created player NPC."
		)

	return insert_success


## ============================================================
## Inventory changed
## ============================================================

func _on_inventory_changed() -> void:

	# --------------------------------------------------------
	# 一次購買可能造成兩次 changed：
	#
	# spend()
	#   ↓ changed
	#
	# add_item()
	#   ↓ changed
	#
	# 所以不能每次 changed 都立刻寫 DB。
	#
	# 使用 call_deferred 合併同一幀的異動。
	# --------------------------------------------------------

	if _save_queued:
		return

	_save_queued = true

	call_deferred(
		"_save_queued_inventory"
	)


## ============================================================
## Deferred Save
## ============================================================

func _save_queued_inventory() -> void:

	_save_queued = false

	if inventory == null:
		return

	_save_inventory()


## ============================================================
## Inventory → SQLite
## ============================================================

func _save_inventory() -> bool:

	if database_manager == null:
		return false

	if not bool(
		database_manager.get("is_ready")
	):
		return false

	# --------------------------------------------------------
	# BEGIN
	# --------------------------------------------------------

	var begin_success: bool = (
		database_manager.begin_transaction()
	)

	if not begin_success:

		push_error(
			"[InventoryDatabaseSync] "
			+ "BEGIN TRANSACTION 失敗。"
		)

		return false

	# --------------------------------------------------------
	# 刪除玩家目前舊背包
	# --------------------------------------------------------

	var delete_success: bool = (
		database_manager.delete(
			"npc_inventory",
			"npc_id = '%s'"
			% _escape(PLAYER_NPC_ID)
		)
	)

	if not delete_success:

		database_manager.rollback_transaction()

		push_error(
			"[InventoryDatabaseSync] "
			+ "清除舊背包失敗。"
		)

		return false

	# --------------------------------------------------------
	# 將目前 Inventory 全部寫入 SQLite
	# --------------------------------------------------------

	for slot_index in Inventory.SIZE:

		var slot: Dictionary = (
			inventory.get_slot(slot_index)
		)

		if slot.is_empty():
			continue

		var item_id := str(
			slot.get("item_id", "")
		)

		var count := int(
			slot.get("count", 0)
		)

		var decay := int(
			slot.get("decay", 0)
		)

		var durability := int(
			slot.get("durability", -1)
		)

		if item_id.is_empty():
			continue

		if count <= 0:
			continue

		# ----------------------------------------------------
		# Inventory stackable item：
		#
		# durability = -1
		#
		# SQLite schema：
		#
		# durability BETWEEN 0 AND 100
		#
		# 所以 DB 中存 100。
		# ----------------------------------------------------

		if durability < 0:
			durability = 100

		var insert_success: bool = (
			database_manager.insert(
				"npc_inventory",
				{
					"npc_id": PLAYER_NPC_ID,
					"slot": slot_index,
					"item_id": item_id,
					"count": count,
					"decay": clampi(
						decay,
						0,
						100
					),
					"durability": clampi(
						durability,
						0,
						100
					)
				}
			)
		)

		if not insert_success:

			database_manager.rollback_transaction()

			push_error(
				"[InventoryDatabaseSync] "
				+ "寫入 slot %d 失敗。"
				% slot_index
			)

			return false

	# --------------------------------------------------------
	# COMMIT
	# --------------------------------------------------------

	var commit_success: bool = (
		database_manager.commit_transaction()
	)

	if not commit_success:

		database_manager.rollback_transaction()

		push_error(
			"[InventoryDatabaseSync] "
			+ "COMMIT 失敗。"
		)

		return false

	print(
		"[InventoryDatabaseSync] "
		+ "Inventory saved to SQLite."
	)

	return true


## ============================================================
## SQLite → Inventory
## ============================================================

func _load_inventory() -> bool:

	if database_manager == null:
		return false

	# --------------------------------------------------------
	# SELECT
	# --------------------------------------------------------

	var rows: Array = database_manager.select(
		"""
		SELECT
			slot,
			item_id,
			count,
			decay,
			durability
		FROM npc_inventory
		WHERE npc_id = '%s'
		ORDER BY slot ASC;
		"""
		% _escape(PLAYER_NPC_ID)
	)

	# --------------------------------------------------------
	# 清空目前 Inventory
	# --------------------------------------------------------

	for i in Inventory.SIZE:
		inventory.slots[i] = {}

	# --------------------------------------------------------
	# 還原 DB
	# --------------------------------------------------------

	for row_variant in rows:

		var row: Dictionary = row_variant

		var slot_index := int(
			row.get("slot", -1)
		)

		if slot_index < 0:
			continue

		if slot_index >= Inventory.SIZE:
			continue

		var item_id := str(
			row.get("item_id", "")
		)

		var count := int(
			row.get("count", 0)
		)

		var decay := int(
			row.get("decay", 0)
		)

		var durability := int(
			row.get("durability", 100)
		)

		if item_id.is_empty():
			continue

		if count <= 0:
			continue

		# ----------------------------------------------------
		# DB 100 對應 Inventory 的 -1
		# ----------------------------------------------------

		if durability >= 100:
			durability = -1

		inventory.slots[slot_index] = {
			"item_id": item_id,
			"count": count,
			"decay": decay,
			"durability": durability
		}

	# --------------------------------------------------------
	# 通知 UI
	# --------------------------------------------------------

	inventory.changed.emit()

	print(
		"[InventoryDatabaseSync] "
		+ "Loaded %d inventory rows."
		% rows.size()
	)

	return true


## ============================================================
## Debug：列出 SQLite 背包
## ============================================================

func print_database_inventory() -> void:

	if database_manager == null:
		return

	var rows: Array = database_manager.select(
		"""
		SELECT
			slot,
			item_id,
			count,
			decay,
			durability
		FROM npc_inventory
		WHERE npc_id = '%s'
		ORDER BY slot ASC;
		"""
		% _escape(PLAYER_NPC_ID)
	)

	print(
		"========== SQLite Inventory =========="
	)

	if rows.is_empty():

		print("(empty)")

	else:

		for row_variant in rows:

			var row: Dictionary = row_variant

			print(
				"slot=%d item=%s count=%d decay=%d durability=%d"
				% [
					int(row.get("slot", -1)),
					str(row.get("item_id", "")),
					int(row.get("count", 0)),
					int(row.get("decay", 0)),
					int(row.get("durability", 100))
				]
			)

	print(
		"======================================"
	)


## ============================================================
## SQL Escape
## ============================================================

func _escape(value: String) -> String:

	return value.replace(
		"'",
		"''"
	)
