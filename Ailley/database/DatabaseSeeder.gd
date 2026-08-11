class_name DatabaseSeeder
extends RefCounted


## =====================================================
## Database Seeder
##
## 負責：
## 1. 建立必要的初始資料
## 2. 不負責建立資料表
## 3. 不負責開啟 SQLite
##
## DatabaseManager 會把 db 傳進來
## =====================================================


static func initialize(db) -> bool:

	print(
		"[DatabaseSeeder] Starting database seeding..."
	)


	# =================================================
	# 確認資料庫物件
	# =================================================

	if db == null:

		push_error(
			"[DatabaseSeeder] Database object is null."
		)

		return false


	# =================================================
	# 這裡之後放初始資料
	# =================================================
	#
	# 目前先不塞任何遊戲資料。
	#
	# 等所有 Schema 建立成功後，
	# 再逐步加入：
	#
	# location
	# item
	# npc
	# npc_state
	# npc_wallet
	# ...
	#
	# =================================================


	print(
		"[DatabaseSeeder] Seeding completed."
	)

	return true
