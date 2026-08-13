---
tags:
  - agent
  - llm
  - 計畫
status: 進行中
updated: 2026-08-13
---

# LLM 串接與 AI 服務層

把 LLM 實際接進遊戲：同一套 client、同一組 JSON 信封、同一套驗證與 fallback，
同時驅動 Agent 的「講什麼」與「做什麼」。

這是「Agent 的 AI 呼叫跑在擁有者自己的電腦上」那條決策的具體化。
內容層切點見 [[talk 動作設計]]，任務結構見 [[行程佇列與任務仲裁]]，
角色狀態來源見 [[Character 基底與 Agent]]。

## 現況：兩條並存的線，定位不同

| | 正式出貨線 | R&D 驗證線 |
| --- | --- | --- |
| 走哪個協定/服務 | `AIService`（`scripts/ai/ai_service.gd`）→ 最終是 Godot ↔ Sidecar（`llama-server`） | `village_sim_client.gd` 等 → `poc_village_sim/server.py`（本機 Python，不在這個 git repo） |
| 做到哪 | Step 0（底層：request/佇列/速率限制/驗證骨架）已完成，**尚無任何呼叫端**——`conversation.gd` 仍同步、`agent.gd` 仍純行程表驅動 | Transport、讀真實狀態、執行動作/說話、玩家靠近自動觸發、`physiology_override`、通用動作提示，全部完成且驗證過 |
| 玩家最終會不會玩到 | 會，這是拍板的出貨方向 | **不會**，純粹用來快速驗證 prompt/決策邏輯，供 GDScript 重寫參考 |

> [!success] 架構決定：出貨不走 Python 後端
> 三六零否決「隨遊戲出貨 Python 後端」：自架中繼伺服器已被否決過（AI 呼叫要跑在
> 擁有者自己機器上、費用自己付）；出貨包 Python 要三平台各打包、簽章、防毒誤判，
> Godot 端照樣得寫 HTTP client 去打它；`base_url` 能指向任何 OpenAI 相容端點，
> 程式一行不用改，想用 Python 的人自己架一層換網址就好。
>
> **結論：Python 後端是玩家自己的選擇，不是專案出貨的架構決定。** 正式方向是
> **Godot（`HTTPRequest`）↔ Sidecar（`llama-server`）**，不經 Python 中間層；
> `poc_village_sim` 定位是 R&D／驗證用途，繼續開發但要保留 HTTP 接口給 Godot 端。

> [!warning] 2026-08-12：GDScript 決策邏輯重寫由使用者負責
> 正式線現況：**決策迴圈還未實作**（目前只有仲裁器的殼，對應
> [[行程佇列與任務仲裁]] 的 Step 2）、**身分對照系統尚未**、**雙向對話尚未**
> （對應 Step 1）。把 `poc_village_sim` 決策邏輯搬進 GDScript、接上仲裁器，
> 是**使用者自己要寫的東西**。
>
> 身分對照系統的缺口是兩條線共同的洞：這條 R&D 線用的
> `VillageSimLocale.GODOT_NAME_TO_POC_ID` 也是寫死的 demo 對照，不是正式方案；
> issue #69（`character_id`／`character_name` 固定指派，見下方）補的是
> Character 基底層的身分基礎，兩條線都用得上，不是白做。

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
| `prompt_builder.gd` | 由 Character 組出請求信封（尚未實作） |

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
		"local":      {"base_url": "http://127.0.0.1:8080/v1", "api_key": "", "model": "qwen2.5-7b-instruct", "timeout": 10.0},
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
> Agent 決策迴圈，那個還沒實作（見上面「現況」）；唯一沾得上邊的
> `VillageSimDecision` 是 R&D 測試線，而且 #86 要移除它。在那之前先加一個
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

### `scripts/ai/`（R&D 驗證線，已完成，見下方詳細章節）

| 檔案 | 職責 |
| --- | --- |
| `village_sim_client.gd` | 打 `poc_village_sim/server.py` 的純 HTTP client，跟 `AIService` 完全獨立 |
| `village_sim_decision.gd` | `decide()`（組真實狀態問一次，不執行動作）＋ `apply()`（套用到角色） |
| `village_sim_locale.gd` | Godot 地點/角色名 ↔ poc 中文地點/id 的有限對照表 |

### 未來要改的既有檔案（正式線，尚未動工）

