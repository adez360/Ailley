---
tags:
  - agent
  - character
scene: scenes/character.tscn
script: scripts/character/character.gd
status: 已實作
updated: 2026-08-29
---

# Character 基底與 Agent

Player 與 Agent 共用同一個基底，移動與動畫是同一份實作 ——
專案那條核心約束「Player 能做到的 Agent 也必須能做到」在這裡是靠繼承強制的，
不是靠自律。移動 API 見 [[尋徑與 Debug 主控台]]。

## 檔案

| 檔案 | 角色 |
| --- | --- |
| `scripts/character/character.gd` | `class_name Character`，共用基底 |
| `scripts/character/player.gd` | `extends Character`，WASD 輸入驅動 |
| `scripts/character/agent.gd` | `extends Character`，行程表驅動 |
| `scenes/character.tscn` | Player／Agent 共用的 Inherited Scene 基底：三向 SpriteFrames、`State`/`Sensing`/`UI` 元件節點、根節點 collision layer/mask |
| `scenes/player.tscn` / `scenes/agent.tscn` | 繼承 `character.tscn`（Godot Inherited Scene），只覆寫各自差異 |

## 分工

基底管「怎麼走、怎麼演」：A\* 移動、三向動畫、卡住偵測、`move_finished` 訊號、
以及元件子節點（`State/Stats`、`State/Relationships`、`State/Inventory`、
`State/Memory`、`Sensing/Vision`、`UI/Bubble`、`UI/WorkProgress`、
`UI/MoneyPopup`，全部 `get_node_or_null`，沒掛也不會壞）。

節點依功能分成三個子節點分類——`State`（數值/關係/背包/記憶）、`Sensing`
（感測）、`UI`（介面）——場景結構跟 `character.gd` 的 `get_node_or_null` 路徑
一一對應。`player.tscn`／`agent.tscn` 用 Inherited Scene 繼承 `character.tscn`，
只覆寫根腳本、collision 半徑，以及 Player 專屬的 `Sensing/InteractArea`／
`UI/WaypointIndicator`（Agent 沒有這兩個節點）。`vision.gd`／
`waypoint_indicator.gd` 用 `owner`（場景根節點）取得所屬 Character，不用
`get_parent()`——分類進子節點後直接父節點不再是 Character 本體（issue #616）。

> [!warning] 三個分類節點必須是 `Node2D`，不能是純 `Node`（issue #673）
> Godot 的 CanvasItem 算 `global_position` 只認緊鄰的父節點
> （`CanvasItem::get_parent_item()` 只查 `get_parent()`，不會往上跳過非
> CanvasItem 節點找）。`State`／`Sensing`／`UI` 底下掛的都是 `Node2D`／
> `Area2D`（`Vision`、`InteractArea`、`Bubble`、`WorkProgress`、
> `MoneyPopup`、`WaypointIndicator`），這三個分類節點只要退回純 `Node`，
> 底下全部斷了座標繼承，`global_position` 卡在自己 `.tscn` 裡存的本地座標，
> 不會跟著角色移動——視野／互動偵測會直接失效，UI 元件會飄在角色出生點附近。
> 曾經因為場景重構誤設成 `Node` 整個系統跑不動，實測數據與修法見 #673。

子類別只覆寫 `_decide_velocity()` 決定「往哪走」：

- **Player** —— 有輸入就用輸入並中斷現有路徑，否則 `super()` 跟隨 A\* 路徑
- **Agent** —— 不覆寫，純粹跟隨行程表下的 `move_to()`

## 身分、名字、行程模板是三件事

| 欄位 | 用途 | 玩家可改 | 可撞名 |
| --- | --- | --- | --- |
| `character_id` | 全遊戲唯一身分。存檔、記憶連結、交誼區靠它指人，內部用不顯示 | 否 | 否 |
| `character_name` | 玩家取的名字，顯示用，指令也用它指名 | 是 | 是 |
| `schedule_template`（僅 Agent） | 用哪份行程資料，對應 `npc_schedule.json` 的鍵 | — | 是 |

