---
tags: [交流]
status: 現況
updated: 2026-08-16
---

# SQLite schema 對齊清單

給 SQLite 組員。這是《14 存檔資料存取層規格書》§4 第 3 關「schema 逐欄位核對《06》」的結果。

核對範圍：`Ailley/database/schemas/` 全部 26 張表，對《01》《02》《03》《06》《07》《08》《09》《13》。
**改完這份清單就把它刪掉**，結論該留的部分我會抄進規格書，不要從別的地方引用這則筆記。

**規格書與 schema 不一致時以規格書為準。** 下面每一條都附了規格出處，有疑問先查那一節，不要照我的摘要改。

---

## 0. 一句話結論

第 1 節兩條現在就會讓程式炸掉，先修。第 2 節是欄位落差，MVP 要用到的才急。
第 3 節是「規格書沒有、你自己加的」，要先問過才留。第 4 節是規格書自己矛盾，不是你的問題，我會去修規格書。

---

## 1. 阻斷級：現在就會失敗

### 1-1 `npc_emotion` 的 FK 指向不存在的表

`NPCEmotionSchema.gd`：

```sql
FOREIGN KEY (cause_event_id)
    REFERENCES event_memory(event_id)
```

`event_memory` 這張表整個專案都沒有。`DatabaseManager.gd:29` 有 `db.foreign_keys = true`，
所以建表會過（SQLite 建表時不檢查父表存在），但**任何一筆 INSERT 進 `npc_emotion` 都會失敗**，
錯誤訊息是 `no such table: main.event_memory`。等於情緒表完全不能用。

《14》§4 第 2 關（連線、寫入一筆假資料、讀回來）如果照著跑，這條會第一個被抓到。

| 選項 | 得到 | 失去 |
| --- | --- | --- |
| 拿掉這條 FK，`cause_event_id` 留成純 TEXT | 一行刪掉就能動；規格書本來就沒有 event 表 | 沒有參照完整性，寫進去的 event id 可能是孤兒 |
| 補一張 `event_memory` 表 | 有完整性 | 規格書沒有這張表，等於自己發明資料模型（違反《06》§使用方式）|
| 改指 `memories(memory_id)` | 有現成父表 | ID 格式對不上——《06》§4 命名約定寫 `evt_1043`，`memories` 用的是 `mem_004821`，語意也不同 |

> 建議：拿掉 FK —— 《03》定義的是記憶不是事件，專案裡沒有「事件」這層資料模型，
> 現在補一張表等於在規格書沒定案的地方先寫死。

順帶一提，`DatabaseSchema.gd` 的註解說「有 FK 的表必須在被參照的表之後建立」。
SQLite 其實不管 CREATE 順序，只管 DML 當下父表在不在。這條註解會誤導人，順手改掉。

### 1-2 `npc_state` 的 range 是 0.0–1.0，規格是 0–100

`NPCStateSchema.gd` 有 5 欄的 CHECK 跟預設值都錯：

| 欄位 | 目前 CHECK | 目前預設 | 《01》§4-1 規定 | 預設應為 |
| --- | --- | --- | --- | --- |
| `satiety` | 0.0–100.0 ✔ | 100.0 ✔ | 0–100 | 100 |
| `hydration` | 0.0–100.0 ✔ | 80.0 ✔ | 0–100 | 80 |
| `stamina` | **0.0–1.0** | **1.0** | 0–100 | **80** |
| `wakefulness` | 0.0–100.0 ✔ | 90.0 ✔ | 0–100 | 90 |
| `hygiene` | **0.0–1.0** | **1.0** | 0–100 | **70** |
| `alcohol` | **0.0–1.0** | **0.0** ✔ | 0–100 | 0 |
| `health` | **0.0–1.0** | **1.0** | 0–100 | **100** |
| `injury` | **0.0–1.0** | **0.0** ✔ | 0–100 | 0 |

