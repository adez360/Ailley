---
tags:
  - 技術
  - 存檔
status: 進行中
script: database/DatabaseManager.gd
updated: 2026-08-15
---

# SQLite 儲存層

動態資料的落地方式：`godot-sqlite`（GDExtension），由 GDScript 直接讀寫本機
`user://game.db`。**不架 Python 後端。**

在 [PR #129](https://github.com/adez360/Ailley/pull/129)，尚未合併。
它是骨架 —— 資料表建得起來，但還沒有任何遊戲系統讀寫它，
實際的存讀檔邏輯在 [[存檔]] 的 #21～#23。

## 為什麼是 godot-sqlite

《[[04_Godot與AI資料介接規格]]》《[[12_決策來源抽象與執行架構規格書]]》的舊架構圖
把 SQLite 畫在 Python 後端那一側，但 [[LLM 串接與 AI 服務層]] 已經拍板「出貨不走
Python 後端」。兩者對不上，[#124](https://github.com/adez360/Ailley/issues/124)
把它收斂到 godot-sqlite：

- 跟「不出貨 Python 後端」一致
- [[存檔]] 定案的位置是 `user://`，那是單機內嵌檔案的形狀，
  跟 SQLAlchemy／Alembic 這類給網路服務用的工具不對版
- 《[[00_設計原則與架構]]》已定案「資料儲存：SQLite（動態）＋ JSON（靜態）」

## 怎麼用

autoload `DatabaseManager`（`database/DatabaseManager.gd`）。

```gdscript
DatabaseManager.insert("npc", {"npc_id": id, "name": "Ana"})
DatabaseManager.select("npc", "npc_id = '%s'" % id)          # -> Array[Dictionary]
DatabaseManager.update("npc_wallet", {"money": 300}, "npc_id = '%s'" % id)
DatabaseManager.delete("npc_condition", "npc_id = '%s'" % id)
DatabaseManager.query("UPDATE memories SET decay_value = decay_value - ?", [5])
```

`is_ready` 在資料庫開好、資料表建好之後才是 `true`。沒 ready 時每個方法都會
`push_error` 並回 false／空陣列，不會靜默失敗。

交易用 `begin_transaction()` / `commit_transaction()` / `rollback_transaction()`。

> [!important] 值不要自己拼進 SQL 字串
> `insert` / `update` 的 Dictionary 和 `query()` 的 `bindings` 都是走
> godot-sqlite 的參數綁定。這個專案的記憶內容是 LLM 產的 ——
> 拼字串等於把 query 交給模型改寫。
>
> `conditions` 參數是例外：它是原始 SQL（WHERE 子句，不含 `WHERE`），
> **只能由程式碼自己組**，不可以放模型或玩家輸入的字串。

`update` 與 `delete` 收到空 `conditions` 會直接拒絕並 `push_error` ——
godot-sqlite 拿到空字串是會動整張表的。

## 資料表

25 支 schema、26 張表（`MemorySchema` 一支建兩張），欄位依《[[06_資料欄位對應表]]》。
一張表一支 `.gd`，放 `database/schemas/`，各自提供 `static func create(db) -> bool`。

建立順序由 `DatabaseSchema.initialize()` 決定，**有 FK 的表必須排在被參照的表之後**。
整批包在一個 transaction 裡（SQLite 的 DDL 可以進 transaction），
中間任一張失敗就整個回滾 —— 否則會留下建到一半的資料庫，
而且因為用 `CREATE TABLE IF NOT EXISTS`，下次開機也不會自己修好。

### id 欄位一律 TEXT

`npc_id` / `item_id` / `location_id` 這些都是 TEXT。

宣告成 INTEGER 不會讓 FK 對不上（SQLite 的 FK 比對走父鍵的 affinity），
真正的問題是**儲存類別被靜默轉換**：`'1001'` 進 INTEGER affinity 的欄位會變成整數
1001，進 TEXT 欄位維持字串。於是同一個 id 從這張表讀回來是 int、從那張表讀回來是
String，而 GDScript 的 `1001 == "1001"` 是 false。

## addon 只留桌面平台

`Ailley/addons/godot-sqlite/bin/` 只有 windows / macos / linux，
`gdsqlite.gdextension` 也只列這三個平台。

上游 release 附的 ios / android / web 共 306 MB，其中 271 MB 是
`libgodot-cpp.ios.*.xcframework` —— 那是編 GDExtension 用的靜態庫，
只有 iOS 匯出會讀。整包進版控會讓 repo 從 83 MB 變成四百多 MB，
而且合進 main 之後只能改寫歷史才刪得掉。

要出那些平台時，再從上游 release 補回 `bin/` 檔案與 `.gdextension` 設定。

## 踩過的坑

- **`db.foreign_keys = true` 必須在 `open_db()` 之前設**。addon 是在開檔時才送出
  `PRAGMA foreign_keys`，開完再設沒有效果。
- **失敗訊息在 `db.error_message`**。`db.query()` 只回 bool，
  真正的原因（`near "CHECK": syntax error`、`no such column: x`）在那個 property 裡，
  不印出來的話 24 支 schema 完全沒辦法 debug。
- **schema 是 GDScript class，`str()` 出來是 `<GDScript#...>`**。
  要印是哪張表得用 `schema.resource_path.get_file().get_basename()`。
- **UNIQUE 對可為 NULL 的欄位沒有保護**。SQLite 視 NULL 彼此相異，
  所以 `UNIQUE (npc_id, item_id, slot_index)` 在 `slot_index` 可為 NULL 時
  同一組值塞兩次都會成功。
- **跟 UNIQUE / PRIMARY KEY 重複的 index 不要建**。SQLite 自己會為它們建 b-tree，
  再建一個只是每次寫入多維護一棵樹。複合索引的前綴欄位同理。

## 相關

- [[存檔]] —— 角色／世界兩層切分，實際的存讀檔邏輯在那邊
- [[LLM 串接與 AI 服務層]] —— 「不出貨 Python 後端」的拍板出處
- [[06_資料欄位對應表]] —— 欄位定義的來源
