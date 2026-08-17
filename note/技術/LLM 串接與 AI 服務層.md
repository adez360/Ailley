---
tags:
  - agent
  - llm
  - 計畫
status: 進行中
updated: 2026-08-17
---

# LLM 串接與 AI 服務層

把 LLM 實際接進遊戲：同一套 client、同一組 JSON 信封、同一套驗證與 fallback，
同時驅動 Agent 的「講什麼」與「做什麼」。

這是「Agent 的 AI 呼叫跑在擁有者自己的電腦上」那條決策的具體化。
內容層切點見 [[talk 動作設計]]，任務結構見 [[行程佇列與任務仲裁]]，
角色狀態來源見 [[Character 基底與 Agent]]。

## 現況：只有一條線

LLM 一律走 `AIService`（`scripts/ai/ai_service.gd`）→ Godot ↔ Sidecar
（`llama-server`），不經任何 Python 中間層。`agent.gd` 不直接呼叫
`AIService`，透過 `DecisionProvider`（`LocalLLMProvider`／`RemoteLLMProvider`）
呼叫。Step 0-4 全部完成：底層、`conversation.gd` 非同步對話（issue #82）、
`agent.gd` 任務池＋仲裁器（issue #71）、決策迴圈（issue #88，
`llm_decision_enabled` 開關）、DecisionProvider 介面與雲端驗證失敗重試
（issue #155／#152）。細節見下方「正式線實作順序」。

> [!success] 架構決定：出貨不走 Python 後端
> 三六零否決「隨遊戲出貨 Python 後端」：自架中繼伺服器已被否決過（AI 呼叫要跑在
> 擁有者自己機器上、費用自己付）；出貨包 Python 要三平台各打包、簽章、防毒誤判，
> Godot 端照樣得寫 HTTP client 去打它；`base_url` 能指向任何 OpenAI 相容端點，
> 程式一行不用改，想用 Python 的人自己架一層換網址就好。
>
> **結論：Python 後端是玩家自己的選擇，不是專案出貨的架構決定。** 正式方向是
> **Godot（`HTTPRequest`）↔ Sidecar（`llama-server`）**，不經 Python 中間層。

> [!warning] 2026-08-12：GDScript 決策邏輯重寫由使用者負責
> Step 0-3（底層、對話、任務池仲裁器、決策迴圈）都已完成，**身分對照系統
> 仍是缺口**——`llm_decision_enabled` 開啟後 Agent 會自己問 LLM 該做什麼，
> 但把 `poc_village_sim` 驗證過的那套決策邏輯（門檻判斷、人格影響）搬進
> GDScript 的 prompt/schema 設計，是**使用者自己要寫的東西**，
> 不是這幾個 issue 的範圍。
>
> 身分對照的缺口在 Character 基底層：issue #69（`character_id`／`character_name`
> 固定指派）補的就是這塊，正式線的決策迴圈用得上。

## 已拍板

- 範圍：**底層 ＋ 行程 ＋ 對話**，三塊一起做
- Provider 是**一組具名端點**，可以同時併用（見下方「多 provider」）。開發期實測過
  本機 llama-server 與 OpenRouter 兩條
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

- `timeout: float`（預設 0 ＝ 不逾時）→ 設 `10.0`
- `use_threads: bool`（預設 false）→ 開啟，否則 TLS 握手會卡主執行緒掉幀
- `signal request_completed(result, response_code, headers, body: PackedByteArray)`
- **一個節點同時只能跑一個請求** → 需要節點池＋佇列，這是 `AIService` autoload 存在的主要理由

## 檔案配置

### `scripts/ai/`（正式線）

| 檔案 | 職責 |
| --- | --- |
| `ai_config.gd` | 讀 `user://ai_config.json`。金鑰**永不進 log、永不進錯誤訊息**。檔案不存在 → `enabled = false`，全系統走 fallback。解析出一組具名 `providers` 與全域的速率限制三個旋鈕 |
| `ai_service.gd` | **正式線唯一碰網路的地方**。autoload。節點池、佇列、逾時、速率限制、重試 |
| `ai_schema.gd` | 回應驗證：`JSON.parse_string` → null 檢查 → 逐欄位型別檢查 → `action` 白名單 |
| `prompt_builder.gd` | 由 Character 組出請求信封。dialogue 信封已實作，plan 還沒 |

`data/personas.json` — 人格資料，Agent 以 `@export var persona_id` 指定（尚未實作）。

> [!note] `user://` 在 repo 之外
> Linux 下 `user://` ＝ `~/.local/share/godot/app_userdata/ailley4.3/`。
> 金鑰放這裡連 `.gitignore` 都不需要，天然滿足「API key 存 `user://` 不進版控」。

### 多 provider

`ai_config.json` 裝的是一組具名 provider，可以同時併用（例如 `local` 打本機
llama-server、`openrouter` 打雲端），每個各自有 `base_url` / `api_key` /
`model` / `timeout`：

```json
{
	"enabled": true,
	"default_provider": "local",
	"providers": {
		"local":      {"base_url": "http://127.0.0.1:8080/v1", "api_key": "", "model": "qwen2.5-7b-instruct", "timeout": 10.0, "format_guaranteed": true},
		"openrouter": {"base_url": "https://openrouter.ai/api/v1", "api_key": "sk-or-v1-…", "model": "openai/gpt-4o-mini", "timeout": 10.0}
	},
	"min_interval_sec": 30.0
}
```