任一欄位為空時，`character.gd::_ready()` 對該欄位依序試三層：

| 順位 | 來源 | 給誰用 |
| --- | --- | --- |
| 1 | `@export` 手擺的值 | 場景裡的測試角色 |
| 2 | `npc_schedule.json` 的 `identities`，用**節點名**查表 | 場景裡固定的 NPC（Agent／Agent2） |
| 3 | `character_id` 生成 UUID、`character_name` 退回節點名小寫 | Player 與動態生成的角色 |

「玩家可改」不等於「這一場不會變」：`character_id` 玩家碰不到，但撞號時
`_ensure_unique_id()` 會就地換掉一個，別把它快取在 `_ready()` 之外。

**跨場次是否穩定要看走到第幾層，第 3 層本身又分兩種**：走第 2 層的固定 NPC
每次開遊戲都拿到同一個 id（`identities` 是靜態資料）；走第 3 層的 Player
一樣穩定，但穩定的方式不同——見下面「Player 的 id 額外持久化」；走第 3 層的
其他動態角色（非角色庫投放、沒有事先帶 `character_id` 的）才是每次重開都新 UUID。

## `character_id` 是生成的 UUID，不帶任何語意

`Character.generate_id()` 用 `Crypto.generate_random_bytes(16)` 產生 RFC 4122 v4。
`@export var character_id` 留著只是給場景裡手擺的測試角色用，**留空才是正常路徑**。

> [!important] 不要解析 id，也不要把東西編進去
> 擁有者、名字、行程都不在 id 裡，那些各自是欄位。
> 選 UUID 而不是 `<owner>/<local_id>` 命名空間，理由是唯一性的**來源**：
> 命名空間把唯一性押在一個現在還不存在、日後幾乎一定會被真實帳號系統取代的
> `<owner>` 上，那時所有既有 id 都要遷移。UUID 不押任何東西。
>
> 附帶一個硬性理由：Godot 的節點名不接受 `/`，會靜默換成 `_`。
> `character.gd` 拿兩個 id 組 `Conversation_%s_%s`，
> `adez360/agent` + `bob/agent2` 與 `adez360/agent_bob` + `agent2` 會撞成同一個名字。

唯一性是**保證**不是偵測：`_ensure_unique_id()` 撞到就換一個新的並 `push_error`，
而不是印完錯誤讓兩隻共用。共用 id 等於共用一份關係與記憶
（`relationships.gd` 拿 id 當 key）。生成的 id 不會撞，會走到這條的是場景裡手寫重複。

### Player 的 id 額外持久化（issue #399）

固定 NPC 靠 `identities` 表天生穩定，但 Player 沒有節點名可查的身分資料——
`main.tscn` 不能直接 `@export` 填一個固定字串（那個欄位是給場景裡手擺的
**測試角色**用，填死字串也違反「id 不帶語意」的原則）。

做法是讓 `_ready()` 走到第三層時，改呼叫一個可被子類別覆寫的 hook
（`_resolve_generated_id()`，預設就是 `generate_id()`）。`player.gd` 覆寫它：
第一次生成後，把這組 UUID 額外寫進 `user://saves_<hash>/player_id.txt`——
跟 `user://saves_<hash>/characters/`／`user://saves_<hash>/worlds/`（見 [[存檔]]）分開放，
因為它不屬於 `SaveService` 那套整包讀寫／版本／鎖的機制，從頭到尾只有一個值，
寫一次之後只會被讀取。下次 `_ready()` 先讀這個檔案，讀得到就沿用，不必再過一次
存檔那套重量級流程。

動態生成的角色（`spawn_character()`）不需要覆寫這個 hook：它們要嘛已經帶著角色庫
存好的 `character_id`（走第一層就結束，不會落到這裡），要嘛是一次性測試用途，
沒有「跨場次是同一隻」的需求，仍會呼叫到基底 `_resolve_generated_id()`
再由基底實作執行 `generate_id()`。

