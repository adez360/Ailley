extends Node

## 存讀角色／世界資料的唯一入口，定義於 note/規格書/14_存檔資料存取層規格書.md §2。
##
## 刻意不宣告 class_name：全域 autoload 也叫 SaveService（掛在
## JsonSaveService 上，見 project.godot），Godot 不允許 class_name 跟
## autoload 撞同一個識別字（"Class X hides an autoload singleton" 開機期
## 直接 Parser Error）。子類別改用路徑繼承：
## extends "res://scripts/save/save_service.gd"
##
## 呼叫端（角色生成、睡眠反思寫回、debug console 等）一律只呼叫這七個函式，
## 不直接使用 FileAccess 或任何資料庫 API —— 存取邏輯只能在這個介面的實作裡。
##
## 兩個實作：
##     JsonSaveService     每個角色／世界各自一個 JSON 檔（本次發表使用）
##     SqliteSaveService   走 SQLite（Ailley/database/），非阻塞、平行開發中
##
## 遊戲啟動時決定要用哪個實作、掛成全域 autoload，呼叫端不需要知道也不需要
## 判斷目前是哪一個。粒度是整包讀寫（見《14》§2.2），不支援局部欄位更新。


## 這個角色有沒有存檔紀錄——只判斷存不存在，不管內容讀不讀得出來。
## 用來跟 get_character() 回傳空 Dictionary 的兩種原因分開：從沒存過
## （這裡回傳 false，呼叫端當成新角色）vs 存過但讀不出來、檔案損毀
## （這裡回傳 true 但 get_character() 仍回傳空，呼叫端要當成讀檔失敗處理）
func has_character(id: String) -> bool:
	push_error("SaveService: has_character 未實作")
	return false


## 讀一個角色的完整資料，找不到回傳空 Dictionary
func get_character(id: String) -> Dictionary:
	push_error("SaveService: get_character 未實作")
	return {}


## 寫入一個角色的完整資料（整包覆蓋，不做局部欄位更新）
##
## 實作需求（見《規格書 14》§2）：
##   - 並行寫入保護：需 version 欄位 ＋ compare-and-swap 或鎖定式 read-modify-write 交易
##   - 版本衝突處理：定義失敗／重試行為，成功時遞增 version
##   - 返回 true（成功）或 false（失敗，含版本衝突）
func save_character(id: String, data: Dictionary) -> bool:
	push_error("SaveService: save_character 未實作")
	return false


## 這個世界有沒有存檔紀錄——語意跟 has_character() 一致，見上方註解
func has_world(id: String) -> bool:
	push_error("SaveService: has_world 未實作")
	return false


## 讀一個世界的完整資料
func get_world(id: String) -> Dictionary:
	push_error("SaveService: get_world 未實作")
	return {}


## 寫入一個世界的完整資料
func save_world(id: String, data: Dictionary) -> bool:
	push_error("SaveService: save_world 未實作")
	return false


## has_world()==true 且 get_world() 非空只代表頂層有解析出東西，不保證巢狀
## 欄位型別正確（例如存檔被手改成 "characters": [] 而不是 {}）。
## GameManager.apply_world_save_data() 對這種情況會 push_error 後跳過角色
## 載入、不是硬性失敗——但主選單只看頂層 is_empty() 判斷「可以繼續」的話，
## 玩家會看到 ContinueButton 可按，實際套用卻悄悄漏掉角色資料。main_menu.gd
## （要不要顯示 Continue）跟 main_scene.gd（要不要套用）共用這個判斷，兩邊
## 對「這份存檔算不算讀得出來」的認定才會一致
func is_world_data_valid(data: Dictionary) -> bool:
	if data.is_empty():
		return false
	# has() 而不是 get(default={})——get_world_save_data() 一定會寫出
	# characters 這個 key（沒有角色也是 {}），完全缺這個 key 代表寫入被截斷
	# 之類的損毀，不是「零角色」的正常情況，不該放行
	return data.has("characters") and data["characters"] is Dictionary
