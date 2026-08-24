---
tags:
  - 技術
  - character
status: 已實作
scene: scenes/persuade_dialog.tscn, scenes/hud.tscn, scenes/player.tscn
script: scripts/character/agent.gd, scripts/character/player.gd, scripts/ui/persuade_dialog.gd
updated: 2026-08-21
---

# persuade 對玩家

NPC 對玩家發起 `persuade` 時的 Y/N 彈窗流程（issue #305）。依賴 #227（`persuade`
核心機制）與 #415（waypoint 導引元件），兩者都已落地。

## 為什麼不是 `_pending_persuade` 那條路

Issue #227 的核心機制是「待回應事實句注入下一輪決策，被說服者的模型自己輸出
`persuaded`」——這條路徑假設目標有 LLM 決策迴圈。玩家沒有：玩家的行動來自
真人操作，不經過 `_request_next_decision()`。`agent.gd::_pursue_persuade_task()`
因此在送達判定通過、確認距離足夠後就分兩條路：目標在 `player` 群組走這裡
描述的 Y/N 彈窗，其餘目標才走 #227 那套 `try_record_pending_persuade()`。

兩條路都不擲骰、都是「送達即成立」，差別只在「被不被說動」怎麼問出來。

## 彈窗：`_ask_player_persuade()`

`agent.gd::_ask_player_persuade(player, reason, proposed_task)` 是 fire-and-forget
（呼叫端 `_pursue_persuade_task()` 不 `await` 它）：送達當下就讓任務照
`persuade` 的固定 duration 收尾，彈窗的結果晚點才回來，兩者互不卡住。

文案比照 #227 對 Agent 目標用的同一種事實句措辭（「說服者是誰、理由是什麼」，
帶 `proposed_task` 時額外描述想讓玩家做的事），複用 `_describe_task_intent()`——
兩條路徑的用字要一致，不要各寫各的。

## `player.gd::request_persuade_response()`：跟 `next_line()`/`turn_resolved` 同一種介面設計

`agent.gd` 不知道彈窗長什麼樣、怎麼收玩家輸入，只呼叫
`player.request_persuade_response(text) -> bool`，內部才去找
`persuade_dialog` 群組的節點並 `await` 它的 `ask()`。跟 `next_line()` 對
`turn_resolved` 訊號的介面抽象是同一種精神：呼叫端只要「玩家的答案」，
不需要知道答案從哪個 UI 事件來。

## `PersuadeDialog`：跟 `vending_menu`／`god_stone_input` 同一種單例寫法

`scenes/persuade_dialog.tscn` 掛在 `hud.tscn` 底下（`PersistentUI` 的子節點，
跟 `ChatInput`／`GodStoneInput` 平行），用 `persuade_dialog` 群組找，不是
存節點參照。同一時間只服務一個請求：`ask()` 被呼叫時若已經開著，直接回傳
`false`（視同拒絕），不排隊、不覆蓋——跟 Agent 目標的
`try_record_pending_persuade()` 忙碌拒絕是同一種精神，只是玩家這邊沒有事後
補顯示的機制，直接讓後到的那筆說服落空。

`layer` 刻意設成 20，比 `god_stone_input`／`vending_menu`／`chat_input` 等其餘
`layer=1` 的面板都高——這則彈窗是 NPC AI 非同步觸發的，玩家隨時可能正開著
另一個 `layer=1` 面板時彈窗突然跳出來，是唯一會跟別的面板同時開著的情況
（其餘面板都是玩家主動開一次只會有一個）。使用者實測發現：兩個 `layer=1`
的 `CanvasLayer` 疊在一起時，視覺上後加入的畫在最上層，但滑鼠點擊事件會被
底下那層搶走，按鈕點不到——同一個 `layer` 只保證畫面順序，不保證滑鼠事件
分派順序也一致，只有明確調高 `layer` 才能兩者都拿到。