這條《99》P-32 已經拍板過了（2026-08-16，決議「最終 range 定為 0–100，只有 SQLite 原型要跟著改」），
理由是 `Ailley/scripts/character/stats.gd` 跟規格書兩邊本來就都是 0–100，改那兩邊成本高、改這裡是零成本。

不改的後果不是「數字比例不同」，是引擎寫 `health = 88` 直接被 CHECK 擋掉、整筆 INSERT 失敗。

---

## 2. 欄位落差

### 2-1 `npc`

| # | 問題 | 規格出處 | 動作 |
| --- | --- | --- | --- |
| 1 | 缺 `home_location_id` | 《01》§1-1（**必填**）、《07》§1 | 補 `TEXT NOT NULL`，FK → `location(location_id)`。`move`/`sleep` 對 `loc_home` 的實際目標靠這欄解析，缺了 MVP 的「家」這個地點就不能用 |
| 2 | 缺 `decision_source` | 《06》L0、《13》§三 MVP-1 | 補 `TEXT NOT NULL DEFAULT 'local' CHECK (decision_source IN ('local','cloud','human'))`。投放後不可改 |
| 3 | 缺 `model_name` | 《06》L0、《13》§三 MVP-1 | 補 `TEXT DEFAULT ''`。供角色面板顯示，投放後不可改 |
| 4 | `words_to_creator` 只有 `content` 跟 `is_spoken` | 《01》§1-4 | 缺 `generated_at`、`spoken_at`、`trigger` 三欄。`trigger` 規格標【待定】，欄位先留 NULL |
| 5 | `age DEFAULT 18`，且無範圍檢查 | 《01》§1-1 | 預設改 30，補 `CHECK (age BETWEEN 16 AND 70)` |
| 6 | `character` 無長度檢查 | 《01》§1-3 | 補 `CHECK (LENGTH(character) <= 250)` |
| 7 | `words_to_creator` 無長度檢查 | 《01》§1-4 | 補 `CHECK (LENGTH(words_to_creator) <= 60)` |
| 8 | `village_id` 沒有父表 | 《10》 | MVP 單機、單村，先不管。但 `DEFAULT 'default_village'` 這個魔術字串要記在《99》，不要讓它變成事實標準 |

### 2-2 `npc_relations`　← 這張要瘦身

規格對每個認識的人**只留一項引擎欄位 `trust`**。`affinity`／`familiarity`／`debt`
在 2026-08-16 全庫查過引擎消費者後拿掉了（《01》§3-1、《02》§1-1 的 note）——
理由是《00》原則三：這三項從沒被任何公式讀取過，只被寫入、餵給 AI 看。

| # | 問題 | 動作 |
| --- | --- | --- |
| 1 | 多了 `relations_affinity`、`relations_familiarity`、`relations_debt` | 三欄刪掉 |
| 2 | 缺 `appearance_cache` | 補 `TEXT DEFAULT '' CHECK (LENGTH(appearance_cache) <= 20)`，見《06》L2、《01-3》 |
| 3 | `relations_trust DEFAULT 0` | 規格預設是 **20**（《01》§3-1） |
| 4 | 欄位名帶 `relations_` 前綴 | 規格的欄位名是 `trust`。《01》文件性質那行寫「本文件的英文欄位名為跨組唯一依據，不得各自命名」。表名已經是 `npc_relations`，前綴是重複的 |

### 2-3 `npc_condition`

`type` 的 enum 缺 `bleeding`（《02》§2-2，2026-08-16 新增）。

`bleeding` 跟 `injured` 是同一個 `injury` 數值的兩個門檻，不是兩套機制：
`injury > 0` → `injured`，`injury >= 20` → 額外疊 `bleeding`。兩個都是「門檻自動」，
每 tick 重新檢查、條件不成立自動移除。所以 DB 這邊只要 enum 加一個值就好，不用另外開欄位。

其餘 13 個值都對得上（含 `detained`／`outcast`／`petrified`）。

