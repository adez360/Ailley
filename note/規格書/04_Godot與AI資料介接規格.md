---
tags: [規格書, 架構]
status: 大致定案
updated: 2026-08-24
---

# 04_Godot與AI資料介接規格

# 04｜Godot 與 AI 資料介接規格

**閱讀對象**：後端組・前端組・AI 組
**文件性質**：通訊契約。Godot 端 `AIService` 與 `LocalLLM`／`RemoteLLM`／`HumanInput` 之間所有資料交換的格式以本文件為準；沒有獨立的 AI 後端行程，見 §1。
**前置閱讀**：《00 設計原則與架構》、《01-3 Prompt 注入與資料傳送》、《12 決策來源抽象與執行架構規格書》

---

## 1. 系統架構

**沒有獨立的 Python AI 後端。** Godot（房主機兼玩家端）本身就是《12》定義的房主機權威——`AIService`（見《技術/LLM 串接與 AI 服務層》）在 Godot 行程內完成 prompt／schema 組裝、佇列排程、驗證與狀態套用，只有「實際生成文字」這一步會呼叫外部的 `DecisionProvider`：`LocalLLM` 是本機 `llama-server`（HTTP，同機 localhost）、`RemoteLLM` 是雲端 API（HTTP，走網際網路）、`HumanInput` 是本機決策面板（無 HTTP）。多人模式下 `RemotePlayer` 才會有 Godot↔Godot 的網路連線，完整職責邊界見《12》§5。

```text
┌──────────────────────────────────────────────────────────────┐
│              房主機（Godot 4.x，權威／操控層一體）               │
│  ────────────────────────────────────────────────────────    │
│  • 世界模擬（移動、碰撞、偵測範圍、時間推進）                    │
│  • UI 渲染（立繪、內心狀態視窗、天神之石輸入框）                 │
│  • Prompt 組裝（Tier 分級、事實句、兜底句）                     │
│  • Schema 組裝（《12》§2，取代手寫 GBNF）                       │
│  • 決策佇列與排程（事件驅動，見《10》§5.1）                      │
│  • DecisionProvider 呼叫、schema 驗證、三條硬規定檢查            │
│  • 成功率判定與擲骰（《01-2》）、狀態套用與存檔                  │
│  • 記憶檢索                                                     │
└───────────────────────────┬──────────────────────────────────┘
                            │  DecisionProvider（見《12》§3）
                            │  LocalLLM／RemoteLLM 走 HTTP，
                            │  HumanInput 不經網路，RemotePlayer 見《12》§3.4
                            ▼
┌──────────────────────────────────────────────────────────────┐
│  LocalLLM: llama-server（127.0.0.1:8080，--parallel 3, ctx 16000）│
│  RemoteLLM: 雲端 API（OpenRouter 等，見 `ai/api.md` AIConfig）   │
└──────────────────────────────────────────────────────────────┘
```

### 職責切分原則

| 這件事 | 誰做 |
| --- | --- |
| 決定「想做什麼」 | Provider（LLM 或真人，見《12》§3） |
| 組 Prompt / Schema、過濾資料 | 房主機 |
| schema 驗證、三條硬規定檢查 | **房主機**（客戶端不可信，見《12》§5.2） |
| 決定「做不做得到」、擲骰 | **房主機** |
| 數值增減與存檔 | **房主機** |
| 尋路、播動畫、純表現 | **Godot 操控層** |
| 記憶寫入與檢索 | 房主機 |

> ⚠️ 擲骰與數值變更**一律在房主機**。Provider 不得直接改動任何角色數值，只能回傳意圖；Godot 操控層不做任何判定，只接收已驗證的決策並執行表現（《12》§5.3）。

---

## 2. 通訊方式

以下描述 Godot（`AIService`）呼叫 `LocalLLM`／`RemoteLLM` 這一段；`HumanInput` 不經 HTTP（本機決策面板直接讀寫），`RemotePlayer` 見《12》§3.4。

| 項目 | 規格 |
| --- | --- |
| 協定 | HTTP/1.1 |
| 位址 | `LocalLLM`：`http://127.0.0.1:8080/v1`（llama-server，OpenAI 相容端點，2026-08-16 定案——與《技術/LLM 串接與 AI 服務層》現行實作一致）；`RemoteLLM`：依 provider 而定，見 `ai/api.md` `AIConfig` |
| 資料格式 | JSON，UTF-8 |
| Godot 端 | `HTTPRequest` node，非同步 |
| 編碼 | `JSON.stringify()` / `JSON.parse_string()` |

