---
tags: [ailley, poc, task-handoff, director-mode, bugfix]
status: done
created: 2026-07-24
---

# 任務交接：JSON 崩潰防禦修復（n_predict 上限 + 解析失敗重試）

> [!info] 用途
> 這份筆記是給另一個 Claude Code session 接手用的自包含任務說明。背景脈絡見 [[POC 紀錄 - 導演模式 B]] 第 856-863 行「目前累積的待決策/待辦清單」與其後續章節，這裡只抽出跟這次任務直接相關的部分。

> [!success] 已完成（2026-07-24）
> 實際上是同一個主 checkout 裡直接接手完成的，不是另開 session。做法、實測數字、驗證結果都寫在 [[POC 紀錄 - 導演模式 B]] 的「JSON 崩潰防禦修復：n_predict 上限 + 解析失敗重試」章節，這份筆記保留當初的任務說明原文，不再更新。

## 背景

`director_poc.py` / `continue_director_poc.py` / `poc_mode_a/dialogue_ping_pong.py` 這幾支腳本呼叫 llama-server 時用 `n_predict: -1`（不設生成長度上限）。長鏈驗證過程中踩到三種崩潰模式，都發生在 JSON 解析成功「之前」，事後比對類的修復機制（`repeat_guard`／`batch_regen`）天生攔不到：

1. **單欄位失控複製**：模型陷入某個欄位的生成迴圈，同一句話複製上百次，把 JSON 撐爆到解析失敗（15 條鏈中出現 1 次，約 7%，見「新發現：更嚴重的失控案例」章節）。
2. **JSON 引號混用語法錯誤**：模型輸出中英文引號混用，破壞 JSON 字串邊界（Mode A 測試中 15 場出現 1 次，約 7%）。
3. **grammar `ws` 規則無長度上限卡死**：`ws ::= [ \t\n]*` 沒有上限，模型卡在裡面狂吐空白字元直到吐出 24000+ 字元的破碎 JSON。**這個已經修過**，見下方「已驗證的修法」。

## 已驗證的修法（直接複製這個 pattern）

`poc_mode_a/dialogue_ping_pong_memory.py` 已經踩過第 3 種崩潰並修好，可以直接參考／複製：

- `call_director()` 函式簽名加 `n_predict: int = -1` 參數（保留預設 -1 給不需要限制的呼叫）。
- 對於「期望輸出很短、有明確上限」的呼叫（例如重要性評分只需要 `{"importance": N}`），明確傳入 `n_predict=20` 這種小上限。
- 加 `except SystemExit` 保底，失敷就回退成預設值（例如重要性評分失敗就用預設分數 5），不讓一次呼叫失敗拖垮整場/整條鏈。

## 要做的事

**⚠️ 重要：檔案位置**——真正要改的檔案在**主 checkout** `/home/neon/Projects/Ailley`，分支 `agent-loop-persistent-memory`（從 `neon-POC` 分出來），不是任何一個 worktree 裡的舊副本。先確認自己在正確的分支上再動手。

1. **盤點所有 `n_predict: -1` / `n_predict=-1` 呼叫點**，至少包含：
   - `poc/director_poc.py`
   - `poc/continue_director_poc.py`（第 266 行附近）
   - `poc/director_poc_cloud.py`（雲端版，可能不適用同一套邏輯，OpenRouter 的長度限制機制不同，需要先確認）
   - `poc_mode_a/dialogue_ping_pong.py`（第 268 行附近，注意：這支是「有問題的舊版」，`dialogue_ping_pong_memory.py` 才是已修好的版本，兩支都在用，要看記憶版本是否已完全取代舊版或並存）
   - `poc_agent_loop/agent_loop.py` 裡是否還有其他預設 `n_predict: -1` 的呼叫（第 99 行主 payload 是 -1，第 143-146 行的重要性評分呼叫已經有 override 成 20，只需要確認主對話生成呼叫要不要也設上限）

2. **對每個對話生成呼叫（不是評分呼叫）設一個寬鬆但有界的 `n_predict` 上限**：依 `MAX_TURNS`（目前預設 6）× 每回合預估 token 數抓一個安全值，寧可設鬆一點也不要卡死。抓法：可以先用 `/tokenize` API 對幾份現有 transcript 的完整回應算實際 token 數，取最大值加緩衝（例如 ×1.5）當上限。

3. **加一層通用的 JSON 解析失敗重試**：解析失敗時，同一批次重打一次（最多 1-2 次），不是讓整條鏈/整天直接崩潰。這跟 `poc_agent_loop` 已經有的「當天沒存檔=可安全重跑」精神一致，只是把保護粒度從「一整天」下放到「一次呼叫」，成本更低。

## 驗證方式

- 找出過去曾經觸發過崩潰的 seed／角色配對（筆記裡有記錄具體場次，例如 batch_regen v2 擴大驗證那條在第 3 輪崩潰的鏈），重跑確認不再崩潰、或至少能被重試機制救回來。
- 至少跑一次原本規模的長鏈驗證（15 條鏈，`MAX_TURNS=6` 起始 + 續 5 輪疊到 36 回合），確認：
  - 沒有新的崩潰模式被引入。
  - n_predict 上限沒有誤傷正常長度的生成（不能出現「正常內容被腰斬」的新問題）。
- 結果記錄回 [[POC 紀錄 - 導演模式 B]]，格式比照既有章節（做法／驗證表格／結論）。

## 明確不在這次任務範圍內

- 不是要解決「重複退化」本身——那條線已經有結論（見 [[POC 紀錄 - 導演模式 B]] 「repeat_end」章節後的總結），三次獨立嘗試都打不穿，這次不重新挑戰。
- 不是要優化取樣參數（temperature/top_p 等）——那條線也已經有結論。
- 只處理「會讓整場直接崩潰掛掉」的硬故障，不處理「內容有瑕疵但至少能跑完」的問題。