`min_interval_sec` / `max_calls_per_game_day` / `dialogue_exempt` 維持全域，
**不逐 provider**：那是角色的成本控管，算在 `requester_id` 上，同一隻角色不管
打本地還雲端用的是同一份額度。

「誰該用哪個 provider」不在 `AIConfig` 裡，是呼叫端用
`AIService.request()` 的 `provider_name` 參數帶進來的。目前唯一會指名的呼叫端
是 debug 主控台的 `ai @<provider>`。

> [!note] 「每個角色固定用哪個 provider」還沒有實作，是刻意的
> 方向已經想清楚：那應該是**角色自己的屬性**，不是一張「節點名 → provider」的
> 查表——角色未來是動態生成丟進世界的（#73），查表的前提「固定節點名」不成立。
>
> 但**掛在哪裡要等真正的讀取端出現才決定**。會讀它的是一條走 `AIService` 的
> Agent 決策迴圈，那個還沒實作（見上面「現況」）。在那之前先加一個
> `@export`，只會在 Inspector 長出一個填了沒作用的開關，而且等真的要接的時候
> 多半發現該掛的是生成設定或 persona 資料，不是每隻 Agent 一個欄位。

> [!important] 一個 provider 壞掉不該連累其他的
> `enabled` 只回答「設定檔結構完整、至少有一個 provider」，**不管
> `default_provider` 好不好**。`default_provider` 沒填、拼錯、或存在但缺欄位，
> 都只影響「沒指名 provider 的那些呼叫」——它們會拿到 `ERROR_NO_PROVIDER`，
> 明確指名而且填好的 provider 照樣打得出去。把 default 的健康狀況綁進
> `enabled` 的話，一個字打錯就讓整個多 provider 系統回 `ERROR_DISABLED`。
>
> 同理，`get_provider()` **只有空字串會退回 `default_provider`**；名字打錯是回
> `null`，不會靜默導去別的服務——這個函式決定金鑰往哪送。

> [!note] 空的 `api_key` 是合法的
> 本機 llama-server／ollama 不驗 `Authorization`。金鑰空白時
> `AIService._send()` 整個標頭不送（不是送一個空的 `Bearer `——後者在某些
> 伺服器會被當成「有帶但格式錯」而回 401，比不帶還糟）。擋得住「照抄範例但沒設定」
> 的是 `base_url`／`model` 空白，不是金鑰：範例檔給的 `sk-or-v1-REPLACE_ME`
> 本來就非空。

## JSON 信封