### 2-4 `npc_goal` 與 `npc_last_action` 記了同一件事

《06》L3 只定義兩樣東西：`current_goal`（string，≤40 字）跟 `last_action_result`（4 欄的 object）。

現在 DB 開了兩張表都在記上次動作：

```
npc_goal          current_goal, last_action, last_target, is_success, action_reason
npc_last_action   action_type, action_description, action_result, location_id,
                  target_npc_id, target_item_id, success, action_started_at, action_finished_at
```

`last_action`/`last_target`/`is_success`/`action_reason` 跟
`action_type`/`target_npc_id`/`success`/`action_result` 是同一組資料的兩套命名。
兩邊都能寫，遲早會不一致，而且誰是真相沒有定義。

另外 `npc_goal` 是 `AUTOINCREMENT` 加一個非唯一 index，同一個 NPC 可以有多筆 `current_goal`，
但規格的 `current_goal` 是單一字串。

| 選項 | 得到 | 失去 |
| --- | --- | --- |
| 留 `npc_last_action`，`npc_goal` 砍到只剩 `current_goal` | 一表一責，欄位名可直接對齊《06》 | 要搬 `action_reason` 的那個 CHECK 過去 |
| 留 `npc_goal`，砍掉 `npc_last_action` | 改動最小 | `npc_last_action` 的 `location_id`／`target_item_id`／起訖時間會一起消失，那些欄位規格沒有但引擎大概會想要 |

> 建議：第一個 —— `npc_goal` 砍成 `npc_id TEXT PRIMARY KEY` ＋ `current_goal TEXT`（加 `CHECK (LENGTH(current_goal) <= 40)`），
> `npc_last_action` 欄位名對齊《06》改成 `action`／`target`／`success`／`reason`，
> 並把 `npc_goal` 現有的 `action_reason` CHECK（失敗時 reason 必填）搬過去 —— 那條 CHECK 本身是對的，
> 《01》§4-3 明講 `reason` 必填且要中文自然語言，值得留著。

### 2-5 `npc_daily_plan` 分不出是哪一天的計畫

`today_plan` 是 LLM 睡醒時填的當日計畫（《01》§4-3、《06》L3）。現在表裡沒有任何欄位表示「哪一天」，
`created_at` 是現實世界時間，換算不出遊戲日。跑到第二天，昨天的計畫跟今天的會混在同一個 `npc_id` 底下。

補 `game_day INTEGER NOT NULL`。順序靠 `plan_id` 遞增可以，不用另外開排序欄。

### 2-6 `memories` 缺遊戲時間

《03》§2 的記憶結構有 `created_tick`、`created_day`、`location_id`，DB 三個都沒有，只有 `created_at`（現實時間）。

這不是可有可無：《03》§4-1 的衰減公式是「**每遊戲日**執行一次」，
《03》§3 的 L2 淘汰規則是「三日後若未被檢索則淘汰」。兩條都要遊戲日，現實時間算不出來。

補 `created_tick INTEGER NOT NULL`、`created_day INTEGER NOT NULL`、`location_id TEXT`（FK → location）。

其餘欄位都對得上：`level` 1–4 ✔、`content` ≤60 ✔、`valence` 三值 ✔、`importance` 0–100 ✔、
`decay_value` ✔、`embedding` ✔、`related_npcs` 拆成獨立表 ✔。

### 2-7 `npc_inventory` / `npc_home_storage` 沒有格數與堆疊上限

《08》§4：隨身 **36 格**（快捷欄 9 ＋主背包 27），家中 **50 格**，單一堆疊上限 **30 個**。

| # | 問題 | 動作 |
| --- | --- | --- |
| 1 | `slot` 無上界 | `npc_inventory` 補 `CHECK (slot BETWEEN 0 AND 35)` |
| 2 | `slot_index` 無上界 | `npc_home_storage` 補 `CHECK (slot_index BETWEEN 0 AND 49)` |
| 3 | `count` 只有 `>= 0` | 兩張表都補 `CHECK (count BETWEEN 0 AND 30)` |
| 4 | 同一件事兩個欄位名（`slot` vs `slot_index`） | 統一成 `slot` |

