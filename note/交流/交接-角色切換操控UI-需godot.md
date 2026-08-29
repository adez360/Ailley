---
tags: [交流, 交接]
status: 進行中
updated: 2026-08-29
---

# 交接：issue #659 角色庫「操控」按鈕（需要 Godot 編輯器）

Worktree 已開在 `.claude/worktrees/feat+character-switch-ui`，分支
`feat/character-switch-ui`（已從最新 main `4158648` 開出，不用再 rebase）。
先 `cd` 進這個 worktree 接續，不要重開分支。

## 背景

原操控角色進入異常狀態（死亡／昏迷）後要換新角色，唯一入口是 debug 指令
`embody <id>`，得肉眼核對角色庫 UUID 手動輸入。issue 要求比照角色庫首頁
既有的清單式操作（編輯／刪除／投放／複製），加一顆可以直接點選的切換按鈕。

範圍界線（issue 本文）：只處理「切換操作方式」本身，不含化身者投放入口 UI
（#372／#378／#455 那一群——查證過 #372／#378／#455 都還 OPEN，#374 已
CLOSED，跟這則本來就是各自獨立的範圍，沒有依賴關係，不用等誰合併）。

## 已完成（純 GDScript 邏輯，未動場景檔）

- [ ] 尚未 commit——改動還在 worktree 工作目錄，下面是內容清單
- `Ailley/scripts/ui/character_library.gd`：`_row()` 在既有的
  編輯／複製／投放／刪除四顆按鈕之間插入「操控」按鈕（`disabled` 條件跟
  「投放」相同，僅未投放者可按），新增 `_on_embody_pressed(id)` 呼叫
  `GameManager.deploy_from_library(id, true)`，失敗時沿用 `_capacity_label`
  顯示 `UI_CL_DEPLOY_FAILED`（跟既有 `_on_deploy_pressed()` 同一套模式）。
  頂部 doc comment「四個操作」同步改成「五個操作」
- `Ailley/locale/game.csv`：新增 `UI_CL_BTN_EMBODY,"操控","Embody"`
- `note/技術/建角面板.md`「開啟入口」一節：`embody <id>` 那段改寫成現況——
  debug 指令保留（腳本化測試／查詢未投放清單仍有效），但角色庫首頁現在有
  正式 UI 入口，兩條路徑並存

`GameManager.deploy_from_library()` 本身沒改：`as_player=true` 分支早就會
自動清掉場景裡既有的 player 節點、把舊條目 `deployed` 重置回 `false`
（見 `game_manager.gd:409-422`），按鈕端不用另外處理。

## 卡住的地方：godot-ai MCP 連不上

這個 session 呼叫 `mcp__godot-ai__*` 全部 `ConnectionRefused`，連
`session_manage(op="list")` 都叫不動，不是「沒有 session」而是 server
本身連不上。本機也沒有 `godot` 在 PATH，headless 備援
（`--headless --path . --check-only`）這條路也走不通，所以這次**完全沒有
驗證過**，純粹是靜態改動＋人工看 diff。

## 完成後開 PR 前要做的事

1. 確認 godot-ai 連得上：`session_manage(op="list")`，找這個 worktree
   `project_path`（`.claude/worktrees/feat+character-switch-ui/Ailley`）
   對應的 session——**不要借用別的 worktree 已連上的 session**，沒有就回報
   使用者開一個專屬 Godot editor 視窗指向這個 worktree
2. 之後每次呼叫都明確帶這個 session_id
3. `project_run` 進遊戲、開角色庫（debug 指令 `charnew` 建至少一個未投放
   角色，`charlib` 開面板），確認「操控」按鈕：
   - 顯示文字正確（`UI_CL_BTN_EMBODY` 有沒有正確落地成「操控」）
   - 未投放者可按、已投放者 disabled，跟旁邊「投放」同步
   - 按下去真的換上該角色（`get_first_node_in_group("player")` 變成新角色）
   - 原本操控的舊角色（如果是化身角色庫來的）`deployed` 正確重置回 false
   - 失敗情境（世界投放上限已滿）`_capacity_label` 有正確顯示
4. `editor_screenshot` 確認排版沒有明顯跑版——**這是這次最沒把握的一塊**：
   `_row()` 這個 HBoxContainer 塞五顆按鈕＋四個 Label，`PANEL_SIZE` 沒動
   （仍是 `Vector2(560, 260)`），新按鈕文字取了跟其他按鈕同樣精簡的兩字
   「操控」（不是 issue 建議的「切換操控」四字，避免更擠），但沒有實機驗證
   過整排會不會超出面板寬度、六維摘要文字會不會被擠爆——若真的跑版，
   優先考慮把 `PANEL_SIZE.x` 略為加寬（viewport 只有 640 寬，加寬空間有限），
   不要輕易砍掉六維摘要
5. `logs_read` 確認沒有非預期錯誤
6. 都過了才 push 開 PR：標題英文、內文中文，`Closes #659`

有任何需要拍板的問題（例如排版真的擠不下時要不要砍欄位）隨時停下來問使用者。
