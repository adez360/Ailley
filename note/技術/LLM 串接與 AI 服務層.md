---
tags:
  - agent
  - llm
  - 計畫
status: 進行中
updated: 2026-08-11
---

# LLM 串接與 AI 服務層

把 LLM 實際接進遊戲：同一套 client、同一組 JSON 信封、同一套驗證與 fallback，
同時驅動 Agent 的「講什麼」與「做什麼」。

這是「Agent 的 AI 呼叫跑在擁有者自己的電腦上」那條決策的具體化。
內容層切點見 [[talk 動作設計]]，任務結構見 [[行程佇列與任務仲裁]]，
角色狀態來源見 [[Character 基底與 Agent]]。

> [!note] 狀態
> **設計，尚未實作。** 現況是零 —— 全專案 game code 無任何 `HTTPRequest`、
> 無金鑰處理、無存檔機制。`addons/godot_ai/` 裡的 WebSocket 與 api_key 是
> **編輯器 MCP bridge，不是 runtime SDK**，不可挪用。

> [!success] 2026-08-11：架構問題已有團隊結論——出貨不走 Python 後端
> 三六零在組員討論裡明確否決「隨遊戲出貨 Python 後端」這個方向，理由：
> - 自架中繼伺服器早就被否決過（決策：「AI 呼叫跑在擁有者自己的電腦上、費用自己付」，
>   架中繼等於幫玩家代付、還多一台要維運的機器）
> - 出貨包 Python：三平台各打包、macOS 要簽章、Windows 會被防毒誤判、多幾十 MB、
>   每次發版要顧兩套 build，還多出「程式沒起來/port被佔/防火牆攔掉」這些新壞法，
>   而且 Godot 端照樣得寫 HTTP client 去打它——程式碼變多不變少
> - `scripts/ai/` 這 700 行（`ai_service.gd`/`ai_config.gd`/`ai_schema.gd`）已經寫完、
>   除過兩個真的難抓的 bug（見上方 Step 0），重寫成 Python 等於把這些學費丟掉
> - Python 真正的優勢（本機向量檢索、SSE 串流）現在都用不到，不值得為它們多開一個進程
> - **`base_url` 能指向任何 OpenAI 相容端點，程式一行不用改**——想用 Python 的人
>   自己在前面架一層、把網址改掉就跑起來了（Ollama 就是這樣接的）
>
> **結論：Python 後端是每個玩家自己的選擇，不是專案要不要出貨的架構決定。**
> 傾向的正式出貨方向是 **Godot（`HTTPRequest`）↔ Sidecar（`llama-server`）**，
> 不經過任何 Python 中間層——這條線正在確認中，核果已經在研究把原本規劃在
> Python 後端的邏輯（grammar 組建等）直接用 GDScript 寫一份試看看。
>
> **這對 `poc_village_sim`／`village_sim_client.gd` 的定位是什麼**：
> 三六零同時明講「可以繼續使用 python 開發，但是要提供一個 http 接口給 godot 端」——
> 也就是 `poc_village_sim` 繼續當 **R&D／驗證用途**（快速調校 prompt、grammar、
> 決策邏輯，方法論見下方「不記入本篇」的教訓），不是出貨架構的一部分。
> `village_sim_client.gd`／`village_ai` 指令完全符合這個要求，已經端到端驗證通過
> （headless 測試 + 編輯器實測 `village_ai aji` 三次 `200 OK`），繼續保留當驗證
> 工具沒問題，只是**不會是玩家實際玩到的那條路**。
>
> 動工前要做的事：跟核果對一下 GDScript 版 grammar/決策邏輯的進度，避免兩邊
> 各自重寫一份同樣的東西。

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
> 自架 WS 中繼幫玩家代打 LLM，會同時違反
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
> 少了它，那條防注入規則形同虛設 ——
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
> 不必額外做任何計費邏輯就滿足「API 費用由 Agent 擁有者負擔」。
> 整場一次生成則會讓其中一方付掉兩隻的費用。

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
> 與「每遊戲日最多 20 次 AI 請求」那條上限直接衝突，目前無防護。
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

## 進度斷點（2026-08-11）：`village_sim_client` 這條線做到哪、下一步是什麼

這是 `feature/godot-ai-transport` 分支這幾輪的完整進度記錄，方便之後接手／回頭查。

### 已經做到的（都經過 headless + 編輯器實測驗證）

1. **Transport 層**（`village_sim_client.gd` + `village_ai` 指令）——Godot 真的
   打得通 `poc_village_sim/server.py`／地端 llama-server，拿回合法決策 JSON
