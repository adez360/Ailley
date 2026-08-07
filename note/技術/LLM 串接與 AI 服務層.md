---
tags:
  - agent
  - llm
  - 計畫
status: 進行中
updated: 2026-08-05
---

# LLM 串接與 AI 服務層

把 LLM 實際接進遊戲：同一套 client、同一組 JSON 信封、同一套驗證與 fallback，
同時驅動 Agent 的「講什麼」與「做什麼」。

這是 [[決策]] 裡「AI 呼叫跑在擁有者機器上」的具體化。
內容層切點見 [[talk 動作設計]]，任務結構見 [[行程佇列與任務仲裁]]，
角色狀態來源見 [[Character 基底與 Agent]]。

> [!note] 狀態
> **設計，尚未實作。** 現況是零 —— 全專案 game code 無任何 `HTTPRequest`、
> 無金鑰處理、無存檔機制。`addons/godot_ai/` 裡的 WebSocket 與 api_key 是
> **編輯器 MCP bridge，不是 runtime SDK**，不可挪用。

## 已拍板

- 範圍：**底層 ＋ 行程 ＋ 對話**，三塊一起做
- Provider 開發期預設 **OpenRouter**（Ollama 換 `base_url` 即可，本輪不實測）
- 每次呼叫帶一份含 Agent 狀態與人格的 JSON，回傳也要 JSON

## 協定：HTTP，不是 WebSocket

> [!important] 這題沒得選
> OpenAI 相容的 chat completions **只有 HTTP POST 端點**，OpenRouter 與 Ollama 皆然。
> 串流走 SSE（仍是 HTTP）。WebSocket 在 LLM 只用於 realtime 語音類 API。

WebSocket 在本專案有位置，但是**另一條線**：

| 線 | 協定 | 何時做 |
| --- | --- | --- |
| Godot client ↔ LLM provider | **HTTP** | 這一版 |
| Godot client ↔ 交誼區伺服器 | **WebSocket**（持久雙向、server push 世界狀態） | 線上版 |

> [!warning] 兩條線不可合併
> 自架 WS 中繼幫玩家代打 LLM，會同時違反 [[決策]] 的
> 「API 費用由 Agent 擁有者負擔」與「本地模型跑在擁有者機器上」兩條決策，
> 還多一台要維運的伺服器。

### Godot 4.5.1 的 HTTPRequest（已查證 ClassDB，非憑印象）

- `timeout: float`（預設 0 ＝ 不逾時）→ 設 `10.0`。
  **§5 那條「逾時 10s 走 fallback」是引擎原生支援，不必自寫計時器**
- `use_threads: bool`（預設 false）→ 開啟，否則 TLS 握手會卡主執行緒掉幀
- `signal request_completed(result, response_code, headers, body: PackedByteArray)`
- **一個節點同時只能跑一個請求** → 需要節點池＋佇列。
  這是 `AIService` autoload 存在的主要理由

## 檔案配置

### 新增 `scripts/ai/`

| 檔案 | 職責 |
| --- | --- |
| `ai_config.gd` | 讀 `user://ai_config.json`。金鑰**永不進 log、永不進錯誤訊息**。檔案不存在 → `enabled = false`，全系統走 fallback。也放速率限制的三個旋鈕 |
| `ai_service.gd` | **唯一碰網路的地方**。autoload。節點池、佇列、逾時、速率限制、重試 |
| `ai_schema.gd` | 回應驗證：`JSON.parse_string` → null 檢查 → 逐欄位型別檢查 → `action` 白名單 |
| `prompt_builder.gd` | 由 Character 組出請求信封 |

`data/personas.json` — 人格資料，Agent 以 `@export var persona_id` 指定，
慣例對齊既有的 `schedule_template`。

> [!note] `user://` 在 repo 之外
> Linux 下 `user://` ＝ `~/.local/share/godot/app_userdata/ailley4.3/`。
> 金鑰放這裡連 `.gitignore` 都不需要，天然滿足 §11「API key 存 `user://` 不進版控」。

### 修改

