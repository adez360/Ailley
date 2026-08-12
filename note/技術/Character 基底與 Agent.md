---
tags:
  - agent
  - character
scene: scenes/main.tscn
script: scripts/character/character.gd
status: 已實作
updated: 2026-08-12
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

| 欄位 | 用途 | 玩家可改 | 可撞名 |
| --- | --- | --- | --- |
| `character_id` | 全遊戲唯一身分。存檔、記憶連結、交誼區靠它指人，內部用不顯示 | 否 | 否 |
| `character_name` | 玩家取的名字，顯示用，指令也用它指名 | 是 | 是 |
| `schedule_template`（僅 Agent） | 用哪份行程資料，對應 `npc_schedule.json` 的鍵 | — | 是 |

優先序（`character_id`／`character_name` 兩個欄位一致）：
`npc_schedule.json` 的 `assignments` 固定值 > 這個 `@export`（場景裡手擺的值）
> 執行期生成／退回節點名小寫。

「玩家可改」不等於「這一場不會變」：`character_id` 玩家碰不到，但撞號時
`_ensure_unique_id()` 會就地換掉一個。**只有沒被 `assignments` 指派的角色**
（現況只有 Player）才是每次開遊戲重新生成，別把它快取在 `_ready()` 之外，
也別假設它跨場次還是同一個；場景裡固定的 demo NPC（`Agent`／`Agent2`）已經
用 `assignments` 指定固定值，跨開遊戲都一樣。

## `character_id` 沒指派時是生成的 UUID，不帶任何語意

`Character.generate_id()` 用 `Crypto.generate_random_bytes(16)` 產生 RFC 4122 v4。
`@export var character_id` 留著給場景裡手擺的測試角色用，`assignments` 沒指派、
`@export` 也留空才會走生成——這是 Player 跟未指派角色的正常路徑。

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

Player 跟未指派角色的 id 每次開遊戲都重新生成——這塊要等真正的存檔系統，
見 [[存檔]]。場景裡固定的 demo NPC 不受影響：它們的 id 是設計時就決定好的
資料，寫進 `assignments` 就跨開遊戲一致，不需要「記住」也不需要存檔。

> [!important] 為什麼 `schedule_template` 不共用 `character_id`
> 它是「用哪份資料」不是「我是誰」。id 既然是全遊戲唯一身分，
> 就不可能同時等於一個手寫的模板名。
>
> 這是暫時欄位 —— 行程改由 AI 逐一維護之後就會消失。

## 誰用哪份行程、身分寫在資料檔，不寫在場景

`npc_schedule.json` 的 `assignments` 把**節點名**對到一組資料：

```json
"assignments": {
  "Agent": {
    "schedule_template": "npc001",
    "character_id": "agent-001-fixed-demo-npc",
    "character_name": "阿吉"
  },
  "Agent2": {
    "schedule_template": "npc006",
    "character_id": "agent2-001-fixed-demo-npc",
    "character_name": "阿蘭"
  }
}
```

`agent.gd` 先問 `GameManager.get_schedule_template(name)`，
`character.gd._ready()` 先問 `get_character_id(name)`／`get_character_name(name)`，
沒有指派才退回 `@export`。三個欄位是同一套查表模式，順序都不能反過來 ——
`@export` 一定有值（場景的預設），先看它的話 `assignments` 永遠不會生效。

`schedule_template` 退回時會 `push_warning`（因為 `agent.tscn` 的預設值所有
instance 共用，靜默退回會兩隻走同一份行程）；`character_id`／`character_name`
退回是安全的（各自生成 UUID／退回節點名），不特別警告。

> [!important] key 用節點名，不用 `character_id`
> `assignments` 問的是「場景裡哪一隻該用哪組資料」，不是「哪個身分」——
> 用節點名查表才問得出來。這裡的 `character_id` 值本身也不再一定是
> `generate_id()` 那種真的 UUID：手動指派固定身分時，寫一個好讀、穩定的
> 字串就夠，不需要跟隨機生成的格式一致，反正 `character_id` 的規則本來就是
> 「不要解析它」，格式從來不是任何呼叫端該假設的東西。

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

> [!warning] `npc002`~`npc005` 仍然指向不存在的地點
> 它們用 `shop` / `temple` / `home_002`… 這些**沒有錨點**，
> 到點時只會 `push_error` 然後原地不動。目前沒有任何角色被指派到它們，
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
> 那是座標的唯一事實來源：`agent.gd` 只認錨點，沒有就 `push_error` 且不動身。
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

## 狀態快照是純資料，供顯示端與 AI payload 共用

`get_state_snapshot()` 回傳角色狀態（位置、數值、好感、行程……），
主控台的 `status` 指令只負責把它排版成 BBCode，不自己蒐集一次
——蒐集邏輯原本糊在 `debug_console.gd` 裡，任何人想重用都得先拆掉格式。

> [!important] key/value 一律是識別字，不可以是翻譯過的字
> `Stats.SPEC` 的 `label` 存的是翻譯 key（如 `STAT_HUNGER`），snapshot 照樣只放
> key 不放翻譯後的文字。這批資料以後會直接進 LLM 的 prompt
> （見 [[LLM 串接與 AI 服務層]] 的 payload 設計），不該隨玩家介面語系跑掉。

`schedule` 欄位（`place`/`state`/`size`）只有 Agent 才有。它由 `agent.gd`
override `get_state_snapshot()`、`super()` 之後補上去，**不是**基底自己去嗅探
誰是 Agent —— `schedule`/`current_place`/`current_state` 宣告在 `agent.gd`，
就由 `agent.gd` 負責放進快照。基底若改用 `is_in_group("agents")` 加
`get("current_place")` 動態讀，group 成員資格跟「有沒有這個欄位」是兩件事，
不吻合時會拿到 `null`（或在 `as Array` 那步直接崩）。

`affinity` 每筆是 `{affinity, met_count}`，欄名跟 `relationships.gd` 的 record
一致，不要在快照裡改名 —— 同一個數值兩個名字，讀過 `relationships.gd` 的人
會在快照上找不到它。取值走 `get_affinity()` / `get_met_count()` 這兩個純量
accessor，不用 `get_record()`：後者每筆都 `duplicate(true)` 深拷一份，
只為了讀兩個數字。

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
- 兩隻 Agent 的行程已經不同，顯示名也已經覆寫（`assignments` 指定
  `Agent`＝阿吉、`Agent2`＝阿蘭），但**人格還沒有**：沒有 `persona_id`
- 兩隻的家都是 `home_001` —— 「家在哪」還不是角色的屬性
