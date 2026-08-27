---
tags:
  - 交流
status: 現況
updated: 2026-08-27
---

# 交接：main.tscn 拆除 Agent~Agent5（issue #599）

這則筆記是給**另一台有 Godot 編輯器可開的機器**上的 Claude Code session 接手用的。
本機（沒有 godot-ai MCP 連線）只能做到程式邏輯與資料層的部分，場景節點的實際刪除
必須在有編輯器、有 MCP session 的機器上進行。做完、確認 PR 合併後，這則筆記可以刪除。

## 背景（先讀這個，不用重查）

`main.tscn` 目前寫死放了 `Agent`~`Agent5` 五個角色節點，但依《規格書10》
§2.1、§8.6（B21/B24/B25/B27），世界的人口組成應該由玩家在建立世界時自己
決定要投放什麼——可以只投真人、只投 AI、混合、甚至一個都不投；世界開啟後
也能持續有新人加入。規格裡沒有「村莊本來就該有幾個固定村民」這件事。這五個
節點是拍板前留下的測試資料，繞過了投放機制（`spawn_character()`／
`deploy_from_library()`），也繞過 B21（個人投放上限）、B26（房主審核）。

完整脈絡見 `note/交流/決策.md`「村莊人口由玩家投放決定，不寫死（2026-08-26）」
一節，以及 `note/技術/角色庫與投放.md`。

## 前置條件：確認 #598 已經合併

**這是阻塞項，先檢查再動手。**

`deploy_from_library()`／`spawn_character()` 過去投放出來的角色不會被打開
`llm_decision_enabled`（只有開機時跑一次的 `main_scene.gd::_apply_startup_ai_state()`
會打開，且只認開機當下就在場的節點）。如果 `Agent`~`Agent5` 被拆掉、又沒有這個
修正，投放出來的角色會是完全靜止、不做任何決策的殭屍角色。

檢查方式：

```bash
gh pr view 619 --repo adez360/Ailley --json state,mergedAt
```

或直接看 `Ailley/scripts/core/game_manager.gd` 的 `deploy_from_library()`
結尾（`entry["deployed"] = true` 之後）有沒有一段呼叫
`agent.debug_set_llm_decision(true)` 的邏輯。**如果還沒合併，先處理 #598
（PR #619），不要先做這則。**

## 這則要做的事（issue #599）

1. `git fetch && git switch refactor/main-scene-blank-village`——這條分支已經
   建好、追蹤 `origin/refactor/main-scene-blank-village`，從 main 分出來，
   目前是乾淨的（還沒有任何 commit）。如果 #598 已經合併進 main，先
   `git rebase origin/main` 把它帶進來
2. 依 `Ailley/CLAUDE.md` 的規則，**開場檢查**：
   - `session_manage(op="list")` 確認編輯器有連線
   - `editor_state` 確認 `readiness=ready`
3. `scene_get_hierarchy` 看一次 `main.tscn` 目前結構，確認 `Agent`~`Agent5`
   五個節點還在（跟本筆記描述的一致，見下方「目前結構」）
4. 用 `node_manage`（不是手改 `.tscn`）把 `Agent`、`Agent2`、`Agent3`、
   `Agent4`、`Agent5` 五個節點從 `main.tscn` 刪除。`Player` 節點保留——
   它是 MVP-1 測試用途，跟這則的範圍無關（見下方「範圍界線」）
5. `scene_save` 存檔
6. 驗證：`project_run` 跑起來，`editor_screenshot` 看一次村莊現在是空的（除了
   `Player`），`logs_read` 確認沒有非預期錯誤。可以的話用 debug 主控台
   `spawn tpl_051`（或其他 template_id，如果 #600 的 PR #620 已合併）投放一隻
   角色，確認投放出來的角色會動（間接驗證 #598 有生效）
7. `project_manage(op="stop")`

## 目前結構（拆除前，供比對）

```
Node（main_scene.gd）
├── Level
├── PersistentUI
├── Player          ← 保留，不是這則的範圍
├── Agent            ← 刪除
├── Agent2           ← 刪除
├── Agent3           ← 刪除
├── Agent4           ← 刪除
├── Agent5           ← 刪除
├── Workstation
├── VendingMachine
└── VendingMachineHerbShop
```

## 範圍界線

- 不含 `llm_decision_enabled` 的修正——那是 #598（前置條件，見上）
- 不含把人設轉正進範本庫——那是 #600（PR #620，跟這則沒有先後依賴，可以
  先合併也可以後合併，只要在這則實際刪節點之前合併過一次就好，免得五份
  人設在任何時間點「兩邊都沒有」）
- 不含 `Player` 節點的處理——`main.tscn` 常駐 `Player` 節點跟「MVP-1 玩家
  預設無身體、靠天神之石介入」的既定方向已經有落差，但那是已經被追蹤在
  `note/交流/MVP開發看板.md`／`專案現況.md` 的既有事項（MVP-2 化身者），
  不是這次發現的新問題，不要一起動

## 完成後

- `gh pr create` 走正常流程，`--base main --head refactor/main-scene-blank-village`，
  body 引用 `Resolves #599`
- 這則交接筆記可以刪除了

## 相關

- `note/交流/決策.md` ——「村莊人口由玩家投放決定，不寫死」
- `note/技術/角色庫與投放.md`
- issue #598（PR #619，前置條件）／#599（這則）／#600（PR #620）