`_resolve_generated_id()` 只顧首次生成／讀檔，沒顧到 `_ensure_unique_id()`
事後把 `character_id` 換掉的情況（讀進壞掉的存檔、撞到場上已有的角色）——
換掉的結果不會自動回頭同步進 `player_id.txt`，下次開遊戲讀到的還是那組已經
被撞掉的舊 id。補一個同樣可覆寫的 hook `_on_id_changed(new_id)`（基底預設
no-op），`_ensure_unique_id()` 換掉 `character_id` 後呼叫它；`player.gd`
覆寫它，跟 `_resolve_generated_id()` 共用同一段寫檔／錯誤處理邏輯
（抽成 `_write_player_id_file()`）。沒有額外持久化的子類別（Agent／動態生成
角色）不用覆寫，撞號換掉就換掉（issue #438）。

> [!important] 為什麼 `schedule_template` 不共用 `character_id`
> 它是「用哪份資料」不是「我是誰」。id 既然是全遊戲唯一身分，
> 就不可能同時等於一個手寫的模板名。
>
> 這是暫時欄位 —— 行程改由 AI 逐一維護之後就會消失。

## 誰用哪份行程寫在資料檔，不寫在場景

`npc_schedule.json` 的 `assignments` 把**節點名**對到模板名：

```json
"assignments": { "Agent": "npc001", "Agent2": "npc006" }
```

`agent.gd` 先問 `GameManager.get_schedule_template(name)`，
沒有指派才退回 `@export var schedule_template`。順序不能反過來 ——
`@export` 一定有值（場景的預設），先看它的話 `assignments` 永遠不會生效。

退回時會 `push_warning`。退回本身是允許的，但因為 `agent.tscn` 的預設值
所有 instance 共用，靜默退回的結果就是兩隻走同一份行程 —— 正是這個機制要防的事。
漏寫 `assignments` 遠比刻意不指派常見，所以寧可吵。
這套查表只適用場景固定 NPC——動態投放的角色（建角面板投放／存檔還原／
debug spawn）由 `spawn_character()` 標記 `schedule_optional`，
`_load_schedule()` 直接走無排程路徑，不進這個查表（見 [[角色庫與投放]]）。

> [!important] key 用節點名，不用 `character_id`
> id 是生成的 UUID，人在 json 裡手寫不出來。
> 而 `assignments` 問的正是「場景裡哪一隻用哪份資料」，不是「哪個身分」。

> [!warning] 節點名只在同一層唯一
> 引擎只保證兄弟節點不撞名（撞了會自動改成 `@Agent@2`），
> `HouseA/Agent` 與 `HouseB/Agent` 則是合法的，而它們會查到同一筆 assignment。
> `_warn_if_node_name_shared()` 掃 group `agents` 抓這種撞名並 `push_error` ——
> 擋不住，但至少不是靜默的。

> [!important] `@export` 的預設值是 instance 之間共用的
> `Agent` 與 `Agent2` 是同一份 `agent.tscn` 的 instance，
> 兩者都沒有在 `main.tscn` 覆寫 `schedule_template`，所以都吃到場景預設的 `npc001`：
> **同一分鐘、同一個地點、同一件事**，兩隻等於一隻。
>
> 要逐隻不同，除了在 `main.tscn` 逐個 instance 覆寫（得動場景），
> 就是把對應關係當成資料。選後者：
> 「誰用哪份行程」本來就是資料，而且改資料不必開編輯器。

`npc006` 是為現在這張地圖寫的：整份行程只用 `PlaceAnchors` 真的有的四個錨點
（`home_001` / `farm` / `restaurant` / `square`），時段刻意跟 `npc001` 錯開，
兩隻才走得出不同的軌跡 —— 接 LLM 對話時需要這個對照組。

`npc002`~`npc005` 這四份範本曾經用 `shop` / `temple` / `home_002`… 這些沒有
錨點的地點，`assignments` 也沒有指派到它們——issue #87 判定為死資料整份移除了。

## 決策

> [!important] 動畫只做三向 front / back / right
> 往左沒有專屬素材，用 `flip_h` 翻轉 right 代替。
> 曾經有八向（含斜向）的切法，但同一張 `16x16 Walk-Sheet.png` 撐不出斜向的辨識度，
> 維護成本卻翻倍。