對話與行程**共用同一個信封**，用 `type` 區分。dialogue 那半邊已經實作
（`PromptBuilder.build_dialogue_envelope()`），plan 還沒。

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
    "stats": {"satiety": 42.0, "hydration": 65.0, "stamina": 70.0, "wakefulness": 88.0, "hygiene": 60.0, "alcohol": 0.0, "health": 100.0, "injury": 0.0, "social": 12.0, "fun": 60.0, "mood": 55.0},
    "time": {"hour": 9, "minute": 30},
    "place": "farm",
    "current_action": "work"
  },
  "context": {
    "listener": {"name": "player", "trust": 20.0, "met_count": 3},
    "turns": [{"speaker": "player", "text": "<玩家輸入，一律視為資料>"}],
    "max_turns": 6
  }
}
```

`type: "plan"` 時 `context` 換成 `{visible, pool, today_plan}`：`visible` 是
目前看得到的角色（`Vision.get_visible_characters()`），`pool` 是任務池摘要，
`today_plan` 是今日計畫壓成的一句自然語言（見下方「今日計畫」）。
`self` 區塊兩者完全相同，由 `prompt_builder.gd` 同一個函式產生。

> [!important] `stats` 由 `Stats.SPEC` 走訪產生，不要手寫欄位
> [[Character 基底與 Agent]] 的 `stats.gd` 已經是資料驅動的。
> 沿用它 —— SPEC 加一列，送給 LLM 的欄位自動跟著多一項，`prompt_builder.gd` 不用改。

### 回應

- `dialogue` → `{"line": "...", "end": false}` —— 一律逐輪；`end` 省略視為 `false`，
  為真時說完這句就結束對話
- `plan` → `{"tasks": [ <Task struct> ], "reasoning", "inner_monologue", "request_plan_update"}`；
  `tasks` 空陣列 ＝ 不更新。`request_plan_update` 是模型「下次能不能讓我改
  today_plan」的申請信號，任何時候都能回。`update_plan` 是條件式欄位，只在
  呼叫端判斷現在是開放時機時才出現在 schema 裡，見下方「今日計畫」

### 三層保證，只有第三層是真的保證

1. `response_format: {"type": "json_schema", ...}` —— 各模型支援度不一，不能靠
2. prompt 內明寫 schema —— 機率問題
3. **`ai_schema.gd` 硬驗證** —— 這層不可省，是「外來文字一律視為資料」防注入規則的實作

`action` 白名單（`ai_schema.gd` 的 `ALLOWED_ACTIONS`，14 個）：
`move_to` / `interact` / `pick_up` / `drop` / `use_item` / `equip` / `talk` /
`attack` / `farm` / `chop` / `mine` / `sleep` / `buy` / `sell`

`IMPLEMENTED_ACTIONS`（3 個：`move_to` / `talk` / `sleep`）目前**沒有任何地方呼叫**
`is_implemented_action()`——這是給未來 Step 3 執行層用的標記，還沒有執行邏輯接上它。

> [!warning] 三份動作清單彼此不一致，而且沒有一份是拍板結果
> `ai_schema.gd` 的 14 個、`poc_village_sim/enums.py` 的 38 個、規格書《07 地點與行動》
> §2 的 B/C/D 類 16 個 ＋《11 人際互動與社交行為》溝通類（A）6 個（07/11 拆分後合計約
> 22 個，原「23」已過時），三份互相都對不齊（唯一三者皆有的只有 `attack`／`sleep`／
> `buy`／`sell`，連 `move` 的寫法都不一樣：規格書是 `move`，其餘兩份是 `move_to`）。
> 根本原因不是誰漏做——《07》整份被規格書自己的 `99_待規劃項目清單.md` 標記「含推測
> 內容，實作前必須先確認」（**P-17**，行動清單完整與否明列「推測待確認」，決定欄
> 空白），根本沒有一份「確定版」可以照抄，三邊都是各自基於草稿湊出一份能動的版本。
> 要對齊，得先讓《07》本身拍板，不是三份互相校對。

## 對話生成粒度：一律逐輪

> [!success] 已定案 —— 每個角色的台詞由「該角色的擁有者」產生
> 多人模式下對話的兩隻 Agent 屬於**不同玩家**，LLM 各自跑在擁有者的 client 上，
> 一次生成整場等於某一台 client 幫別人的 Agent 寫台詞，它既沒有對方的人格與
> 記憶，也無權這麼做。

> [!important] 逐輪讓成本模型自然成立
> 6 輪對話雙方各付 3 輪，帳單自動落在正確的人頭上，不必額外做計費邏輯。
> 單機也走同一條路：兩隻 Agent 技術上可以批次，但那會長成「本機批次、線上逐輪」
> 兩套實作，正是 [[行程佇列與任務仲裁]] 警告過的「不要保留兩套資料再合併」。

## 對話由 Agent 自己決定何時結束

> [!success] 已定案 —— 拿掉 `MAX_TURNS`，改由 Agent 判斷
> 原本「講滿 6 輪就散」不是人類行為，是計時器。改成每一輪的回傳多一個
> `end` 欄位，由說話的一方自己決定要不要收尾：`{"line": "那我先去忙了，改天聊", "end": true}`。
> `end` 省略視為 `false`。收尾語就是它自己那句話，`DialogueLines.closing()`
> 不再參與正常流程，只留給 fallback。
>
> **正常結束 ＝ 有人決定結束**（`ENDED_BY_SPEAKER`），`TOO_FAR` / `INTERRUPTED`
> 維持原樣仍是「沒好好講完」——這條原則跟 [[talk 動作設計]] 原本的
> `TURN_LIMIT` 描述不同，實作時要回頭改那份筆記。

### 界線：軟壓力為主，工程安全閥兜底（issue #178 已收斂範圍）

不設「設計上」的輪數硬上限，改用**軟壓力**：payload 帶 `turns_so_far`，system prompt
告訴模型「聊得越久越該收尾」。但兩隻 Agent 都禮貌性不收尾時，`conversation.gd`
的 `SAFETY_MAX_TURNS`（工程安全閥，跟上面的設計軟壓力是兩回事，同時也是無觀眾
世界的 LLM 呼叫成本閘門，issue #178）會強制截斷，值訂為 **10**。10 是三份獨立
證據（實測、poc_village_sim 導演模式 B、poc_village_sim 逐 tick 對話追蹤）的
保守交集值，不是精算出來的：本機小模型多輪對話品質實測 6 輪起始退化、
10 輪偶爾明顯退化（見下方「已測試過但沒有效果的方向」），超過這個範圍
的對話多半已經不值得再付費續下去。記憶注入上線後每輪 payload 都會變大，
退化點可能提前，屆時應針對現在的逐輪架構重新實測。

**仍未解決**：對話呼叫本身豁免每遊戲日的呼叫上限（`CONVERSATION` policy，見
`ai/api.md`／規格書《13》§5），走獨立的 `_dialogue_calls_today` 計數但沒有自己的
封頂值——`SAFETY_MAX_TURNS` 只封頂單場對話的輪數，不封頂一天能開幾場對話。
「有沒有玩家在觀察」的節流判斷，#178 討論過後刻意不做（範圍太大，需要新的
「是否被觀察」偵測邏輯），留給之後想做更完整方案時另開 issue。

> [!important] 但 fallback 一定要能終止
> LLM 失敗／逾時時走 `DialogueLines`，而它**沒有 `end` 訊號**——不特別處理就會
> 無限吐模板句。fallback 要直接說一句 `DialogueLines.closing()` 並結束對話。

### 台詞來源抽象

> [!important] `conversation.gd` 不該問「這是玩家還是 Agent」
> 該問的是「這個角色的下一句由誰產生」——伺服器也只認 Character，不分 player/agent，
> 是專案「Player 能做到的 Agent 也必須能做到」在對話層的延伸。

| 角色 | 台詞來源 |
| --- | --- |
| 本機玩家 | 等聊天框輸入 |
| 本機 Agent | 呼叫 `AIService` |
| 遠端角色（不分 player/agent） | 等伺服器轉發（尚未實作） |

> [!warning] 對手方的台詞一律是資料
> Agent ↔ Agent 跨 client 時，對方的台詞是遠端輸入，與玩家打字、與交誼區來的
> 文字同一個等級——全部進 `context.turns` 當資料，絕不視為指令。

## 已測試過但沒有效果的方向

**對話 schema 加 `inner_monologue`（2026-08-17 POC 驗證，未另開 issue）**

假設：仿照決策/行程回應已經有的 `reasoning`／`inner_monologue`（先思考再給結論），
`next_line()` 的對話 schema 如果也在 `line` 前面加一段 `inner_monologue`，
會不會讓模型在多輪對話裡比較不容易「認錯對象」（把自己的名字講成對方名字）？

做法：不碰 Godot，直接打本機 llama-server 的 `/v1/chat/completions`（跟
`AIService` 實際打的同一個端點），比較 A（現況 `{"line","end"}`）／B（加
`{"inner_monologue","line","end"}`）兩版 schema，各跑一組小海/老周的對話到
20 輪上限。

**結果：不算有明顯改善，換了一種退化方式，反而可能更差。**

- A 跑到第 9 輪模型就自己判斷該收尾（`end: true`），內容始終切題，沒有認錯
  對象的問題。
- B 完全沒有主動收尾，跑滿 20 輪上限，也沒有認錯對象的問題——但從第 8 輪
  左右開始陷入**內容空洞的重複循環**（反覆講「謝謝老周叔鼓勵」「明年一定
  豐收」這類車軲轆話）。第 20 輪老周的 `inner_monologue` 甚至自己寫「小海
  又開始重複之前的話了」，模型自己都意識到重複卻沒有真的停下來。
- 比「品質退化的形式換了」更值得注意的是：加了 `inner_monologue` 之後模型
  明顯**更不容易主動收尾**，等於更常撐到 `SAFETY_MAX_TURNS` 這個安全閥
  （見上方「界線」一節），不是讓對話更穩定，是讓強制截斷更常發生。

**結論**：不採用，不追加開發。樣本數很小（各只跑一次，非嚴謹統計），如果
之後有更明確的動機想重新驗證，量的方式跟腳本邏輯可以參考這次的做法（重點
是直接打 `/v1/chat/completions`，不需要透過 Godot 才能測 dialogue schema
的改動效果）。

## 今日計畫（today_plan，issue #89，《10》§5.4）

**定位**：「想做的事」，不是排定的行程——引擎不強制執行，只當 prompt
context 用，跟 `agent.gd` 的 `_tasks`（引擎真的會執行的排程單位）是不同
語意的東西。

**資料形狀**：`Agent._today_plan`，`Array[Dictionary]`，每筆
`{id, text, is_done}`。欄位對齊 `database/schemas/NPCDailyPlanSchema.gd`
的 `npc_daily_plan` 表（`plan_id`/`text`/`is_done`）——存檔（#21～#23）
還沒接上這張表，先用同樣的形狀存在記憶體，之後接上不用改欄位名。`id` 是
`agent.gd` 自己配發的本機序號，跟資料庫的 `plan_id`（真的落地才有意義）
是兩回事。

**輸入端**：一律注入，壓成一句自然語言（`PromptBuilder._today_plan_sentence()`），
不是原始欄位列表。

**輸出端（`update_plan`）**：條件式欄位（《12》§2.4）——只在
`AISchema.plan_response_schema(allow_update_plan)` 收到 `true` 時才出現在
schema 跟系統提示裡，其餘時候模型的 response_format 契約裡文法上就不存在
這個選項。回應語意是**整份取代**，不是逐筆增刪改：四個開放時機都是「重寫」，
不用讓模型追蹤既有項目的 id 才能局部編輯。

四個開放時機，目前接了三個：

| # | 時機 | 觸發點 | 狀態 |
| --- | --- | --- | --- |
| 1 | 意圖全數完成 | `Agent._today_plan_needs_new_goal()`——空的或全部 `is_done` 都算，世界開場（`_today_plan` 必為空）是這個狀況的degenerate case | ✅（見下方限制） |
| 2 | 睡覺反思 | `_reevaluate()` 偵測「這次進來時 `current_state == "sleep"`，選完任務後不是了」的轉換瞬間 | ✅ |
| 3 | AI 主動申請 | 模型在任何一次回應裡回 `"request_plan_update": true`，記在 `Agent._plan_update_requested`，下一次不管哪個理由觸發 `_request_next_decision()` 都會兌現、用掉 | ✅ |
| 4 | 意圖被事實推翻 | 角色實際執行動作時發現前提不成立（《10》§5.3：沒錢買東西、想找人講話但對方在忙這類）——目前只有 `talk`（issue #90）有執行層、有明確失敗原因碼可以掛，其餘動作（`buy`/`eat`/`work`…）還沒有執行層，無從偵測「失敗」 | ⏳ 待 #90 merge 後補 |

> [!warning] `is_done` 是模型自我回報，不是引擎驗證過的事實
> 唯一會寫 `is_done` 的地方是 `_apply_today_plan()`，也就是模型自己在
> `update_plan` 回應裡講「這項完成了」——跟《10》§5.4 給的範例（「你今天原本
> 打算：採藥草（**已完成**）」）是同一種語氣，角色自己回顧敘述，不是引擎拿
> 「這筆計畫項目」去對照「哪個 Task 真的執行完成」逐筆核實。目前也沒有這種
> 對照機制：`_tasks`（引擎真的執行的排程）跟 `_today_plan`（自我回報的意圖）
> 之間完全沒有連結，任務池選中並跑完一筆 Task，不會自動把 today_plan 對應
> 那項標成完成。
>
> 這代表「意圖全數完成」這個開放時機，實務上依賴模型自己願不願意、記不記得
> 在某次 `update_plan` 裡把舊項目標完成——不是穩固的引擎事實。要做成真的
> 引擎驗證（幫每筆計畫項目建立可比對身分、Task 完成時自動回寫），是比這次
> 大得多的工程，不在 #89 這輪範圍內。

## 正式線實作順序（Step 0-4 全部完成）

### Step 0 — 底層 ✅ 完成

`ai_config.gd`／`ai_service.gd`／`ai_schema.gd`／`data/ai_config.example.json`，
autoload 已註冊，主控台加了 `ai` 指令。

- `request(envelope, requester_id, policy)`：`enum Policy { SCHEDULED, CONVERSATION }`，
  `CONVERSATION` 跳過冷卻與每日配額但照樣計數（走獨立的 `_dialogue_calls_today`），
  預設 `SCHEDULED`——忘了指定的呼叫端落在保守那邊，不會意外拿到無限額度
- 速率限制三個旋鈕搬進 `user://ai_config.json`（皆可設 0＝不限），預設值與規格數值
  見 `ai/api.md`（`AIConfig`）／規格書《13》§5
