---
created: 2026-08-07
tags: [ailley, api, 文件, 盤點]
status: done
---

# 腳本 API 盤點

盤點 `Ailley/scripts/` 全部 8 支 GDScript（共 533 行），完整 API 文件輸出至 `Ailley/docs/api-reference.md`。

## 架構現況

- **Autoload 只有兩個**：`GameManager`（JSON 靜態資料）、`GameClock`（遊戲時鐘，08:00 起跳）。
- 主要迴路：`GameClock.time_changed` → `villager.on_time_changed()` → `go_to()` → `NavigationAgent2D`。
- 村民場景固定需要 `AnimatedSprite2D` / `StateMachine` / `Needs` / `NavigationAgent2D` / `Bubble` / `VisionArea` / `RayCast2D` 七個子節點。

## 發現的問題（優先處理順序）

> [!warning] 三個子系統沒有接上
> 1. `place_manager.gd` **未註冊為 autoload、未被任何場景引用** → `capacity` 上限完全沒生效，村民可以擠爆 `capacity: 1` 的房子。掛載時要排在 `GameManager` 之後。
> 2. `StateMachine` 的 `enabled` 預設 `false`，沒有任何地方呼叫 `start()`；`villager._on_state_changed` 也沒連上 `state_changed` 訊號 → 隨機遊走等於不存在。
> 3. `Needs` 數值持續衰減，但 `needs_attention()` / `get_lowest_need()` / `get_place_for_need()` 全無呼叫端 → 村民餓了不會有反應。

> [!note] 其他
> - `json_loader.gd` 是死碼，`game_manager.gd` 自己內聯重寫了同樣的讀檔邏輯。
> - `on_time_changed` 用字串精確比對 `HH:MM`，跳過的分鐘 = 跳過該筆行程。
> - 除錯快捷鍵 `D` / `+` / `-` 走 `_unhandled_input`，會同時作用在**所有**村民身上。
> - `get_place()` 用 `Vector2.ZERO` 當「查無」，跟合法的原點座標無法區分。
> - `get_place_for_need("energy")` 硬編碼 `home_001`，不會回各自的家。
> - `bubble.say()` 沒有重入保護，舊的 timeout 會提前藏掉新氣泡。

## 待辦

- [ ] 決定 `place_manager` 要掛 autoload 還是併進 `GameManager`
- [ ] 接上 `Needs` → `get_place_for_need()` → `go_to()`，讓需求真正驅動行為
- [ ] `get_place_for_need("energy")` 改成查該村民自己的家
- [ ] 移除或改用 `json_loader.gd`