> [!important] 地點座標用場景錨點
> 在 `Node2D/PlaceAnchors`（group `place_anchors`）底下放與地點同名的錨點，
> 那是座標的唯一事實來源：`agent.gd` 只認錨點，沒有就 `push_error` 且不動身。
>
> 這也是多場景（家園／交誼區）本來就需要的：全域絕對座標在多張地圖下必然是錯的。

> [!warning] `place_anchors` 節點本身可能還沒掛進場景樹，跟「查無此地」是兩層不同的失敗
> `get_tree().get_first_node_in_group("place_anchors")` 在動態生成的 Agent
> 搶在 `PlaceAnchors._ready()` 之前先跑一次 `_reevaluate()` 時會拿到 `null`——
> 這跟「`PlaceAnchors` 存在但查無此地」（`has_for()` 回傳 false）是兩個階段的
> 暫時失敗，都會自己好，但**不能共用同一個 if 分支**：分支內部只要有任何一行
> 讀 `anchors` 的屬性或呼叫它的方法（例如 `anchors.HOME_PLACE_NAME`），
> 就得先擋掉 `anchors == null` 這條路徑再進去，不然會對 null 取屬性直接 crash
> 把遊戲卡進 debugger break（issue #916）。`_pursue_current_task()` 已修好；
> 這個檔案裡其他 `anchors == null or not anchors.has_for(...)` 守門式只要
> 分支內部沒有再碰 `anchors`，就不受影響，不用比照修改。

> [!warning] 抵達判定要同時看距離與格
> `ARRIVE_DISTANCE` 是 2px，但尋徑以 16px 的格為單位 ——
> 中間 2..11px 是死角：距離判定說「還沒到」，而 `find_path()` 因為起訖同格
> 只給得出一個點，`move_to()` 回傳 false，於是噴出假的「走不到」。
>
> `_has_arrived_at()` 因此除了比距離，也判斷是否已在目標格內。
> 少了這條，每次重算行程（對話結束、看到人愣完）都會誤報一次。

> [!warning] NavGrid 開場是非同步建置
> `nav_grid.gd` 要等 TileMapDual 的碰撞體進物理空間才建得出網格。
> Agent 在 `_ready()` 就呼叫 `move_to()` 必定拿到空路徑 ——
> 所以它會先 `await nav.grid_built`。

## 狀態快照是純資料，供顯示端與 AI payload 共用

`get_state_snapshot()` 回傳角色狀態（位置、數值、關係、行程……），
主控台的 `status` 指令只負責把它排版成 BBCode，不自己蒐集一次
——蒐集邏輯原本糊在 `debug_console.gd` 裡，任何人想重用都得先拆掉格式。

> [!important] key/value 一律是識別字，不可以是翻譯過的字
> `Stats.SPEC` 的 `label` 存的是翻譯 key（如 `STAT_SATIETY`），snapshot 照樣只放
> key 不放翻譯後的文字。這批資料以後會直接進 LLM 的 prompt
> （見 [[LLM 串接與 AI 服務層]] 的 payload 設計），不該隨玩家介面語系跑掉。

`schedule` 欄位（`place`/`state`/`size`）只有 Agent 才有。它由 `agent.gd`
override `get_state_snapshot()`、`super()` 之後補上去，**不是**基底自己去嗅探
誰是 Agent —— `schedule`/`current_place`/`current_state` 宣告在 `agent.gd`，
就由 `agent.gd` 負責放進快照。基底若改用 `is_in_group("agents")` 加
`get("current_place")` 動態讀，group 成員資格跟「有沒有這個欄位」是兩件事，
不吻合時會拿到 `null`（或在 `as Array` 那步直接崩）。

`relations` 每筆是 `{met_count}`，欄名跟 `relationships.gd` 的 record
一致，不要在快照裡改名 —— 同一個數值兩個名字，讀過 `relationships.gd` 的人
會在快照上找不到它。取值走 `get_met_count()` 這個純量 accessor，不用
`get_record()`：後者每筆都 `duplicate(true)` 深拷一份，只為了讀一個數字。

