---
tags: [規格書, 架構]
status: 大致定案
updated: 2026-08-16
---

# 04_Godot與AI資料介接規格

# 04｜Godot 與 AI 資料介接規格

**閱讀對象**：後端組・前端組・AI 組
**文件性質**：通訊契約。Godot 端 `AIService` 與 `LocalLLM`／`RemoteLLM`／`HumanInput` 之間所有資料交換的格式以本文件為準；沒有獨立的 AI 後端行程，見 §1。
**前置閱讀**：《00 設計原則與架構》、《01-3 Prompt 注入與資料傳送》、《12 決策來源抽象與執行架構規格書》

---

## 1. 系統架構

**沒有獨立的 Python AI 後端。** Godot（房主機兼玩家端）本身就是《12》定義的房主機權威——`AIService`（見《技術/LLM 串接與 AI 服務層》）在 Godot 行程內完成 prompt／schema 組裝、佇列排程、驗證與狀態套用，只有「實際生成文字」這一步會呼叫外部的 `DecisionProvider`：`LocalLLM` 是本機 `llama-server`（HTTP，同機 localhost）、`RemoteLLM` 是雲端 API（HTTP，走網際網路）、`HumanInput` 是本機決策面板（無 HTTP）。多人模式下 `RemotePlayer` 才會有 Godot↔Godot 的網路連線，完整職責邊界見《12》§5。

