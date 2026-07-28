# POC 封存區

這裡存放已經確定不採用、但保留作參考的早期 POC 版本。封存原因跟細節見
`note/40-規劃與路線圖/POC 完整技術文件 - 架構、測試方法、檔案與資料流程.md`
與 `note/40-規劃與路線圖/POC 架構總覽與 Generative Agents 論文比對.md`。

## 目前確定要繼續發展、拿來寫正式主程式的版本（不在這裡）

- `poc_mode_a/dialogue_ping_pong_multimodel.py`——一村民一模型架構
- `poc_agent_loop/`——規劃 → 行程重疊觸發相遇 → 對話 → 意識流 → 跨天持久化記憶

正式主程式會把這兩者合併：`poc_agent_loop` 的整體迴圈架構為基礎，對話生成環節換成
`dialogue_ping_pong_multimodel.py` 驗證過的「依村民切換底層模型」機制。

> [!warning] 2026-07-28 更新
> 上面這段是舊規劃（紅藍村獻祭博弈場景時代寫的）。引擎改 Godot、村民 AI 規格改版之後，
> 實際往下發展的是全新的 `poc_village_sim/`（六維人格＋生理狀態＋通用動作＋睡眠反思＋
> 攻擊/生命值系統，已經過多輪 20-30 tick × 5 次批次驗證），不是這裡講的「合併 A+B」路線。
> `poc_agent_loop/memory_store.py`／`run_multiday.py`（跨天存檔接續）跟
> `poc_mode_a/dialogue_ping_pong_multimodel.py`（多模型切換）這兩塊功能**還沒有被
> `poc_village_sim` 重新實作**，繼續留在原地當參考，但不代表「正式主程式＝這兩者合併」
> 這個舊計畫還算數。詳見 [[POC 紀錄 - poc_village_sim 五人整合試跑（新版 AI 架構首測）]]、
> [[poc_village_sim 驗證引擎邏輯總覽]]。

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
- `poc_agent_loop_flag_scenario/`（2026-07-26 封存）——「紅村／藍村獻祭博弈」場景內容，
  因應引擎改用 Godot、村民 AI 規格改版為 `neon/Specify1.md`／`Specify2.md`／`actor1.md`
  定義的開放世界生活模擬（六維人格＋生理狀態＋通用動作，而非機密攻防對話）而封存：
  - `world_lore.txt`——紅村/藍村/TAMMY 神/NEON 神/CHO 神諭世界觀
  - `villager_system_prompt.txt`——社交攻防戰術規則（bluff/pressure/empathy_bait…），新架構改用
    Snapshot 式輸入（生理狀態/好感矩陣/視野/上一動作結果）
  - `turn.gbnf.template`——`reveals_core_energy`/`reveals_altar_key` 洩密判定 schema，新架構改用
    `emotion`/`intent` 通用動作 schema
  - `characters.py`——`FIXED_CAST_RED/BLUE` 10 人角色卡（core_energy/holds_altar_key 資料模型），
    跟新的六維人格＋生理狀態模型不相容

  當時 `poc_agent_loop/agent_loop.py`、`memory_store.py`、`run_multiday.py` 主幹留在原地
  未動；評估詳情見 `note/40-規劃與路線圖/意見書 - 新版 AI 架構修正與舊 POC 封存評估.md`。
- `poc_mode_a_flag_scenario/`（2026-07-26 封存）——`poc_mode_a/` 同一套「紅村／藍村獻祭博弈」
  場景內容（`world_lore.txt`／`villager_system_prompt.txt`／`turn.gbnf.template`／
  `characters.py` 的 `FIXED_CAST_RED/BLUE`），原因同上。`dialogue_ping_pong_multimodel.py`
  （一村民一模型切換機制）留在原地未動，跟場景內容無關，不在封存範圍。同樣注意：
  `dialogue_ping_pong_multimodel.py` 目前 import `characters.py` 會失敗，暫時只當
  參考程式碼用，功能還沒被 `poc_village_sim` 重新實作。
- `poc_agent_loop_superseded/`（2026-07-28 封存）——`agent_loop.py`。呼叫 llama-server 的
  HTTP／JSON 崩潰防禦重試邏輯、`template.replace()` 組 prompt 的寫法，已經被
  `poc_village_sim/run_tick_sim.py` 重新實作且做得更完整（多了連線層級重試、平行呼叫），
  這個檔案本身也已經因為 `characters.py` 被搬走而跑不動，繼續留在 `poc_agent_loop/` 沒有
  意義。`poc_agent_loop/memory_store.py`／`run_multiday.py`（跨天硬碟持久化＋接續執行）跟
  `prompts/plan_system_prompt.txt`／`inner_monologue_system_prompt.txt`（規劃／內心獨白，
  `poc_village_sim` 目前是純反應式、沒有規劃機制）**沒有被封存**——這些功能還沒被
  `poc_village_sim` 重新實作，繼續留在原地當參考。詳見
  [[poc_village_sim 驗證引擎邏輯總覽]] 的「已知限制」一節。