2. **讀真實狀態**（`village_ai_act` 指令）——用 `Character.get_state_snapshot()`
   ＋ `Agent.current_place` 組出真實 payload（不再是寫死的測試資料），透過
   `VillageSimLocale` 的有限地點對照表把 Godot 錨點名稱翻譯成 poc 中文地點
3. **動作真的被執行**——AI 決定 `move_to` 時，真的呼叫 `character.move_to()`，
   角色在畫面上真的走過去（headless 測試量到座標真的變動、`is_moving()` 為真）
4. **話真的被執行**——`output.speech` 非 null 時呼叫 `character.say()`，
   `Bubble.is_speaking()` 確認氣泡真的顯示出來
5. **視野真的被讀取**——`character.vision.get_visible_characters()` 抓真實
   視野內角色，透過 `VillageSimLocale.GODOT_NAME_TO_POC_ID`（目前只認得
   `agent`/`agent2` 兩隻demo角色）過濾成 poc id 塞進 `visible`

### 2026-08-11 續：已經做到「玩家靠近自動觸發」，範圍限定單一角色

抽出共用邏輯 `VillageSimDecision.decide_and_act()`（`scripts/ai/
village_sim_decision.gd`），debug 指令跟自動觸發共用同一份，不要各寫一份。
`agent.gd` 新增 `@export village_ai_enabled`（預設關閉，逐隻手動開）跟
`@export poc_character_id`，`_on_spotted()` 裡加一段：開關開著、看到的是
玩家、不在對話中，就自動打一次決策——不看認不認識，跟既有「陌生人才會
『！』」的邏輯是獨立的兩件事。

headless 驗證：玩家傳送到開了開關的 demo agent 旁邊，完全沒有下任何手動
指令，`AGENT_IS_MOVING=true`、`BUBBLE_IS_SPEAKING=true` 都自動成立，
`server.py` 的 access log 確認收到新的請求。

**這不是完整的決策迴圈，是一個範圍很小的自動化起點**：
- 只在玩家主動靠近時觸發，不是持續輪詢／固定間隔
- 只有手動開了 `village_ai_enabled` 的那隻 Agent 會觸發，其餘照舊跑
  `npc_schedule.json` 時刻表，完全不受影響
- Agent 對 Agent 互相觸發、時刻表以外的持續性決策迴圈，都還沒做——
  這才是本篇 Step 3 完整範圍要處理的東西，跟 `AIService` 的 `plan` envelope
  信封格式怎麼對齊，仍然沒有結論

暫停在這裡，之後接續開工前先讀這一段跟上面「已拍板」／「Step 0-3」對齊一次。

### 2026-08-11 續：實測抓到一個真的會 crash 的案例，加上防呆＋log 補強

編輯器實測時真的撞到一次：把 `Agent2` 的 `poc_character_id` 設成 `aji`，
但 `GODOT_NAME_TO_POC_ID` 表裡 `agent`（另一隻角色）也對應 `aji`，兩個不同
Godot 節點被設成同一個 poc 身分時，`Agent2` 看到 `agent`、視野清單翻譯出來
也是 `aji`，等於送出「我看到了我自己」，`poc_village_sim` 沒有自己對自己
的好感度紀錄，`server.py` 直接 500（`KeyError: 'aji'`）。已修：
`decide_and_act()` 組 `visible` 清單時，跳過 poc id 等於自己 `poc_character_id`
的條目。

同時發現自動觸發路徑完全沒有可見回饋（跑失敗跟跑成功但剛好沒事，使用者
分不出來），補了 `print()`（含 `reasoning` 欄位，之後判斷決策合不合理主要
看它）。

### 重要澄清：現在證明的是「管線通」，不是「決策內容對」

實測到這裡，`village_ai_enabled` 這條自動觸發路徑已經證明**機制可行**：
玩家靠近 → 自動觸發 → 讀真實 `get_state_snapshot()` → 翻譯地點/視野 →
打地端模型 → 執行動作/說話，全部真的跑通，不是紙上規劃。

但**決策內容本身目前是脫節的**，不能拿「角色動了、AI 回答合理」當作
「這個決策是對的」的證據：

- **AI 完全沒看到 Godot 角色的真實生理狀態**——`DecideRequest.physiology_override`
  這個欄位一直沒接，AI 決策依據的是 `poc_village_sim` 自己存的那份角色
  檔案（`characters/<id>.json`），跟這隻 Godot 角色的 `Stats.SPEC`（hunger/
  energy/social/fun/mood）完全無關、不同步
