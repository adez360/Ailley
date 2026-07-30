---
tags: [ailley, poc, village-sim, memory, reflection, proposal]
status: implemented
created: 2026-07-27
updated: 2026-07-30
---

> [!success] 2026-07-30 更新：方案 C 已定案並實作
> 提案的方案 C 已採用，反思/記憶機制已大量測試（見 [[POC 紀錄 - poc_village_sim 五人整合試跑（新版 AI 架構首測）]]），並在此基礎上進一步加了「反思生成當日計畫」層（`today_plan`），見該筆記「計畫層實測結果」一節。

# 意見書：poc_village_sim 記憶與睡眠反思設計（Reflection 補完提案）

> [!info] 背景
> 這不是新發明——`note/40-規劃與路線圖/POC 架構總覽與 Generative Agents 論文比對.md`
> 已經點名：Reflection（反思）是論文四大元件裡我們**完全沒實作**的一塊，消融實驗證明它是
> 僅次於完整架構、影響第二大的元件。`neon/Specify2.md` §8 也已經草擬過睡眠反思的輸出格式，
> 但四組 POC 裡沒有一組真的做過。本文件把「記得跟某人發生過什麼事、個性衝突、睡覺濃縮、
> 逐漸遺忘」這個構想整理成正式提案，**尚未動手實作**。

---

## 1. 已經有的、可以直接沿用的部分

`poc_agent_loop/memory_store.py` 的 `retrieve_memories()` 已經實作「新近度＋重要性」加權
排序（`MEMORY_RECENCY_DECAY = 0.95`，用 `global_index` 指數衰減），每次只取分數最高的
`MEMORY_TOP_K = 6` 筆餵進 prompt。

這不是硬刪除，是**排序上讓舊的、不重要的事自然被擠出「最近 N 筆」的窗口**——資料還在硬碟上，
但角色實際「想得起來」的只有分數夠高的那幾筆。效果上就是逐漸遺忘。這部分**直接沿用，不重寫**。

也要記得：`retrieve_memories()` 刻意拿掉了論文原本的第三項（relevance／embedding 相關性），
因為 `poc_mode_a/dialogue_ping_pong_memory_embed.py` 驗證過相關性檢索會強化對話卡住、重複的
傾向。這個教訓也要一併沿用——不要在 poc_village_sim 重新加回 relevance 排序項。

---

## 2. Specify2 §8 已經草擬的睡眠反思格式

```json
{
  "reflection": "我今天為了吃飯偷了東西，我不喜歡這樣的自己。",
  "personality_delta": { "morality": +2, "bravery": -1 },
  "long_term_memory": "阿蘭看到我偷東西了，她大概不會再理我。"
}
```

`long_term_memory` 就是「濃縮成精簡的一小筆資料」——而且範例本身就是**跟特定對象綁定、帶關係
推論的事件記憶**（不是流水帳）。規則：單項人格變動上限 ±3、單晚總變動上限 ±6（跟現行
`render_personality_block()` 的六維人格數值模型直接對接）。

---

## 3. 需要先決定的設計取捨：原始事件要不要留底

| 做法 | 說明 | 優點 | 缺點 |
| --- | --- | --- | --- |
| **A. 論文原版**：每筆原始觀察永久存進 memory stream，只靠排序權重讓舊的沉下去 | Generative Agents 原始架構 | 反思抓錯重點時，細節還在，之後可以重新萃取 | 資料量隨時間線性成長，25 人規模、長期模擬下儲存與檢索成本都會上升 |
| **B. 使用者提案**：當天細節在睡覺那一刻就被壓縮掉，只有濃縮後的反思被長期保留，原始事件不留底 | 更貼近真人記憶（記得「那陣子跟誰處得不好」，不記得三天前午餐吃什麼） | 資料量小很多，長期跑起來輕量 | 反思那次濃縮如果抓錯重點或遺漏，細節真的回不來，沒辦法事後重新萃取 |
| **C. 折衷**：當天原始事件另外存一份「當日 log」，但不進 `retrieve_memories()` 的排序，只有 `long_term_memory`（反思產物）會被檢索到 | 平時跟 B 一樣輕量（檢索範圍只有濃縮後的反思），但保留事後回放/除錯的能力 | 兼顧 B 的檢索輕量 跟 A 的可回溯性 | 需要多一個檔案／欄位存當日 log，複雜度介於 A、B 之間 |

