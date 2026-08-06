# Ailley 腳本 API 參考

涵蓋 `Ailley/scripts/` 底下所有 GDScript 的公開介面（Godot 4.5，GL Compatibility）。

## 模組總覽

| 檔案 | 繼承 | 掛載方式 | 角色 |
|---|---|---|---|
| `core/game_manager.gd` | `Node` | **Autoload `GameManager`** | 讀取並查詢 JSON 靜態資料（場所、NPC 行程） |
| `core/GameClock.gd` | `Node` | **Autoload `GameClock`** | 遊戲內時鐘，每遊戲分鐘發出訊號 |
| `core/place_manager.gd` | `Node` | ⚠️ 未掛載 | 場所人數／容量管理 |
| `npc/villager.gd` | `CharacterBody2D` | 村民場景根節點 | 村民主控：移動、行程、視覺感測、動畫 |
| `npc/needs.gd` | `Node` | 村民子節點 `$Needs` | 四項需求數值衰減 |
| `npc/state_machine.gd` | `Node` | 村民子節點 `$StateMachine` | IDLE / WANDER 狀態切換 |
| `bubble.gd` | `Node2D` | 村民子節點 `$Bubble` | 頭頂對話氣泡 |
| `json_loader.gd` | `Node` | ⚠️ 未掛載 | 通用 JSON 讀取工具 |

> ⚠️ `place_manager.gd` 與 `json_loader.gd` 目前**沒有**註冊為 autoload，也沒有被任何 `.tscn` 引用。文件仍記錄其介面，但呼叫前需先接上（見文末「已知問題」）。

---

## `GameManager`（autoload）

`scripts/core/game_manager.gd` — 全域靜態資料來源。`_ready()` 時自動載入 `res://data/places.json` 與 `res://data/npc_schedule.json`。

### 屬性

| 名稱 | 型別 | 說明 |
|---|---|---|
| `places` | `Dictionary` | `places.json` 的 `places` 區塊，key 為場所名稱 |
| `npc_data` | `Dictionary` | key 為 NPC id，value 為該 NPC 的完整資料物件 |

### 方法

```gdscript
func load_places() -> void
```
讀取 `res://data/places.json` 填入 `places`。檔案不存在時 `print("找不到 places.json")` 後直接返回（不會 push_error）。

```gdscript
func load_npc_data() -> void
```
讀取 `res://data/npc_schedule.json`，以 `villagers[].id` 為 key 建立 `npc_data`。會先 `clear()`，因此可安全重複呼叫做熱重載。檔案不存在時 `push_error`。

```gdscript
func get_place(place_name: String) -> Vector2
```
回傳場所的世界座標。查無此場所時回傳 `Vector2.ZERO`（**注意：與「原點座標」無法區分**）。

```gdscript
func get_place_data(place_name: String) -> Dictionary
```
回傳場所的完整資料（含 `x`、`y`、`type`、`capacity`）。查無時回傳 `null`。

```gdscript
func get_npc(id: String)
```
回傳該 NPC 的資料物件（含 `id`、`schedule`）。查無時回傳 `null`。

### 資料格式

`data/places.json`：
```json
{ "places": { "home_001": { "x": 160, "y": 160, "type": "home", "capacity": 1 } } }
```
`type` 目前出現的值：`home` / `work` / `eat` / `pray`（`square` 另有其型別）。

`data/npc_schedule.json`：
```json
{ "villagers": [ { "id": "npc001", "schedule": [
  { "time": "08:00", "place": "home_001", "state": "idle" }
] } ] }
```
`time` 必須是 `HH:MM` 零補位格式，才能與 `GameClock` 比對成功。

---

## `GameClock`（autoload）

`scripts/core/GameClock.gd` — 以 `_process` 驅動的遊戲時鐘，起始時間 08:00。

### 訊號

```gdscript
signal time_changed(hour: int, minute: int)
```
每推進一個「遊戲分鐘」發出一次。24:00 會回捲為 0。

### 屬性

| 名稱 | 型別 | 預設 | 說明 |
|---|---|---|---|
| `seconds_per_game_minute` | `float` (`@export`) | `1.0` | 幾秒真實時間 = 1 遊戲分鐘 |
| `hour` | `int` | `8` | 目前小時（0–23） |
| `minute` | `int` | `0` | 目前分鐘（0–59） |

### 用法

