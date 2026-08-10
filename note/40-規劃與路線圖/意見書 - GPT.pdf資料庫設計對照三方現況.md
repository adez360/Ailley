---
tags: [ailley, database, schema, spec, comparison, proposal]
status: needs-team-discussion
created: 2026-08-10
---

> [!question] 待定事項
> 這是對照文件，不是實作計畫。用途是釐清 `GPT.pdf`（另一份 ChatGPT 對話，讀取
> GitHub `main` 分支後設計出的 SQLite 資料庫 schema）跟現有三方（POC／Ru 規格書／
> Godot main 實際程式碼）的對齊程度，供後續要不要採用、要跟誰同步討論用。

## 背景

`GPT.pdf`（63 頁，`~/Projects/Ailley/GPT.pdf`）是一份獨立的 ChatGPT 對話紀錄，
只讀取了 GitHub `adez360/Ailley.git` 的 `main` 分支（Godot 本體專案），**沒有
看過 Ru 的正式規格書、也沒有看過 `poc_village_sim` 這幾天驗證出來的東西**。
設計出 8 個資料域、30 張表的 SQLite schema，分 5 個 Phase 漸進實作，並附上
`DatabaseManager` autoload + Repository pattern 的 GDScript 實作範例。

**關鍵認知**：這不是「跟我們現有資料模型對不對齊」這種單一維度的問題——
現在已經有三套彼此就不完全一致的東西（POC 的 Python 資料模型、Ru 的正式
規格書、Godot main 分支的實際程式碼現況），這份 DB 設計是**第四個獨立長出來
的版本**。

## 對照表（依資料域）

| 資料域 | GPT.pdf 設計 | 跟 Godot main 實際程式碼 | 跟 Ru 規格書 | 跟 POC |
|---|---|---|---|---|
| 生理需求 | `character_stats`：hunger/energy/social/fun/mood | ✅ 完全對上——就是 `Stats.SPEC` 現有的5項 | ❌ 規格書是8項（hunger/thirst/stamina/sleepiness/hygiene/alcohol/health/injury） | ❌ POC是hunger/thirst/stamina/boredom/health+money |
| 人格 | `personality_traits`：彈性key-value | 大致對得上 | ❌ 不同哲學，規格書固定10維 | ❌ POC固定6維 |
| 關係 | `relationships`：affinity/familiarity/trust/respect/fear/romance（6維）+`relationship_history`稽核 | 遠超現況——main現在只有affinity/met_count 2維 | 部分重疊但不同——規格書4維（affinity/trust/familiarity/debt），**雙方都沒有對方獨有的維度**（GPT.pdf沒有debt，規格書沒有respect/fear/romance） | POC目前只有單一好感度數值 |
| 地點 | `locations`+`location_points`：泛用型別分類（work/eat/social）+容量 | 用的是farm/shop/restaurant/temple這種範例地點 | ❌ 規格書是15個具名地點（loc_tavern／loc_forest…）+capacity/danger/resources | ❌ POC用餐酒館/森林/藥草叢等具體中文地點 |
| 記憶 | `memories`+`memory_tags`：重要度導向，單層，**沒有embedding欄位** | 現況完全沒有記憶系統 | ❌ 規格書是L1-L4分層＋語意向量檢索 | 部分接近——都沒有embedding欄位，但沒有POC的新鮮度衰減公式 |
| 行程 | `schedule_templates→schedule_entries→character_schedules`三層分離 | ✅ 概念對上——`agent.gd`自己的註解就寫「現在的schedule是暫時模板，之後要換成AI維護的個別行程」，這個三層設計正好解決這個已知問題 | ❌ 規格書用六級優先權佇列（P0-P5），完全不同的決策模型 | ❌ POC用DES事件佇列即時決策，沒有預先排程概念 |
| 對話 | `conversations`+`conversation_participants`+`conversation_messages`：**有真正的對話session概念** | 現況只有模板台詞，LLM尚未真正接上 | 沒有對應的表格設計 | **最值得注意**——POC完全沒有對話session追蹤，2026-08-10長時間驗證直接量到這個缺口（見下方） |
| 物品/經濟 | 刻意留白、明確列為低優先（Phase 4） | 尚未實作 | ❌ 規格書08有item_id+decay+durability完整模型 | ❌ POC有SELL_PRICES/EAT_COST等常數但無decay/durability |
| 存檔 | SQLite + Repository pattern，這次分析的核心建議 | 完全沒有——這是整個專案第一個要建的持久化層 | 沒有涵蓋這塊 | POC是JSON transcript，非正式存檔系統 |

## 結論：不是對齊問題，是第四套獨立版本

這份分析只讀了 GitHub 程式碼，跟 Ru 規格書、POC 這邊的驗證結果完全獨立產生。
結果是：它跟 Godot main 現在寫死的東西（`hunger/energy/social/fun/mood`）
對得很準（因為是照現有程式碼反推），但這代表**如果真的照這份去建資料庫，
等於把 main 現在這套跟 Ru 規格書不一樣的生理需求／關係維度給鎖死**——
跟「記憶檢索跟 Ru 衝突」是同一類問題，只是這次多了一個第三方版本要協調。

## 幾個真正有價值、值得留意的設計（不管採不採用整份方案）

1. **`relationship_history`**——關係變動留稽核紀錄（誰、為什麼、變動多少），
   Ru規格跟POC都沒有這個設計
2. **`schedule_templates`/`character_schedules`三層分離**——解決了`agent.gd`
   自己註解裡提到、還沒解決的問題
3. **`conversations`對話session表**——直接對應到2026-08-10長時間驗證發現的
   缺口，見下一節

## 跟今天長時間驗證發現的對話缺口直接相關

2026-08-10 的7小時長時間驗證（見主線POC紀錄筆記）直接量到：65次「有明確
指定對象」的說話類事件裡，只有3次（約4.6%）對方緊接著的下一個決策也回話
給同一個人，而且這3次裡有2次明顯答非所問。機制上，說話類動作會觸發對方
中斷重新決策，但重新決策之後選不選擇回話、回話對不對題完全交給模型當下
判斷，**沒有一個真正的「對話session」在追蹤這是一場進行中的交流**。

`GPT.pdf`的`conversations`/`conversation_participants`/`conversation_messages`
設計，剛好是這個問題的一種解法方向（雖然是給Godot／SQLite設計的，POC這邊
要做的話是完全獨立的實作，不會直接套用這份schema，但概念上「要有明確的
對話session追蹤」這個方向是對的）。

## 待決策/下一步

1. **最優先**：這份DB設計如果團隊要採用，需要跟Ru/夏對過生理需求／關係
   維度要用哪一套（現在有GPT.pdf版、規格書版、POC實測版三種，各自不同）
2. 地點清單同樣要對齊——現在GPT.pdf用的是範例地點（farm/shop/restaurant），
   跟規格書的15個具名地點、POC的中文地點都不同
3. POC這邊要開始做對話追蹤機制（跟這份DB設計無關，是獨立實作，見下方
   工作紀錄）