- 回傳一律 `{"ok": bool, "data": Dictionary, "error": String}`，呼叫端一律 `await`
- 4xx 不重試；網路錯誤／5xx 重試 1 次

> [!warning] 兩個容易忽略的網路層 bug（教訓：只用 happy path 的 stub 測網路層等於沒測）
> **`await` 死鎖**：URL 格式錯時失敗發生在呼叫端跑到 `await` 之前，訊號永遠等不到——
> 修法是 `_finish()` 改 `emit.call_deferred()`。
> **幽靈回應**：請求中途失敗但逾時計時器已起跑，`timeout` 秒後補送一個
> `request_completed` 給沒有工作的節點——修法是失敗時先 `cancel_request()`。

**尚未執行期驗證**：這些是在沒有 Godot 執行檔的環境做的，只做過靜態檢查，
合併前要補：`project_run` → `ai` ×2 → `ai dialogue` ×2 → `logs_read`。

### Step 1 — 對話 ✅ 完成

`PromptBuilder.build_dialogue_envelope()` 組信封，`Agent.next_line()` 打
`AIService`，`conversation.gd` 改成非同步、等台詞時掛「…」氣泡、拿不到就退回
`DialogueLines`。`MAX_TURNS` 換成 `SAFETY_MAX_TURNS`（純保險，收尾由 `end` 欄位決定），
`character.gd` 有 `signal spoke`，玩家在對話中打的字也送得進上下文。