### 為什麼單機是 HTTP、多人是反向連線

單機模式：Godot 內建 `HTTPRequest`，零額外依賴；`LocalLLM` 同機、單向請求為主（Godot 主動問、llama-server 回答），不需要伺服器主動推播。

多人模式：依《12》§3.4 `RemotePlayer` 的結論，連線方向為反向——玩家客戶端位於 NAT 後方，房主無法主動連入，因此由玩家連進房主（WebSocket 或長輪詢皆可），房主將工作放入佇列等待對方領取。這不是「日後再評估」的空白，而是已有依據的既定方向；實作時機仍待規劃，見《99》P-20。

---

## 3. 訊息類型

事件驅動架構下，決策請求以**單一角色**為單位發起，不再是每 tick 批次送出全體 NPC（見《10》§5.1、《12》§5.1）。

**這些不是獨立行程的網路端點**——`AIService` 一律打同一個 `LocalLLM`／`RemoteLLM` 的 `/v1/chat/completions`。`AIService` 內部維護一個 `POOL_SIZE := 3` 的 `HTTPRequest` 節點池（跟 llama-server 的 `--parallel 3` 對齊），佇列裡的請求依序分派給空閒節點，可以同時有 3 筆在飛，不是單一節點依序排隊。差別只在 `PromptBuilder` 組出來的 `envelope.payload.type`（決定 system prompt、要不要帶 `response_format`），不是不同 URL——下表沿用「訊息類型」只是方便對照「這次呼叫要做什麼」，實際 wire format 見《技術/LLM 串接與 AI 服務層》與 `Ailley/scripts/ai/prompt_builder.gd`。

啟動就緒檢查也不是獨立端點：`AIService._probe_models()` 打 provider 標準的 `GET {base_url}/models`（OpenAI 相容 API 既有端點，順便驗證 API 金鑰是否有效），不是下面曾經設想過的 `/health`——`ai_service.gd`／`ai_config.gd` 的註解都明講「刻意不用《04》§4-1 想像的 `/health`，那是沒有的」。

| `payload.type` | 用途 | 對應 `PromptBuilder` |
| --- | --- | --- |
| `plan` | 單一角色的決策請求，回一組 `tasks[]`（角色完成動作後發起，或事件觸發） | `build_plan_envelope()` |
| `dialogue` | 對話逐輪生成，一次一句 | `build_dialogue_envelope()` |
| `words_to_creator_choice` | 天神之石事件觸發後，判斷「現在要不要把想對造物主說的話說出口」 | `build_words_to_creator_envelope()` |
| `creation` | 建角完成當下生成 `words_to_creator` | `build_creation_envelope()` |
| `reflection` | 睡眠反思、記憶壓縮 | `build_reflection_envelope()` |
| `checkpoint` | 長動作固定間隔檢查點（issue #336）：問「繼續還是放棄」 | `build_checkpoint_envelope()` |

---

## 4. 封包格式

所有請求共用同一個信封形狀：`{"system": "<system prompt 字串>", "payload": {...}, "response_format": {...}}`（`response_format` 選填，只有 provider 支援 `json_schema` 時才會真的送出，見 §8）。下面每節只列 `payload` 與 AI 回應本體，信封外殼不重複寫。`self` 區塊（角色自身狀態）由 `plan`／`dialogue`／`reflection`／`checkpoint` 四種類型共用，形狀統一，見 4-2 第一次出現處，後面章節不重複列全部欄位。

### 4-1 就緒檢查

**Godot → AI**：`GET {base_url}/models`（OpenAI 相容 API 標準端點，本機／雲端同一條路徑），不帶 payload。

**判定**：HTTP 2xx 視為就緒；3xx（通常代表 `base_url` 設錯）與其餘狀態碼一律視為未就緒。沒有本文件先前設想的 `status: ready/loading/error` 欄位——這支端點本身就不是本專案的自訂 API，回應格式由 provider（llama-server／雲端 API）決定，Godot 端只看 HTTP 狀態碼。

---

### 4-2 `plan`　單一角色決策請求

**Godot → AI**

角色完成當前動作後才發起（見《10》§5.1、《00》§7），一次一位，不是批次陣列。

