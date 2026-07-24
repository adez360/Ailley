---
tags: [ailley, poc, config, characters, worldbuilding, reference]
status: done
created: 2026-07-24
---

# POC 設定檔清單：會影響角色行為、對話內容、世界觀的檔案

> [!info] 用途
> 整理目前所有 POC 線裡，會實際影響「角色是誰、角色怎麼想、角色講什麼話、世界背景設定」的檔案，方便之後要調整內容時知道該改哪裡。技術架構本身見 [[POC 完整技術文件 - 架構、測試方法、檔案與資料流程]]，這份只聚焦「內容/設定」層面。

## 一、角色設定（`characters.py`）

四個目錄（`poc/`、`poc_mode_a/`、`poc_planning/`、`poc_agent_loop/`）各有一份 `characters.py`，**目前四份逐字元完全相同**（224 行），還沒有分岔。內容結構：

| 常數/函式 | 內容 | 影響 |
|---|---|---|
| `NAME_POOL` | 隨機角色卡可用的姓名池 | 隨機生成角色時的名字 |
| `PERSONALITY_POOL` | 性格描述池 | 影響角色說話語氣、決策傾向 |
| `OCCUPATION_POOL` | 職業池 | 影響角色的立場、知識背景、行程規劃內容 |
| `CORE_ENERGY_POOL` | 核心能源名稱池（個人層級機密） | 洩漏偵測比對的目標字串 |
| `ALTAR_KEY_NAMES` | 舊神祭壇密鑰名稱（村莊層級機密） | 洩漏偵測比對的目標字串 |
| `ALTAR_KEY_ELIGIBLE_OCCUPATIONS` | 哪些職業才能持有密鑰（祭司見習、守衛） | 密鑰持有者分配規則 |
| `VILLAGES` | 紅村／藍村的基本設定 | 陣營背景 |
| `FIXED_CAST_RED` / `FIXED_CAST_BLUE` | **固定角色卡**（10 位村民，紅藍各 5 位，含姓名/性格/職業/驅動力/關係），大部分驗證都用這組，不是每次隨機生成 | 這是實際跑測試時最常用到的角色內容來源 |
| `generate_villager()` / `generate_roster()` | 隨機生成邏輯（不用固定角色卡時） | 隨機模式的角色生成 |
| `generate_fixed_roster()` | 讀取 `FIXED_CAST_RED/BLUE` 組出完整名冊 | 目前主要驗證路徑用的函式 |
| `pick_encounter()` | 從名冊裡選一組紅藍配對做對話 | 決定這一場誰對誰 |

**要改角色個性/姓名/職業/驅動力/關係，改這裡（`FIXED_CAST_RED`／`FIXED_CAST_BLUE`）**，四個目錄要一起改（沒有共用模組，見 [[POC 架構總覽與 Generative Agents 論文比對]] 第四節提到的技術債）。

`poc/characters/roster_*.json`（50+ 個檔案）是**執行時的輸出快照**，不是設定來源——是每次跑隨機生成模式時存下的名冊記錄，不用去改這些檔案本身。

## 二、世界觀素材（`prompts/world_lore.txt`）

四個目錄的 `world_lore.txt`（30 行）**逐字元完全相同**，是唯一的世界觀來源文字，內容涵蓋：老周、阿柏、老馮、芷姨等 NPC、渡口／老井／市集／哨站／田埂／茶棚等地點、CHO 神／舊神祭壇等信仰背景。這份文字直接被塞進每次呼叫的 prompt 裡（`{{WORLD_LORE}}` 佔位符），**是影響對話內容、規劃內容、閒聊話題最直接的一份檔案**。

`poc/prompts/experiments/world_lore.experiment_v2.txt` 是一份實驗性擴充版（更豐富的世界觀素材），只在特定實驗腳本裡用過，沒有正式取代主版本。

`STUCK_TOPIC_HOOKS`（見下方第四節）也是取材自這份世界觀，是額外硬編碼在程式碼裡、專門給「停滯強制新話題」機制用的固定話題池，內容跟 `world_lore.txt` 呼應但獨立維護。

## 三、系統 Prompt 模板

決定「模型該怎麼扮演角色、輸出什麼結構」的模板文字，依 POC 線各自不同：

| 檔案 | 用於 | 內容重點 |
|---|---|---|
| `poc/prompts/director_system_prompt.txt` | 模式 B 單次生成整場 | 導演視角，一次决定雙方對話 |
| `poc/prompts/continue_system_prompt.txt` | 模式 B 續寫 | 接續劇本的規則說明 |
| `poc_mode_a/prompts/villager_system_prompt.txt` | 模式 A 雙 LLM 對話 | 單一村民第一人稱視角，含機密分層說明（`{{TWO_TIER_BLOCK}}` 等佔位符） |
| `poc_agent_loop/prompts/villager_system_prompt.txt` | Agent Loop 對話 | 跟模式 A 版本**內容不同**（已確認），是為「規劃驅動相遇」情境調整過的版本 |
| `poc_agent_loop/prompts/plan_system_prompt.txt` | 規劃（6 時段行程） | 決定角色一天的行程風格 |
| `poc_agent_loop/prompts/inner_monologue_system_prompt.txt` | 意識流獨白 | 決定沒觸發相遇時角色在想什麼 |
| `poc_planning/prompts/plan_system_prompt.txt` | Planning POC 規劃 | 跟 agent_loop 版本是否相同未逐一比對，功能上是同一套邏輯的最初來源 |
| `poc/prompts/experiments/*.txt` | 各種實驗分支專用 | 只在對應實驗腳本裡使用，非正式版本 |

