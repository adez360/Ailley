---
tags: [ailley, ai-architecture, proposal, godot-pivot]
status: done
created: 2026-07-26
updated: 2026-07-30
---

> [!success] 已核准並執行完畢（2026-07-26）
> 見本文件第 5、6 節「執行紀錄」，舊 POC 已封存，新架構即 [[POC 紀錄 - poc_village_sim 五人整合試跑（新版 AI 架構首測）|poc_village_sim]]。

# 意見書：新版 AI 架構修正與舊 POC 封存評估

> [!info] 決策脈絡
> 引擎確定改用 **Godot**（取代 [[技術架構總覽]] 原訂的 Phaser 路線）。同時新的村民 AI 規格 `neon/Specify1.md`、`neon/Specify2.md`、`neon/actor1.md` 定義了一個 tick-based 開放世界村莊生活模擬，跟現行 `poc_agent_loop` 的「紅村／藍村獻祭博弈」場景是不同的遊戲內容。本文件只做評估與提案，**未執行任何檔案異動**，待核准後才動手。

---

## 1. 現況盤點

讀了現行的三個關鍵檔案：

- `poc_agent_loop/prompts/villager_system_prompt.txt`：system prompt 只餵了世界觀、**博弈攻防戰術規則**（bluff/pressure/empathy_bait/misdirect/retreat）、單句性格描述、驅動力、寫死的關係文字、核心能源機密、對手公開資訊、對話歷史。
- `poc_agent_loop/grammar/turn.gbnf.template`：輸出 schema 只有 `reasoning` / `tactic` / `dialogue` / `state_delta`（懷疑度變化 + 是否洩漏核心能源／密鑰）。
- `poc_agent_loop/characters.py`：`FIXED_CAST_RED/BLUE` 10 人角色卡，欄位是 name/occupation/personality（字串）/motivation/relationship（字串，寫死指名對象）/core_energy/holds_altar_key。

這一整套是**專門為「一對一心理攻防、騙出機密」這個場景寫的窄格式**，跟 `actor1.md` 展示的「開放世界、生理狀態驅動、多人多動作」完全是不同資料模型。

---

## 2. AI 架構需要修正的事項

比對 Specify1/Specify2 與現行三個檔案，缺口如下：

| 缺口 | Specify2 對應章節 | 現行 POC 有嗎 | 建議修正 |
| --- | --- | --- | --- |
| 6 維度人格數值（勤勉/膽識/社交/道德/情緒穩定/浪漫藝術） | §3.1 | 只有一句話性格字串 | `characters.py` 角色卡改成 6 個 0–100 數值欄位，套 §3.1 對照表轉譯成自然語言敘述 |
| 生理狀態 Snapshot（飢餓/口渴/體力/無聊/傷病/錢/背包） | §3.2、§4 | 完全沒有 | system prompt 新增 Snapshot 區塊，數值需搭配中文形容詞（「87」→「很餓」），不能丟裸數字 |
| 好感度數值矩陣，且要對視野內每個人各出一句 | §3.3 | 只有寫死的單一靜態關係文字 | 改成 −100~100 數值 + 對照句，且要能對「當下看得到的每一個人」各自產生一句，而不是只對唯一對手 |
| 情緒 enum（8 選一，LLM 自主宣告） | §3.4 | 沒有 `emotion` 欄位 | grammar 新增 `emotion` |
| 上一動作結果回報（含失敗原因） | §4 兩個必要條件之一 | 沒有這個概念，每回合都是純對話 | Snapshot 模板新增「上一個動作結果」欄位——沒有這塊 LLM 會不斷重試同一個無效動作，Specify1/2 都特別點名這是硬要求 |
| 通用動作空間（打獵/採集/移動/交易/結婚…） | §5 A–E | 只有「說話」一種輸出 | grammar 新增 `intent.action` / `intent.target` / `intent.location`，對應 Specify1 §4 五大類動作 |
| 視野內看得到誰、對方在做什麼 | §4 | 沒有，現在是封閉一對一相遇 | Snapshot 新增「你看得到」清單 |
| 睡眠反思迴圈（人格微調） | §8 | 沒有 | 新增一個獨立的 LLM 呼叫，輸入當日事件摘要，輸出 `reflection` + `personality_delta`（±3/±6 由程式邏輯把關）+ `long_term_memory` |

**要動的檔案（新增，不覆蓋舊檔）**：
1. 新的 system prompt 模板（Snapshot 結構，取代博弈戰術規則）
2. 新的 grammar（`emotion`/`inner_monologue`/`speech`/`intent`，取代 `tactic`/`state_delta` 那套）
3. 新的角色資料模型（6 維人格 + 好感矩陣 + 初始生理數值，比照 `actor1.md` 格式）

**可以直接沿用、不用重寫的**：`agent_loop.py` 呼叫 llama-server 的 HTTP 邏輯、JSON 解析失敗重試機制（3707ac1 那個修復）、`memory_store.py` 的跨天持久化模式。這些是「怎麼跟模型對話、怎麼扛得住崩潰」的通用基礎設施，跟場景內容無關，新架構應該**沿用同一套呼叫模式**，只是換掉 prompt 模板跟 grammar 檔案本身。

---

## 3. 舊 POC 資料封存評估

### 建議封存（場景內容跟新方向不符，但保留檔案供之後參考，不刪除）