《08》§4 規則 3「`carry` 類（有 `durability`）不可堆疊，一件佔一格」是應用層規則，
DB 這邊靠 `item.max_stack` 表達就好，不用寫成 CHECK。

### 2-8 `item` 缺效果數值，`max_stack` 預設錯

| # | 問題 | 規格出處 | 動作 |
| --- | --- | --- | --- |
| 1 | `max_stack DEFAULT 99` | 《08》§4 規則 2 | 上限是 30，預設改 30；`carry` 類的資料列填 1 |
| 2 | 沒地方存腐壞速率 | 《08》§3 各物品表都有「腐壞速率（/tick）」 | 補 `decay_rate REAL NOT NULL DEFAULT 0` |
| 3 | 沒地方存耐久消耗 | 《08》§3 工具表 | 補 `durability_cost INTEGER NOT NULL DEFAULT 0` |
| 4 | 沒地方存回復量 | 《08》§3：麥酒加 `alcohol`、烤肉加 `satiety`、水加 `hydration` | 補 `effect_satiety` / `effect_hydration` / `effect_alcohol`，三個 `INTEGER NOT NULL DEFAULT 0` |
| 5 | `item_type` 無 enum | 《08》§2 有分類清單 | 補 CHECK，值以《08》§2 為準 |

第 2～4 點不補的話，這些數字只能硬寫進 GDScript，等於《08》§3 那幾張表在程式裡再抄一份。

### 2-9 `location` 只有名字，缺引擎要用的四個數值

《07》§1-1 定義的地點結構有 `capacity`、`danger`、`resources`、`regen`、`available_actions`、`carryable`，
DB 一個都沒有。其中兩個有明確的引擎消費者：

- `capacity`：滿員則無法進入（《07》§1-1）
- `danger`：0–100，**扣減行為成功率**（《07》§1-1、公式在《01-2》）

沒有這兩欄，《01-2》的成功率公式算不出來。至少補這兩個 `INTEGER`。

`resources`／`regen`／`available_actions` 是陣列與 map，關聯式表要拆子表。
但它們是**靜態設定**，不是存檔資料——15 個地點的內容整局不會變。

| 選項 | 得到 | 失去 |
| --- | --- | --- |
| 全部入庫（含子表） | 一個地方查得到全部 | 多三張表，且每次改地點設定要跑 migration |
| 只入庫會變動的（`capacity`／`danger`／`is_active`），靜態清單留 JSON | 表少、改設定不用碰 DB | 地點資料散在兩處 |

> 建議：第二個 —— 這些是設定不是存檔，《14》§2.2 講的粒度是「一次讀寫一個角色或一個世界」，
> 靜態地點清單本來就不在存讀檔的範圍裡。

另外 `description` 這個欄位名，規格《07》§1-1 用的是 `desc`。挑一個，然後兩邊統一。

### 2-10 `npc_appearance` 兩邊都對不上

- DB：固定 5 欄 `hair_id` / `face_id` / `clothes_id` / `decoration1_id` / `decoration2_id`
- 《01》§1-2：`appearance[]` 陣列，每筆 `{slot, item_id, label}`，slot 清單標【待規劃】
- 《13》§三 MVP-1：外觀**不拆 slot**，改提供**固定 6 套「造型組」整套挑選**，素材先用佔位圖

MVP 要的其實是一欄：造型組編號。現在這 5 欄是介於「拆 slot」跟「整套挑」之間的第三種做法，兩份規格都沒有。

還缺 `label`（≤20 字的中文短句）——《01》§1-2 明講「**組 Prompt 時使用的就是這個**」，
以及 `build_appearance_text()` 產生的快取字串（存檔時算一次，外觀變更時重算）。