**建議：C**。理由：
- 檢索邏輯（`retrieve_memories()`）只吃反思產物，效果上就是 B 描述的「精簡＋逐漸遺忘」，
  不會因為原始事件塞爆檢索窗口。
- 但保留當日原始 log 的成本很低（`poc_village_sim/run_tick_sim.py` 現在本來就把每個 tick
  的完整輸出存進 `transcripts/`，只是還沒有「依角色、依天」重新整理過）——多留一份等於是
  對現有 tick 記錄做一次依角色重新索引，不是額外的大工程。
- 保留原始 log 對這個階段（還在驗證行為是否合理、還常常要回頭除錯）特別重要——上次鐵牛
  卡在 100% angry、target bug 這些問題，都是靠回看原始輸出才抓到的，如果反思一開始就把
  細節壓掉，之後除錯會少一個工具。

---

## 4. 提議的資料流程

```
每個 tick 產出的事件（沿用 run_tick_sim.py 現有的 ticks_log）
        │
        ▼
【當日 log】依角色重新索引，存一份（供除錯/回放，不進檢索排序）——方案 C 的新增部分
        │
        ▼（角色宣告「睡覺」時觸發，比照 Specify2 §8）
【睡眠反思】把當天事件摘要餵給 LLM，輸出 reflection / personality_delta / long_term_memory
        │
        ▼
long_term_memory 存進 memory_store 的記憶清單（比照 poc_agent_loop 的 global_index／
importance／recency 格式），personality_delta 套用進角色的六維人格數值（±3／±6 上限）
        │
        ▼
隔天的 Snapshot 用 retrieve_memories()（新近度＋重要性，不含 relevance）撈最近 N 筆
long_term_memory 塞進 {{RECENT_MEMORY_BLOCK}}
```

---

## 5. 還沒決定、需要之後補的細節

- 睡眠反思的 importance 評分：`poc_agent_loop` 有 `score_importance()` 這個獨立 LLM 呼叫可以
  直接沿用，但 grammar／prompt 要另外寫一份（現有的是給紅藍村獻祭劇本用的，已封存）。
- `personality_delta` 套用時機：是每次睡覺都套用，還是要等反思內容真的觸及人格相關的事件才
  套用？目前規格沒講清楚，需要之後定案。
- 觸發 reflection 的時機目前假設是「角色自己選擇睡覺」，但如果角色一直不睡（跟鐵牛不去療傷
  同一種問題），會不會永遠沒有反思機會、記憶永遠不會濃縮？這跟強制送醫的討論類似，但這次
  使用者已經明確表態**不希望用引擎硬性覆蓋角色的行為選擇**（見
  [[POC 紀錄 - poc_village_sim 五人整合試跑（新版 AI 架構首測）]] 的討論），所以這裡也不
  該用強制睡覺解決，先記錄這個風險，之後看實測結果再決定要不要處理。

---

## 6. 下一步

這是設計提案，**尚未實作**。確認方向後才動手：
1. 幫 `run_tick_sim.py` 的 ticks_log 加上「依角色重新索引」的當日 log（方案 C）。
2. 新增睡眠反思的 prompt／grammar（比照 Specify2 §8 格式）。
3. 把 `poc_agent_loop/memory_store.py` 的 retrieve/save 邏輯搬一份到 `poc_village_sim/`，
   欄位對齊 `long_term_memory` 格式。