## 碰撞分層

角色之間不互相碰撞，但仍會被地形擋住。用 layer / mask 達成，不是用程式忽略碰撞：

| | collision_layer | collision_mask |
| --- | --- | --- |
| 地形（TileSet physics layer 0） | 1 `terrain` | — |
| Player / Agent | 2 `character` | 1 `terrain` |
| `Vision`（Area2D） | 0 | 2 `character` |

角色在 layer 2，而沒有任何人的 mask 含 layer 2，所以角色之間彼此看不見；
角色的 mask 是 1，所以照樣撞牆。層名寫在 `project.godot` 的 `layer_names/2d_physics`。

> [!important] 設定寫在 `.tscn`，不寫在 `character.gd`
> 位置是 `character.tscn` 的 root（`player.tscn`／`agent.tscn` 用 Inherited
> Scene 機制繼承，不必各自設定；`main.tscn` 裡的 instance 再自動繼承一次）。
> 寫在腳本裡的話，inspector 改了會被程式蓋掉。

驗證用物理查詢不是目測：在 Agent 位置用 Player 的 mask 查回傳空、
開全部 layer 查得到 Agent、用同一個 mask 在牆的位置查得到 TileMapLayer。

> [!note] `nav_grid` 的 `_actor_body_rids()` 現在是冗餘的
> 它掃可走性時會排除場上的 CharacterBody2D，但查詢用 mask 1，
> 而角色已經在 layer 2，本來就掃不到。留著沒壞處（還擋著 RigidBody2D），
> 只是不再必要。

## 固定 NPC 的身份指派

`npc_schedule.json` 的 `identities` 區塊，用節點名對到 `{character_id, character_name}`：

```json
"identities": {
    "Agent":  {"character_id": "aji",  "character_name": "阿吉"},
    "Agent2": {"character_id": "alan", "character_name": "阿嵐"}
}
```

`GameManager.get_npc_identity(node_name)` 查它，`character.gd::_ready()` 在生成 UUID／
退回節點名之前先問一次。查不到回空字典，自然落回第 3 層 —— Player 與動態生成的角色
不必列進表裡。

> [!important] `identities` 跟 `assignments` 分兩塊，不合併
> 「用哪份行程」（`assignments` → `schedule_template`）與「我是誰」（`identities`）
> 是兩件事。同一隻角色換行程不該換身分，換身分也不該換行程。
> 合併成一個物件會讓這兩件事被迫同進同出。

問的時間點在基底 `Character._ready()`，不是 `agent.gd::_load_schedule()`：
Player 沒有 schedule 概念，但一樣要走這套 fallback 鏈。

不走 #73 的 `spawn_character()`：那是給動態生成角色用的（identity 當參數傳），
Agent/Agent2 是場景裡的靜態節點，`_ready()` 時自己查表更貼近現有架構，
不用為了兩隻寫死的示範 NPC 去改場景結構。

> [!warning] 目前的 id 值不符合《01》§1-1 的格式規定
> 規格書寫 `id` 格式是 `npc_001`，這裡用的是 `aji`／`alan`。
> 存檔還沒接上、沒有任何持久化資料綁在這兩個值上，改動成本目前是零；
> 要對齊規格就趁現在。追蹤見 issue #69 的 PR 討論。

## 情緒 emotion 與特殊狀態 conditions

`emotion`（單一物件）與 `conditions`（陣列）都直接是 `Character` 的欄位，不掛在
`Stats` 底下——規格書《02》把兩者定義成獨立於生理數值的狀態層，`Stats` 只管
`SPEC` 驅動的數值本身。`conditions` 的門檻檢查（`_update_conditions()`）讀
`stats.get_value()`，但寫入的是 `Character.conditions`。

