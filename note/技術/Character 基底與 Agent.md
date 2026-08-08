---
tags:
  - agent
  - character
scene: scenes/main.tscn
script: scripts/character/character.gd
status: 已實作
updated: 2026-08-09
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
| `scenes/player.tscn` / `scenes/agent.tscn` | 共用同一份三向 SpriteFrames |

## 分工

基底管「怎麼走、怎麼演」：A\* 移動、三向動畫、卡住偵測、`move_finished` 訊號、
以及元件子節點（`Stats` / `Relationships` / `Bubble` / `Vision`，全部
`get_node_or_null`，沒掛也不會壞）。

子類別只覆寫 `_decide_velocity()` 決定「往哪走」：

- **Player** —— 有輸入就用輸入並中斷現有路徑，否則 `super()` 跟隨 A\* 路徑
- **Agent** —— 不覆寫，純粹跟隨行程表下的 `move_to()`

## 身分、名字、行程模板是三件事

| 欄位 | 用途 | 可變 | 可撞名 |
| --- | --- | --- | --- |
| `character_id` | 全遊戲唯一身分。存檔、記憶連結、交誼區靠它指人，內部用不顯示 | 否 | 否 |
| `character_name` | 玩家取的名字，顯示用，指令也用它指名 | 是 | 是 |
| `age` | 年齡，純顯示用（狀態表），不影響任何邏輯 | 是 | — |
| `schedule_template`（僅 Agent） | 用哪份行程資料，對應 `npc_schedule.json` 的鍵 | — | 是 |

留空時：`character_id` 生成一個 UUID，`character_name` 退回節點名小寫。`age` 預設 20。

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

id 目前每次開遊戲都重新生成 —— 寫下來要等存檔，見 [[存檔]]。

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

`agent.gd` 先問 `GameManager.get_schedule_template(str(name))`，
沒有指派才退回 `@export var schedule_template`。順序不能反過來 ——
`@export` 一定有值（場景的預設），先看它的話 `assignments` 永遠不會生效。

> [!important] key 用節點名，不用 `character_id`
> id 是生成的 UUID，人在 json 裡手寫不出來。節點名在場景裡本來就唯一，
> 而 `assignments` 問的正是「場景裡哪一隻用哪份資料」，不是「哪個身分」。

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

> [!warning] `npc002`~`npc005` 仍然指向不存在的地點
> 它們用 `shop` / `temple` / `home_002`… 這些**沒有錨點**，
> 會退回 `places.json` 那組已經失效的座標。目前沒有任何角色被指派到它們，
> 但 `assignments` 一旦指過去就會踩到。要用之前得先補錨點或改寫那幾份行程。

## 決策

> [!important] 動畫只做三向 front / back / right
> 往左沒有專屬素材，用 `flip_h` 翻轉 right 代替。
> 曾經有八向（含斜向）的切法，但同一張 `16x16 Walk-Sheet.png` 撐不出斜向的辨識度，
> 維護成本卻翻倍。

> [!important] 地點座標用場景錨點，不吃 `places.json`
> `places.json` 的座標（x 最遠到 1120）綁死在一張已經不存在的舊地圖尺寸上，
> 而現在的可走區只有 18 格寬 —— 所有地點都落在界外。
>
> 改成在 `Node2D/PlaceAnchors`（group `place_anchors`）底下放與地點同名的 Marker2D，
> `agent.gd` 優先讀錨點、找不到才退回 `GameManager.get_place()`。
>
> 這也是多場景（家園／交誼區）本來就需要的：全域絕對座標在多張地圖下必然是錯的。

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
> 位置是 `player.tscn` 與 `agent.tscn` 的 root（`main.tscn` 兩者都是 instance，
> 自動繼承）。寫在腳本裡的話，inspector 改了會被程式蓋掉。

驗證用物理查詢不是目測：在 Agent 位置用 Player 的 mask 查回傳空、
開全部 layer 查得到 Agent、用同一個 mask 在牆的位置查得到 TileMapLayer。

> [!note] `nav_grid` 的 `_actor_body_rids()` 現在是冗餘的
> 它掃可走性時會排除場上的 CharacterBody2D，但查詢用 mask 1，
> 而角色已經在 layer 2，本來就掃不到。留著沒壞處（還擋著 RigidBody2D），
> 只是不再必要。

## 未做

- Agent 不會對 `Stats` 反應，數值只是持續遞減。
  需求→地點的對照已經在 `Stats.SPEC` 的 `place` 欄位（`get_lowest_need_place()`），
  但沒有任何呼叫端 —— 接上它就是「AI 壞掉時退回內建行為」的那條 fallback
- `main.tscn` 是測試方塊圖，四個錨點擺在外圍空地，不是真的地點
- 行程表是靜態 JSON，之後換成 AI 維護的版本，見 [[行程佇列與任務仲裁]]
- 兩隻 Agent 的行程已經不同，但**人格還沒有**：沒有 `persona_id`，
  也沒有覆寫 `character_name`（顯示名就是 `agent` / `agent2`）
- 兩隻的家都是 `home_001` —— 「家在哪」還不是角色的屬性