`layer=20` 是暫時性的數字，不是系統性方案——下次有第三個需要更高優先權的
面板出現，一樣要猜一個更大的數字。系統性做法（把所有可能互相覆蓋的面板搬進
共用容器，用子節點順序取代 `layer` 數字比較）另開 **#501** 追蹤；#501 完成後
這裡的 `layer=20` 要一併拿掉，改用新容器的子節點排序，不要留下雙重邏輯。

## 選 Y 之後：行動說服導引、純思想說服寫記憶

- **帶 `proposed_task` 且有地點**（`params.place` 解析得到）：呼叫
  `player.waypoint_indicator.show_waypoint()`（#415）導引玩家過去。純粹導引，
  玩家沒有任務池，不會被自動執行動作，去不去、中途放不放棄都是玩家自己決定。
  地點解析不到（世界上不存在、或任務本身沒地點）時靜默略過，不報錯。
- **沒有 `proposed_task`**（純思想說服）：沿用 #227 對 Agent 目標的效果，寫進
  `player.memory.add_candidate()`。玩家沒有 LLM 可以像 Agent 那樣自己評
  `importance`／`valence`，這裡用固定的中等重要度、正面傾向（50 分、
  `positive`）：玩家已經主動選了「Y」，這件事對他來說值得記住、感受傾向
  正面，不是引擎無中生有替他判斷（不違反《00》原則二——這是玩家自己的
  決定被記錄下來，不是引擎替 NPC 貼主觀標籤）。
- **選 N**：什麼都不做，比照 #227 拒絕的情況。

## 補的既有缺口：`player.tscn` 沒有 `WaypointIndicator`

開工前查證發現：`WaypointIndicator`（#415）只手動掛在 `main.tscn` 設計時期
擺的 3 隻測試角色身上，沒有進 `scenes/player.tscn` 這個共用場景本體。
`GameManager.deploy_character()`（`as_player=true` 時）會先 `queue_free()`
main.tscn 那個測試用 Player 節點，再從 `player.tscn` 重新 `instantiate()`——
跟 `Memory` 節點先前踩過的坑（issue #209）同一個模式：真正投放的玩家角色
沒有這個元件。已補進 `player.tscn`，跟 `main.tscn` 現有的 `WaypointIndicator`
節點同一份屬性（`position=(0,-14)`、`Arrow` 子節點同一個 `Polygon2D`）。

## `class_name Player` 缺失

`player.gd` 原本只有 `extends Character`，沒有 `class_name Player`——全庫
之前沒有任何地方需要把 `Player` 當靜態型別用（都是走 `is_in_group("player")`
或 duck typing）。`_ask_player_persuade(player: Player, ...)` 是第一個需要
靜態型別的呼叫端，補上 `class_name Player`（跟 `Character`／`Agent` 等其他
角色腳本一致）。

## 檔案

| 檔案 | 角色 |
| --- | --- |
| `scenes/persuade_dialog.tscn` | Y/N 彈窗場景，掛在 `hud.tscn` 的 `PersistentUI` 底下 |
| `scripts/ui/persuade_dialog.gd` | 開關面板、忙碌拒絕、`ask()` 介面 |
| `scripts/character/agent.gd` | `_pursue_persuade_task()` 的 player 分支、`_ask_player_persuade()` |
| `scripts/character/player.gd` | `request_persuade_response()`、`class_name Player` |
| `scenes/player.tscn` | 補上 `WaypointIndicator`／`Arrow` |
| `locale/game.csv` | `UI_PERSUADE_YES`／`UI_PERSUADE_NO` |

## 相關

- [[記憶與睡眠反思]] —— `player.memory.add_candidate()` 寫入的記憶目前不會被
  任何 prompt 讀取（玩家沒有 LLM 決策迴圈），純粹是資料，之後有功能要讀
  再接
- [[give attack shout 對玩家]] —— 同一個玩家化身群組，NPC 對玩家發起
  give／attack／shout 的相容性驗證與反應補完
- [[Ailley]] —— 筆記庫入口