> 建議：MVP 收斂成 `outfit_id TEXT` ＋ `appearance_text TEXT`（快取字串）兩欄，
> 完整的 slot 陣列等《99》P-01 定案再回來做。改之前先跟我確認，這條牽涉到《05》建角面板。

### 2-11 `npc_taboo` 欄位比規格多

《01》§1-1：`taboos` 是**字串陣列**，例「絕不向人乞討」。

DB 有 `taboo_type` / `description` / `severity` / `is_active` 四欄。`description` 對應規格的字串，
其餘三欄規格沒有。

`severity`（0–100）這欄要特別拉出來講：**這是引擎替 AI 的禁忌預先定性「有多嚴重」**。
按 CLAUDE.md 的「AI 自主性自檢」與《00》原則二（引擎只給事件，不給情緒），
這種欄位要先拋出來拍板才能進規格書，不能因為它只存在後端就當作不受這條規則管。

我會把這條開成問題丟給決策者。在拍板之前，`severity` 先不要接上任何引擎公式。

### 2-12 `updated_at` 永遠不會更新

大約 12 張表有 `updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP`，但沒有任何 UPDATE trigger。
DEFAULT 只在 INSERT 時生效，之後 UPDATE 這欄不會動，除非呼叫端每次自己帶。

`DatabaseManager.update()` 沒有自動塞這欄。所以現在 `updated_at` 實際上是第二個 `created_at`。

| 選項 | 得到 | 失去 |
| --- | --- | --- |
| 每張表加 `AFTER UPDATE` trigger | 呼叫端不用記得 | 12 個 trigger 要維護，且 trigger 裡的邏輯在 SQL 不在 GDScript，除錯要另外開工具看 |
| `DatabaseManager.update()` 統一塞 `updated_at` | 一個地方改完全部 | 繞過 `update()` 直接下 SQL 的路徑不會被涵蓋 |
| 砍掉 `updated_at` | 少 12 欄 | 之後真的要查「這筆多久沒動」時要重加 |

> 建議：第二個 —— `DatabaseManager.update()` 只有一處，加三行就好；
> 專案的紀律本來就是「CRUD 一律走 addon 的 insert_row / update_rows」（`DatabaseManager.gd` 開頭的註解），
> 繞過去的路徑本來就該被 code review 擋下來。

---

## 3. 規格書沒有、DB 有的

《06》§使用方式：「這裡沒有的欄位，代表還沒定案，先問過再加。」下面幾張表都落在這條。
不是說做錯，是**先問過**這步跳掉了。

| 表 | 狀況 | 建議 |
| --- | --- | --- |
| `money_transaction` | 規格書沒有交易歷史。《08》§5 只定義交易規則，不要求保存流水 | MVP 先不建。`技術/存檔` 有提到「經濟交易歷史」是 SQLite 未來該接手的部分，那是發表後的事（《14》§4「發表後」） |
| `item_transaction` | 同上 | 同上 |
| `npc_occupation` | 《01》§1-5 的 `occupation` 標【待決策】，只預留 `{id, name, since_day}` 三欄，並明講「角色無預設職業綁定，工作行為由 AI 自行選擇」。DB 建了 11 欄的完整職業系統（`salary`／`workplace_id`／`work_start_time`／`working_days`／`is_employed`）。而且《13》§三 MVP 把工作簡化成「單一工作站，站著即可賺錢」，用不到這些 | 砍到規格預留的三欄，或整張表暫緩。追蹤在《99》P-02 |
| `npc_schedule` | 規格書裡沒有這張表。`Ailley/data/npc_schedule.json` 有個同名的靜態設定檔 | 先講清楚它要取代那個 json 還是別的東西。行程佇列的設計在《技術/行程佇列與任務仲裁》，那是 runtime 結構不是存檔 |
| `npc_death`／`grave`／`grave_highlights`／`grave_epitaphs` | 欄位跟《09》對得上，但《13》§三寫「**MVP 不做死亡／安葬／墓園全套**」，改用「昏迷」 | 不用刪，但別再花時間補。確認 `DatabaseSchema.initialize()` 建這 4 張表不會拖慢啟動就好 |