**這些是決定「角色怎麼想、怎麼說話、輸出格式」最直接的槓桿**——改角色行為模式（例如想讓角色更謹慎/更衝動、想調整機密分層說明怎麼講）優先看這裡。

## 四、對話內容/行為的程式碼內常數（散落在各腳本裡，非獨立檔案）

這些不是獨立設定檔，是寫在每支主腳本裡的常數，**同樣的內容重複貼在十幾支腳本裡**（`grep` 找到 23 處 `TACTIC_LABEL`／6 處 `STUCK_TOPIC_HOOKS`），沒有共用模組：

| 常數 | 內容 | 影響 |
|---|---|---|
| `TACTIC_LABEL` | 5 種社交工程戰術的中文標籤（虛張聲勢／步步進逼／示弱誘敵／轉移話題／戰略撤退） | 決定模型可選的戰術類型，也是 grammar enum 的中文對照 |
| `STUCK_TOPIC_HOOKS` | 9 條固定話題（取材自 world_lore），停滯偵測觸發時強制帶入 | 直接影響對話內容轉折，是唯一被證實有效的重複退化緩解機制之一 |
| `TEMPERATURE`／`TOP_P`／`TOP_K`／`REPEAT_PENALTY`／`SEED` | 取樣參數，多數用環境變數覆寫（`AILLEY_TEMPERATURE` 等），程式碼裡是預設值 | 影響輸出的隨機性/多樣性，不是內容本身但直接影響行為表現 |

## 五、Grammar／Schema（結構約束，間接限制行為範圍）

不是「內容」，但**規定了模型能輸出什麼形狀的內容**，等於是行為的硬邊界：

| 檔案 | 決定 |
|---|---|
| `poc/grammar/director.gbnf.template`／`continue_director.gbnf.template` | 模式 B 的 JSON 結構、`tactic` enum（bluff/pressure/empathy_bait/misdirect/retreat） |
| `poc_mode_a/grammar/turn.gbnf.template` | 模式 A 單回合的 JSON 結構 |
| `poc_mode_a/grammar/importance.gbnf.template` | 重要性評分的極簡結構（`{"importance": N}`） |
| `poc_agent_loop/grammar/plan.gbnf.template`／`thought.gbnf.template` | 規劃／意識流的輸出結構 |
| `poc_planning/grammar/plan.gbnf.template` | Planning POC 的規劃結構 |
| `poc/schema/script_schema.json` | 模式 B 完整劇本的正式 JSON Schema 規格（給前後端對接用，理論上要跟 grammar 保持一致，見 schema 檔案本身註解） |

`tactic` 的 5 個選項本身定義了角色「能採取的策略種類」，是相對上位的行為框架——要新增/調整戰術種類，grammar、schema、`TACTIC_LABEL` 三處都要一起改。

## 六、上游設計文件（`note/20-系統設計/`，非程式讀取，但是這些設定的來源依據）

不是執行時讀取的檔案，但是上面所有 prompt/角色設定內容的設計依據，調整內容方向前建議先對照：

- [[AI 角色系統]]——角色設計的整體規則
- [[世界與時間系統]]——世界觀跟時間機制的設計
- [[世界觀素材撰寫指南（給組員）]]——世界觀素材撰寫規範，`world_lore.txt` 應該依這份指南維護
- [[記憶與認知系統]]——記憶流設計的上位文件，對應 `retrieve_memories()` 的實作依據
- [[資安攻防核心玩法]]——洩漏偵測、機密分層機制的設計依據

## 七、一句話總結：要改什麼找什麼

| 想改的東西 | 改這裡 |
|---|---|
| 角色姓名/性格/職業/驅動力/人際關係 | `characters.py` 的 `FIXED_CAST_RED`／`FIXED_CAST_BLUE`（四目錄要一起改） |
| 世界背景、地點、NPC | `prompts/world_lore.txt`（四目錄要一起改） |
| 角色怎麼扮演、機密怎麼描述、輸出規則 | 對應 POC 線的 `*_system_prompt.txt` |
| 對話卡住時要帶入的話題 | 各腳本裡的 `STUCK_TOPIC_HOOKS`（目前 6 處重複，要改要一起改） |
| 可選的社交工程戰術種類 | grammar `.gbnf.template` + `script_schema.json` + `TACTIC_LABEL`（三處連動） |
| 輸出的隨機性/多樣性 | 環境變數 `AILLEY_TEMPERATURE`／`AILLEY_SEED`／`AILLEY_SAMPLING_EXTRA`，或程式碼裡的預設值 |

## 延伸閱讀
- [[POC 完整技術文件 - 架構、測試方法、檔案與資料流程]]
- [[POC 架構總覽與 Generative Agents 論文比對]]