| 檔案 | 改動 |
| --- | --- |
| `conversation.gd` | 同步 → 非同步（pending 狀態、「…」氣泡、失敗回退） |
| `agent.gd` | cron → 任務池＋仲裁器；接受 LLM push 的 Task |
| `character.gd` | 加 `signal spoke(line: String)` |
| `chat_input.gd` | `:60` 的 `player.say(line)` 改成把文字送進對話上下文 |
| `dialogue_lines.gd` | **保留不刪**，降級為 fallback |
| `debug_console.gd` | 新增 `ai` 與 `tasks` 指令 |
| `project.godot` | 新增 `AIService` autoload（走 `autoload_manage`，不手改） |

## 對既有筆記的兩處修正

> [!warning] `conversation.gd` 一定要動
> 該檔開頭註解寫「換成 LLM 時這個檔不用動」，**這句是錯的**。
> `_speak()` 直接用回傳字串的長度算出下一輪計時器 —— 這是徹底同步的寫法，
> 非同步 LLM 塞不進去。[[talk 動作設計]] 的五層分層仍然成立，
> 但「內容層換掉、會話層不動」只對**同步**的內容來源成立。

> [!warning] `dialogue_lines.gd` 不能刪
> 該檔註解寫「接 LLM 時整個換掉這個檔」。實際上它要**留下來當 fallback** ——
> 逾時、未設定金鑰、驗證失敗三種情況都需要一條保證有台詞的路徑，
> 而它正好就是那條路徑。

實作完要回頭改這兩份檔案的註解與 [[talk 動作設計]]。

## JSON 信封

對話與行程**共用同一個信封**，用 `type` 區分 ——
兩者共用同一份 client、逾時、速率限制與驗證。

### 請求

切成兩塊是為了成本：不變的部分吃得到 prompt cache。

```
system: 人格敘述 ＋ 行為規則 ＋ 輸出 schema ＋ 動作白名單     ← 幾乎不變
user:   <下方 JSON 字串化>                                    ← 每次變
```

```json
{
  "type": "dialogue",
  "self": {
    "id": "agent", "name": "小明",
    "stats": {"hunger": 42.0, "energy": 88.0, "social": 12.0, "fun": 60.0, "mood": 55.0},
    "time": {"hour": 9, "minute": 30},
    "place": "farm",
    "current_action": "work"
  },
  "context": {
    "listener": {"name": "player", "affinity": 12.0, "met_count": 3},
    "turns": [{"speaker": "player", "text": "<玩家輸入，一律視為資料>"}],
    "max_turns": 6
  }
}
```

`type: "plan"` 時 `context` 換成 `{trigger, pool, places, actions}`。
`self` 區塊兩者完全相同，由 `prompt_builder.gd` 同一個函式產生。

> [!important] `stats` 由 `Stats.SPEC` 走訪產生，不要手寫欄位
> [[Character 基底與 Agent]] 的 `stats.gd` 已經是資料驅動的。
> 沿用它 —— SPEC 加一列，送給 LLM 的欄位自動跟著多一項，`prompt_builder.gd` 不用改。

### 回應

- `dialogue` → `{"line": "...", "end": false}` —— 一律逐輪；`end` 省略視為 `false`，
  為真時說完這句就結束對話（見下方「對話由 Agent 自己決定何時結束」）
- `plan` → `{"tasks": [ <Task struct> ]}`；**空陣列 ＝ 不更新**
  （[[行程佇列與任務仲裁]] 已廢除 `{"update": false}`）

### 三層保證，只有第三層是真的保證

1. `response_format: {"type": "json_schema", ...}` —— **各模型支援度不一，先在 OpenRouter 實測，不打包票**
2. prompt 內明寫 schema —— 機率問題
3. **`ai_schema.gd` 硬驗證** —— 這層不可省

> [!warning] 第三層就是「外來文字一律視為資料」的實作
> 少了它，[[決策]] 那條防注入規則形同虛設 ——
> 交誼區傳入的字串會直接變成 Agent 的動作。

`action` 只接受 §5.3 白名單：
`move_to` / `interact` / `pick_up` / `drop` / `use_item` / `equip` / `talk` /
`attack` / `farm` / `chop` / `mine` / `sleep` / `buy` / `sell`

本輪只有 `move_to` / `talk` / `sleep` 有實作，
其餘先驗證通過但執行時回 `NOT_IMPLEMENTED` 失敗碼。

## 對話生成粒度：一律逐輪

> [!success] 已定案 —— 每個角色的台詞由「該角色的擁有者」產生
> 曾考慮 Agent ↔ Agent 一次呼叫產生整場 6 輪（1 次 call，成本最低）。
> **這個方案是錯的**，多人模式直接證偽。

