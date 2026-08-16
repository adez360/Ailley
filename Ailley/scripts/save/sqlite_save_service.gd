extends SaveService
class_name SqliteSaveService

## SaveService 的 SQLite 實作，走 DatabaseManager autoload 存取 user://game.db。
## 介面定義見 note/規格書/14_存檔資料存取層規格書.md §2，資料形狀見《06 資料欄位對應表》§1。
##
## 目前是骨架：四個函式的資料形狀與該讀寫哪幾張表已經定下來（寫在下面的
## TODO 裡），實際的 DatabaseManager 呼叫留給後續 issue 填。
##
## 《14》§5 要求兩個實作的資料形狀必須一致 —— 這裡回傳／接收的 Dictionary
## 一律以《06》§1 的 JSON 結構為準，不因為 SQLite 分表就換一套形狀：
## 攤平的工作在這一層做完，呼叫端看不到 npc / npc_state / npc_relations 的存在。
##
## 缺值一律補《06》的預設值（見各欄位「範圍」欄），不回傳 null 也不省略 key ——
## 少一個 key 跟值是預設值，對呼叫端是兩種不同的東西。
##
## 整包讀寫，不做局部欄位更新（《14》§2.2）。save_* 一律包在
## DatabaseManager.begin_transaction() / commit_transaction() 裡，
## 中途任何一張表失敗就 rollback_transaction()。


## 讀一個角色的完整資料，找不到回傳空 Dictionary
##
## 回傳形狀（《06》§1）：
##     {
##       "identity": { id, name, age, gender, village_id, appearance[],
##                     character, words_to_creator{}, taboos[], occupation{},
##                     home_location_id, decision_source, model_name, created_at },
##       "hexaco_input": { hex_honesty … hex_openness },
##       "personality":  { diligence … honesty },
##       "system_prompt": String,
##       "relations": { <target_id>: { trust, appearance_cache } },
##       "reputation": int,
##       "economy": { money, inventory[], home_storage[] },
##       "state": { physical{}, emotion{}, conditions[], current_goal,
##                  today_plan[], appointment{}, last_action_result{}, location_id },
##       "memory": { … 見《03》 }
##     }
##
## TODO 各區塊的來源表，一律 DatabaseManager.select(table, "npc_id = '%s'" % id)：
##     identity        npc（npc_id/name/age/gender/village_id/character/reputation/
##                     system_prompt/words_to_creator/is_spoken/created_at）
##                     ＋ npc_appearance、npc_occupation、npc_taboo（is_active = 1）
##     hexaco_input    npc_personality 的 hex_* 六欄
##     personality     npc_personality 的其餘十欄
##     relations       npc_relations，條件是 character_id = id（不是 npc_id），
##                     每筆攤成 { target_id: { "trust": relations_trust } }
##     economy         npc_wallet.money、npc_inventory、npc_home_storage
##     state.physical  npc_state 八欄
##     state.emotion   npc_emotion
##     conditions      npc_condition
##     today_plan      npc_daily_plan，is_done → done
##     location_id     npc_state.location_id
##     memory          memories（level / content / valence / importance /
##                     decay_value）＋ memory_related_npcs
##
## TODO npc 這一筆撈不到就回傳 {}，不要回傳只有預設值的空殼 ——
##      呼叫端分不出「這個角色不存在」跟「這個角色什麼都沒填」。
##
## TODO 下列欄位《06》有、schema 沒有對應的欄位或表，先補預設值，
##      實際要不要加欄位見本檔最下方的「schema 缺口」：
##      identity.home_location_id / decision_source / model_name、
##      words_to_creator 的 generated_at / spoken_at / trigger、
##      relations.*.appearance_cache、emotion.duration_left、state.appointment
func get_character(id: String) -> Dictionary:
	# TODO 實作：撈上列各表、攤平成上面的形狀
	return super.get_character(id)