```
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
│  LocalLLM: llama-server（127.0.0.1:8080，--parallel 5, ctx 16000）│
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

## 3. 端點清單

事件驅動架構下，決策請求以**單一角色**為單位發起，不再是每 tick 批次送出全體 NPC（見《10》§5.1、《12》§5.1）。

**這些是 `AIService` 對外呈現的邏輯操作，不是獨立行程的網路端點**——`decide`／`event`／`generate/words`／`memory/reflect` 各自組好 prompt/schema 後，一律送進同一個 `LocalLLM`／`RemoteLLM` 的 chat completion 呼叫，差別只在 prompt 內容與 schema，不是不同 URL。下表沿用端點命名只是方便對照「這次呼叫要做什麼」，實際 wire format 見《技術/LLM 串接與 AI 服務層》。

| 操作 | 用途 |
| --- | --- |
| `health` | 啟動時檢查 `LocalLLM`／`RemoteLLM` 是否就緒 |
| `decide` | 單一角色的決策請求（角色完成動作後發起） |
| `event` | 推送即時事件（天神之石） |
| `generate/words` | 建角時生成 `words_to_creator` |
| `memory/reflect` | 睡眠反思、記憶壓縮 |

---

## 4. 封包格式

### 4-1 `/health`

**回應**

```json
{
  "status": "ready",
  "model": "local-7b",
  "slots_total": 5,
  "slots_busy": 0,
  "protocol_version": "1.0"
}
```

`status` 為 `ready` / `loading` / `error`。Godot 啟動時先打這支，未 ready 前不開始接受決策請求。

---

### 4-2 `/decide`　單一角色決策請求

**Godot → AI**

角色完成當前動作後才發起（見《10》§5.1、《00》§7），一次一位，不是批次陣列。

```json
{
  "protocol_version": "1.0",
  "request_id": "req_00001234",
  "tick": 4210,
  "game_time": { "day": 30, "hour": 14, "minute": 20 },
  "npc_id": "npc_017",
  "snapshot": {
    "physical": {
      "hunger":     { "value": 62, "label": "很餓" },
      "thirst":     { "value": 38, "label": "有點渴" },
      "stamina":    { "value": 45, "label": "有點累" },
      "sleepiness": { "value": 20, "label": "清醒" },
      "hygiene":    { "value": 55, "label": "還算乾淨" },
      "alcohol":    { "value": 0,  "label": "清醒" },
      "health":     { "value": 88, "label": "健康強壯" },
      "injury":     { "value": 12, "label": "輕微擦傷" }
    },
    "emotion": {
      "type": "anger", "intensity": 78, "duration_left": 6
    },
    "conditions": [ { "type": "injured", "turns_left": 8 } ],
    "current_goal": "把藥草賣掉，換錢買一把好一點的刀",
    "today_plan": [
      { "text": "採藥草", "done": true },
      { "text": "找 TAMMY 聊天", "done": false },
      { "text": "修屋頂", "done": false }
    ],
    "last_action_result": {
      "action": "steal",
      "target": "npc_003",
      "success": false,
      "reason": "現場有兩名目擊者，你臨陣退縮了"
    },
    "location": {
      "id": "loc_herb_field",
      "name": "藥草叢",
      "desc": "一片半人高的草叢，泥土有點濕。"
    },
    "fact_lines": [
      "你已經半天沒和任何人說過話了。"
    ],
    "present_npcs": [
      {
        "npc_id": "npc_003",
        "name": "NEON",
        "appearance_text": "他綁著一頭紅色長髮，穿著沾滿油汙的工作服。",
        "relation": { "trust": 15 }
      }
    ],
    "available_actions": ["gather", "move", "talk", "rest", "eat", "steal"],
    "economy": {
      "money": 300,
      "inventory": [
        { "item_id": "herb", "count": 4, "decay": 22, "durability": 100 }
      ]
    },
    "injected_lines": []
  }
}
```

#### 欄位說明

| 欄位 | 必填 | 說明 |
| --- | --- | --- |
| `protocol_version` | ✔ | 版號不合時 AI 端回 `400` |
| `request_id` | ✔ | 房主機產生，回應必須帶回同一個 |
| `tick` | ✔ | 全域 tick 計數，僅供時間顯示，不是觸發依據（見《00》§3） |
| `npc_id` | ✔ | 本次決策請求的角色，單一角色一次 |
| `physical.*.value` | ✔ | 數值本體。這裡的 `hunger`／`thirst`／`sleepiness` 是**換算過的顯示概念**（飢餓度／口渴度／睡意），不是內部儲存欄位名——內部儲存分別叫 `satiety`／`hydration`／`wakefulness`，方向相反（見《01》§4-1）。換算式：`hunger = 100 − satiety`、`thirst = 100 − hydration`、`sleepiness = 100 − wakefulness`。`stamina`／`hygiene`／`alcohol`／`health`／`injury` 內部與顯示同名同方向，直接傳原始值（見《99》P-07） |
| `physical.*.label` | ✔ | **中文形容詞，缺一不可**，5 級距對照表見《99》P-07 |
| `today_plan[].done` | ✔ | 每筆標記完成／未完成，不限筆數（見《10》§5.4） |
| `fact_lines` | ✔ | 引擎產生的事實句陣列，無則傳 `[]` |
| `present_npcs` | ✔ | **只放在場的人**，無則傳 `[]` |
| `available_actions` | ✔ | 由房主機依地點與狀態過濾後給定 |
| `injected_lines` | ✔ | 特殊注入行（如 `words_to_creator` 觸發），無則傳 `[]` |

> ⚠️ **每次決策只讀請求發起當下的快照**。套用階段在房主機序列處理，避免 race condition（見《00》§7）。

**AI → Godot**

```json
{
  "protocol_version": "1.0",
  "request_id": "req_00001234",
  "npc_id": "npc_017",
  "decision": {
    "action": "gather",
    "target": null,
    "location_id": "loc_herb_field",
    "monologue": "藥草再不採就要被別人拿光了。",
    "speech": null,
    "speech_volume": "normal",
    "emotion": { "type": "neutral", "intensity": 30 },
    "current_goal": "把藥草賣掉，換錢買一把好一點的刀",
    "update_plan": null,
    "appointment": null
  },
  "meta": {
    "source_model": "local-7b",
    "latency_ms": 820
  }
}
```

#### 欄位說明

| 欄位 | 型別 | 說明 |
| --- | --- | --- |
| `action` | enum | schema 靜態 enum 約束，轉 GBNF 見《12》§2.1 |
| `target` | string \| null | 目標角色或物品 ID，schema 動態 enum |
| `location_id` | string \| null | 移動目的地，schema 動態 enum |
| `monologue` | string | **必填**，內心獨白 |
| `speech` | string \| null | **可為 null**——AI 自己決定說不說、說多長 |
| `speech_volume` | enum | `whisper` / `normal` / `shout`，靜態 enum |
| `emotion` | object | AI 自行宣告 |
| `current_goal` | string | AI 可隨時改寫，上限 40 字 |
| `update_plan` | array \| 不存在 | 僅在《10》§5.4 列出的時機，schema 才含此欄位（見《12》§2.4） |
| `appointment` | object \| null | `with` / `location` / `game_time`，結構見《10》§5.5 |
| `meta.source_model` | string | Provider 實際使用的模型名稱，供《10》B33 結算揭露 |

失敗（逾時／格式錯誤／模型失效）時房主機不會收到 `decision`，改依《12》§6 走 `DecisionError` 流程，見本文件 §6。

> ⚠️ 回應中**不得包含任何數值變更**。Provider 不可回傳 `satiety`、`money`、`relations` 等欄位——那些一律由房主機計算。
> 

---

### 4-3 `/event`　天神之石事件

**Godot → AI**

```json
{
  "protocol_version": "1.0",
  "event_id": "evt_1043",
  "event_type": "divine_stone",
  "tick": 4210,
  "content": "北邊的井裡有東西",
  "credibility": 0.5,
  "audience": [
    {
      "npc_id": "npc_017",
      "snapshot": { "…": "同 /decide 的 snapshot 結構" },
      "words_to_creator": {
        "triggered": true,
        "content": "你把我設計成連話都懶得講，那你現在是想聽什麼？"
      }
    }
  ]
}
```

| 欄位 | 說明 |
| --- | --- |
| `content` | 玩家原句，未經處理 |
| `credibility` | Event Parser 給的可信度 0.0–1.0，AI 自行決定信不信 |
| `audience` | 範圍內聽得到的角色 |
| `words_to_creator.triggered` | **Godot 端擲骰決定**，為 `true` 時 AI 才把該句注入 prompt |

**觸發規則**（Godot 端判定）：

```
玩家在天神之石輸入一段話
        │
        ▼