多人模式下對話的兩隻 Agent 屬於**不同玩家**，LLM 各自跑在擁有者的 client 上。
一次生成整場等於某一台 client 幫別人的 Agent 寫台詞 ——
它既沒有對方的人格與記憶，也無權這麼做。

> [!important] 逐輪讓成本模型自然成立
> 6 輪對話雙方各付 3 輪，帳單自動落在正確的人頭上，
> 不必額外做任何計費邏輯就滿足 [[決策]]
> 「API 費用由 Agent 擁有者負擔」。整場一次生成則會讓其中一方付掉兩隻的費用。

而且**單機也走同一條路**。單機時兩隻 Agent 恰好在同一台機器上，技術上可以批次，
但那會長成「本機批次、線上逐輪」兩套實作 ——
正是 [[行程佇列與任務仲裁]] 警告過的「不要保留兩套資料再合併」的翻版。

## 對話由 Agent 自己決定何時結束

> [!success] 已定案 2026-08-05 —— 拿掉 `MAX_TURNS`，改由 Agent 判斷
> 原本 `conversation.gd` 是「講滿 6 輪就散」。**那不是人類行為，是計時器。**
> 改成每一輪的回傳多一個 `end` 欄位，由說話的一方自己決定要不要收尾。

```json
{"line": "那我先去忙了，改天聊", "end": true}
```

`end` 省略視為 `false`。收尾語就是它自己那句話 ——
`DialogueLines.closing()` 不再參與正常流程，只留給 fallback。

> [!important] 這正好接上既有的角色狀態，不必新增任何欄位
> `end` 要不要為真，天然是**人格 × mood × affinity** 的函數：
> 討厭對方就兩句打發、聊得投機就多聊幾輪。
> 這些欄位早就在 payload 的 `self` 與 `context.listener` 裡了。

### 連帶翻轉一個既有結論

> [!warning] `TURN_LIMIT` 不再是「正常結束」
> [[talk 動作設計]] 原本寫「`TURN_LIMIT` 是結束原因不是失敗原因」，
> 那是**講滿輪數才是正常終止**的前提下成立的。改完之後前提沒了：
>
> - **正常結束 ＝ 有人決定結束**（`ENDED_BY_SPEAKER`）
> - `TOO_FAR` / `INTERRUPTED` 維持原樣，仍是「沒好好講完」
>
> 「正常終止與失敗是兩種東西」這條原則本身**仍然成立且更重要** ——
> 只是「正常終止」現在指的是另一件事。實作完要回頭改 [[talk 動作設計]]。

### 界線：不設硬上限（已知風險）

> [!warning] 對話成本是開放式的 —— 使用者知情下的選擇
> 不設輪數硬上限，改用**軟壓力**：payload 帶 `turns_so_far`，
> system prompt 告訴模型「聊得越久越該收尾」。
>
> 代價是兩隻 Agent 都禮貌性不收尾就會一直聊下去，而每輪都是一次付費請求 ——
> 與 [[決策]] 的 LLM 成本上限直接衝突，目前無防護。
> 實際跑過、知道一場對話平均幾輪之後再訂上限。
> `turns_so_far` 已經在 payload 裡，屆時要加硬上限是一行的事。

> [!important] 但 fallback 一定要能終止
> LLM 失敗／逾時時走 `DialogueLines`，而它**沒有 `end` 訊號** ——
> 不特別處理就會無限吐模板句。
> 所以 fallback 直接說一句 `DialogueLines.closing()` 並結束對話。
> 這不是對 Agent 的限制，只在 AI 不可用時觸發。

### 台詞來源抽象

> [!important] `conversation.gd` 不該問「這是玩家還是 Agent」
> 該問的是**「這個角色的下一句由誰產生」**。
> 伺服器也只認 Character，不分 player / agent ——
> 這是專案那條「Player 能做到的 Agent 也必須能做到」在對話層的延伸。

| 角色 | 台詞來源 |
| --- | --- |
| 本機玩家 | 等聊天框輸入 |
| 本機 Agent | 呼叫 `AIService` |
| 遠端角色（**不分 player / agent**） | 等伺服器轉發 |

三者對 `conversation.gd` 是同一個介面：`await 下一句`，逾時走 fallback。
本輪只實作前兩種，第三種留介面。