| 檔案 | 改動 |
| --- | --- |
| `conversation.gd` | 同步 → 非同步（pending 狀態、「…」氣泡、失敗回退）；`_speak()` 目前用字串長度算計時器，非同步 LLM 塞不進去，這段一定要動 |
| `agent.gd` | cron → 任務池＋仲裁器；接受 LLM push 的 Task，見 [[行程佇列與任務仲裁]] |
| `character.gd` | 加 `signal spoke(line: String)` |
| `chat_input.gd` | 玩家在對話中打字 → 文字送進對話上下文 |
| `dialogue_lines.gd` | **保留不刪**，降級為 fallback（逾時/未設金鑰/驗證失敗時要有保底台詞） |
| `debug_console.gd` | 新增 `tasks` 指令 |
| `project.godot` | 新增 autoload 走 `autoload_manage`，不手改 |

## JSON 信封（正式線設計，尚未實作）

對話與行程**共用同一個信封**，用 `type` 區分。

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
  為真時說完這句就結束對話
- `plan` → `{"tasks": [ <Task struct> ]}`；**空陣列 ＝ 不更新**

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
> 的 23 個，三份互相都對不齊（唯一三者皆有的只有 `attack`／`sleep`／`buy`／`sell`，
> 連 `move` 的寫法都不一樣：規格書是 `move`，其餘兩份是 `move_to`）。根本原因不是
> 誰漏做——《07》整份被規格書自己的 `99_待規劃項目清單.md` 標記「含推測內容，
> 實作前必須先確認」（**P-17**，行動清單完整與否明列「推測待確認」，決定欄空白），
> 根本沒有一份「確定版」可以照抄，三邊都是各自基於草稿湊出一份能動的版本。
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

### 界線：不設硬上限（已知風險，尚未解決）

不設輪數硬上限，改用**軟壓力**：payload 帶 `turns_so_far`，system prompt 告訴模型
「聊得越久越該收尾」。代價是兩隻 Agent 都禮貌性不收尾就會一直聊下去，而每輪都是
一次付費請求——與「每遊戲日最多 20 次 AI 請求」直接衝突，目前無防護。實際跑過、
知道一場對話平均幾輪之後才有辦法訂上限。

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

## 正式線實作順序（Step 0 完成，Step 1-3 未開始）

前置：先把工作區未提交的東西分開 commit，從乾淨基準開工。

### Step 0 — 底層 ✅ 完成

`ai_config.gd`／`ai_service.gd`／`ai_schema.gd`／`data/ai_config.example.json`，
autoload 已註冊，主控台加了 `ai` 指令。

- `request(envelope, requester_id, policy)`：`enum Policy { SCHEDULED, CONVERSATION }`，
  `CONVERSATION` 跳過冷卻與每日配額但照樣計數（走獨立的 `_dialogue_calls_today`），
  預設 `SCHEDULED`——忘了指定的呼叫端落在保守那邊，不會意外拿到無限額度
- 速率限制三個旋鈕搬進 `user://ai_config.json`（`min_interval_sec` 預設 30、
  `max_calls_per_game_day` 預設 20、`dialogue_exempt` 預設 true，皆可設 0＝不限）
- 回傳一律 `{"ok": bool, "data": Dictionary, "error": String}`，呼叫端一律 `await`
- 4xx 不重試；網路錯誤／5xx 重試 1 次

> [!warning] 兩個容易忽略的網路層 bug（教訓：只用 happy path 的 stub 測網路層等於沒測）
> **`await` 死鎖**：URL 格式錯時失敗發生在呼叫端跑到 `await` 之前，訊號永遠等不到——
> 修法是 `_finish()` 改 `emit.call_deferred()`。
> **幽靈回應**：請求中途失敗但逾時計時器已起跑，`timeout` 秒後補送一個
> `request_completed` 給沒有工作的節點——修法是失敗時先 `cancel_request()`。

**尚未執行期驗證**：這些是在沒有 Godot 執行檔的環境做的，只做過靜態檢查，
合併前要補：`project_run` → `ai` ×2 → `ai dialogue` ×2 → `logs_read`。

### Step 1 — 對話（未開始）

1. `prompt_builder.gd` 的 dialogue 信封
2. 台詞來源介面（見上）
3. `conversation.gd` 改非同步，`_pending` 狀態顯示「…」氣泡，移除 `MAX_TURNS`，
   逾時/驗證失敗走 fallback 並結束對話