```gdscript
GameClock.time_changed.connect(on_time_changed)
on_time_changed(GameClock.hour, GameClock.minute)  # 補一次目前時間
```

> 時鐘每幀最多前進 1 分鐘。若 `seconds_per_game_minute` 小於單幀 delta，時間會落後於設定倍率。

---

## `place_manager.gd`

`scripts/core/place_manager.gd` — 追蹤各場所目前有哪些 NPC，並強制 `capacity` 上限。依賴 `GameManager.places` 已載入。

### 屬性

| 名稱 | 型別 | 說明 |
|---|---|---|
| `occupancy` | `Dictionary` | `place_name -> Array[String]`（NPC id 陣列），`_ready()` 時依 `GameManager.places` 初始化為空陣列 |

### 方法

```gdscript
func enter_place(place_name: String, npc_id: String) -> bool
```
嘗試讓 NPC 進入場所。回傳 `false` 的情況：場所不存在、或已達 `capacity`。成功則 append 並回傳 `true`。

> 不做重複檢查——同一個 `npc_id` 連續呼叫兩次會被登記兩次。

```gdscript
func leave_place(place_name: String, npc_id: String) -> void
```
把 NPC 從場所移除。場所不存在時靜默返回。

```gdscript
func is_full(place_name: String) -> bool
```
查詢場所是否已滿。**場所不存在時會因 `null` 索引而報錯**，呼叫前請自行確認。

```gdscript
func get_people(place_name: String) -> Array
```
回傳該場所目前的 NPC id 陣列。同樣不對不存在的場所做防護。

---

## `villager.gd`

`scripts/npc/villager.gd` — 村民主腳本，繼承 `CharacterBody2D`。

### 場景節點需求

腳本以 `@onready` 綁定下列子節點，缺一即會在 `_ready()` 崩潰：

```
Villager (CharacterBody2D)
├── AnimatedSprite2D
├── StateMachine        # state_machine.gd
├── Needs               # needs.gd
├── NavigationAgent2D
├── Bubble              # bubble.gd
├── VisionArea (Area2D)
│   └── CollisionShape2D
└── RayCast2D
```

`_ready()` 會把自己 `add_to_group("villagers")`——視覺感測靠這個群組過濾對象。

### 常數與匯出

| 名稱 | 值 | 說明 |
|---|---|---|
| `SPEED` | `50.0` | 移動速度（px/s） |
| `TILE_SIZE` | `16.0` | 1 格 = 16px，感測半徑換算用 |
| `villager_id` (`@export`) | `"npc001"` | 對應 `npc_schedule.json` 的 `id` |

### 狀態屬性

| 名稱 | 型別 | 說明 |
|---|---|---|
| `schedule` | `Array` | 從 `GameManager` 載入的行程 |
| `current_place` | `String` | 最近一次 `go_to()` 的目標場所 |
| `target_position` | `Vector2` | 目標世界座標 |
| `has_target` | `bool` | 是否正在前往目標 |
| `detected_targets` | `Array[Node2D]` | 目前在感測圓內的其他村民 |
| `is_paused` | `bool` | 為 `true` 時停止移動（速度歸零，動畫照更新） |
| `debug_draw` | `bool` | 是否繪製感測範圍圓 |
| `vision_radius_tiles` | `int` (setter) | 感測半徑（格）。setter 以 `clampi(value, 1, 20)` 夾限並即時套用到 `CollisionShape2D` |

### 移動與行程

```gdscript
func go_to(place_name: String) -> void
```
設定 `current_place`、向 `GameManager` 取座標、寫入 `NavigationAgent2D.target_position` 並開啟 `has_target`。這是外部驅動村民移動的主要入口。

```gdscript
func load_schedule() -> void
```
以 `villager_id` 向 `GameManager.get_npc()` 取行程。查無 NPC 時靜默返回（`schedule` 維持空陣列）。

```gdscript
func on_time_changed(hour: int, minute: int) -> void
```
`GameClock.time_changed` 的處理器。把時間格式化為 `"%02d:%02d"` 與 `schedule[].time` 做**字串完全比對**，命中就 `go_to()` 並 `break`。

> 因為是精確字串比對，若某分鐘被跳過（低幀率或時鐘倍率過快），該筆行程會被整個錯過。

```gdscript
func move_to_target() -> void
```
每個 physics frame 由 `_physics_process` 呼叫。導航完成即歸零速度並清除 `has_target`；否則朝 `get_next_path_position()` 前進。

### 視覺感測