Event Parser → event_type / content / credibility
        │
        ▼
判斷範圍內有哪些角色
        │
        ├─► 一般反應（每個人都跑）
        │
        └─► words_to_creator 觸發判定（每個人各自骰）
                │
                ├─ is_spoken == true ──► triggered = false
                │
                └─ 擲骰【機率待填】
                        ├─ 成功 ──► triggered = true
                        └─ 失敗 ──► triggered = false
```

**AI → Godot**

```json
{
  "protocol_version": "1.0",
  "event_id": "evt_1043",
  "reactions": [
    {
      "npc_id": "npc_017",
      "believed": false,
      "monologue": "井裡有東西？誰知道是誰在講話。",
      "speech": "你把我設計成連話都懶得講，那你現在是想聽什麼？",
      "spoke_words_to_creator": true,
      "emotion": { "type": "surprise", "intensity": 55 }
    }
  ]
}
```

| 欄位 | 說明 |
| --- | --- |
| `believed` | AI 自行決定信不信這段話 |
| `spoke_words_to_creator` | AI **實際上有沒有把那句話說出口**。為 `true` 時 Godot 才寫入 `is_spoken` / `spoken_at` / `trigger` |

> ⚠️ `speech` 若為 `words_to_creator` 的內容，**只送給玩家 UI**（浮動文字／內心狀態視窗），**不寫入其他 NPC 的對話事件與記憶**。
> 

---

### 4-4 `/generate/words`　建角時生成

**Godot → AI**

```json
{
  "protocol_version": "1.0",
  "npc_id": "npc_017",
  "system_prompt": "你正在扮演一個遊戲角色。\n\n【行為準則】\n- 你極度自私狡猾…"
}
```

**AI → Godot**

```json
{
  "protocol_version": "1.0",
  "npc_id": "npc_017",
  "content": "你把我設計成連話都懶得講，那你現在是想聽什麼？",
  "retries": 0
}
```

生成規則見《01》§1-4。用 GBNF 約束輸出長度（≤60 字）與型別，格式面不會違規；違反內容規則（提及遊戲內容或數值）時
Godot 端重試，**上限 3 次**（2026-08-16 定案，見《99》P-10），`retries` 回報重試次數。3 次都違規時，
改用固定備用句庫（依人格傾向挑一句籠統但不違規的版本，例如「我沒什麼想對你說的」），`content` 絕不留空——
它是唯讀欄位，之後沒有機會補救。50 個官方 NPC 模板在資料準備階段就先生成好、經過人工檢閱，不等投放時才生成。

---

### 4-5 `/memory/reflect`　睡眠反思

**Godot → AI**

```json
{
  "protocol_version": "1.0",
  "npc_id": "npc_017",
  "day": 30,
  "events": [ { "…": "當日事件流" } ],
  "personality": { "…": "10 項現值" }
}
```

**AI → Godot**

```json
{
  "protocol_version": "1.0",
  "npc_id": "npc_017",
  "summary": "今天採了藥草但沒賣掉，跟 NEON 又吵了一架。",
  "personality_delta": { "grudge": 2, "sociability": -1 },
  "today_plan": [
    { "text": "去藥草鋪賣掉藥草", "done": false },
    { "text": "避開 NEON", "done": false },
    { "text": "晚上去餐酒館", "done": false }
  ]
}
```

| 欄位 | 說明 |
| --- | --- |
| `personality_delta` | **單項絕對值上限 3**。超過時房主機夾制，不採信 |
| `today_plan` | 睡眠反思是《10》§5.4 開放 `update_plan` 的時機之一，此處重寫整份，不限筆數 |

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
  │                           │  ③ 截取快照、組 prompt+schema│
  │                           │── POST /decide ─────────►│
  │                           │   （schema→GBNF，《12》§2）│
  │                           │◄── JSON ──────────────────│
  │                           │  ④ schema 驗證＋三條硬規定  │
  │                           │  ⑤ 計算成功率＋擲骰        │
  │                           │  ⑥ 套用結果（序列處理）    │
  │◄── 已驗證的 decision ──────│                          │
  │  ⑦ 尋路、播動畫            │                          │
  │  ⑧ 回報執行結果            │                          │
  │── 動作結束，回到頂端 ──────┤                          │
  │                           │                          │
```