開場白仍然是模板句：對話由 `DialogueLines.opening()` 起頭，第二輪才進 LLM。

### Step 2 — 任務池與仲裁器 ✅ 完成

照 [[行程佇列與任務仲裁]] 實作，改動全在 `agent.gd`，刻意不含 LLM。
`tasks` 指令印得出池子與分數拆項。

### Step 3 — LLM 填行程 ✅ 完成（issue #88）

1. `prompt_builder.gd` 的 plan 信封（`build_plan_envelope()`），沿用
   `_self_block()`，`context` 帶 `visible`（`Vision.get_visible_characters()`）
   跟 `pool`（目前任務池摘要）
2. 觸發情境：「目前任務做滿引擎套用過下限的 `duration`」（事件驅動，對應
   《10》§5.1）、世界開場第一次、剛睡醒、模型申請下次改 today_plan（#89，
   見上方「今日計畫」）都接了；需求跌破閾值／被搭話／動作失敗／突發事件／
   進出交誼區還沒接，見 [[行程佇列與任務仲裁]] 的「什麼時候會請 LLM 重排」
3. LLM 回傳的 Task 過 `ai_schema.gd::validate_tasks()` → `agent.gd::_push_llm_tasks()`
   push 進池子
4. 池子守則：上限 `LLM_TASK_POOL_CAP`（20，只算 llm 來源）、單次回應另外有
   `AISchema.MAX_TASKS_PER_RESPONSE`（5）、同 `action + params.target` 去重、
   `expires_at` 到期清除沿用既有的 `_is_expired()`（issue #92）
5. 搶佔／`retries` 遞增：**還沒接**——這一版被搶佔的 llm 任務直接留在池子裡
   或被仲裁器自然汰換，`retries` 欄位存在但沒有任何呼叫端遞增它
6. 逾時 fallback：`AIService` 層級失敗（AI 停用、逾時、連線失敗、額度）不重試，
   `_request_next_decision()` 直接靜默放棄，`_awaiting_decision` 重置，Agent 靠
   任務池 fallback（schedule 任務或上一輪還沒被選中的 llm 任務）頂著，不是標記
   `pending`；內容驗證失敗（拿到回應但格式不合）走 Step 4 的重試

### Step 4 — DecisionProvider 介面與雲端驗證失敗重試 ✅ 完成（issue #155／#152）

