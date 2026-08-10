# POC 封存區

這裡存放已經確定不採用、但保留作參考的早期 POC 版本。封存原因跟細節見
`note/40-規劃與路線圖/POC 完整技術文件 - 架構、測試方法、檔案與資料流程.md`
與 `note/40-規劃與路線圖/POC 架構總覽與 Generative Agents 論文比對.md`。

## 目前實際在用、拿來寫正式主程式的版本（不在這裡）

- `poc_village_sim/`——現行主線，六維人格＋生理狀態＋通用動作＋睡眠反思＋攻擊/生命值系統，
  已經過多輪長時間驗證（見 [[POC 紀錄 - poc_village_sim 五人整合試跑（新版 AI 架構首測）]]）。

> [!warning] 2026-07-28 更新（早期規劃已作廢）
> 這份 README 最早（7/24）規劃的是「`poc_agent_loop` 整體迴圈 + `dialogue_ping_pong_multimodel.py`
> 的多模型切換機制」合併成正式主程式——那是紅藍村獻祭博弈場景時代的規劃。引擎改 Godot、
> 村民 AI 規格改版之後，實際往下發展的是全新的 `poc_village_sim/`，不是「合併 A+B」這條路線。
> 詳見 [[poc_village_sim 驗證引擎邏輯總覽]]。

> [!info] 2026-08-10 更新：地端一村民一模型確認不做，兩塊「參考用」程式碼移進本目錄找到定位
> - **地端不再打算做「一角色一模型」**；雲端如果要做類似效果，是走 OpenRouter 選模型的邏輯，
>   不會直接沿用 `dialogue_ping_pong_multimodel.py` 這份地端實作——已封存進
>   `poc_mode_a_multimodel_reference/`，見下方條目。
> - `poc_agent_loop/memory_store.py`／`run_multiday.py`（跨行程存檔接續）**目前仍是
>   `poc_village_sim` 沒有的能力**（同一個世界關掉程式重開仍要記得，不是「開新世界」的
>   概念），還不確定要不要做，先搬進 `reference_cross_run_persistence/` 保留參考、方便找。

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
- `poc_agent_loop_superseded/`（2026-07-28 封存 `agent_loop.py`，2026-08-10 補上剩餘四份）——
  `agent_loop.py`：呼叫 llama-server 的 HTTP／JSON 崩潰防禦重試邏輯、`template.replace()`
  組 prompt 的寫法，已經被 `poc_village_sim/run_tick_sim.py` 重新實作且做得更完整（多了
  連線層級重試、平行呼叫），這個檔案本身也已經因為 `characters.py` 被搬走而跑不動。
  `prompts/plan_system_prompt.txt`／`inner_monologue_system_prompt.txt`／
  `grammar/plan.gbnf.template`／`thought.gbnf.template`／`importance.gbnf.template`：
  2026-08-10 確認全專案已經沒有任何現行程式碼 import 這五個檔案（`grep` 全 repo，只有
  已封存檔案還在引用），一併搬進來——規劃／內心獨白／重要性評分這三個概念，現在都已經被
  `poc_village_sim` 自己的 `reasoning`／`inner_monologue` 欄位跟獨立的
  `poc_village_sim/grammar/importance.gbnf.template`（睡眠反思機制的一部分）取代掉了，
  不是「還沒重新實作」的曖昧狀態，是真的已經有新版本在跑。`poc_agent_loop/` 資料夾搬完後
  已經完全清空並移除，不再存在。詳見 [[poc_village_sim 驗證引擎邏輯總覽]] 的「已知限制」一節。
- `reference_cross_run_persistence/`（2026-08-10 搬移，非封存——只是換位置方便找）——
  `poc_agent_loop/memory_store.py`／`run_multiday.py`，跨行程硬碟存檔接續機制（`roster.json`／
  `state.json`／`memory_*.json` 都寫在同一個 `memory_store/` 目錄，關掉程式重開會自動接續讀取
  同一個世界；沒有多重「世界存檔槽」的設計，要開新世界得手動清空該目錄）。`poc_village_sim`
  目前沒有跨行程存檔能力（單次執行內的模擬結束就只留 transcript JSON，不能中斷後接續），
  這兩個檔案原本留在 `poc_agent_loop/` 裡不容易找到，搬來這裡並改成一望即知用途的資料夾名。
  `run_multiday.py` 依賴已封存的 `characters.py`，目前 import 會失敗，純參考用。
- `poc_mode_a_multimodel_reference/`（2026-08-10 封存）——`dialogue_ping_pong_multimodel.py`
  ＋依賴的 `grammar/importance.gbnf.template`。一村民一模型（依角色動態切換 llama-server
  背後模型）的驗證實作，見 [[POC 紀錄 - 多模型輪替啟動測試（10 顆 7-9B 模型）]]。**地端確認
  不採用**這個方向；雲端如果要做類似效果會走 OpenRouter 選模型的邏輯，不會直接沿用這份地端
  `subprocess` 熱切換實作，純供歷史參考。