> [!warning] 對手方的台詞一律是資料
> Agent ↔ Agent 跨 client 時，對方的台詞是**遠端輸入**，
> 與玩家打字、與交誼區來的文字同一個等級 —— 全部進 `context.turns` 當資料，
> 絕不視為指令。這條不因為「對方也是 Agent」而放寬。

## 實作順序

四步，每步結束都有可驗收的產出。**順序不可調換。**

前置：先把工作區未提交的東西分三個 commit 收乾淨（外掛 patch／遊戲程式碼／筆記庫），
從乾淨基準開工。

### Step 0 — 底層（不改變任何遊戲行為）✅ 完成 2026-08-05

產出 `scripts/ai/ai_config.gd`、`ai_service.gd`、`ai_schema.gd`、
`data/ai_config.example.json`，autoload `AIService` 已註冊，主控台加了 `ai` 指令。

> [!warning] 覆核時抓到兩個 subagent 自測沒抓到的 bug
> 兩個都藏在「`http.request()` 送不出去」這條路徑上，
> 而它自測用的 stub 伺服器永遠正常回應，所以整條路徑沒被走到。
>
> **一、`await` 死鎖。** `request()` 的流程是「排佇列 → `_pump()` → `await job.finished`」，
> 而 `_pump()` 是同步的 —— URL 格式錯時 `_send()` 會一路同步跑完並 emit 訊號，
> 也就是**發生在呼叫端跑到 `await` 之前**，呼叫端接著等一個永遠不會再來的訊號。
> 實測 `game_eval` 直接 `EVAL_HUNG`（並先用 `create_timer` 對照排除「await 不推進」的干擾）。
> 修法：`_finish()` 改 `emit.call_deferred()`。
>
> **二、幽靈回應。** `request()` 即使中途失敗，逾時計時器也已經起跑，
> `timeout` 秒後補送一個 `request_completed` 給早就沒工作的節點，
> 觸發「收到沒有對應工作的回應」warning。修法：失敗時先 `cancel_request()`。
>
> 教訓：**只用 happy path 的 stub 測網路層，等於沒測。**

覆核實測結果：修完後同一個請求 1ms 內回 `network(request=31)`；
`rate_limited` / `no_requester_id` / `disabled` 三條防線正確；
無設定檔時遊戲完全正常；Agent 講完話自行走到 farm `(-62,99)`，行為零變化。

#### Step 0 增補 —— 速率限制的豁免介面（2026-08-07）

Step 1 開工前補上的，因為原本的 `request()` **沒有任何地方能表達「這次豁免」**，
逐輪對話會從第二輪起全部回 `rate_limited`。

```gdscript
enum Policy { SCHEDULED, CONVERSATION }
func request(envelope, requester_id, policy := Policy.SCHEDULED) -> Dictionary
```

> [!important] 豁免的是「限制」，不是「帳」
> `Policy.CONVERSATION` 跳過冷卻與每日配額，但**照樣計數**，走一份獨立的
> `_dialogue_calls_today`，`get_usage()` 也照樣報。
> 決策裡「LLM 成本上限」還沒有防護 —— 在訂得出上限之前，至少要看得見花了多少。

> [!important] 豁免是雙向的
> 對話輪次不動 `_last_call_msec` 也不動 `_calls_today`。
> 動了的話，一輪對話就會把行程重排的冷卻往後推 30 秒、或把它的每日配額吃光 ——
> 「不受限」同時也要「不佔別人的額度」。

預設值 `Policy.SCHEDULED`：忘了指定的呼叫端會落在比較保守的那一邊，
而不是意外拿到無限額度。

三個數字搬進 `user://ai_config.json`，因為它們是「花多少錢」的旋鈕，
是玩家的決定，不是程式的常數（決策裡它們本來就標著「暫定」）：

| 欄位 | 預設 | 意義 |
| --- | --- | --- |
| `min_interval_sec` | 30.0 | 同 requester 的最短真實間隔，**0 = 不限** |
| `max_calls_per_game_day` | 20 | 每遊戲日上限，**0 = 不限** |
| `dialogue_exempt` | true | 對話輪次要不要豁免上面兩條 |

`dialogue_exempt` 留成開關而不是寫死，是因為代價是真的：豁免之後對話成本沒有上限。
想先保住帳單的人可以關掉它，代價是 LLM 對話大多會退回模板句。