```gdscript
func _check_line_of_sight() -> void
```
每個 physics frame 執行。對 `detected_targets` 中每個目標，把 `RayCast2D` 指向對方並 `force_raycast_update()`；若第一個命中的碰撞體就是對方（或其子節點），代表中間沒有牆，觸發 `_trigger_detection()`。

```gdscript
func _on_vision_area_entered(other_area: Area2D) -> void
func _on_vision_area_exited(other_area: Area2D) -> void
```
`VisionArea` 的訊號處理器，在 `_ready()` 中以程式碼連接。進入時取 `other_area.get_parent()`，過濾掉自己與非 `villagers` 群組的節點後加入 `detected_targets`；離開時移除，且清空後會呼叫 `bubble.say("")`。

```gdscript
func _trigger_detection() -> void
func _pause_movement(duration: float) -> void   # async
```
偵測成立時顯示 `"！"` 氣泡，並在未暫停的情況下暫停移動 2 秒。

> `_check_line_of_sight()` 每幀都可能觸發，`is_paused` 是唯一的重入保護，因此暫停結束的瞬間可能立刻被再次觸發。

### 除錯快捷鍵

`_unhandled_input` 監聽（無 InputMap，直接讀 keycode）：

| 按鍵 | 行為 |
|---|---|
| `D` | 切換 `debug_draw`（感測範圍圓） |
| `=` / 小鍵盤 `+` | 感測半徑 +1 格 |
| `-` / 小鍵盤 `-` | 感測半徑 −1 格 |

> 所有村民都會收到 `_unhandled_input`，按一次鍵會同時影響場上**每一個**村民。

### 動畫

```gdscript
func update_animation() -> void
```
依 `velocity` 方向播放 `walk_down` / `walk_up` / `walk_right` / `walk_down_right` / `walk_up_right`；向左靠 `flip_h` 鏡像。速度 < 1 時把 `walk_*` 換成對應的 `idle_*`。

```gdscript
func get_place_for_need(need: String) -> String
```
需求名稱 → 場所名稱的對照：`hunger→restaurant`、`energy→home_001`、`social→square`、`fun→square`，其餘回傳 `""`。

> `energy` 硬編碼為 `home_001`，對其他村民而言是錯的目的地。目前尚無呼叫端。

```gdscript
func choose_direction() -> void
func _on_state_changed() -> void
```
`_on_state_changed()` 在有目標時直接返回，否則於 `WANDER` 狀態隨機取一個 `direction`。

> `direction` 目前**沒有被 `_physics_process` 使用**——移動完全由 `NavigationAgent2D` 決定，隨機遊走尚未接上。`_on_state_changed` 也未連接到 `StateMachine.state_changed`。

---

## `needs.gd`

`scripts/npc/needs.gd` — 四項需求數值，每幀線性衰減並 clamp 在 0–100。

### 訊號

```gdscript
signal need_changed
```
已宣告但**目前沒有任何地方 emit**。

### 屬性與衰減率

| 名稱 | 預設 | 每秒衰減 | 歸零時間 |
|---|---|---|---|
| `hunger` | `100.0` | `3.0` | ~33 秒 |
| `energy` | `100.0` | `1.0` | ~100 秒 |
| `social` | `100.0` | `0.5` | ~200 秒 |
| `fun` | `100.0` | `0.2` | ~500 秒 |

四項皆為 `@export`，可在 Inspector 調整初始值。

### 方法

```gdscript
func needs_attention() -> bool
```
任一項 < 30 即回傳 `true`。

```gdscript
func get_lowest_need() -> String
```
回傳最低的需求名稱（`"hunger"` / `"energy"` / `"social"` / `"fun"`）。平手時依 hunger → energy → social → fun 的順序優先。

> `_process` 每 5 秒 `print` 一次四項數值（`H:/E:/S:/F:`），無開關可關閉。

---

## `state_machine.gd`

`scripts/npc/state_machine.gd` — 極簡計時式狀態機。

### 訊號與列舉

```gdscript
signal state_changed
enum State { IDLE, WANDER, WORK }
```

### 屬性

| 名稱 | 型別 | 說明 |
|---|---|---|
| `current_state` | `State` | 目前狀態，初始 `IDLE` |
| `timer` | `float` | 剩餘秒數，歸零即切換 |
| `enabled` | `bool` | `false` 時 `_process` 直接返回 |

### 方法

