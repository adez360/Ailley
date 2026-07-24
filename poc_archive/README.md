# POC 封存區

這裡存放已經確定不採用、但保留作參考的早期 POC 版本。封存原因跟細節見
`note/40-規劃與路線圖/POC 完整技術文件 - 架構、測試方法、檔案與資料流程.md`
與 `note/40-規劃與路線圖/POC 架構總覽與 Generative Agents 論文比對.md`。

## 目前確定要繼續發展、拿來寫正式主程式的版本（不在這裡）

- `poc_mode_a/dialogue_ping_pong_multimodel.py`——一村民一模型架構
- `poc_agent_loop/`——規劃 → 行程重疊觸發相遇 → 對話 → 意識流 → 跨天持久化記憶

正式主程式會把這兩者合併：`poc_agent_loop` 的整體迴圈架構為基礎，對話生成環節換成
`dialogue_ping_pong_multimodel.py` 驗證過的「依村民切換底層模型」機制。

## 這裡封存的內容

- `poc/`——導演模式 B（單一 LLM 扮演旁白/導演），含大量針對「長鏈重複退化」的實驗分支
  （repeat_guard／batch_regen／misdirect_settle／repeat_end／narrowwindow／natural_end）。
  只有 narrowwindow 的視窗限制邏輯被驗證有效，其效果已經吸收進
  `poc_agent_loop`／`poc_mode_a` 的 `RECENT_TURNS_WINDOW` 機制裡，不需要保留這整條線繼續維護。
- `poc_planning/`——最早的 Planning 最小可行 POC，邏輯已經被 `poc_agent_loop` 原封不動沿用，
  獨立保留意義不大。
- `poc_mode_a_legacy/`——`poc_mode_a/` 底下已被取代的舊版對話腳本：
  - `dialogue_ping_pong.py`（最早版本，全部歷史無限制塞進 prompt）
  - `dialogue_ping_pong_memory.py`（加上記憶流檢索，`dialogue_ping_pong_multimodel.py` 的直接基礎）
  - `dialogue_ping_pong_memory_embed.py`（驗證過 embedding 相關性檢索會強化重複退化，未採用）