- `GODOT_NAME_TO_POC_ID` 目前是寫死的 2 條demo對照，不是真正的角色身分系統
- `character_id`／`poc_character_id` 誰對應誰純靠操作者手動保證，程式不驗證

**下一步（尚未開始）：接上 `physiology_override`**，把 Godot 的
`get_state_snapshot()` 真的餵給 AI 當決策依據。卡點：兩邊生理模型維度
不一樣（Godot 5 維 hunger/energy/social/fun/mood，poc_village_sim 是
hunger/thirst/stamina/boredom/health+money 這套），不是換個欄位名字就好，
要先決定怎麼對應（甚至要不要對應——兩套本來就是為不同情境設計的）。

### `physiology_override` 欄位對照表（Godot `Stats.SPEC` ↔ poc_village_sim `physiology`）

決定不改 `poc_village_sim` 的資料方向（改動範圍會牽動這幾天所有驗證過的
門檻邏輯跟 prompt 樣板，風險/工作量都太大，而且之後真正出貨的 GDScript
版本不會沿用 poc 這套資料模型，對齊工作可能是白做的），改成**在 Godot 端
寫轉換**，只送對得上的欄位，其餘讓 `physiology_override` 的淺層合併沿用
poc 角色檔案原本的值：

| Godot `Stats.SPEC` | poc_village_sim `physiology` | 換算 |
| --- | --- | --- |
| `hunger`（100=飽→0=餓） | `hunger`（0=飽→100=餓） | **方向相反**：`poc_hunger = 100 - godot_hunger` |
| `energy`（100=飽滿→0=沒力） | `stamina`（同方向） | 直接映射，不用轉 |
| `fun`（100=不無聊→0=無聊） | `boredom`（方向相反） | **方向相反**：`poc_boredom = 100 - godot_fun` |
| `social` | 無對應欄位 | poc 沒有獨立追蹤社交需求，不送 |
| `mood` | 無對應欄位 | poc 的「情緒」是 AI 自己宣告的 `emotion`，不是 physiology 數值，不送 |
| （無） | `thirst`／`health`／`money` | Godot `Stats.SPEC` 沒有這三項的資料來源，不送，沿用 poc 預設值 |

> [!warning] 給之後寫正式 GDScript 版本的人（可能是核果，也可能是我自己）
> 如果那份重寫**照抄了 poc_village_sim 已驗證過的門檻邏輯**（`characters.py`
> 的 `_tier_adjective`、`if hunger >= 90` 這類具體數字），**移植的當下方向
> 要反過來翻，不能把數字原封不動複製過去**——poc 的 `hunger >= 90`「快撐
> 不住」，翻成 Godot 自己的方向要變成 `hunger <= 10` 才是同一個意思。
> 這是移植當下要抓對的一次性正確性問題，不是要求你之後永遠記得「這裡是
> 反的」——寫完的 GDScript 版本應該要是自洽的，全部用 Godot 自己的方向，
> 不需要在執行時做任何轉換。真的要重寫時回頭讀這份對照表當檢查清單。

### 2026-08-11 續：已實作，`physiology_override` 接上了

`VillageSimDecision._build_physiology_override()` 照上面的對照表換算，
每次呼叫都從 `character.get_state_snapshot()` 抓最新的即時 `Stats.SPEC`
數值（不是一次性快照，Stats 元件本來就持續在跑 drift 模擬），塞進
`physiology_override` 送給 `server.py`。headless 驗證：手動核對三個欄位
換算結果，跟公式手算的期望值完全一致，`social`/`mood` 正確沒有送出去，
`server.py` 接受這個 payload 正確回應。

**現在跟前面那段「證明的是管線通，不是決策內容對」的落差縮小了一塊**——
AI 決策依據的生理狀態，至少 `hunger`/`stamina`/`boredom` 三項已經是這隻
Godot 角色真實累積出來的數值，不再是完全脫節的 poc 自己那份存檔。
`thirst`/`health`/`money`（沒有 Godot 資料來源）跟 `social`/`mood`
（沒有 poc 對應欄位）這幾項還是沿用 poc 的預設值，這塊落差還在，
沒有辦法完全消除——除非兩邊的資料模型本身先對齊，而那個決策還沒做。

### 2026-08-11 續：實測發現延遲對即時互動來說很明顯，記下體感層面的解法（尚未實作）