## 寫入一個角色的完整資料（整包覆蓋，不做局部欄位更新）
##
## 收的 Dictionary 形狀跟 get_character() 回傳的一致。
##
## TODO 寫入順序（外鍵：npc 必須先在，其餘表才插得進去）：
##      1. begin_transaction()
##      2. npc：DatabaseManager.select 查有沒有這筆 →
##         有就 update(…, "npc_id = '%s'" % id)，沒有就 insert()
##      3. 一對一的表（npc_state / npc_emotion / npc_appearance /
##         npc_occupation / npc_last_action / npc_personality / npc_wallet）
##         同樣是先查再 update／insert
##      4. 一對多的表（npc_taboo / npc_condition / npc_daily_plan /
##         npc_inventory / npc_home_storage / npc_relations / memories）
##         先 delete(table, "npc_id = '%s'" % id) 再整批 insert()，
##         因為介面粒度是整包覆蓋，殘留的舊列等於髒資料。
##         npc_relations 的條件欄位是 character_id，不是 npc_id
##      5. commit_transaction()；中途任何一步 false 就 rollback_transaction()
##         並回傳 false
##
## TODO 《14》§2 要求的並行寫入保護（version 欄位 ＋ compare-and-swap）
##      目前沒有掛靠欄位 —— npc 表沒有 version。見下方「schema 缺口」。
func save_character(id: String, data: Dictionary) -> bool:
	# TODO 實作：照上面的順序寫入
	return super.save_character(id, data)


## 讀一個世界的完整資料
##
## 回傳形狀（《技術/存檔》「兩層：角色與世界」，《06》未定義世界層）：
##     {
##       "world_id": String,
##       "day": int,                  GameClock.day，見《技術/存檔》「兩個前置」
##       "allow_player_join": bool,   建立世界時決定，不是「現在有沒有 player」
##       "locations": [ { location_id, name, description, location_type, is_active } ],
##       "items":     [ { item_id, name, item_type, base_price, … } ]
##     }
##
## TODO locations ← DatabaseManager.select("location")、
##      items ← DatabaseManager.select("item")，兩張都是整表撈，沒有 WHERE。
##
## TODO world_id / day / allow_player_join 目前沒有任何表裝 ——
##      整個世界層在 schema 裡是空的。見下方「schema 缺口」。
func get_world(id: String) -> Dictionary:
	# TODO 實作：等世界層的表建好
	return super.get_world(id)


## 寫入一個世界的完整資料
##
## TODO 跟 save_character() 同一套：begin_transaction() → location / item
##      各自先 delete 再整批 insert → commit_transaction()，失敗 rollback。
##      world_id / day / allow_player_join 等世界層的表建好才寫得下去。
func save_world(id: String, data: Dictionary) -> bool:
	# TODO 實作：等世界層的表建好
	return super.save_world(id, data)


## ===================================================================
## schema 缺口
##
## 下列是《06》／《技術/存檔》有、Ailley/database/schemas/ 沒有的東西。
## 骨架先用預設值頂著，實際補欄位要先拍板（登記在《99 待規劃項目清單》）：
##
## 世界層整層沒有表     world_id / day / allow_player_join 無處可存，
##                      get_world()／save_world() 現在只搬得動 location 與 item
## npc 沒有 version     《14》§2 要求的並行寫入保護沒有掛靠欄位
## npc_relations        多了 affinity / familiarity / debt 三欄，《06》已把它們
##                      拿掉（見《99》2026-08-16 01§3-1）；少了 appearance_cache
## npc_appearance       是 hair_id / face_id / clothes_id 三個定欄，
##                      《06》的 appearance 是 { slot, item_id, label } 陣列
## npc_occupation       欄位是 occupation / occupation_level / workplace_id …，
##                      《06》的 occupation 是 { id, name, since_day }
## npc_state 的 range   stamina / hygiene / health 預設 1.0，是 0.0–1.0；
##                      《99》P-32 已拍板統一為 0–100
## identity 三個欄位     home_location_id / decision_source / model_name 無欄位
## words_to_creator     只有 content 與 is_spoken，
##                      缺 generated_at / spoken_at / trigger
## emotion              缺 duration_left
## state.appointment    整組（with / location / game_time）沒有表
## ===================================================================
