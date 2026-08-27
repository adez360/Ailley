---
tags: [交流, 交接]
status: 進行中
updated: 2026-08-27
---

# 交接：issue #601 trust 欄位移除（需要 Godot 編輯器）

分支 `chore/remove-relations-trust-field` 已從 issue #601 開好、推上 origin，
並且已經 rebase 對齊最新 main（commit `edb4197`）。先
`git fetch && git checkout chore/remove-relations-trust-field` 接續，不要重開
分支，也不用再 rebase（已經是最新的）。

## 背景

`relations.trust` 全庫查證零引擎消費者：`persuade` 已於 issue #177（《00》原則四）
改成不擲骰、完全交給被說服者自己的模型判斷 `persuaded`，從沒讀過 trust；PR #489
（已合併）把僅存的三個固定公式加減（深度對話+2／被攻擊-50／被救助+15）也改成
事實句陳述，`trust` 因此變成只寫不讀的死欄位，違反《00》原則三「除了餵給LLM讀，
引擎自己有沒有拿它算東西」。這次要比照 2026-08-16 拿掉 affinity/familiarity/debt
的做法把 trust 整條拿掉。追蹤於《99》P-60——但 P-60 目前只存在另一個未合併的
PR #557（全專案稽核分支）裡，還沒進 main。**這則 PR 刻意不動
`note/規格書/99_待規劃項目清單.md`**（避免跟 43-commit 的 #557 搶著改同一段，
等 #557 合併時一起帶入「已解決」狀態），只在 PR 描述裡文字引用《99》P-60，
不要自己加一份新的 P-60 條目進 99 檔案。

## 已完成

- [x] `Ailley/scripts/character/relationships.gd`（commit `edb4197`）：拿掉 trust
  欄位、`get_trust()`/`add_trust()`、`TRUST_MIN`/`MAX`，`load_save_data()` 已清理

## 還要做的事

- [ ] `Ailley/scripts/database/schemas/NPCRelationsSchema.gd`：移除 `relations_trust`
      欄位，需要一版 DB migration（`DatabaseSchema.CURRENT_VERSION` 遞增）——
      先查目前版本號有沒有其他分支同時在動（P-60 筆記提過 PR #511 曾撞過版本號）
- [ ] `Ailley/scripts/save/sqlite_save_service.gd`：拿掉對應的讀寫映射
- [ ] `Ailley/scripts/ai/prompt_builder.gd`：`_listener_block()` 移除 `trust`
- [ ] `Ailley/scripts/ui/debug_console.gd`：移除 trust 顯示欄
- [ ] `note/規格書/01_角色數值規格書.md` §3-1：移除 trust 變動表，比照
      affinity/familiarity/debt 移除時的說明方式補一段（不要留「原本/後來」對照，
      只寫現況）

## Godot 內測試（這是換到這台機器的原因）

CLAUDE.md 規定 Godot 場景/腳本改動要用 godot-ai MCP 測試。動工前：
1. `session_manage(op="list")` 確認有沒有連到本專案 project_path 的 session，
   沒有就回報使用者請他開編輯器
2. 之後每次呼叫 godot-ai 工具都明確帶上這個 session_id
3. 完成後用 `project_run` 跑起來、`game_eval` 或既有的 debug 主控台指令
   （`status <name>` 等）驗證 trust 欄位真的從角色狀態、存讀檔、debug 顯示裡
   消失，且不會因為缺這個欄位而報錯

## 完成後開 PR

- Push 到 `chore/remove-relations-trust-field`，開 PR 標題用英文、內文中文，
  `Closes #601`，PR 描述裡引用《99》P-60 說明背景（可參考 issue #601 本文）
- 依照這個專案既有 workflow：開 PR 後 `gh pr comment <N> --body "@coderabbitai
  full review"` 觸發審查，逐項判斷 CodeRabbit 意見（不需要修正就回覆說明理由，
  需要修正就修完回覆「已修復」，新 commit 觸發下一輪 review，重複到沒有新意見）
- 確認可合併：用一次 GraphQL query 把 review 狀態、statusCheckRollup、
  reviewThreads 的 isResolved 一起撈出來，確認最新一筆 CodeRabbit review 是
  APPROVED 且全部 thread 都 resolved，都過就留言「已自審完成」，不用另外叫
  subagent 自審
- 過程中若呼叫 `@coderabbitai full review` 累計 5 次都未獲回應：停止再等，
  留言註明「CodeRabbit 逾時未回應」，回報使用者

## 完成這則後，同一台有 Godot 的機器上還有別的事可以撿

這幾則都需要 godot-ai，這個 session 一直卡在沒有連線，如果 Windows 那邊順利，
處理完 #601 可以繼續往下：

- **#391**（per-character home assignment）：OPEN，無 PR，要在地圖上擺房子、
  建角時指派 `home_location_id`
- **#455**（auto re-embody player character on save load）：OPEN，無 PR
- **#384**（life_highlights 彙整）：OPEN，無 PR，但依賴的死亡/墓園系統已合併，
  現在可以動工了
- **#477**（Task.preconditions）：已有 PR #530，`CHANGES_REQUESTED`——**使用者
  先前指示過這則先不要處理**，除非使用者另外交代，否則跳過

有任何需要拍板的設計問題（例如 migration 版本號怎麼排、schema 欄位怎麼刪）
隨時停下來問使用者，不要自己猜。