4. `character.gd` 加 `signal spoke(line)`
5. `chat_input.gd` 對話中打字送進上下文

**驗收**：走到 Agent 旁按 E → 講出 LLM 產的台詞；關掉 `enabled` → 自動回到模板句。

### Step 2 — 任務池與仲裁器（未開始，純重構不接 LLM）

完全照 [[行程佇列與任務仲裁]] 實作，改動全在 `agent.gd`。刻意不含 LLM，
這樣行為若有回歸，責任歸屬明確——是重構寫錯，還是 LLM 給了爛任務。

**驗收**：`tasks` 指令印出池子與分數拆項 → Agent 行為與重構前完全一致。

### Step 3 — LLM 填行程（未開始）

1. `prompt_builder.gd` 的 plan 信封
2. 觸發情境：遊戲日開始／需求跌破閾值／被搭話／動作失敗
3. LLM 回傳的 Task 過 `ai_schema.gd` → push 進池子
4. 池子守則：上限 20、同 `action + params.target` 去重、`expires_at` 到期清除
5. 搶佔：`schedule` 丟掉／`llm` 放回池子且 `retries += 1`／`reflex` 丟掉
6. 逾時 fallback：Agent 標記 `pending` 但繼續做原本的事

**驗收**：需求打到閾值以下觸發重排 → `tasks` 看到 `source = "llm"` 的新任務 →
Agent 真的改去該地點 → 關掉 AI 後退回純 schedule 行為。

## 不在這一版（正式線）

- **記憶系統** —— 卡在專案完全沒有存檔機制，記憶無處持久化。`character.gd` 的
  `signal spoke` 是日後寫逐字稿的接點
- **交誼區 WebSocket 線** —— 伺服器技術棧尚未決定
- `preconditions` 求值 —— 結構留欄位，v1 一律通過
- 白名單中除 `move_to` / `talk` / `sleep` 外的動作實作

## 待決（正式線）

- [ ] `response_format` 的 json_schema 在選定模型上到底支不支援（要實測）
- [ ] 「…」氣泡的等待體感要實跑才知道能不能接受
- [ ] **LLM 成本上限完全沒有防護**——拿掉硬上限、對話又豁免配額的直接後果，
      要先實跑量出「一場對話平均幾輪」才有辦法訂
- [ ] 軟壓力（system prompt 叫模型「聊久了該收尾」）到底有沒有用，未知數
- [ ] 尚未對真正的 OpenRouter 打過請求，TLS/DNS 與真實回應格式未驗證
- [ ] 人格資料的欄位結構——`data/personas.json` 要放哪些欄位才夠組 system prompt
- [ ] 成本上限機制的具體設計
- [ ] 記憶系統上線前，Agent 的對話逐字稿要不要先存記憶體就好

---

# R&D 驗證線：poc_village_sim 串接

`village_sim_client.gd`／`village_sim_decision.gd`／`village_sim_locale.gd`，
全部已完成並驗證過（headless + 編輯器實測）。用途是快速驗證「AI 接進 Godot 後
可以呼叫、決策、驅動看得到的行動」這條資料流，供之後 GDScript 重寫參考——
**不是玩家實際會玩到的路徑**（見上方「現況」表格）。

## 已完成的部分

- **Transport 層**：Godot 打得通 `poc_village_sim/server.py`，拿回合法決策 JSON
- **讀真實狀態**：用 `Character.get_state_snapshot()` ＋ `Agent.current_place`
  組出真實 payload，透過 `VillageSimLocale` 把 Godot 錨點名稱翻譯成 poc 中文地點
- **動作與話語真的被執行**：`move_to` 真的移動、`speech` 真的呼叫 `character.say()`
- **視野真的被讀取**：`character.vision.get_visible_characters()` 過濾成 poc id
  塞進 `visible`（`GODOT_NAME_TO_POC_ID` 目前只認得 `agent`/`agent2` 兩隻 demo 角色）
- **玩家靠近自動觸發**：`village_ai_enabled` 開啟時，`_on_spotted()` 偵測到玩家
  就自動打一次決策，範圍限定單一角色（逐隻手動開，不是全體 Agent 一起開）