```json
{
  "type": "plan",
  "self": {
    "id": "npc_017",
    "name": "NEON",
    "stats": {
      "hunger":     { "value": 62, "label": "有點餓" },
      "thirst":     { "value": 38, "label": "有點渴" },
      "stamina":    { "value": 55, "label": "有點累" },
      "sleepiness": { "value": 20, "label": "清醒" },
      "hygiene":    { "value": 70, "label": "還算乾淨" },
      "alcohol":    { "value": 0,  "label": "清醒" },
      "health":     { "value": 88, "label": "健康強壯" },
      "injury":     { "value": 0,  "label": "沒有受傷" }
    },
    "time": { "day": 30, "hour": 14, "minute": 20 },
    "place": "loc_herb_field",
    "current_action": "idle",
    "last_action_result": "",
    "money": 300,
    "inventory": { "herb": 4 },
    "emotion": { "type": "neutral", "intensity": 0 },
    "conditions": [],
    "current_goal": "把藥草賣掉，換錢買一把好一點的刀"
  },
  "context": {
    "visible": [ { "name": "TAMMY", "trust": 15, "met_count": 3 } ],
    "pool": [ "…Agent._task_pool_summary() 摘要" ],
    "today_plan": "You intended to do today: 採藥草 (done), 找 TAMMY 聊天.",
    "fact_lines": [ "你已經大半天沒和任何人說過話了。" ],
    "memory": { "recent": [ "…" ], "core": [ "…" ] }
  }
}
```

#### 欄位說明

| 欄位 | 必填 | 說明 |
| --- | --- | --- |
| `self.stats.*.value` | ✔ | 數值本體。`hunger`／`thirst`／`sleepiness` 是**換算過的顯示概念**，不是內部儲存欄位名——內部儲存分別叫 `satiety`／`hydration`／`wakefulness`，方向相反（見《01》§4-1）。換算式：`hunger = 100 − satiety`、`thirst = 100 − hydration`、`sleepiness = 100 − wakefulness`。其餘 5 項內部與顯示同名同方向，直接傳原始值（見《99》P-07） |
| `self.stats.*.label` | ✔ | **中文形容詞，缺一不可**，5 級距對照表見《99》P-07（`prompt_builder.gd` 的 `PHYSICAL_LABELS`） |
| `self.money`／`self.inventory` | ✔ | `inventory` 是 `{item_id: 總數量}` 摘要，不是逐格陣列，不帶 decay／durability（#339） |
| `self.conditions` | ✔ | 只帶 `type` 字串陣列，不帶倒數細節，無則傳 `[]` |
| `context.fact_lines` | ✔ | 引擎產生的事實句陣列，無則傳 `[]` |
| `context.visible` | ✔ | **只放在場的人**，無則傳 `[]`，形狀是 `{name, trust, met_count}`——只送 `trust`，好感／熟悉／虧欠三維已拿掉（《01》3-1） |
| `context.memory` | ✔ | L2（近期）依連結展開篩選、L4（核心）固定全量帶入（#360），只帶 `content` 字串 |

沒有本文件先前設想的 `available_actions` 陣列、`present_npcs` 的 `appearance_text`、`location.desc`——可選動作清單是寫死在 system prompt 文字裡的 `AISchema.IMPLEMENTED_ACTIONS`（`Ailley/scripts/ai/ai_schema.gd`，由 `PromptBuilder._plan_system()` 動態組進提示詞），不是每次動態依前提條件過濾出來的陣列。

《07 地點與行動》§5 描述的「Godot 端依地點／角色狀態／持有物過濾 `available_actions`」是還沒落地的目標設計，不是文件寫錯——issue #477（`Task.preconditions` 評估）就是在追蹤這個缺口，目前 `Task.preconditions` 一律通過，過濾這一層完全沒做。兩份文件不衝突：《07》講的是設計終點，這裡講的是現在打出去的請求實際長什麼樣，#477 落地前不要照《07》的措辭去對接實作。

> ⚠️ **每次決策只讀請求發起當下的快照**。套用階段在房主機序列處理，避免 race condition（見《00》§7）。

**AI → Godot**