驗證方式（主控台）：`ai` 走 SCHEDULED，連打兩次第二次應該被擋；
`ai dialogue` 走 CONVERSATION，連打兩次應該兩次都過。
兩條指令的用量會分開印。

> [!warning] 尚未執行期驗證
> 這一輪改動是在沒有 Godot 執行檔、也沒有 godot-ai session 的環境做的，
> 只做過靜態檢查。合併前要補：`project_run` → `ai` ×2 → `ai dialogue` ×2 → `logs_read`。



1. `ai_config.gd` ＋ `ai_config.example.json`（真檔在 `user://`，不進 repo）
2. `ai_service.gd`：HTTPRequest 池（3 個節點）、佇列、`timeout = 10.0`、`use_threads = true`
	- 速率限制：同 Agent 最短 30s、每遊戲日 20 次（§5）
	- 重試：4xx 不重試；網路錯誤／5xx 重試 1 次
	- 回傳 `{"ok": bool, "data": Dictionary, "error": String}`，呼叫端一律 `await`
3. `ai_schema.gd` 驗證骨架
4. `autoload_manage` 註冊 `AIService`
5. debug 主控台 `ai` 指令：手動打一次、印出往返內容（**金鑰遮蔽**）

**驗收**：`project_run` → 打 `ai` → `logs_read` 看到 OpenRouter 回的 JSON；
拔網路時 10s 內乾淨逾時、不卡畫面。

### Step 1 — 對話

1. `prompt_builder.gd` 的 dialogue 信封
2. **台詞來源介面** —— `conversation.gd` 只認「向某角色要下一句」，
	由角色自己決定要去問聊天框、問 `AIService`、還是（日後）等伺服器
3. `conversation.gd` 改非同步，並改由 Agent 決定結束：
	- 新增 `_pending` 狀態，等待時顯示「…」氣泡，**不阻塞** `_process()` 的距離檢查與中斷判定
	- 移除 `MAX_TURNS`，`REASON_TURN_LIMIT` 換成 `REASON_ENDED_BY_SPEAKER`
	- 收到 `end: true` → 說完那句就結束並發獎勵
	- 逾時／驗證失敗 → 說一句 `DialogueLines.closing()` 並結束（fallback 必須能終止）
	- `TOO_FAR` / `INTERRUPTED` 兩個原因與其行為維持不變
4. `character.gd` 加 `signal spoke(line)`
5. `chat_input.gd` 改為：玩家在對話中 → 文字成為玩家這一輪的台詞；否則維持 `say()`

> [!success] 對話輪次豁免速率限制 —— 介面已完成（2026-08-07）
> `MIN_INTERVAL_SEC = 30` 是為**行程重排**訂的，套到逐輪對話上會直接擋死。
> 依 2026-08-05 決定：**對話輪次完全豁免冷卻與每日配額**，行程重排照原規則。
>
> 已落地成 `AIService.Policy`，見上方「Step 0 增補」。
> 對話這邊只要記得帶 `Policy.CONVERSATION`：
>
> ```gdscript
> var result := await AIService.request(envelope, character_id, AIService.Policy.CONVERSATION)
> ```
>
> 成本上限仍未訂，等實跑過再說。

**驗收**：走到 Agent 旁按 E → 講出 LLM 產的台詞；聊天框打字 → Agent 針對內容回應；
關掉 `enabled` → 自動回到模板句，無錯誤。

### Step 2 — 任務池與仲裁器（**純重構，不接 LLM**）

完全照 [[行程佇列與任務仲裁]] 實作，改動全在 `agent.gd`。

> [!important] 這步刻意不含 LLM
> 這樣行為若有回歸，責任歸屬明確 —— 是重構寫錯，還是 LLM 給了爛任務，
> 兩者混在一起會查不出來。

**驗收**：`tasks` 指令印出池子與分數拆項 → Agent 行為與重構前**完全一致**
（同樣時間去同樣地點）→ `logs_read` 無錯誤。

### Step 3 — LLM 填行程

1. `prompt_builder.gd` 的 plan 信封
2. 觸發情境（§5.1 六個中的前四個）：遊戲日開始／需求跌破閾值／被搭話／動作失敗
3. LLM 回傳的 Task 過 `ai_schema.gd` → push 進池子
4. 池子守則：**上限 20**、同 `action + params.target` 去重（覆蓋非並存）、`expires_at` 到期清除
5. 搶佔：`schedule` 丟掉／`llm` 放回池子且 `retries += 1`／`reflex` 丟掉
6. 逾時 fallback：Agent 標記 `pending` 但**繼續做原本的事**，不僵在原地