編輯器實測 `village_ai_enabled` 自動觸發：玩家靠近到角色真的有反應（動作/
說話），中間大概 2.5-4 秒（跟 headless 測試量到的 `elapsed_sec` 一致，
時間主要花在 llama-server 的 grammar 約束生成本身，不是網路或 Godot 端）。
**這個延遲對「玩家靠近、期待角色即時反應」這種互動模式來說很明顯，體感
上會覺得卡**——玩家靠近之後畫面上完全沒有任何回饋，3 秒後突然講話/移動。

這不是意外——本篇前面跟更早的專案啟動文件都提過同樣的擔心：「逐輪之後
每輪都有一次網路延遲，『…』氣泡的等待體感要實跑才知道能不能接受」，
更早的模組 D 前端規劃甚至寫了「推理時的『內心思考中』視覺雜訊動畫，
完美隱藏硬體延遲」——原始設計本來就沒有預期「即時無感」，是打算靠視覺
回饋讓等待感覺合理，不是要把延遲真的消除。

**體感層面的解法（記下想法，尚未實作，等之後要動再回來看）**：
`_trigger_village_ai()` 觸發的當下（送出請求之前），先給一個立即的視覺
回饋——氣泡先顯示「…」思考中，或角色停下腳步做個「在想事情」的小動作，
等 `decide_and_act()` 真的回來才把「…」換成真正的台詞/執行動作。把死寂的
2.5-4 秒變成「看得出來它在反應」的等待，不用真的縮短延遲，體感會差很多。

**縮短延遲本身的槓桿（另一個方向，同樣尚未實作）**：`REASONING_INSTRUCTION`
的 100 字上限是延遲/品質的直接槓桿（見主線 POC 紀錄的字數上限測試），
往下砍會更快但決策品質會掉；其他槓桿是模型量化等級、llama-server 的
`--parallel` 設定，這些會影響全部呼叫、不只這個功能，改動範圍更大。

### 2026-08-12：拆分 decide()/apply()，並記下一個待對齊的協作規範落差

`VillageSimDecision.decide_and_act()` 拆成 `decide()`（純問答，不執行任何
動作）＋ `apply()`（把結果套用到角色身上），呼叫端（`agent.gd`／
`debug_console.gd`）自己明確呼叫兩步，不再是一次 black-box 呼叫。理由：
對齊組長發的協作規範裡「向下呼叫、向上發信號」的精神，副作用要留在角色
自己的程式碼路徑才看得到、才好追蹤。headless 驗證：`decide()` 單獨呼叫後
角色沒有任何動作，呼叫 `apply()` 才真的移動，行為跟拆分前一致。

> [!warning] 待對齊：組長發的資料夾結構規範，跟現有 `CLAUDE.md` 不一樣
> 組長發了一份協作規範文件，資料夾結構建議是**按遊戲物件模組**分類
> （`entities/player/` 場景/腳本/圖片全部放一起），跟現有 `Ailley/CLAUDE.md`
> 記載的**按系統層**分類（`scripts/ai/`／`scripts/character/`／
> `scripts/dialogue/`...）是兩套不同邏輯，不是小差異。
>
> 目前沒有動任何現有檔案去符合新規範——這個決定牽動全隊檔案怎麼放，
> 影響範圍大，不該片面判斷。使用者原話：「規範文件是組長發的，主要是
> Godot 端為了讓每個 PR 跟 issue 避免重工或找不到檔案使用的，如果我們
> 製作 Godot 文件，可能要配合」——代表這份新規範至少對**新產出的 Godot
> 文件/檔案**適用，但現有結構要不要整個重排、`CLAUDE.md` 要不要一併更新，
> 都還沒有結論。之後如果要新增 AI 相關的 Godot 檔案（例如把
> `village_sim_client.gd`／`village_sim_decision.gd` 這類正式收進主線），
> 先跟組長確認這份新規範的實際適用範圍再動作。

### 2026-08-12 續：已把 main 合併進來，分支跟上團隊進度

`git merge origin/main`，`agent.gd` 一處衝突：main 的聽覺感測在 `_on_spotted()`
後面加了 `_on_noise_heard()`，跟這條分支加的 `_trigger_village_ai()` 插在
同一個位置，兩個都是新函式、沒有邏輯重疊，直接兩個都留下。其餘檔案（`character.gd`／
`player.gd`／`main.tscn`／`project.godot`／背包與狀態面板等 UI）都是 main
單方面新增，git 自動合併沒有動到這條分支的東西。

合併進來的內容跟這條分支要做的事無關：聽覺感測（`make_noise()`／F 鍵）、
背包/狀態/設定面板、熱鍵列偷焦點的修正。headless 重新匯入＋開機驗證都過，
無 script error。