```gdscript
func start() -> void     # enabled = true，並進入 IDLE
func stop() -> void      # enabled = false（保留目前狀態）
func switch_state() -> void
func change_state(new_state) -> void
```

`switch_state()` 只在 IDLE ↔ WANDER 間來回：IDLE 停 3 秒、WANDER 停 5 秒，各自 `print` 一行中文除錯訊息。

> `State.WORK` 已定義但沒有任何轉換路徑會進入。`change_state()` 的 `match` 也沒有 `WORK` 分支——若手動切入，`timer` 會停在 0 而每幀重複觸發。
> `enabled` 預設為 `false`，且沒有任何腳本呼叫 `start()`，所以狀態機目前是停用狀態。

---

## `bubble.gd`

`scripts/bubble.gd` — 頭頂對話氣泡，會依文字長度自動調整寬度並置中。

### 場景節點需求

```
Bubble (Node2D)
└── BubbleBox (NinePatchRect)
    └── Label
```

### 常數

| 名稱 | 值 | 說明 |
|---|---|---|
| `MAX_CHAR` | `10` | 單行最大字數，超過截斷並補 `……` |
| `BOX_HEIGHT` | `36` | 氣泡固定高度 |
| `PADDING_X` | `24` | 文字左右內距 |
| `MIN_WIDTH` | `48` | 最小寬度 |

### 方法

```gdscript
func say(message: String, duration := 2.0) -> void   # async
```
顯示訊息 `duration` 秒後自動隱藏。內部會 `await get_tree().process_frame` 讓 `Label` 算出 `get_minimum_size()`，再據此設定 `BubbleBox` 的寬度與位置（`x = -width / 2` 置中）。

> 這是 coroutine，呼叫端通常不 await（如 `bubble.say("！")`）。
> **沒有處理重入**：在前一次 `say()` 的計時器結束前再呼叫，舊的 timeout 仍會把氣泡藏起來。`villager.gd` 在 `detected_targets` 清空時呼叫 `say("")`，是靠這個副作用「清空」氣泡，但仍會顯示一個空氣泡 2 秒。

---

## `json_loader.gd`

`scripts/json_loader.gd` — 通用 JSON 讀檔工具。

```gdscript
func load_json(path: String)
```
讀檔並 `JSON.parse_string()`。檔案開不起來時回傳 `null`；**解析失敗時也回傳 `null`**（無法區分兩者，也沒有錯誤訊息）。

> `game_manager.gd` 自己重複實作了同樣的讀檔邏輯，沒有使用這個工具。

---

## 依賴關係

```
GameClock ──time_changed──▶ villager.on_time_changed ──▶ go_to()
                                                           │
GameManager.get_place() ◀──────────────────────────────────┘

villager ──▶ NavigationAgent2D ──▶ move_and_slide()
         ├─▶ Bubble.say()
         ├─▶ Needs（自主衰減，無人查詢）
         ├─▶ StateMachine（未 start()）
         └─▶ VisionArea + RayCast2D ──▶ detected_targets

place_manager ──▶ GameManager.places / get_place_data()   # 未掛載
```

## 已知問題

1. **`place_manager.gd` 未掛載**：既非 autoload 也未被任何場景引用，容量上限完全沒有生效——多個村民可以同時擠進 `capacity: 1` 的房子。要啟用需在 `project.godot` 的 `[autoload]` 加入，並確保排在 `GameManager` 之後（它的 `_ready()` 讀取 `GameManager.places`）。
2. **`json_loader.gd` 為死碼**，功能已被 `game_manager.gd` 內聯重複實作。
3. **`StateMachine` 從未啟動**：`enabled` 預設 `false` 且無人呼叫 `start()`；`_on_state_changed` 也沒有連接到 `state_changed` 訊號。
4. **`Needs` 是唯讀的裝飾**：數值持續衰減，但 `needs_attention()` / `get_lowest_need()` / `get_place_for_need()` 都沒有呼叫端，村民不會因為餓了而改變行為。
5. **行程比對可能漏拍**：`on_time_changed` 用字串精確比對 `HH:MM`，跳過的分鐘等於跳過該筆行程。
6. **除錯快捷鍵是全域的**：`D` / `+` / `-` 會同時作用在所有村民身上。
7. **`get_place()` 用 `Vector2.ZERO` 表示查無**，與合法的原點座標無法區分。
8. **`get_place_for_need("energy")` 硬編碼 `home_001`**，不會回到各自的家。
