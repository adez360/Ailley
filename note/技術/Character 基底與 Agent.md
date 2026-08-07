---
tags:
  - agent
  - character
scene: scenes/main.tscn
script: scripts/character/character.gd
status: 已實作
updated: 2026-08-07
---

# Character 基底與 Agent

Player 與 Agent 共用同一個基底，移動與動畫是同一份實作 ——
專案那條「Player 能做到的 Agent 也必須能做到」（見 [[決策]]）在這裡是靠繼承強制的，
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
| `schedule_template`（僅 Agent） | 用哪份行程資料，對應 `npc_schedule.json` 的鍵 | — | 是 |

兩個 id 欄位留空時分別退回節點名小寫、退回 `character_id`。

> [!important] 為什麼 `schedule_template` 不共用 `character_id`
> 它是「用哪份資料」不是「我是誰」。id 既然是全遊戲唯一身分，
> 就不可能同時等於一個手寫的模板名。
>
> 這是暫時欄位 —— 行程改由 AI 逐一維護之後就會消失。

> [!warning] id 唯一性目前只是「偵測」，不是「保證」
> `_ready()` 會掃 `characters` group，撞 id 就 `push_error`。
> 真正的唯一性要等存檔做起來才能改成建立角色時生成一次並持久化；
> 跨玩家的唯一性（交誼區）另需命名空間或 UUID，都還沒做。

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
  但沒有任何呼叫端 —— 接上它就是 [[決策]] 說的 AI 逾時 fallback
- `main.tscn` 是測試方塊圖，四個錨點擺在外圍空地，不是真的地點
- 行程表是靜態 JSON，之後換成 AI 維護的版本，見 [[行程佇列與任務仲裁]]