```json
{
  "reasoning": "藥草再不採就要被別人拿光了，而且我有點餓，先解決吃飯問題比較划算。",
  "inner_monologue": "先吃飽再去採藥草好了。",
  "request_plan_update": false,
  "emotion": { "type": "neutral", "intensity": 30 },
  "current_goal": "把藥草賣掉，換錢買一把好一點的刀",
  "tasks": [
    { "action": "eat", "params": {}, "priority": 20, "duration": 10 },
    { "action": "gather", "params": {}, "priority": 15, "duration": 30 }
  ]
}
```

#### 欄位說明

| 欄位 | 必填 | 說明 |
| --- | --- | --- |
| `reasoning` | ✔ | 上限 100 字，寫在 `tasks` 之前——因果鏈，不是選項清單 |
| `emotion` | ✔ | `type` 固定 8 值 enum，`intensity` 0–100，AI 每次都要宣告（#351） |
| `tasks` | ✔（可空陣列） | 最多 5 筆，`{"action", "params", "priority", "duration", "expires_in_minutes"?}`。`action` 是 `ALLOWED_ACTIONS` 靜態 enum；`priority` 整數 0–125（10–110 是一般偏好，門檻以上留給真緊急事件）；`duration` 整數 1–1440（遊戲分鐘）；`expires_in_minutes` 選填，模型填的是**相對時長**（1–10080 分鐘），房主機自己換算成絕對 `expires_at`，不是要求模型算絕對時間（#268／#290）。空陣列＝這輪不改任何行程 |
| `inner_monologue` | 選填 | 自由文字，缺席視為空字串 |
| `request_plan_update` | 選填 | 缺席視為 `false`；沒開放 `update_plan` 的這輪，模型想申請下次能改就設 `true` |
| `current_goal` | 選填 | 上限 40 字。省略＝維持原樣；明確傳空字串＝主動清除，兩者語意不同（#352） |
| `update_plan` | 條件式 | 只在《10》§5.4 列出的開放時機才存在於 schema／system prompt，不是模型自己判斷要不要填（見《12》§2.4） |
| `persuaded`／`importance`／`valence` | 條件式 | 只在 `context.fact_lines` 帶有待回應的說服事實句時，schema 才含這三個欄位（#227）。省略 `persuaded` 視同不被說動 |
| `appointment` | 尚未實作 | 《10》§5.5 已拍板設計，但 `ai_schema.gd`／`prompt_builder.gd` 都還沒接上這個欄位，見 issue #479 |

`action == "persuade"` 的那筆 `tasks[]` 項目，`params` 另外多兩個欄位：`target`（必填，非空字串）、`reason`（必填，非空字串，說服理由，不驗證內容合不合理）、`proposed_task`（選填）：

- **省略 `proposed_task`**：純思想說服——只想改變對方相信什麼，不要求對方做什麼
- **給一個合法的 task 物件**（跟 `tasks[]` 裡一筆任務同一個形狀，遞迴驗證，但不可再是 `persuade`）：行動說服。被說服者下一輪決策回應 `persuaded: true` 時（`agent.gd::_resolve_pending_persuade()`），這筆 `proposed_task` 才會被插進它自己的任務池；`persuaded: false` 或省略則不插入，只留一句事實句記錄被拒絕，`persuaded` 本身怎麼判斷見上方那列
- **傳 `null`、`{}`，或任務驗證不過**：整包 `plan` 回應直接判失敗，不是只丟掉這一筆 `persuade` 任務——`_validate_persuade_params()` 在 `validate_tasks()` 的逐筆迴圈裡，失敗會讓整個回應被拒收，見 §6。錯誤碼依失敗原因而定：`null`／`{}`／巢狀 `persuade`／欄位形狀錯誤是 `ERROR_BAD_SHAPE`；`proposed_task.action` 不在 `ALLOWED_ACTIONS` 白名單則是 `ERROR_ACTION_NOT_ALLOWED`，不是一律同一個錯誤碼

失敗（逾時／格式錯誤／驗證不過）時房主機不會收到上面這個形狀，改走 §6。

> ⚠️ 回應中**不得包含任何數值變更**。Provider 不可回傳 `satiety`、`money`、`relations` 等欄位——那些一律由房主機計算，AISchema 也只挑驗證過的欄位複製出來，不會原樣放行整包回應。

---

### 4-3 `dialogue`　對話逐輪生成

**Godot → AI**（`speaker` 一定是本機 Agent，玩家的台詞不經過這裡）