`agent.gd` 不再直接呼叫 `AIService`，改透過 `DecisionProvider`（`scripts/ai/
decision_provider.gd`）：`LocalLLMProvider` 打 AIConfig 的 `"local"`
provider，`RemoteLLMProvider` 建構時帶入要打哪個 provider 名字（對應《06》
`model_name`），兩者都是 `AIService.request()` 的薄包裝，行為不變。

玩家的 `ai_config.json` 不保證真的有一個可用的 `"local"`——可能只設了
`default_provider`、取了別的名字，或有這個項目但 `base_url`／`model` 沒填齊。
`LocalLLMProvider._init()` 因此先用 `AIConfig.has_valid_provider("local")`
解析一次：不成立就 `push_warning` 並改傳空字串，交給 `default_provider`。
硬傳 `"local"` 的話這些情況一律是 `ERROR_NO_PROVIDER`，角色決策整個安靜啞掉。
解析放在 `_init()` 而不是 `decide()`：設定在一場遊戲內不會變，放 `decide()`
的話設定真的缺 `"local"` 時每次決策都洗一行警告。

檢查一律用 `has_valid_provider()` 而不是 `has_provider()`——後者只查設定項
存不存在，但 `AIService.request()` 擋的條件是 `provider == null or not
provider.valid`，只查存在會放行設定不全的項目、然後每次請求安靜失敗。

每隻 Agent 出生時依 `decision_source`（`@export`，#122 落地前的佔位欄位，
不是真實角色資料）建一次 provider，存成 `_provider` 成員變數，之後所有決策
／對話呼叫都用它——對應《06》「`decision_source`／`model_name` 投放後不可改」，
不是每次呼叫才重新判斷。三種資料異常都安靜退回 `LocalLLMProvider`、
`push_warning` 帶原因：`decision_source` 打錯字／空字串；`"cloud"` 但
`model_name` 是空的；`"cloud"` 但 `model_name` 不是可用的 provider。
空字串要跟打錯字分開判斷，是因為不擋住的話它會被 `AIConfig.get_provider()`
解析成 `default_provider`，讓角色實際打本機模型、卻頂著 `RemoteLLMProvider`
的身分（連帶套用錯的重試次數），而且沒有任何警告。

`agent.gd::_decide_with_retry()` 集中處理「decide → parse_completion →
validate」，內容驗證失敗（`parse_completion()` 或 `AISchema.validate_*()`
回傳 `ok=false`）時依 `DecisionProvider.max_validation_retries()` 重試：
`RemoteLLMProvider` 固定 2 次（《12》§3.4／P-22 #3）；`LocalLLMProvider` 改讀
`AIConfig.get_provider(_provider_name).format_guaranteed`（#212）——這個 provider
的輸出格式有沒有被文法層（如 GBNF）保證，true 給 0 次（保證格式，出錯代表更根本
的問題，重試沒有意義）、false 給 2 次，不再用「provider 名字是不是字面值 `"local"`」
判斷。玩家的 `ai_config.json` 要幫 `"local"` 那筆 provider 補上
`"format_guaranteed": true` 才能維持原本的 0 次重試行為，沒補的話會安全退化成
2 次（多重試幾次，不是正確性問題）。

`DecisionProvider.decide()` 現在是共用的基底實作（#213），`LocalLLMProvider`／
`RemoteLLMProvider` 都不再各自覆寫；`is_retry` 改包在 `DecisionContext`
（`scripts/ai/decision_context.gd`）物件裡傳遞，不再是逐層宣告的 `bool` 參數
（#217）——未來 `HumanInput`／`RemotePlayer` 新增請求層級中繼資訊時只改
`DecisionContext` 加欄位，不用逐層加參數、逐層轉發。
`AIService` 層級的失敗（見上方第 6 點）不進這個重試迴圈，直接回傳給呼叫端
走 fallback——「這次問不到」與「問到了但答案壞掉」是兩種不同情境。

`next_line()`／`_request_next_decision()` 呼叫這一個共用函式，各自傳自己的
`AISchema.validate_dialogue`／`validate_tasks` 當 validator，其餘邏輯不變。

**不在這一版**：模型失效後「視同離線走入眠流程」（《10》§4.5／《12》§6.1）
——牽涉 `Stats` 暫停衰減、持續性 UI 顯示，範圍超出決策來源介面，留給之後
另開的 issue。

`response_format` 依 provider 分岔（原規劃的 GBNF／response_format 二選一）
簡化成單一路徑：`AIConfig.Provider.supports_json_schema`（預設 `true`）決定
送不送這個欄位，不分本機／雲端——本機 llama-server 已知支援 OpenAI 相容的
`response_format` 並在內部自己轉成 grammar 約束，不需要在 GDScript 端手刻
JSON Schema → GBNF 的轉換器。

**驗收**：`llm_decision_enabled` 開啟、AI 停用時 `_request_next_decision()`
靜默失敗、`_awaiting_decision` 正確重置、fallback 到 schedule 候選、
`_push_llm_tasks()` 的 dedup／duration 下限／池子上限、`LLM_WAIT_MIN_COMMIT`
都已用 `game_eval` 白箱驗證；真的接上本機 provider 端到端跑一次才算完整
驗收，這次還沒做。

## 不在這一版（正式線）

- **記憶系統** —— 卡在專案完全沒有存檔機制，記憶無處持久化。`character.gd` 的
  `signal spoke` 跟 Task 上的 `reasoning`／`inner_monologue`（issue #88）都是
  日後寫逐字稿/決策脈絡的接點，先鋪路但還沒有東西讀
