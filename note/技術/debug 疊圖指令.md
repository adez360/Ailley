---
tags:
  - debug
scene: scenes/main.tscn
status: 已實作
updated: 2026-08-12
---

# debug 疊圖指令

主控台的 `debug` 指令，開關遊戲中的除錯疊圖。相關筆記：[[尋徑與 Debug 主控台]]。

```
debug                 列出所有項目與開關狀態
debug <項目>          切換
debug <項目> on|off   明確指定
debug off             全關
```

| 項目 | 畫什麼 |
| --- | --- |
| `grid` | tile 網格線，涵蓋整個 NavGrid region |
| `coord` | 每格左上角標格座標 |
| `solid` | NavGrid 判定為障礙的格，紅色半透明填色 |
| `path` | 所有角色目前的 A* 路徑（折線 + 路徑點） |
| `collision` | 碰撞形狀 |
| `vision` | 角色的視野範圍與目前看得到誰 |

檔案：`scripts/ui/debug_overlay.gd`，掛在 `main.tscn` 的 `Node2D/DebugOverlay`
（group `debug_overlay`，`z_index = 50`）。

## 為什麼是逐項開關而不是一個總開關

全部同時畫會糊成一片，`coord` 在格子多的時候尤其吵（目前 region 是 32x24 = 768 格）。
要加一項只要在 `layers` 字典多一行，指令的清單與錯誤提示會自己跟上。

## collision 不是自己畫的

另外四項都是 `_draw()` 裡自己畫，只有 `collision` 是去打開 Godot 本來就有的除錯繪製，
而且是**兩套獨立機制**：

- `CollisionShape2D`：看 `SceneTree.debug_collisions_hint`。這個旗標改完不會自動重繪，
  要對每個 shape 呼叫一次 `queue_redraw()`
- `TileMapLayer`：不看上面那個旗標，走自己的 `collision_visibility_mode`

> [!warning] DEBUG_VISIBILITY_MODE_FORCE_SHOW 是 1 不是 2
> 這個 enum 的值不照直覺排：`DEFAULT = 0`、`FORCE_SHOW = 1`、`FORCE_HIDE = 2`。
> 憑印象寫會靜靜地把碰撞藏起來而不是顯示。

## 幾個實作細節

- `nav.cell_to_world()` 回傳的是**格中心**，畫格線與填色要退半格才對得齊
- 路徑每幀都在變，所以有任何一項開著時才 `set_process(true)` 持續重畫，全關就停掉
- 線寬是世界單位，鏡頭拉遠時網格線會細到看不見。這是世界座標疊圖的正常行為，
  遊戲常用的縮放下沒問題，真的要改就把線寬除以 `camera.zoom`

## 截圖驗證時的一個坑

`path` 很難截到 —— 角色抵達時 `stop_moving()` 會清空 `_path`，而一次工具往返就走完了。
解法是下完 goto 後立刻 `get_tree().paused = true`，畫面會凍在最後一次繪製的內容上。