```json
{
  "type": "dialogue",
  "self": { "…同 4-2 的 self 區塊" },
  "context": {
    "listener": { "name": "TAMMY", "trust": 42, "met_count": 5 },
    "turns": [ { "speaker": "NEON", "text": "最近好嗎？" } ],
    "max_turns": 10,
    "memory": { "recent": [ "…" ], "core": [ "…" ] }
  }
}
```

沒有 `response_format`——`validate_dialogue()` 是這條路徑唯一的硬保證，system prompt 只用文字要求「純 JSON」。

**AI → Godot**

```json
{ "line": "還不錯，你呢？", "end": false }
```

| 欄位 | 必填 | 說明 |
| --- | --- | --- |
| `line` | ✔ | 非空字串，超過 200 字截斷不拒絕 |
| `end` | 選填 | 布林，省略視為 `false`（沒說要收尾就當作還沒講完） |

對話輪數沒有設計上的硬上限，改用軟壓力＋`SAFETY_MAX_TURNS`（工程安全閥，值 10）兜底，見《技術/LLM 串接與 AI 服務層》§界線。

---

### 4-4 `words_to_creator_choice`　天神之石：這句話現在要不要說出口

跟本文件曾經設想的「單一 `/event` 請求打包 `audience[]`、換回一批 `reactions[]`」不同——天神之石事件觸發後，**範圍內**（`god_stone_input.gd` 的 `HEAR_RADIUS`＝96px＝6 格，跟 note/技術/天神之石輸入機制.md 一致）每個候選角色**各自獨立擲骰、各自打一次這種呼叫**（`agent.gd::maybe_speak_to_creator()`），不是一次請求換一批反應。擲骰本身（情緒強度 ≥70 時 40% 機率，否則 25%）是 Godot 端純機率判定，不經 AI；AI 只回答「骰中之後，這句我早就想好的話，現在要不要說出口」這個是非題。

**Godot → AI**

角色自己那句私藏的話（`words_to_creator`）直接嵌進 system prompt，不是每次當 payload 傳：

```json
{
  "type": "words_to_creator_choice",
  "context": { "heard": "北邊的井裡有東西" }
}
```

**AI → Godot**

```json
{ "say_it": true }
```

沒有本文件先前設想的 `credibility`／Event Parser／`believed`／`emotion`／`spoke_words_to_creator` 這些欄位——實作沒有做「AI 對事件內容信不信」這一層判斷，只有「說不說得出口」。回 `true` 時，房主機直接呼叫 `say(words_to_creator)`，`_words_to_creator_spoken` 標記一生只消耗一次（骰中但回 `false` 不算數，下次還能再骰，見 note/技術/天神之石輸入機制.md）。

`speech` 內容（也就是這句話）只送給玩家 UI（浮動文字／內心狀態視窗），不寫入其他 NPC 的對話事件與記憶——這一點跟原設計一致。

---

### 4-5 `creation`　建角時生成 `words_to_creator`

**Godot → AI**

```json
{ "type": "creation" }
```

system prompt 是 `character.system_prompt`（人格段）接上固定的收尾指示，不是 payload 帶 `system_prompt` 欄位。

**AI → Godot**

```json
{ "words_to_creator": "我天生就是個怕生的傢伙，也是沒辦法。" }
```

生成規則見《01》§1-4。**違反內容規則時重試 3 次、3 次都不過改用固定備用句庫**是《99》P-10 已拍板的目標設計（2026-08-16 定案），但目前**沒有實作**——`agent.gd::_generate_words_to_creator()`／`game_manager.gd::_generate_words_to_creator()` 兩處都只呼叫一次 `AIService.request()`，`AISchema.validate_creation(result["data"])` 沒過就直接 `return`，沒有內容驗證重試迴圈、也沒有備用句庫。實際行為是：這次生成失敗，`words_to_creator` 就停在空字串——不是「絕不留空」。

AI 回應裡本來就**沒有** `retries` 欄位回報（重試次數如果真的做了，也只會是呼叫端自己數的迴圈次數，不會是 AI 回應的一部分）。50 個官方 NPC 模板在資料準備階段就先生成好、經過人工檢閱，不等投放時才生成，這件事不受上面這個缺口影響。

> ⚠️ `AIService` 本身對部分可重試的傳輸層錯誤（HTTP 5xx、特定網路錯誤）會自動重試 1 次（`RETRY_LIMIT := 1`），但那是**傳輸層**重試，跟這裡在講的「內容違規要不要重打」是兩回事——傳輸重試對所有呼叫類型都生效，不是 `creation` 專屬的行為，見 §6。