另外規格書有、DB 完全沒有的：

- **`appointment`**（《06》L3、《10》§5.5）：`with` / `location` / `game_time` 三欄。
  `npc_schedule` 不是它——那是預定行程，`appointment` 是 AI 自己跟別人約好的事，開放時機由《12》§2.4 的條件式 schema 控制。
  MVP 要不要做，我去確認《13》，先不要動手。

### 3-1 兩處資料重複

`words_to_creator` 同時存在 `npc` 跟 `grave` 兩張表。《09》§4-2 講得很明白，墓碑上刻的
就是**建角時生成的那一句**，不是另外生成的。這裡應該 JOIN，不該複製一份——複製之後兩邊會漂移，
而且沒有規則說哪邊是真相。`grave.words_to_creator` 刪掉。

`death_cause` 與 `last_words` 也同時在 `npc_death` 跟 `grave`，同一個問題。
`npc_death` 是死亡當下的紀錄、`grave` 是墓碑內容，《09》§2 與 §4-1 兩份 JSON 確實都列了這兩欄，
但來源是同一次死亡事件。建議 `grave` 這邊改 JOIN。

反過來，`npc_death` 缺 `grave_id`（《09》§2 有）。現在只能從 `grave.npc_id` 反查，規格是雙向的。

---

## 4. 規格書自己矛盾，我去修

這幾條不用你判斷，也不要照《06》改：

| 項目 | 《06》 | 《01》§3-3 與《08》§4 | 以哪邊為準 |
| --- | --- | --- | --- |
| `inventory` 上限 | ≤8 格 | **36 格**（快捷欄 9 ＋主背包 27） | 《08》 |
| `home_storage` 上限 | ≤20 格 | **50 格** | 《08》 |

《06》那兩個數字是舊值沒跟上，兩份文件對一份，而且《08》§4 是這件事的定義文件。
我會去改《06》。你照 36 / 50 做。

---

## 5. 建議的做事順序

按《14》§4 的四關驗證來排，不要平行做：

- [ ] **第 1 步**　修 §1-1（FK）跟 §1-2（range）—— 這兩條不修，第 2 關「寫入一筆假資料、讀回來」跑不過
- [ ] **第 2 步**　跑第 2 關，每張表各寫一筆讀一筆。26 張表都要，不要只測 `npc`
- [ ] **第 3 步**　修 §2 的欄位落差，MVP 用得到的優先：`npc`（2-1）→ `npc_state` → `npc_relations`（2-2）→ `npc_condition`（2-3）→ `memories`（2-6）→ `npc_inventory`（2-7）
- [ ] **第 4 步**　§3 那幾張表先別動，等問過再說
- [ ] **第 5 步**　重跑第 4 關（完整匯出成執行檔再測一次連線讀寫）。§1-2 動到 CHECK，匯出後要重驗

`CREATE TABLE IF NOT EXISTS` 的關係：改了欄位定義之後，**既有的 `user://game.db` 不會自己更新**，
也不會報錯，它會安靜地繼續用舊 schema。測之前先把那個檔案刪掉，不然你會以為改好了。

---

## 6. 要拍板的兩件事

這兩條我不自己決定，等回覆：

1. **`npc_taboo.severity`**（見 §2-11）—— 引擎替禁忌預先定性「有多嚴重」，違反《00》原則二與 CLAUDE.md 的 AI 自主性自檢。留還是砍？
2. **`npc_appearance` 的形狀**（見 §2-10）—— MVP 的「固定 6 套造型組」對應到 DB 應該是一欄 `outfit_id`，
   還是保留現在的 5 個 slot 欄位？這條牽涉《05》建角面板，改之前要對齊。