| 路徑 | 原因 |
| --- | --- |
| `poc_agent_loop/prompts/world_lore.txt` | 紅村/藍村/TAMMY 神/NEON 神/CHO 神諭世界觀，是「獻祭機密」劇本專用，跟開放世界村莊生活模擬無關 |
| `poc_agent_loop/prompts/villager_system_prompt.txt` | 博弈攻防戰術規則（tactic 系統）是專為社交工程對決設計，新架構不需要 |
| `poc_agent_loop/grammar/turn.gbnf.template` | `state_delta` 裡的 `reveals_core_energy`/`reveals_altar_key` 是機密洩漏判定，新架構沒有這個機制 |
| `poc_agent_loop/characters.py` 內的 `FIXED_CAST_RED/BLUE`、`CORE_ENERGY_POOL`、`ALTAR_KEY_NAMES` | 10 人角色卡的資料模型（core_energy/holds_altar_key）跟新的六維人格+生理狀態模型不相容 |
| `poc_mode_a/`（整個目錄） | 同樣是紅藍村博弈場景的另一種呼叫模式（ping-pong 對話），非新方向要延續的部分 |

### 建議保留、不封存（通用基礎設施，新架構會直接沿用）

| 路徑 | 原因 |
| --- | --- |
| `poc_agent_loop/agent_loop.py` 裡呼叫 llama-server 的部分（`SERVER_URL`、`requests.post`、JSON 重試邏輯） | 跟場景無關的通用呼叫模式，新架構原封不動沿用 |
| `poc_agent_loop/memory_store.py` | 跨天持久化的資料結構與讀寫模式，可直接套用在新角色的長期記憶上 |
| `poc_agent_loop/grammar/importance.gbnf.template`、`thought.gbnf.template` | 意識流／重要性評分的呼叫模式，概念上對應新架構「內心獨白」的需求，格式需要調整但邏輯可沿用 |

### 保持原樣、不動

`poc_archive/` 底下已經封存過的舊版（`poc`、`poc_mode_a_legacy`、`poc_planning`）維持現狀，不重複處理。

---

## 4. 待你確認的事項

1. **封存方式**：是仿照上次 commit（72f9ac1）的做法整個目錄搬進 `poc_archive/`，還是只搬場景相關的檔案（world_lore.txt / villager_system_prompt.txt / turn.gbnf.template / FIXED_CAST 相關程式碼），把 `agent_loop.py` 主幹跟 `memory_store.py` 留在原地當新架構的起點？
   - 個人建議：**只搬場景內容，主幹留原地**——因為新架構要直接沿用呼叫邏輯，整個目錄搬走的話還要再複製一次通用部分出來，多繞一手。
2. `poc_mode_a/` 是否整個封存，還是先確認它跟 `poc_agent_loop` 有沒有共用到需要保留的通用邏輯？
3. 新的三個檔案（system prompt / grammar / 角色資料模型）要新建在哪裡？建議開一個新目錄 `poc_village_sim/`，跟 `poc_agent_loop` 平行，避免跟舊場景的 grammar/prompt 混在一起搞混。

---

## 5. 執行紀錄（2026-07-26）

已依確認方向執行：

- `poc_agent_loop/`：`world_lore.txt`／`villager_system_prompt.txt`／`turn.gbnf.template`／
  `characters.py` 搬進 `poc_archive/poc_agent_loop_flag_scenario/`；`agent_loop.py`／
  `memory_store.py`／`run_multiday.py` 主幹留在原地。
- `poc_mode_a/`：發現 `poc_archive/README.md` 原本記載「一村民一模型」機制（
  `dialogue_ping_pong_multimodel.py`）是確定要合併進正式主程式的，跟「不採用要封存」的東西
  性質不同，先暫停確認 → 你選擇「只封存場景內容，機制留著」。已比照 `poc_agent_loop` 的做法，
  只搬 `world_lore.txt`／`villager_system_prompt.txt`／`turn.gbnf.template`／`characters.py`
  進 `poc_archive/poc_mode_a_flag_scenario/`，`dialogue_ping_pong_multimodel.py` 留在原地。
- 兩邊留在原地的主幹檔案（`agent_loop.py`、`dialogue_ping_pong_multimodel.py`）目前
  `import characters` 會失敗，因為 `characters.py` 被搬走了——這是預期的，這兩個檔案現在
  是「參考用程式碼」，不是可直接執行的管線；新架構會另外建立角色資料模型檔案取代它。
- 封存細節與原因已寫進 `poc_archive/README.md`。

## 6. 新資料夾必要性評估

**建議：需要，開 `poc_village_sim/`，跟 `poc_agent_loop`／`poc_mode_a` 平行放。**

理由：
1. `agent_loop.py` 檔頭本來就寫了「跟 poc/、poc_mode_a/、poc_planning/ 完全獨立，不 import
   它們的任何模組」——這是這個專案從一開始就在遵守的慣例（每條 POC 驗證線互不干擾），新的
   Snapshot／Action Schema 架構延續這個慣例合理。
2. 新舊兩套 grammar／prompt 檔名很容易撞在一起（例如兩邊都會有 `turn.gbnf.template`
   這種命名），混在同一個資料夾容易誤用到封存前的舊版格式。
3. 成本很低——只是開新資料夾，不影響任何現有東西；等真的要動手寫新的 system prompt／
   grammar／角色資料模型時，直接在 `poc_village_sim/` 下建立即可，現在不用預先建立空資料夾。

以上為評估內容與執行紀錄。