> [!important] 「tick」= 10 遊戲分鐘，不是獨立的 tick 引擎、也不是 GameClock 的一遊戲分鐘
> 規格書《02》§1-4 定義 12 tick = 2 遊戲小時（120 遊戲分鐘），也就是 1 tick = 10 遊戲分鐘
> ——用規格書自己的算例反查就對得起來：joy intensity=60、stability=90、grudge=75 算出
> 9 tick，規格書寫「約 1.5 小時」＝90 遊戲分鐘。專案目前沒有事件驅動的 tick 引擎
> （見《02》§4 的流程圖，那套還沒實作）。`GameClock.GAME_MINUTES_PER_TICK`（＝10）是唯一
> 來源，`emotion.duration_left`／`_update_conditions()`／`Stats` 漂移三者都掛
> `GameClock.time_changed`，各自在 `_minute % GAME_MINUTES_PER_TICK == 0` 的分鐘邊界
> 才真的執行一次（#361 修正）——修正前 `Stats._process(delta)` 是連續 real-time drift，
> 沒有經過 GameClock，也沒有 10 倍換算，跟 emotion／conditions 那套不同調，導致漂移
> 速度快了 10 倍；`Character` 自己的本地 `_tick_minute_accum` 累加器也已經拿掉，
> 改成跟 `Stats` 共用同一個全域分鐘邊界判斷，不再各自維護一份計數。

### emotion（`set_emotion()`）

- `type` 限定在 8 種定案 enum（`Character.EMOTION_TYPES`），`duration_left` 由
  `_calc_emotion_duration()` 依《02》§1-4 公式算，夾制 1~144 tick
- 公式吃 `stability`／`grudge` 兩個人格係數，人格資料還沒接上 `Character`（#117），
  呼叫端拿不到真實值時用 50.0（中性值）當預設——比照 `memory.gd::decay_all()`
  對 `grudge` 的既有做法，等 #117 落地後呼叫端改傳真實值即可，`set_emotion()`
  本身不用改
- `AISchema`／`prompt_builder.gd` 的 LLM 輸出端與 prompt 注入**沒有一併做**
  （#116 本文列為選做項），目前只有 debug 主控台 `emotion <name> <type> [intensity]`
  能手動觸發

### conditions（`_update_conditions()`）

8 種生理衍生 condition 全部「門檻自動」，每遊戲分鐘重新檢查一次：

| 只做偵測 | 偵測＋直接數值效果 |
| --- | --- |
| `injured`／`drunk`／`sleepy`／`filthy` | `bleeding`（health −1.5/tick）／`starving`（health −0.5/tick）／`dehydrated`（health −1.0/tick） |

`exhausted`（`stamina = 0`）已經不只是偵測（#361）：`agent.gd::_reevaluate_once()`
偵測到這個 condition 時優先於一般任務仲裁，呼叫 `_force_rest_until_recovered()`
塞一筆 `source: "reflex"`、`interruptible: false` 的 rest 任務並 `stop_moving()`，
直到 stamina 回升、condition 清除為止；清除的當下 `_reevaluate_once()` 會清掉
這筆 reflex 任務並重置追逐狀態，讓一般仲裁接手。「強制昏睡」（角色倒下、
送醫這類更完整的行動佔用）仍留給接手 #160（昏迷狀態）的那則，這裡做的只是
「不給選、強制休息」。

行為成功率／說真心話機率（`injured`／`drunk` 的效果）刻意不做，留給 #120
（成功率／硬規則檢查層）；`filthy` 的效果留給《99》P-35 重新設計。