- **交誼區 WebSocket 線** —— 伺服器技術棧尚未決定
- `preconditions` 求值 —— 結構留欄位，v1 一律通過
- 白名單中除 `move_to` / `talk` / `sleep` 外的動作實作——白名單本身已經是
  《07》《11》拍板的 22 個（issue #88），但 `IMPLEMENTED_ACTIONS` 沒有跟著擴
- `speech` 觸發對話交接（issue #90）、約定機制
- `HumanInput`／`RemotePlayer`（《12》§3.3 另外兩種 DecisionProvider 來源）

## 待決（正式線）

- [ ] 「…」氣泡的等待體感要實跑才知道能不能接受
- [ ] **LLM 成本上限完全沒有防護**——拿掉硬上限、對話又豁免配額的直接後果，
      要先實跑量出「一場對話平均幾輪」才有辦法訂
- [ ] 軟壓力（system prompt 叫模型「聊久了該收尾」）到底有沒有用，未知數
- [ ] 尚未對真正的 OpenRouter 打過請求，TLS/DNS 與真實回應格式未驗證
- [ ] 人格資料的欄位結構——`data/personas.json` 要放哪些欄位才夠組 system prompt
- [ ] 成本上限機制的具體設計
- [ ] 記憶系統上線前，Agent 的對話逐字稿要不要先存記憶體就好
- [ ] `response_format` 的 json_schema 送出去之後，模型端真的照著回、還是仍需要
      layer 2/3 兜底救回來——只驗證過本機 llama-server 自己轉 grammar 這條路徑
      「有在動」（決策迴圈實測延遲 2.5-4 秒能量出來就是證據），沒有拿真實壞掉的
      回應測過三層保證的退場路徑

---

# poc_village_sim 驗證留下來的結論

`poc_village_sim` 是本機的獨立 Python 專案，不在這個 repo、不是出貨架構，
Godot 端也沒有任何程式呼叫它。下面是驗證期間量到、**還在影響正式線決策**的幾件事。

## Godot `Stats` ↔ poc `physiology`：維度與方向都不一樣

移植 poc 的門檻邏輯時要照這張表翻。兩邊的維度跟方向都不同，
而且 poc 那套模型正式線不會沿用：

| Godot `Stats.SPEC` | poc_village_sim `physiology` | 換算 |
| --- | --- | --- |
| `satiety`（100=飽→0=餓，原欄位名 `hunger`，2026-08-16 改名，見《99》P-32） | `hunger`（0=飽→100=餓） | **方向相反**：`poc_hunger = 100 - godot_satiety` |
| `stamina`（100=飽滿→0=沒力） | `stamina`（同方向） | 同名同方向，直接映射，不用轉 |
| `fun`（100=不無聊→0=無聊） | `boredom`（方向相反） | **方向相反**：`poc_boredom = 100 - godot_fun` |
| `social` | 無對應欄位 | poc 沒有獨立追蹤社交需求 |
| `mood` | 無對應欄位 | poc 的「情緒」是 AI 自己宣告的 `emotion`，不是 physiology 數值 |
| （無） | `money` | Godot `Stats.SPEC` 沒有這項的資料來源 |

> [!note] `hydration`／`health` 現在 Stats.SPEC 有欄位了，但跟 poc 的方向對照還沒查證
> 《01》§4-1 擴充（issue #115）之後 Godot 端已經有 `hydration`／`health`，
> 對得上 poc 的 `thirst`／`health`。但 poc_village_sim 是本機獨立專案、不在這個
> repo，這兩項實際的 range 與方向沒有查過原始碼確認，不能照抄 `hunger`／`stamina`
> 的既有換算模式假設。之後真的要移植門檻邏輯時，要先讀 poc 原始碼補上這兩列。

> [!warning] 給之後寫正式 GDScript 版本的人（確認是使用者自己，見上方 2026-08-12 更新）
> 如果那份重寫照抄了 poc_village_sim 已驗證過的門檻邏輯（`characters.py` 的
> `_tier_adjective`、`if hunger >= 90` 這類具體數字），**移植的當下方向要反過來
> 翻**——poc 的 `hunger >= 90`「快撐不住」，翻成 Godot 自己的方向要變成
> `satiety <= 10` 才是同一個意思。這是移植當下要抓對的一次性正確性問題，
> 寫完的 GDScript 版本應該全部用 Godot 自己的方向自洽，不需要執行時轉換。

## poc_village_sim 輸出 JSON vs 規格書《06 資料欄位對應表》的差異

`/decide` 實測拿到的真實回應：

```json
{
  "character_id": "alan", "npc_id": "npc_alan",
  "elapsed_seconds": 3.82, "action_start_offset_seconds": 3270,
  "action_duration_seconds": 120, "prompt_truncated": false,
  "action_en": "sleep",
  "location": {"kind": "HOME", "shared_location": null, "owner_id": "alan", "owner_npc_id": "npc_alan"},
  "target_id": null, "target_npc_id": null,
  "output": {
    "reasoning": "...", "emotion": "neutral", "emotion_intensity": 0,
    "intent": {"action": "睡覺", "duration_ticks": 12, "target": null, "location": "阿蘭家"},
    "current_goal": "恢復體力", "inner_monologue": "...",
    "speech_target": null, "speech": null, "speech_volume": "normal"
  }
}
```