### 天神之石

```
玩家                Godot                    AI 後端
 │                    │                         │
 │── 輸入文字 ───────►│                         │
 │                    │  Event Parser           │
 │                    │  判斷範圍內角色          │
 │                    │  words_to_creator 擲骰   │
 │                    │                         │
 │                    │── POST /event ─────────►│
 │                    │                         │
 │                    │◄── 200 reactions[] ─────│
 │                    │                         │
 │                    │  套用情緒與記憶          │
 │◄── UI 顯示 ────────│                         │
 │   （吐槽句只給玩家）│                         │
```

---

## 6. 錯誤處理

決策失敗一律映射為 `DecisionError`（見《12》§3.1），`reason` 對照玩家可讀訊息如下（《12》§6.3）：

| `reason` | 觸發狀況 | 玩家端訊息 |
| --- | --- | --- |
| `timeout` | 逾時（`LocalLLM` > 5 秒／`RemoteLLM` > 15 秒，2026-08-16 定案，見《99》P-11／P-22） | 模型回應逾時 |
| `invalid_format` | JSON 解析失敗、重試仍失敗 | 模型輸出格式不符 |
| `model_missing` | 指定模型不存在 | 找不到指定的模型 |
| `quota_exceeded` | 雲端模型額度用盡 | 模型額度不足 |
| `rate_limited` | 呼叫過於頻繁 | 模型呼叫過於頻繁 |
| `no_response` | 真人逾時未填表（見《12》§6.2） | 未在時限內做出決定 |