---

### 4-6 `reflection`　睡眠反思

**Godot → AI**

```json
{
  "type": "reflection",
  "self": { "…同 4-2 的 self 區塊" },
  "context": {
    "events": [ { "id": 12, "content": "採了藥草但沒賣掉" } ]
  }
}
```

跟本文件先前設想的差別：請求不單獨帶 `day`／`personality` 這兩個欄位——日期已經在 `self.time.day` 裡，人格現值不需要送進去，模型只要給「變動量」（delta），不需要看當前分數。

**AI → Godot**

```json
{
  "summary": "今天採了藥草但沒賣掉，跟 TAMMY 又吵了一架。",
  "events": [
    { "id": 12, "content": "採了藥草但沒賣掉", "valence": "negative", "importance": 40 }
  ],
  "personality_delta": { "grudge": 2, "sociability": -1 },
  "today_plan": [ { "text": "去藥草鋪賣掉藥草", "is_done": false } ]
}
```

| 欄位 | 必填 | 說明 |
| --- | --- | --- |
| `events` | ✔（可空陣列） | **一定要逐筆帶回 `id`**（`agent.gd` 靠它判斷哪幾筆真的被評過分、可以從緩衝區移除）；`valence`／`importance` 是 LLM 自己判斷，房主機不重算，只夾制 `importance` 到 0–100（本文件先前的範例漏了這塊逐筆評分） |
| `personality_delta` | 選填 | 只列有變動的維度，單項絕對值上限 3（超過房主機夾制） |
| `today_plan` | 選填 | 整份取代，不限筆數（上限 `MAX_PLAN_ITEMS`＝10） |

---

### 4-7 `checkpoint`　長動作固定間隔檢查點

本文件先前完全沒有這個訊息類型（issue #336，《02》§3）：長動作（`duration` 較長的任務）進行到一半，每 `LONG_ACTION_CHECKPOINT_INTERVAL := 10` 遊戲分鐘（跟 `MIN_ACTION_DURATION` 取同一個值，《99》P-14 #9）固定問一次「繼續還是放棄」，不是完整重新規劃，所以只帶 `self`（自身狀態），不帶 `visible`／`pool`／`memory`。放棄時若這個角色正在被別人依附（目前唯一情形是搬運中的目標，`get_checkpoint_dependents()`），依附者也會一併收到通知（`on_dependent_checkpoint()`），但通知走的是引擎內部呼叫，不是另一次 AI 請求。

**Godot → AI**

```json
{
  "type": "checkpoint",
  "self": { "…同 4-2 的 self 區塊" },
  "context": { "action": "gather", "elapsed_minutes": 15, "params": {} }
}
```

**AI → Godot**

```json
{ "continue": true }
```

`continue: false` 代表放棄——已經花掉的時間與體力不退還，這個動作原本能拿到的東西也拿不到，措辭在 system prompt 裡講清楚，房主機不二次判定。

---

## 5. 時序圖

### 正常決策（事件驅動）

每個角色各自獨立、非同步發起，不是全體 NPC 在同一個時間點被送出批次。下圖為單一角色的一次決策；5 個角色可能同時各自處於流程中的不同階段。

```
Godot 操控層                房主機                    llama-server
  │                           │                          │
  │  角色完成當前動作          │                          │
  │── 通知決策已就緒 ─────────►│                          │
  │                           │  ① 更新生理數值            │
  │                           │  ② 產生事實句              │
  │                           │  ③ 截取快照、組 payload     │
  │                           │── chat completion ───────►│
  │                           │   （payload.type=plan，   │
  │                           │    json_schema→GBNF 由   │
  │                           │    llama-server 自己轉，  │
  │                           │    見《12》§8）           │
  │                           │◄── JSON ──────────────────│
  │                           │  ④ schema 驗證＋三條硬規定  │
  │                           │  ⑤ 計算成功率＋擲骰        │
  │                           │  ⑥ 套用結果（序列處理）    │
  │◄── 已驗證的 tasks ─────────│                          │
  │  ⑦ 尋路、播動畫            │                          │
  │  ⑧ 回報執行結果            │                          │
  │── 動作結束，回到頂端 ──────┤                          │
  │                           │                          │
```

### 天神之石

