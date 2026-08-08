---
tags:
  - 尋徑
  - debug
  - 外掛修改
scene: scenes/main.tscn
status: 已實作
updated: 2026-08-08
---

# 尋徑與 Debug 主控台

`main.tscn` 的角色移動除了 WASD 之外，多了一組「走到指定座標」的 API，
以及一個遊戲中的指令輸入框可以直接測。

## 檔案

| 檔案 | 角色 |
| --- | --- |
| `scripts/world/nav_grid.gd` | A* 網格（`AStarGrid2D`），節點 `Node2D/NavGrid`，group `nav_grid` |
| `scripts/character/player.gd` | 玩家移動 + `move_to()` API，group `player` |
| `scripts/ui/debug_console.gd` + `scenes/debug_console.tscn` | 指令輸入框 |

## API

```gdscript
player.move_to(Vector2(x, y)) -> bool   # A* 走過去；找不到路徑回傳 false
player.stop_moving()
player.is_moving() -> bool
player.get_body_position() -> Vector2   # 碰撞圓心，不是 global_position
signal player.move_finished(reached: bool)
```

## 指令（按 `` ` `` 開關，Esc 關閉，上下鍵翻歷史）

- `goto <x> <y>`：走到世界座標
- `stop`：停止移動
- `pos`：顯示座標與所在格
- `nav rebuild`：重建尋徑網格（改完地圖不用重開遊戲）
- `help` / `clear`

## 設計決策與踩過的坑

> [!important] 可走性用物理查詢量，不讀 tile data
> TileMapDual 是 dual-grid：畫的是「世界層」，實際貼圖與碰撞在執行時生成的子
> TileMapLayer 上。改用 `intersect_shape()` 逐格丟一個玩家大小的圓去試，
> 就不必碰 addon 內部，之後手動放進場景的 `StaticBody2D` 也會自動變成障礙。

> [!warning] TileMapDual 外掛被改過一行：碰撞只取世界層
> 外掛會生出**兩個都有碰撞**的圖層，而生成的顯示層偏移半格。
> 碰撞留在顯示層的話，NavGrid 的格中心會落在圖磚角落、探測圓同時碰到周圍四塊，
> 實測掃出 25 格偽障礙。
> `addons/TileMapDual/display_layer.gd:48` 因此把 `collision_enabled` 改成恆為 false，
> 碰撞只由世界層提供，與 NavGrid 完全對齊（偽障礙 0 格）。
>
> **前提：碰撞必須來自世界層的標記圖磚。** 哪天改成只在轉場圖上畫碰撞、
> 世界層不畫，就會變成完全沒有碰撞。理由已寫在改動處的註解裡。
>
> `addons/` 有進版控，所以外掛更新蓋掉這一行時 git 會顯示衝突讓你發現。

> [!warning] 地形碰撞不會在第一幀就位
> `_ready` 後等一個物理幀去掃，結果 `solid=0` —— TileMapDual 的顯示層還沒生成完。
> 現在 `_ready` 會重試最多 10 次，掃到障礙才停。

> [!warning] 掃格要排除角色自己
> 玩家的 `CharacterBody2D` 也在 collision layer 1，不排除的話腳下那格會被標成障礙。
> `query.exclude` 會濾掉場景裡所有 `CharacterBody2D` / `RigidBody2D`。

> [!warning] 尋徑要用碰撞圓心，不是 `global_position`
> Player 的 `CollisionShape2D` 位置是 `(0, 6)`，差了近半格。
> 一開始用 `global_position` 跟隨路徑，waypoint 會把碰撞體塞進牆裡，走幾步就卡住。
> 現在一律用 `get_body_position()`。

> [!note] 輸入框有焦點時要擋住 WASD
> `Input.get_axis()` 讀的是全域輸入狀態，不會被 LineEdit 攔下來，
> 所以 `get_input_direction()` 在 `gui_get_focus_owner() != null` 時回 `Vector2.ZERO`。

其他：`DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES` 避免斜切穿牆；目標落在牆裡會往外找最近的
可走格；走不動超過 1 秒會中止並發出 `move_finished(false)`，不會原地打轉。

移動 API 現在在 `Character` 基底上、Player 與 Agent 共用同一份，
見 [[Character 基底與 Agent]]；路徑視覺化是 `debug path` 圖層，
見 [[debug 疊圖指令]]。


---

## 跟隨鏡頭（2026-08-05）

`Camera2D` 從 `Node2D` 底下搬到 `Player` 底下，跟隨靠父子關係達成，不需要每幀腳本。
開了 `position_smoothing`（speed 8）。

`scripts/world/follow_camera.gd` 只負責一件事：**在 `_ready` 依 TileMap 的 `get_used_rect()`
算出 `limit_*`**，而不是把座標寫死在場景裡 —— 地圖會一直擴建，寫死的值遲早過期
（`PlaceAnchors` 就吃過這個虧）。

邊界取的是**世界層**（TileMapDual）而不是生成的顯示層 —— 顯示層偏移半格，
拿它算邊界會差半格。

> [!note] 地圖比畫面窄時 Godot 會自動置中
> 目前地圖 448 x 320，畫面 480 x 270。水平方向地圖比畫面窄，
> Godot 把鏡頭固定在邊界範圍的中心（x=64），兩側各露出 16px 空白。
> 這不是 bug，是地圖還不夠寬。垂直方向正常捲動並夾在 ±160。
>
> 實測：玩家在左上 → 鏡頭 (64, -25)，可見上緣剛好 -160；
> 玩家在右下 → 鏡頭 (64, 25)，可見下緣剛好 160。