| 狀況 | 房主機行為 |
| --- | --- |
| `/health` 未 ready | 不開始接受決策請求，顯示「模型載入中」 |
| 任何 `DecisionError` | 該角色本次執行 `idle`，寫入 `last_action_result`，依《10》§6.4 走入眠流程 |
| HTTP 5xx | 同上，寫入 log |
| `request_id` 不符 | 丟棄該回應，視為 `timeout` |
| `protocol_version` 不符 | 停止並顯示錯誤，不得靜默降級 |
| Provider 回傳不存在的 `target` | 判定為失敗（三條硬規定，見《12》§4.2），`reason` 寫「你要找的人不在這裡」 |
| Provider 回傳數值變更欄位 | **忽略該欄位**，寫入 log |

### `idle` 兜底

`DecisionError` 發生時，房主機寫入：

```json
{
  "action": "idle",
  "target": null,
  "success": true,
  "reason": null
}
```

角色原地發呆，體力小幅回復。**絕不讓角色因為沒收到決策而卡住或消失。**

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
| 3 | `null` 與空字串 `""` 意義不同：`speech: null` = 不說話，`speech: ""` = 錯誤格式 |
| 4 | 時間戳一律 ISO 8601 UTC（`2026-08-08T10:00:00Z`） |

---

## 8. 決策契約約束範圍

**JSON Schema 為唯一契約來源**，GBNF 只是 `LocalLLM` 其中一種轉換路徑（`json_schema_to_grammar`），不再手寫維護。完整原則見《12》§2。

| 欄位 | 約束方式 |
| --- | --- |
| `action` | 靜態 enum |
| `emotion.type` | 靜態 enum（8 值） |
| `speech_volume` | 靜態 enum（3 值） |
| `target` | **動態產生**，每次呼叫前由 `build_schema_for_call()` 依在場角色與物品組成 |
| `location_id` | **動態產生**，依可移動地點組成 |
| `monologue` / `speech` | 不約束內容，只約束型別（string / null） |
| `update_plan` | **條件式欄位**，僅特定時機加入 schema（《10》§5.4、《12》§2.4） |
| `appointment` | **條件式欄位**，僅對話情境且在場有其他角色時加入 schema（《12》§2.4） |

> 動態規則必須在每次呼叫前重建。若沿用上一次的 schema，AI 可能指向已經離場的角色。RemoteLLM（雲端模型）的 schema 約束為盡力而為，非文法層強制，房主機收到後仍須完整驗證（《12》§4）。
> 

---

## 9. 待辦

| # | 項目 | 負責 | 追蹤 |
| --- | --- | --- | --- |
| 1 | ~~連接埠與逾時秒數定案~~ | 後端 | ☑ 2026-08-16，見《99》P-11 |
| 2 | 是否縮減傳送項目讓 AI 判斷更聚焦 | AI・後端 | 《99》P-03（MVP 定案走方案 A，見該項） |
| 3 | ~~`words_to_creator` 天神之石觸發機率~~ | 遊戲邏輯 | ☑ 2026-08-16，見《99》P-10 |
| 4 | `available_actions` 完整清單 | 遊戲邏輯 | 《07》 |
| 5 | Godot 端 `HTTPRequest` 封裝與重試邏輯 | 前端 | — |
| 6 | ~~單一角色決策請求的併發上限~~ | 後端 | ☑ 2026-08-16，見《99》P-11 |
| 7 | `build_schema_for_call()` / `DecisionProvider` 重構六項任務 | AI・後端 | 《12》§7.1 |