範圍內每個候選角色**各自獨立**擲骰、各自打一次 `words_to_creator_choice` 呼叫——不是一次請求打包全部角色、換回一批反應（見 §4-4）。下圖只畫其中一個角色：

```
玩家                Godot                候選角色（各自獨立）      llama-server
 │                    │                         │                     │
 │── 輸入文字 ───────►│                         │                     │
 │                    │  判斷範圍內角色          │                     │
 │                    │── 逐一通知 ────────────►│                     │
 │                    │                         │  各自擲骰決定       │
 │                    │                         │  要不要打這通呼叫    │
 │                    │                         │── chat completion ─►│
 │                    │                         │   （words_to_       │
 │                    │                         │    creator_choice） │
 │                    │                         │◄── {"say_it":…} ────│
 │                    │                         │  say_it=true 才     │
 │                    │                         │  say(words_to_      │
 │                    │                         │  creator())         │
 │◄── UI 顯示 ────────┤                         │                     │
 │   （只給玩家看）    │                         │                     │
```

---

## 6. 錯誤處理

失敗分兩層，各自一組 identifier——不是本文件先前設想的單一 `DecisionError`／`reason` 對照玩家可讀訊息那張表，那張表目前沒有任何程式碼在維護。

**AIService 層**（`ai_service.gd` 的 `ERROR_*`，網路／額度／設定問題）

| identifier | 觸發狀況 |
| --- | --- |
| `disabled` | AI 功能關閉（設定檔 `enabled=false`） |
| `no_requester_id` | 呼叫端沒給 `requester_id` |
| `no_provider` | 指定的 provider 不存在或設定不完整（`has_valid_provider()` 不成立） |
| `rate_limited` | 撞到 `min_interval_sec`／`max_calls_per_game_day`／`max_dialogue_calls_per_game_day` 任一節流閘門 |
| `daily_quota` | 每日呼叫額度用盡 |
| `timeout` | `HTTPRequest` 逾時（`provider.timeout`，設定檔可調，不是寫死的 5／15 秒） |
| `network` | `HTTPRequest` 本身失敗（DNS／連線層錯誤） |
| `http` | HTTP 狀態碼非 2xx（格式 `http_<code> <回應內容前 200 字>`） |
| `bad_json` | provider 回應不是合法 JSON |

**AISchema 層**（`ai_schema.gd` 的 `ERROR_*`，格式／驗證失敗；`_decide_with_retry()` 依 `provider.max_validation_retries()` 自動重試，重試次數用完才把最後一次的失敗原因往上回）

| identifier | 觸發狀況 |
| --- | --- |
| `not_json` | `choices[0].message.content` 不是合法 JSON |
| `not_object` | 解析出來不是 JSON object（例如模型回了一個陣列） |
| `no_content` | provider 回應形狀不對，撈不到 `content` |
| `bad_shape` | 欄位缺漏／型別錯／超出範圍，逐欄位規則見各 `validate_*()` |
| `action_not_allowed` | `action` 不在 `ALLOWED_ACTIONS` 白名單 |

**房主機收到失敗時的行為**：一律回 `{"ok": false}`，沒有統一合成一筆 `{"action": "idle", ...}` 寫回、也沒有玩家可讀訊息對照表這一層——每種呼叫類型各自決定怎麼收尾：

| 呼叫類型 | 失敗時的行為 |
| --- | --- |
| `plan` | 這輪不產生新 `tasks`，角色留在既有任務池，不特別寫 `last_action_result` |
| `dialogue` | `conversation.gd::_finish_with_fallback()` 改說一句 `DialogueLines.closing()` 收尾 |
| `words_to_creator_choice`／`creation`／`reflection`／`checkpoint` | 直接 `return`，這次呼叫當作沒發生——fire-and-forget，不重試、不降級成別的內容 |

HTTP 5xx、逾時都落在上面 AIService 層的 `http`／`timeout` identifier 裡，不是獨立分類；本文件先前設想的「`request_id`／`protocol_version` 不符」這類檢查也不存在——請求裡本來就沒有這兩個欄位（見 §4）。

> ⚠️ Provider 回傳數值變更欄位（`satiety`、`money`、`relations` 等）：AISchema 的驗證邏輯只挑白名單內的欄位複製出來，多出來的欄位單純不會出現在驗證後的結果裡，不需要額外的「忽略並寫 log」處理。

---

## 7. 資料型別對應

