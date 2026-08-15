extends Node
class_name SaveService

## 存讀角色／世界資料的唯一入口，定義於 note/規格書/14_存檔資料存取層規格書.md §2。
##
## 呼叫端（角色生成、睡眠反思寫回、debug console 等）一律只呼叫這四個函式，
## 不直接使用 FileAccess 或任何資料庫 API —— 存取邏輯只能在這個介面的實作裡。
##
## 兩個實作：
##     JsonSaveService     每個角色／世界各自一個 JSON 檔（本次發表使用）
##     SqliteSaveService   走 SQLite（Ailley/database/），非阻塞、平行開發中
##
## 遊戲啟動時決定要用哪個實作、掛成全域 autoload，呼叫端不需要知道也不需要
## 判斷目前是哪一個。粒度是整包讀寫（見《14》§2.2），不支援局部欄位更新。


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


## 讀一個世界的完整資料
func get_world(id: String) -> Dictionary:
	push_error("SaveService: get_world 未實作")
	return {}


## 寫入一個世界的完整資料
func save_world(id: String, data: Dictionary) -> bool:
	push_error("SaveService: save_world 未實作")
	return false