- **`decide()`／`apply()` 分離**：`decide()` 純問答不執行動作，`apply()` 才套用
  到角色，對齊「向下呼叫、向上發信號」的協作規範——副作用留在角色自己的路徑才好追蹤
- **通用動作提示**：`action_en` 不是 `move_to` 時借用 `Bubble` 顯示
  `［action_en：尚未實作，僅供除錯查看］`，未實作動作也看得到 AI 決定了什麼
- **防呆**：視野清單會跳過跟自己同一個 poc 身分的條目（避免兩個 Godot 節點被
  設成同一個 poc_character_id 時，AI 收到「看到自己」導致 `server.py` 500）

## 重要限制：只證明管線通，不是決策內容對

`village_ai_enabled` 這條路已經證明**機制可行**（真實狀態 → 翻譯 → 打模型 →
執行動作/說話全部真的跑通），但決策內容本身有幾個已知落差：

- `physiology_override` 已接上（見下表），但 `thirst`/`health`/`money`（Godot
  無資料來源）與 `social`/`mood`（poc 無對應欄位）仍沿用 poc 角色檔案的預設值，
  不是這隻 Godot 角色的真實狀態
- `GODOT_NAME_TO_POC_ID` 是寫死的 2 條 demo 對照，不是正式的角色身分系統
- `character_id`／`poc_character_id` 誰對應誰純靠操作者手動保證，程式不驗證
- **決策準不準沒有系統性驗證**——只能肉眼看 `reasoning` 判斷合不合理
- poc 動作白名單 38 種裡只有 `move_to`／說話真的執行，其餘因為 Godot 沒有
  對應玩法機制（種田/戰鬥/買賣……），只借 Bubble 印出來
- 玩家靠近觸發跟 `agent.gd` 既有的 cron 式行程表是**兩個獨立機制，會互相覆蓋**：
  `apply()` 不會回寫 `current_place`，AI 移動後行程表不知道角色被動過，下次整點
  觸發會把角色拉回行程表認定的地方，AI 自己也不知道上一步真的執行了什麼

## `physiology_override` 欄位對照表

Godot `Stats.SPEC` ↔ poc_village_sim `physiology`，維度跟方向都不一樣，
決定不改 `poc_village_sim` 的資料方向（會牽動已驗證過的門檻邏輯跟 prompt
樣板，而且未來 GDScript 版本不會沿用 poc 這套模型，對齊可能白做），
改成在 Godot 端寫轉換，只送對得上的欄位：

| Godot `Stats.SPEC` | poc_village_sim `physiology` | 換算 |
| --- | --- | --- |
| `hunger`（100=飽→0=餓） | `hunger`（0=飽→100=餓） | **方向相反**：`poc_hunger = 100 - godot_hunger` |
| `energy`（100=飽滿→0=沒力） | `stamina`（同方向） | 直接映射，不用轉 |
| `fun`（100=不無聊→0=無聊） | `boredom`（方向相反） | **方向相反**：`poc_boredom = 100 - godot_fun` |
| `social` | 無對應欄位 | poc 沒有獨立追蹤社交需求，不送 |
| `mood` | 無對應欄位 | poc 的「情緒」是 AI 自己宣告的 `emotion`，不是 physiology 數值，不送 |
| （無） | `thirst`／`health`／`money` | Godot `Stats.SPEC` 沒有這三項的資料來源，不送，沿用 poc 預設值 |

> [!warning] 給之後寫正式 GDScript 版本的人（確認是使用者自己，見上方 2026-08-12 更新）
> 如果那份重寫照抄了 poc_village_sim 已驗證過的門檻邏輯（`characters.py` 的
> `_tier_adjective`、`if hunger >= 90` 這類具體數字），**移植的當下方向要反過來
> 翻**——poc 的 `hunger >= 90`「快撐不住」，翻成 Godot 自己的方向要變成
> `hunger <= 10` 才是同一個意思。這是移植當下要抓對的一次性正確性問題，
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

編輯器實測 `village_ai_enabled` 自動觸發：玩家靠近到角色真的有反應，中間約
2.5-4 秒（時間主要花在 llama-server 的 grammar 約束生成，不是網路或 Godot 端）。
對「玩家靠近、期待即時反應」這種互動模式來說很明顯，玩家靠近後畫面上完全
沒有回饋，3 秒後突然講話/移動。

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