| Godot（GDScript） | JSON | Python |
| --- | --- | --- |
| `int` | number | `int` |
| `float` | number | `float` |
| `String` | string | `str` |
| `bool` | true / false | `bool` |
| `Array` | array | `list` |
| `Dictionary` | object | `dict` |
| `null` | null | `None` |

### 注意事項

| # | 事項 |
| --- | --- |
| 1 | Godot 的 `JSON.parse_string()` 會把所有 number 轉成 `float`。整數欄位取值後要 `int()` 轉回 |
| 2 | 中文字串一律 UTF-8，不做 escape |
| 3 | `null` 與空字串 `""` 意義不同，也跟「欄位不存在」不同：以 `update_plan` 為例，房主機收到 `null`（模型沒填這輪的 `update_plan`）代表「這次沒有更新」，跟合法的空陣列 `[]`（模型明確要清空 today_plan）是兩回事，見 `validate_tasks()` |
| 4 | 時間戳一律 ISO 8601 UTC（`2026-08-08T10:00:00Z`） |

---

## 8. 決策契約約束範圍

**JSON Schema 為唯一契約來源**，GBNF 只是 `LocalLLM` 其中一種轉換路徑（`json_schema_to_grammar`），不再手寫維護。完整原則見《12》§2。

| 欄位 | 約束方式 |
| --- | --- |
| `action` | 靜態 enum（`ALLOWED_ACTIONS`） |
| `emotion.type` | 靜態 enum（8 值） |
| `priority`／`duration`／`expires_in_minutes` | 靜態數值範圍（`integer` + `minimum`/`maximum`，見 §4-2） |
| `params` | **不約束**，schema 只宣告成 `{"type": "object"}`——`target`（talk／attack／give）與 `item_id`／`place`（buy）等欄位靠 §3 提到的 AISchema 驗證層逐動作檢查是否為非空字串，不是動態 GBNF enum。§7.1 原本規劃的 `build_schema_for_call()`（依在場角色／物品動態組 `target`／`location_id` 的 enum）已被 §8 簡化路線取代，沒有實作 |
| `update_plan` | **條件式欄位**，僅特定時機加入 schema（《10》§5.4、《12》§2.4） |
| `persuaded`／`importance`／`valence` | **條件式欄位**，僅這輪帶有待回應說服事實句時加入 schema（#227） |

`appointment`（《10》§5.5）、`speech_volume`（`dialogue` 的 `line` 沒有分音量）都是尚未實作的欄位，不在目前的 schema 裡，見 §4-2／§9。

> 動態能力目前只剩「條件式欄位存不存在」這一層，不再有依在場角色/物品即時產生的動態 enum。RemoteLLM（雲端模型）的 schema 約束為盡力而為，非文法層強制，房主機收到後仍須完整驗證（《12》§4）。
> 

---

## 9. 待辦

| # | 項目 | 負責 | 追蹤 |
| --- | --- | --- | --- |
| 1 | ~~連接埠與逾時秒數定案~~ | 後端 | ☑ 2026-08-16，見《99》P-11 |
| 2 | 是否縮減傳送項目讓 AI 判斷更聚焦 | AI・後端 | 《99》P-03（MVP 定案走方案 A，見該項） |
| 3 | ~~`words_to_creator` 天神之石觸發機率~~ | 遊戲邏輯 | ☑ 2026-08-16，見《99》P-10 |
| 4 | 依前提條件動態過濾可選動作（原設想的 `available_actions`） | 遊戲邏輯 | 未實作，見 issue #477（`Task.preconditions` 目前一律通過） |
| 5 | ~~Godot 端 `HTTPRequest` 封裝與重試邏輯~~ | 前端 | ☑ 已實作，見 `ai_service.gd` |
| 6 | ~~單一角色決策請求的併發上限~~ | 後端 | ☑ 2026-08-16，見《99》P-11 |
| 7 | ~~`build_schema_for_call()` / `DecisionProvider` 重構六項任務~~ | AI・後端 | ☑ 已改走 §8 簡化路線，不需要這六項（《12》§8，issue #245） |
| 8 | `creation` 內容違規重試 3 次＋固定備用句庫（《99》P-10 已拍板） | AI・後端 | 未實作，`agent.gd`／`game_manager.gd` 的 `_generate_words_to_creator()` 目前只打一次，失敗就留空字串，見 §4-5 |