> [!important] 兩份文件本來就管不同範圍，大部分「缺席」是預期中的
> 《06》是角色的完整持久資料（身分＋人格＋關係＋經濟＋狀態＋記憶），`/decide`
> 回傳的是單次決策結果，範圍窄很多。《06》的 `identity`／`hexaco_input`／
> `personality`／`relations`／`economy` 整塊缺席，是因為這些該活在角色自己的
> 存檔，跟決策回傳是兩件事，不是漏做。

真正該對齊、目前對不齊的幾塊：

| 語意 | 《06》 | poc 輸出 | 差異 |
| --- | --- | --- | --- |
| 情緒 | `emotion.type`／`intensity`／`cause_event_id`／`duration_left` | `output.emotion`／`emotion_intensity` | 少了 `cause_event_id`、`duration_left`；`emotion.type` 的 8 值枚舉規格書自己標「待補」 |
| 當前目標 | `current_goal`（≤40字） | `output.current_goal` | 有對上 |
| 地點 | `location_id`（單一字串） | 頂層 `location: {kind, shared_location, owner_id, owner_npc_id}` | **結構完全不同**：扁平 ID vs 巢狀物件，之後對齊規格書時要先問清楚用哪一種 |
| 上次動作結果 | `last_action_result.{action,target,success,reason}` | 只在送出的 payload 當輸入欄位 | 語意不同：《06》是引擎寫回的紀錄，poc 是呼叫端自己餵進去的上文 |
| 當日計畫 | `today_plan`（2~4 項） | 無對應 | poc 目前是單次單一動作決策，沒有多步驟計畫 |
| 特殊狀態 | `conditions[]` | 無對應 | 缺席 |
| 生理狀態 | `physical.*`（8 項，「LLM 寫：**禁止**」） | 完全不在回傳裡 | 方向一致，poc 也沒有回傳它 |

poc 輸出裡有、《06》沒提到的欄位：`reasoning`／`inner_monologue`／`speech`／
`speech_target`／`speech_volume`／`intent`／`action_en`／`target_id`／
`target_npc_id`／`elapsed_seconds`／`action_start_offset_seconds`／
`action_duration_seconds`／`prompt_truncated`——多半是單次決策才需要的東西
跟 poc 自己的除錯欄位，不是《06》漏寫。

命名慣例也對不上：《06》規定 ID 格式 `npc_017`（三碼數字），poc 用英文名字當 id；
《06》全 snake_case 無中英夾雜，poc 的 `intent.action`（中文）跟 `action_en`
（英文）同時存在，是重複資訊。

## 延遲：實測 2.5-4 秒，體感層面的解法尚未實作

編輯器實測「玩家靠近就打一次決策」：從靠近到角色真的有反應中間約 2.5-4 秒
（時間主要花在 llama-server 的 grammar 約束生成，不是網路或 Godot 端）。
對「玩家靠近、期待即時反應」這種互動模式來說很明顯，玩家靠近後畫面上完全
沒有回饋，3 秒後突然講話/移動。正式線接對話與行程時會碰到同一個數量級。

**體感層面的解法（想法已記錄，尚未實作）**：觸發當下先給立即視覺回饋——氣泡
顯示「…」思考中，或角色停下腳步做「在想事情」的小動作，等決策回來才換成
真正的台詞/動作。不用真的縮短延遲，體感會差很多。

**縮短延遲本身的槓桿（另一方向，同樣尚未實作）**：`REASONING_INSTRUCTION` 的
100 字上限是延遲/品質的直接槓桿，往下砍會更快但決策品質會掉；其他槓桿是模型
量化等級、llama-server 的 `--parallel` 設定，會影響全部呼叫，改動範圍更大。

## 待對齊：組長發的資料夾結構規範，跟現有 `Ailley/CLAUDE.md` 不一樣

組長發的協作規範建議按**遊戲物件模組**分類（`entities/player/` 場景/腳本/圖片
放一起），跟現有 `Ailley/CLAUDE.md` 的**按系統層**分類（`scripts/ai/`／
`scripts/character/`……）是兩套不同邏輯。目前沒有動任何現有檔案去符合新規範，
這個決定牽動全隊檔案怎麼放，影響範圍大。新規範至少對**新產出的 Godot 文件**
適用，但現有結構要不要整個重排、`CLAUDE.md` 要不要一併更新，都還沒有結論——
之後要新增 AI 相關的 Godot 檔案，先跟組長確認適用範圍。

## `-s` 自訂主迴圈 headless 驗證的限制

想寫 throwaway 的 `extends SceneTree` 腳本、`instantiate()` main.tscn 做端到端
驗證時，只要場景裡任何腳本引用了 `GameClock`／`AIService` 這類 autoload，
就會在 `_initialize()` 階段直接 `Identifier not found` 編譯失敗（用
`print(GameClock.day)` 這種最小化腳本就能重現，是環境限制不是程式錯誤）。
原因跟 `--check-only` 認不得 autoload 是同一個病根：autoload 掛進場景樹、
註冊成 GDScript 編譯器認得的全域名字，發生的時間點比 `-s` 腳本的
`_initialize()` 執行時機晚，`await process_frame` 救不回來——卡編譯期那一行
本身就已經失敗。這種端到端驗證只能靠 `--quit-after` 完整開機或編輯器 Play，
細節見 `Ailley/CLAUDE.md` 的 Headless 驗證那節。