> [!important] `bleeding` 期間 `injury` 的自然衰減暫停，是 `Stats.injury_decay_paused` 一個 bool
> 沒有做成通用的「暫停任意 key 的 drift」機制——目前全規格書只有這一個例外
> （《02》§2-2 附注），加一個只為單一呼叫端存在的通用機制是提前的抽象化。
> `Character._update_conditions()` 每次檢查完就把這個 bool 設成
> `has_condition("bleeding")` 的目前值，`Stats._process()` 只在這個 key 上多一行
> `continue`。真的出現第二個需要暫停 drift 的欄位時再抽成通用機制。
>
> 這個旗標是純執行期 derived 狀態，不會隨存檔走（`Stats.get_save_data()`
> 只存 `values`），所以除了 `_update_conditions()` 的 10 分鐘一次 tick，
> 另外兩個會讓 injury 瞬間跨過門檻、不能等下個 tick 的地方也各自立即重算
> 一次：`attack()` 命中瞬間（#821/#851 一併立即同步昏迷）、
> `Character.load_save_data()` 套用完 `stats.load_save_data()` 之後
> （#923，讀檔到下個 tick 之間的空窗期原本會讓已經在流血的角色悄悄止血）。
> 三處都只重算 `CONDITION_BLEEDING` 與 `injury_decay_paused` 這一組，
> 不呼叫整個 `_update_conditions()`——那個函式會連同 bleeding 的 `-1.5`
> health 直接效果一起重跑，在非 tick 邊界的時間點多套用一次不該發生的傷害。

## 未做

- Agent 不會對 `Stats` 反應，數值只是持續遞減。
  需求→地點的對照已經在 `Stats.SPEC` 的 `place` 欄位（`get_lowest_need_place()`），
  但沒有任何呼叫端 —— 接上它就是「AI 壞掉時退回內建行為」的那條 fallback
- `main.tscn` 是測試方塊圖，四個錨點擺在外圍空地，不是真的地點——規格書《07_地點/》
  已定義 15 個正式地點（一地點一筆記，見《[[Ailley]]》規格書索引），跟這裡的四個測試
  錨點名字對不上（`farm`/`restaurant`/`square` 等不在那 15 個裡），換真地圖時要重新對照
- 行程表是靜態 JSON，之後換成 AI 維護的版本，見 [[行程佇列與任務仲裁]]
- 兩隻 Agent 的行程、身分（`character_id` / 顯示名）與人格（`hexaco` + `character`
  自述，寫在 `npc_schedule.json` 的 `identities`）都已經不同，見
  [[人格與 System Prompt]]
- 兩隻的家都是 `home_001`。已拍板「家要各自不同」（規格書《01》§1-1 `home_location_id`、
  《07_地點/家》），但還沒實作——地圖上要放幾間房子、怎麼指派給角色仍待規劃（《99》P-17 #12）

## 行為判定系統（Success Roll）的當前狀態

`_roll_success()` 與 `_failure_reason()` 實作了規格書《01-2》§2 的通用成功率公式，包含 stamina／injury／alcohol 三項修正。`_roll_success()` 本身會被呼叫，但 MVP-1 現有動作都不在 `SUCCESS_PARAMS` 上、一律走 `params.is_empty()` 的放行分支，公式那段判定邏輯在 MVP-1 **全程都不會被執行過一次**——見 #216 決策記錄（`note/交流/issue-216-success-params-not-in-mvp.md`）。

### 原因

- `SUCCESS_PARAMS` 表上 6 個動作（`hunt_small`／`hunt_large`／`gather`／`fish`／`steal`／`perform`）都在完整版，不在 MVP-1
- MVP-1 的其他動作要麼直接判定必中（`attack`），要麼不走擲骰（`persuade`／`give`／`shout`），要麼尚未實作（`struggle`）

### 誰會第一個真正執行這段公式？

**`struggle`（掙脫搬運，#337）** 是最可能的候選。規格書《01-2》§3 給了它判定參數，但當前 `SUCCESS_PARAMS` 缺少這一筆。#337 實作時需要：

1. 補 `struggle` 進 `SUCCESS_PARAMS`
2. 把 `_roll_success()` 與 `_failure_reason()` 當成**未驗證的程式碼**對待
3. 特別注意「雙人搬運一律失敗，不套用公式」的例外分支（規格書《01-2》§3 例外二）
4. 驗證 stamina 中性值（50）、injury 與 alcohol 修正項的計算邏輯
5. 驗證 `_failure_reason()` 本身的選取邏輯——取四項修正裡最負的一個當理由，
   全部修正項都是 0（沒有扣分）時才回退成「手氣不好」，不是預設值

之後每次新增動作時重新檢視公式。