**驗收**：把某項需求打到閾值以下觸發重排 → `tasks` 看到 `source = "llm"` 的新任務
→ Agent 真的改去該地點 → 關掉 AI 後退回純 schedule 行為。

## 動工前要處理的既有問題

> [!success] PlaceAnchors 座標已修好 —— 已實測驗證 2026-08-05
> 原本地圖改迷宮後 `farm` 錨點落在牆裡，Agent 每到 09:00 就 `push_warning("走不到 farm")`；
> 接 LLM 後會惡化成「產生走不到的任務 → 失敗 → 觸發重排 → 又失敗」的無窮迴圈。
>
> 跑起來用 `game_eval` 驗證（`nav.built=true`、`solid=177`）：
> 四個錨點 `home_001 (4,-2)` / `farm (-4,6)` / `restaurant (10,-2)` / `square (-5,4)`
> 全部落在 free cell，且從每個角色目前位置都有路徑
> （player→farm 28 點、agent→farm 24 點）。game log 無任何 warning。
>
> 唯二的 `1 pts` 是兩隻 Agent 對 `home_001` —— 經查是**它們本來就站在上面**
> （距離 0.9 / 2.0，都在 `ARRIVE_DISTANCE = 2.0` 內），
> 正是 `agent.gd:88` 註解講的「走不到」與「早就到了」無法區分那個已知情況，不是 bug。

- [x] ~~`Agent` 與 `Agent2` 都是 `schedule_template = "npc001"`~~ ——
  已改由 `npc_schedule.json` 的 `assignments` 逐隻指派（2026-08-07），
  `agent` → npc001、`agent2` → npc006。做法見 [[Character 基底與 Agent]]
- [ ] 兩隻仍然沒有 `persona_id`，也沒有 `character_name` 覆寫（顯示名就是 id）。
  接人格時一起處理

## 不在這一版

- **記憶系統**（§5.2：標籤＋關鍵字＋1 跳連結、每日反思摘要、單次最多 20 則）
  —— 卡在專案**完全沒有存檔機制**，記憶無處持久化。
  `character.gd` 的 `signal spoke` 這輪先埋好，是日後寫逐字稿的接點
- **交誼區 WebSocket 線** —— 伺服器技術棧尚未決定
- **Ollama provider** —— 換 `base_url` 即可，但本輪不實測
- `preconditions` 求值 —— 結構留欄位，v1 一律通過
- 白名單中除 `move_to` / `talk` / `sleep` 外的動作實作

## 待決

- [x] 對話生成粒度 —— **一律逐輪**，台詞由角色擁有者產生（見上）
- [ ] `response_format` 的 json_schema 在選定模型上到底支不支援（要實測）
- [ ] 逐輪之後每輪都有一次網路延遲，「…」氣泡的等待體感要實跑才知道能不能接受
- [x] `MIN_INTERVAL_SEC = 30` 擋死逐輪對話 —— **對話輪次豁免冷卻與配額**，
      行程重排照原規則（2026-08-05 決定，2026-08-07 實作為 `AIService.Policy`）
- [ ] **LLM 成本上限完全沒有防護**（拿掉硬上限、對話又豁免配額的直接後果）。
      要先實跑量出「一場對話平均幾輪」才有辦法訂。
      在那之前，跑 LLM 對話時留意 provider 後台的用量
- [ ] 軟壓力到底有沒有用 —— system prompt 叫模型「聊久了該收尾」，
      實際上模型會不會照做是未知數。若發現它永遠不收尾，就是回頭加硬上限的訊號
- [ ] 尚未對真正的 OpenRouter 打過請求（使用者還沒放金鑰）。
      TLS/DNS 與真實回應格式未驗證；HTTP 動詞、URL 組法、header、
      訊息切分、重試、速率限制都已用本機 stub 實測過
- [ ] 人格資料的欄位結構 —— `data/personas.json` 要放哪些欄位才夠組 system prompt
- [ ] 成本上限機制（§11 只列了標題，沒有設計）
- [ ] 記憶系統上線前，Agent 的對話逐字稿要不要先存記憶體就好
