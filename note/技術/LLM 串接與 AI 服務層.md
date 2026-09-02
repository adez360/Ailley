---
tags:
  - agent
  - llm
  - 計畫
status: 進行中
updated: 2026-08-31
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

### Embedding（L3 語意記憶檢索，issue #571）：獨立於對話 provider

2026-08-26 拍板：embedding 是獨立於「玩家對話走 Local 還是 Cloud」的第三條線，
**不管玩家選哪個對話 provider，embedding 這個計算步驟本身一律走本機**。理由：
embedding 模型遠比對話模型輕量（bge-small 幾百 MB、CPU 就能跑），Cloud 玩家
也負擔得起在自己機器常駐這一支，換來的是「產生向量」這件事兩種玩家都不用
多一筆對外 API 呼叫的延遲與費用，也不用把記憶內容送給第三方 embedding 服務。

> [!warning] 這不是「記憶內容整體都不出本機」的保證
> `search_l3()` 命中的記憶**文字內容**會被塞進 `context.memory.recalled`，
> 跟既有的 `recent`(L2)／`core`(L4) 一樣，整包 envelope 送進 `AIService.request()`，
> 送去玩家選的哪個對話 provider（Local／Cloud）就跟哪個一樣，這裡沒有額外
> 攔截。跟 L2／L4 記憶內容既有的行為一致，不是 L3 才有的例外，也沒有計畫
> 幫 L3 加特殊隔離——2026-08-27 拍板維持這個一致性，只修正這裡過度承諾的
> 文件敘述，不改變傳輸行為（CodeRabbit review 抓到，見 issue #571 討論）

- 模型：`bge-small-zh-v1.5-q8_0.gguf`，`llama-server --embedding --pooling cls`
  服務 OpenAI 相容的 `/v1/embeddings`。這組模型檔案原本就在遠端 GPU 機器
  （見「遠端 GPU 機器連線手冊」）留著沒清掉，不用重新下載
- 檢索本身用暴力法 cosine similarity，不引入向量 DB／延伸套件——L3 記憶量級
  （單一 NPC 頂多幾十筆）用不上 ANN 索引，多一個套件只會增加打包風險
- `ai_config.json` 新增一個跟 `providers` **平行**的頂層 `embedding` 區塊
  （不是 `providers` 字典裡的一個 provider）——這條線不受玩家的 Local/Cloud
  選擇影響，混在一起會讓語意不清楚
- 開發期驗證：本機沒有 GPU，改在遠端 GPU 機器（`desktop-h9aniv5`）常駐這支
  embedding server（沿用既有筆記記載的 `neonardooo@100.85.79.25:2222` SSH
  存取方式），本機用 `ssh -N -L 8081:127.0.0.1:8081 ...` 建 tunnel 連過去測。
  **這條 tunnel 是本機行程，機器關機／重開會中止**，下次要驗證前得重新建立

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
| `ai_config.gd` | 讀 `user://ai_config_<hash>.json`（hash 依 checkout 隔離，見 [[存檔]]「存哪」）。金鑰**永不進 log、永不進錯誤訊息**。檔案不存在 → `enabled = false`，全系統走 fallback。解析出一組具名 `providers`、全域的速率限制三個旋鈕，以及跟 `providers` 平行的頂層 `embedding` 區塊（見上方「Embedding」一節） |
| `ai_service.gd` | **對話／決策唯一碰網路的地方**。autoload。節點池、佇列、逾時、速率限制、重試——只打玩家自己選的 Local／Cloud 對話 provider |
| `embedding_service.gd` | **L3 語意檢索唯一碰網路的地方**（issue #571）。autoload，跟 `ai_service.gd` 分開、各自獨立打各自的端點——這裡永遠打本機的 embedding-only server，不受玩家的對話 provider 選擇影響，也不共用 `ai_service.gd` 的節點池／佇列／速率限制（呼叫頻率遠低於對話，見《03》§7 觸發時機表，不需要那一整套） |
| `ai_schema.gd` | 回應驗證：`JSON.parse_string` → null 檢查 → 逐欄位型別檢查 → `action` 白名單 |
| `prompt_builder.gd` | 由 Character 組出請求信封（dialogue／plan／reflection／creation 皆已實作）。system 段前綴每個角色的人格摘要，見下方「人格資料」 |

人格資料在 `npc_schedule.json` 的 `identities`（節點名查表），組成 system 段的
第一截，見 [[人格與 System Prompt]]。

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
		"local":      {"base_url": "http://127.0.0.1:8080/v1", "api_key": "", "model": "qwen2.5-7b-instruct", "timeout": 20.0, "format_guaranteed": true},
		"openrouter": {"base_url": "https://openrouter.ai/api/v1", "api_key": "sk-or-v1-…", "model": "openai/gpt-4o-mini", "timeout": 10.0}
	},
	"embedding": {"base_url": "http://127.0.0.1:8081/v1", "model": "bge-small-zh-v1.5-q8_0.gguf", "timeout": 10.0},
	"min_interval_sec": 30.0
}
```

`embedding` 是跟 `providers` 平行的頂層區塊（見上方「Embedding」一節），不是
`providers` 字典裡的一個 provider——這條線不受 `default_provider` 選擇影響。

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

對話與行程**共用同一個信封**，用 `type` 區分。dialogue／plan／reflection／
creation 四種都已經實作（`PromptBuilder.build_dialogue_envelope()`／
`build_plan_envelope()`／`build_reflection_envelope()`／
`build_creation_envelope()`）。

`creation` 是 #122 加的第四種：建角完成當下打一次的一次性呼叫（規格書 05
流程圖 ⑤，`words_to_creator`——角色對自己性格設定的一句話吐槽）。這一刻
角色還沒有 `Character` 節點（建角面板只丟出 Dictionary，投放才生節點），
所以不沿用吃 `Character` 的 `_system()`，直接接剛算好的 `system_prompt`
字串。呼叫端是 `GameManager.receive_created_character()`，fire-and-forget
（跟 `workstation.gd::_run_work()` 同一種協程模式）：存檔本身不等這通請求，
角色先進角色庫，AI 回應晚到只補 `words_to_creator` 這一個欄位。

### 請求

切成兩塊是為了成本：不變的部分吃得到 prompt cache。

```
system: 人格敘述 ＋ 行為規則 ＋ 輸出 schema ＋ 動作白名單     ← 幾乎不變
user:   <下方 JSON 字串化>                                    ← 每次變
```

`system` 段最後固定接一句語言規則（`PromptBuilder.OUTPUT_LANGUAGE_RULE`，issue
#656）：本機小模型沒有明確語言限制時，容易在中文句子裡夾雜訓練資料帶出來的
英文詞彙。這句只管「自由文字（台詞、心聲、吐槽）要用繁體中文」，不影響 JSON
欄位名／enum 值——所以接在規則段最後面而不是最前面，避免被誤讀成連 schema
都要中文。`build_dialogue_envelope`／`build_plan_envelope`／
`build_reflection_envelope`／`build_checkpoint_envelope`／
`build_last_words_envelope`／`build_words_to_creator_envelope`（都經過
`_system()`）跟 `build_creation_envelope`（不吃 `Character`，另外接一次）
全部套用同一句。

```json
{
  "type": "dialogue",
  "self": {
    "id": "agent", "name": "小明",
    "stats": {"satiety": 42.0, "hydration": 65.0, "stamina": 70.0, "wakefulness": 88.0, "hygiene": 60.0, "alcohol": 0.0, "health": 100.0, "injury": 0.0, "social": 12.0, "fun": 60.0, "mood": 55.0},
    "time": {"day": 3, "hour": 9, "minute": 30},
    "place": "farm",
    "current_action": "work"
  },
  "context": {
    "listener": {"name": "player", "met_count": 3},
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
  為真時說完這句就結束對話。`task` 是選填欄位（issue #658）：講出的話若是
  即時承諾，順帶回一筆 Task struct（跟下面 `plan` 的 `tasks[]` 同一個形狀），
  直接推進講話者自己的任務池，讓內容層講的話跟決策層實際會做的事對得上——
  是不是「真的算承諾」交給模型自己判斷，engine 不比對台詞裡的關鍵字。池滿時
  跟一般 LLM 任務同一套處理（靜默丟棄，`_push_llm_tasks()` 只 `push_warning`），
  不像 persuade 的 `proposed_task` 保證騰位塞入——對話裡的口頭承諾不是對
  另一方的正式應允，沒有信任問題
- `plan` → `{"tasks": [ <Task struct> ], "reasoning", "inner_monologue", "request_plan_update"}`；
  `tasks` 空陣列 ＝ 不更新。`request_plan_update` 是模型「下次能不能讓我改
  today_plan」的申請信號，任何時候都能回。`update_plan` 是條件式欄位，只在
  呼叫端判斷現在是開放時機時才出現在 schema 裡，見下方「今日計畫」

### 三層保證，只有第三層是真的保證

1. `response_format: {"type": "json_schema", ...}` —— 各模型支援度不一，不能靠
2. prompt 內明寫 schema —— 機率問題
3. **`ai_schema.gd` 硬驗證** —— 這層不可省，是「外來文字一律視為資料」防注入規則的實作

`action` 白名單（`ai_schema.gd` 的 `ALLOWED_ACTIONS`，25 個）與規格書逐項對齊：
《07 地點與行動》§2 B/C/D 類（工作消費 8 ＋動作移動 6 ＋敵對 4 ＝ 18 個）
＋《11 人際互動與社交行為》§1 溝通類 A（7 個），合計 25 個，一個不多一個不少
（issue #396 核對，2026-08-19）。唯一差異是命名：規格書寫 `move`，程式碼沿用
既有命名 `move_to`——語意相同，改名要動 `agent.gd`／`debug_console.gd`／`api.md`
好幾處引用，不值得為了對齊用詞冒風險（見 `ai_schema.gd` 註解）。

`IMPLEMENTED_ACTIONS`（16 個）是 `ALLOWED_ACTIONS` 裡真的接了執行層的子集。
逐項核對表（issue #396）：

| 分類 | 規格書 | `ALLOWED_ACTIONS` | `IMPLEMENTED_ACTIONS` | 未接執行層現況 |
| --- | --- | --- | --- | --- |
| A 溝通 | `talk` | ✔ | ✔ | — |
| A 溝通 | `persuade` | ✔ | ✔ | — |
| A 溝通 | `give` | ✔ | ✔ | — |
| A 溝通 | `report` | ✔ | ✘ | 綁《洗心革面所》，明文延後到 MVP 之後，見《13》§三 |
| A 溝通 | `shout` | ✔ | ✔ | — |
| A 溝通 | `perform` | ✔ | ✘ | `SUCCESS_PARAMS` 已定義但無可達呼叫端，見 #216 |
| A 溝通 | `murmur` | ✔ | ✔ | — |
| B 工作消費 | `hunt_small` | ✔ | ✘ | 同上，見 #216 |
| B 工作消費 | `hunt_large` | ✔ | ✘ | 同上，見 #216 |
| B 工作消費 | `gather` | ✔ | ✘ | 同上，見 #216 |
| B 工作消費 | `fish` | ✔ | ✘ | 同上，見 #216 |
| B 工作消費 | `buy` | ✔ | ✘ | 缺「買哪個 item_id」的來源，見 #340 |
| B 工作消費 | `sell` | ✔ | ✘ | 已拍板不做——商店不回收物品，見 #141 |
| B 工作消費 | `eat` | ✔ | ✔ | — |
| B 工作消費 | `drink` | ✔ | ✔ | — |
| C 動作移動 | `move`（code: `move_to`） | ✔ | ✔ | 唯一命名差異，語意相同 |
| C 動作移動 | `sleep` | ✔ | ✔ | — |
| C 動作移動 | `nap` | ✔ | ✔ | — |
| C 動作移動 | `rest` | ✔ | ✔ | — |
| C 動作移動 | `wash` | ✔ | ✔ | — |
| C 動作移動 | `idle` | ✔ | ✔ | — |
| D 敵對 | `steal` | ✔ | ✘ | 同上，見 #216 |
| D 敵對 | `attack` | ✔ | ✔ | — |
| D 敵對 | `haul` | ✔ | ✔ | — |
| D 敵對 | `struggle` | ✔ | ✔ | — |

25 列，規格書欄全部 ✔——確認沒有規格書列了、`ALLOWED_ACTIONS` 漏掉的項目，
也沒有 `ALLOWED_ACTIONS` 多出、規格書沒有的項目（`ai_schema.gd` 註解裡特別
提過的 `work` 正是這種情況，刻意不放進白名單）。

`poc_village_sim/enums.py` 的 38 個不逐項列入這張核對表——它是本機獨立、
不進這個 repo 的 Python 專案（見下方「poc_village_sim 驗證留下來的結論」），
沒有原始清單可以核對，而且它本來就不是出貨架構，不受這裡白名單約束，
只拿來對照已驗證的門檻邏輯／人格影響。

> [!success] P-17 已於 2026-08-16 拍板定案（《99》待規劃項目清單）
> 本節上一版描述的「三份清單互相對不齊、沒有一份是拍板結果」已經過時。
> `ai_schema.gd` 現在的白名單是 issue #88 對齊《07》《11》拍板結果後寫入的，
> 不是舊版占位清單。

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
> `end` 省略視為 `false`。收尾語就是它自己那句話。
>
> **正常結束 ＝ 有人決定結束**（`ENDED_BY_SPEAKER`），`TOO_FAR` / `INTERRUPTED`
> 維持原樣仍是「沒好好講完」——這條原則跟 [[talk 動作設計]] 原本的
> `TURN_LIMIT` 描述不同，實作時要回頭改那份筆記。

### 界線：軟壓力為主，工程安全閥兜底（issue #178 已收斂範圍）

不設「設計上」的輪數硬上限，設計目標是**軟壓力**：payload 帶 `turns_so_far`，system prompt
告訴模型「聊得越久越該收尾」。**這個機制目前還沒有實作**——`Ailley/scripts/ai/prompt_builder.gd`
的 `DIALOGUE_SYSTEM` 尚未帶這段文字、`build_dialogue_envelope()` 傳的是固定
`max_turns`，不是遞增的 `turns_so_far`；這裡描述的是設計目標，接回程式碼是
獨立的後續動作，不在 #482 範圍內。

> [!note] `turns_so_far` 現在等於 `_turns.size()`，不用另外挑一種算法
> `conversation.gd::_run()` 的迴圈變數 `turn`（從 0 起算）跟 `_turns.size()`
> （陣列長度）在同一輪呼叫 `next_line()` 的當下是同一個數字——開場白已改成
> 一律過 LLM（issue #630／《99》P-67），不再有「`turn` 不含開場白、`_turns.size()`
> 含開場白」那個固定 1 的落差。下面 A/B/C 實驗跑在這個落差還存在的舊版上，
> 腳本用的是 `turn`；接回真代碼時兩邊現在算的是同一件事，選哪個當
> `turns_so_far` 都可以，`Ailley/scripts/ai/prompt_builder.gd::build_dialogue_envelope()`
> 沿用同一個公式，不要兩邊各自算一套。

**A/B/C 實測在本次樣本中大幅改善收尾行為**（issue #482，2026-08-23，本機 llama-server
直連 `/v1/chat/completions`，Qwen2.5-7B-Instruct-Q4_K_M，三組各 15 場對話跑到
10 輪上限）。「平均收尾輪次」分母是有主動收尾的場次，不是全部 15 場：

| 組別 | system prompt | 主動 `end:true` 收尾比率 | 平均總輪數 | 平均收尾輪次（僅計主動收尾場次） |
| --- | --- | --- | --- | --- |
| A（現況對照，無提示） | 逐字照抄目前的 `DIALOGUE_SYSTEM` | 40.0%（6/15） | 9.80 | 第 8.5 輪 |
| B（軟壓力） | A 組加一句「`context.turns_so_far` 越大越該找自然的點收尾」 | 93.3%（14/15） | 8.87 | 第 7.8 輪 |
| C（軟壓力＋收尾語氣要求） | B 組再加一句「`end:true` 那句話本身要讀起來像實際道別，不能只是把前面講過的話原樣重複、單純把旗標翻成 true」 | 100.0%（15/15） | 6.80 | 第 5.8 輪 |

單純加「該收尾」的提示（B 組）能把主動收尾比率從 4 成拉到 9 成以上，但人工
檢視內容發現不少場次的 `end:true` 貼在跟前面同一種空話重複的句子上（例如
「同意，共同努力讓村子更美好！」），不是真正的道別語氣。額外明講「收尾
那句話本身要像道別」（C 組）在本次樣本中同時改善了比率與內容品質：比率拉到
100%、平均輪數降到三組最低，收尾句幾乎全是真正的道別語（「再見」「明天見」
「路上小心」）或有語境的收尾陳述。這是單一本機模型、兩個人設、每組 15 場的
小樣本結果，尚未驗證其他模型與 provider 是否同樣成立。**C 組是三版裡最值得
接回 `DIALOGUE_SYSTEM` 的候選文字**，候選文字本身見
`note/ai/soft_pressure_experiment/報告.md`「方法」一節——原始資料與執行腳本
不進版控，這份報告是唯一可查閱的產出。**尚未接回 `DIALOGUE_SYSTEM`**——這裡
只確認本次樣本方向有效，真的把 `turns_so_far` 欄位與 C 組提示文字接進
`Ailley/scripts/ai/prompt_builder.gd`／`build_dialogue_envelope()` 留給下一則 issue。

但兩隻 Agent 都禮貌性不收尾時，`conversation.gd`
的 `SAFETY_MAX_TURNS`（工程安全閥，跟上面的設計軟壓力是兩回事，同時也是無觀眾
世界的 LLM 呼叫成本閘門，issue #178）會強制截斷，值訂為 **10**。10 是三份獨立
證據（實測、poc_village_sim 導演模式 B、poc_village_sim 逐 tick 對話追蹤）的
保守交集值，不是精算出來的：本機小模型多輪對話品質實測 6 輪起始退化、
10 輪偶爾明顯退化（見下方「已測試過但沒有效果的方向」），超過這個範圍
的對話多半已經不值得再付費續下去。記憶注入上線後每輪 payload 都會變大，
退化點可能提前，屆時應針對現在的逐輪架構重新實測。

對話呼叫（`CONVERSATION` policy）豁免 `min_interval_sec`／`max_calls_per_game_day`
這兩條限制時，另外走 `max_dialogue_calls_per_game_day` 這個獨立旋鈕封頂
（#434，落地見下一節）——`SAFETY_MAX_TURNS` 封頂的是單場對話的輪數，這個旋鈕
封頂的是一天能開幾場對話／講幾輪，兩者互補不重疊。`dialogue_exempt=false` 時
對話呼叫改走一般 `max_calls_per_game_day` 路徑，這個旋鈕形同虛設（不需要，見
下一節說明）。「有沒有玩家在觀察」的節流判斷，#178 討論過後刻意不做（範圍太大，
需要新的「是否被觀察」偵測邏輯），留給之後想做更完整方案時另開 issue。

### 每日對話呼叫上限（#395／#434）

實測「一場對話平均幾輪」：用本機 `local` provider（Qwen2.5-7B-Instruct-Q4_K_M）
在 `main.tscn` 直接建立 `Conversation` 節點（繞過 `talk_to()` 的距離判定，
角色互相傳送到同一點後開始對話），跑 **6 場對話樣本**，逐場記下 `_turns.size()`
與收尾類型：

| 場次 | 雙方 | 輪數 | 收尾類型 |
| --- | --- | --- | --- |
| 1 | 小滿／阿虎 | 5 | 正常收尾（`end=true`） |
| 2 | 阿吉／阿嵐 | 9 | 正常收尾（`end=true`） |
| 3 | 小滿／阿虎 | 11 | 撞到 `SAFETY_MAX_TURNS` 安全閥截斷 |
| 4 | 阿吉／陳婆 | 4 | 正常收尾（`end=true`） |
| 5 | 阿嵐／小滿 | 4 | 正常收尾（`end=true`） |
| 6 | 阿吉／小滿 | 9 | 正常收尾（`end=true`） |

平均 **7.0 輪／場**（n=6，範圍 4–11）。另有 1 場因陳婆當時觸發昏迷送醫治療
（#347，跟這次量測無關的既有機制）中途被中斷，樣本捨棄不計。跟這份筆記
上方「已測試過但沒有效果的方向」記錄的退化門檻（6 輪起始退化、10 輪偶爾
明顯退化）對照，這裡把「退化區間」定義為 **6–10 輪（含邊界）**：第 3 場
（11 輪，撞 `SAFETY_MAX_TURNS`）已在上一句另計，不重複算進本區間；其餘
5 場裡，第 2 場（9 輪）與第 6 場（9 輪）落在 6–10 輪內結束，第 1／4／5 場
（5／4／4 輪）在區間之前就已收尾——共 **2/6** 落在退化區間內。

> [!warning] n=6 太小，不足以支持「常態性」這種頻率結論（CodeRabbit review 抓到）
> 本次樣本裡 `SAFETY_MAX_TURNS` 被觸發 1/6 場——這只是「本次樣本觀察到一次」，
> 不能推論成「這道安全閥常態性地會被用到」，安全閥實際被觸發的頻率需要更大
> 樣本才能下結論，這裡先只記錄樣本事實，不做外推

<!-- -->

> [!warning] 「撞到安全閥」是這次量測當下人工肉眼觀察記錄的，不是程式自動分類（CodeRabbit review 抓到）
> `conversation.gd::_run()` 目前對「說話者自己回 `end=true` 收尾」與「耗盡
> `SAFETY_MAX_TURNS` 被強制截斷」發的是同一個 `ENDED_BY_SPEAKER`，表格裡第 3
> 場「撞到安全閥」的註記，是量測當下盯著跑、親眼數到第 11 輪被截斷才記下來
> 的，程式本身讀不出這個區別。要讓這個量測能被重複驗證、不用再人工盯場，
> `_run()` 要先分出獨立的 termination reason（例如安全閥截斷另給
> `SAFETY_TRUNCATED`），這是另一件事，不在這則研究範圍內，這裡先誠實記錄
> 這個方法論限制

**實作**：比照既有 `min_interval_sec`／`max_calls_per_game_day` 這兩個數值型
旋鈕的模式，`ai_config.json` 有第三個數值型全域旋鈕
`max_dialogue_calls_per_game_day`（可設 0＝不限，跟前兩者一致，預設 150）。
`dialogue_exempt` 是布林豁免開關，不是數值上限，不適用「0＝不限」——
它只控制 `CONVERSATION` policy 是否豁免既有的 `min_interval_sec`／
`max_calls_per_game_day` 檢查，跟這個旋鈕各自獨立、互不影響。
`AIService._check_rate_limit()` 判斷 `CONVERSATION` policy 且豁免成立時額外檢查
`_dialogue_calls_today[requester_id]` **達到或超過**這個值（`count >=
max_dialogue_calls_per_game_day`，不是 `>`——跟既有
`_check_rate_limit()` 對 `max_calls_per_game_day` 的判斷式一致，
`count > max` 會讓計數剛好等於上限那一次仍被放行），達到就回傳跟現有
冷卻／配額檢查一樣的 `{"ok": false, ...}`。**沒有額外的降級邏輯**：
`next_line()` 收到 `ok=false` 走既有路徑，
`conversation.gd::_finish_with_fallback()` 靜默結束、不補台詞（issue #949），
跟現有 LLM 失敗／逾時的降級一模一樣，只是提早收尾。
>
> [!important] 這個旋鈕只在 `dialogue_exempt=true` 時才有意義（CodeRabbit review 抓到）
> `_is_exempt(policy)` 只有 `policy == CONVERSATION and dialogue_exempt` 才成立；
> `dialogue_exempt=false` 時 `CONVERSATION` 請求走的是一般 `_calls_today` 路徑，
> `_dialogue_calls_today` 永遠是 0，這個新旋鈕檢查的計數器形同虛設。但這不是
> 疏漏要補一個獨立計數器——`dialogue_exempt=false` 代表玩家已經選擇讓對話呼叫
> 吃現有的 `max_calls_per_game_day`（跟 plan／reflection 共用同一份配額），
> 這種設定下對話本來就已經被管控，不需要疊加第二層限制。這個旋鈕要解決的
> 缺口只存在於 `dialogue_exempt=true`（對話完全豁免既有限制）的情境，範圍要
> 這樣講清楚，不是無條件對兩種設定都生效

**起始值 30 的推算方法論（#395）**：目前預設值是 150。這次記的樣本是
`_turns.size()`（對話輪數），不是真正的 `AIService.request()` 呼叫次數。這次樣本測的是
舊版行為——開場白當時還是 `DialogueLines.opening()` 寫死的模板句，不打 LLM，
7.0 輪／場扣掉這句開場白，換算成雙方合計約 6.0 次呼叫／場。開場白改成一律過
LLM 之後（issue #630／《99》P-67），這個扣減不再成立，同一份 7.0 輪／場的樣本
换算下來會更接近
**7.0 次呼叫／場**（每一輪都打 LLM）；這個數字本身也是舊樣本套新規則的
粗算，不是重新量測的結果。
>
> [!warning] 配額 scope 是 per-`requester_id`（單一角色），不是 per-對話（CodeRabbit review 抓到）
> `_dialogue_calls_today[requester_id]` 算的是**單一角色**今天講了幾輪，不是
> 一場對話兩隻角色合計打了幾次。上面「7.0 次呼叫／場」是雙方合計，若對話
> 輪流發言、大致平均分攤，換算成單一角色的負擔是約 **3.5 次呼叫／場**——30
> 次配額對單一角色來說約可撐 **8～9 場**均值對話，不是拿雙方合計數去除的
> 場次。這個換算本身也只是「輪流均分」的粗略假設，實際上兩隻角色誰先開口、
> 誰講得多不會完全對半分，正式訂數字前要用同一個 per-角色口徑重新記樣本，
> 不是延用這次雙方合計的數字
>
> 「對話單輪成本遠低於一次完整 `plan`／`reflection` 呼叫」也只是**未驗證的
> 假設**，不是量過的事實——`build_dialogue_envelope()` 每次都會把目前為止
> 完整的對話輪次歷史序列化進 payload，對話越長單輪的 payload 越大，不是
> 每輪固定的小開銷；`_decide_with_retry()` 的驗證失敗重試也會讓實際
> `AIService.request()` 次數比輪數本身更多。這兩個因素都會讓真正的呼叫
> 次數／成本比這次的粗算更高，「30」這個數字在兩者都還沒實測之前只能算
> 這次量測給出的一個起點，不是已經校準過的建議值

正式上線前建議搭配大規模驗證一併校準，逐場記錄真正的 `AIService.request()`
次數（依 per-角色 scope 分開記）、payload 隨對話輪次成長的實際大小、以及
驗證失敗重試的發生率，這三項都還沒有數據支持目前 150 這個預設值。

> [!important] 但 fallback 一定要能終止
> LLM 失敗／逾時時 `conversation.gd::_finish_with_fallback()` 直接靜默結束、
> 不補台詞（issue #949），不會有「拿不到 `end` 訊號就無限吐台詞」的循環。

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
`{id, text, is_done}`。欄位對齊 `scripts/database/schemas/NPCDailyPlanSchema.gd`
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

## 約定機制（appointment，#479，《10》§5.5）

**資料形狀**：`Agent._appointment`，單一 `Dictionary` 或 `null`，同時間只追蹤
一筆——新宣告整筆覆蓋舊的，跟 `_today_plan` 的「重寫」語意一致，不是陣列
累加。欄位：`with`／`location`／`game_time`（模型填的原始字串）、
`game_time_minutes`（驗證層算好的絕對分鐘數，`day*1440+hour*60+minute`）、
`reminder_sent`／`waiting_since`（引擎自己記帳的階段旗標，不是模型填的）。

**輸出端**：條件式欄位（《12》§2.4，加入條件「對話情境中且在場有其他角色」）
——跟 `allow_update_plan` 同一種「文法層面就不存在這個選項」做法，但**不是**
`_request_next_decision()` 內部現算 `is_in_conversation()`：仲裁器裡這個條件
唯一真正成立的時刻是 `Agent.exit_conversation()` 剛講完話那一刻，而那個呼叫點
在 `super()` 把 `_conversation` 清成 `null`、對話已經結束之後才觸發下一次決策，
現算會永遠讀到 `false`。改成跟 `allow_update_plan` 同一種「呼叫端自己判斷、
往下傳」做法：`_request_next_decision(allow_update_plan, allow_appointment)`
多一個參數，只有 `exit_conversation()` 那個唯一對應觸發點傳 `true`，其餘呼叫
處維持預設 `false`。`game_time` 固定格式「第D天 HH:MM」
（`AISchema._parse_appointment_game_time()` 手動解析，GBNF 轉換器不處理
pattern 這類字串格式約束，格式與未來時間的檢查落在驗證層；時／分兩段都要求
剛好兩位數，`9:00`／`09:0` 一律拒絕），格式錯或指到過去/現在整包拒絕，跟
`update_plan` 陣列格式錯同一種「條件式欄位格式不對就讓整份回應失敗」的立場。

**產生約定時**：`Agent._apply_appointment()` 同步把一筆摘要 append 進
`_today_plan`（《10》§5.5「不另外詢問 AI」），不透過 `update_plan` 那套整份
取代機制。

**三個時點**（`Agent._process_appointment()`，掛在 `GameClock.time_changed`，
`_on_time_changed()` 裡 `_reevaluate()` 之前跑）：

| 時點 | 行為 |
| --- | --- |
| 約定前 30 分鐘 | 提醒事實句，只給宣告方（`_pending_fact_lines`） |
| 約定時間到 | 用 `_actual_place_of()`（即時位置反查，不是 `current_place`——那是任務目的地不是即時座標）判斷自己在不在場；不在場＝爽約，立刻通知，睡眠中則暫存到 `_appointment_broken_pending_line`，`_on_time_changed()` 偵測到睡醒轉換時補送 |
| 等待期滿（+30 分鐘） | 自己在場的話，這段期間持續檢查對方（`_find_character_by_name()` 找到的 `Character`）是否出現在同一地點；出現了悄悄結束、不通知，沒出現則在期滿當下通知等待方 |

「單方面宣告的約定」不需要額外處理：`_process_appointment()` 只讀
`self._appointment`，未答應的一方從沒呼叫過 `_apply_appointment()`，自然
不會收到任何提醒——不對稱是設計本身。

死亡／昏迷狀態機尚未接上（見 #379），爽約延後通知目前只處理睡眠，不含
「昏迷」那個分支；#379 merge 後需要回頭補上。

好感度變化與情緒反應不由引擎處理，全部交給 AI 自己決定（《10》§5.5、《00》
原則二）——這裡完全沒有寫任何 relations／emotion 的自動調整。

## 正式線實作順序（Step 0-4 全部完成）

### Step 0 — 底層 ✅ 完成

`ai_config.gd`／`ai_service.gd`／`ai_schema.gd`／`data/ai_config.example.json`，
autoload 已註冊，主控台加了 `ai` 指令。

- `request(envelope, requester_id, policy)`：`enum Policy { SCHEDULED, CONVERSATION, CREATION }`，
  `CONVERSATION`／`CREATION` 跳過冷卻與每日配額但照樣計數（分別走獨立的
  `_dialogue_calls_today`／`_creation_calls_today`），`CREATION` 是建角一次性生成
  （words_to_creator，#682），預設 `SCHEDULED`——忘了指定的呼叫端落在保守那邊，
  不會意外拿到無限額度
- 速率限制旋鈕搬進 `user://ai_config_<hash>.json`（皆可設 0＝不限），預設值與規格數值
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
`AIService`，`conversation.gd` 改成非同步、等台詞時掛「…」氣泡、拿不到就靜默
結束（issue #949）。`MAX_TURNS` 換成 `SAFETY_MAX_TURNS`（純保險，收尾由 `end` 欄位決定），
`character.gd` 有 `signal spoke`，玩家在對話中打的字也送得進上下文。

開場白（turn 0，被搭話的一方）也一律過 LLM（issue #630／《99》P-67），多開放
一個 `engage` 欄位，可以選擇不理會這次搭話；LLM 呼叫失敗時靜默結束、不補
台詞（issue #949）。

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
decision_provider.gd`）：`LocalLLMProvider`／`RemoteLLMProvider` 建構時都帶入
`model_name`（對應《06》，建角面板 local／cloud 兩個分頁下拉選單選的型號），
兩者都是 `AIService.request()` 的薄包裝，行為不變。

`model_name` 是空字串（MVP 5 個排程 NPC 沒走建角面板，這個欄位維持預設空值）
時，`LocalLLMProvider` 退回打 AIConfig 裡字面值叫 `"local"` 的 provider——
玩家的 `ai_config.json` 不保證真的有一個可用的 `"local"`——可能只設了
`default_provider`、取了別的名字，或有這個項目但 `base_url`／`model` 沒填齊。
`LocalLLMProvider._init()` 因此再用 `AIConfig.has_valid_provider("local")`
解析一次：不成立就 `push_warning` 並改傳空字串，交給 `default_provider`。
硬傳 `"local"` 的話這些情況一律是 `ERROR_NO_PROVIDER`，角色決策整個安靜啞掉。
解析放在 `_init()` 而不是 `decide()`：設定在一場遊戲內不會變，放 `decide()`
的話設定真的缺 `"local"` 時每次決策都洗一行警告。

檢查一律用 `has_valid_provider()` 而不是 `has_provider()`——後者只查設定項
存不存在，但 `AIService.request()` 擋的條件是 `provider == null or not
provider.valid`，只查存在會放行設定不全的項目、然後每次請求安靜失敗。

每隻 Agent 出生時依 `decision_source`（`@export`）建一次 provider，存成
`_provider` 成員變數，之後所有決策／對話呼叫都用它——對應《06》
「`decision_source`／`model_name` 投放後不可改」，不是每次呼叫才重新判斷。
`decision_source`／`model_name` 這兩欄由 #122 的建角面板寫入、經
`GameManager.deploy_from_library()` 在投放當下套進節點，不再是佔位值。

> [!warning] 套欄位跟建 provider 的時序要對：套完要重建，不能只 set 完就算了
> `spawn_character()` 內的 `add_child()` 會同步觸發 `_ready()`，`_provider`
> 那時候就照 `@export` 當下的值（預設 `"local"`）建好了；`deploy_from_library()`
> 是在 `spawn_character()` **回傳之後**才 `set()` 建角面板選的
> `decision_source`／`model_name`，這時候才 set 已經來不及讓 `_provider`
> 讀到新值（CodeRabbit review 抓到）。解法是 `agent.gd` 開一個公開的
> `rebuild_provider()`（內容就是重跑一次 `_provider = _make_provider()`），
> `deploy_from_library()` 套完兩個欄位後接著呼叫它。

三種資料異常都安靜退回 `LocalLLMProvider`、`push_warning` 帶原因：
`decision_source` 打錯字／空字串（含合法但未實作的 `"human"`，見下方
「不在這一版」）；`"cloud"` 但 `model_name` 是空的；`"cloud"` 但 `model_name`
沒有對應的可用 provider。

> [!warning] `model_name` 存的是型號字串，不是 provider 名字——查表方向要反過來
> 《06》規格與範例（`"model_name": "qwen2.5-7b-instruct"`）明講這欄是給玩家看
> 的型號，不是 `AIConfig.providers` 字典的 key（如 `"openrouter"`，那只是玩家
> 自己取的代號）。所以 `_make_provider()` 的 `cloud`／`local` 兩個分支都不能拿
> `model_name` 直接當 key 查 `AIConfig.get_provider()`（那是 #155 一開始 `cloud`
> 分支的寫法，找不到會誤判成「provider 不存在」），要用
> `AIConfig.get_provider_by_model(model_name)` 反查——掃所有 provider 找
> `.model` 相符的那一個，再用那個 provider 真正的 `.name` 建構
> `RemoteLLMProvider`／`LocalLLMProvider`（#288，兩者現在共用同一套查表邏輯）。

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

- **記憶系統的 SQLite 存檔路徑** —— L1-L4 資料結構、事件→候選記憶生成
  pipeline、prompt 注入（L2＋L4）、JSON 存檔持久化都已完成（issue
  #167／#168／#169／#170，細節見 [[記憶與睡眠反思]]、[[存檔]]），但只接了
  `JsonSaveService`：`SqliteSaveService` 尚未讀寫 `memory` 欄位，SQLite
  round-trip 會遺失記憶（見 [[存檔]]「SQLite 後端現況」）
- **交誼區 WebSocket 線** —— 伺服器技術棧尚未決定，見 #476
- 白名單中除 `move_to` / `talk` / `sleep` 外的動作實作——白名單本身已經是
  《07》《11》拍板的 22 個（issue #88），但 `IMPLEMENTED_ACTIONS` 沒有跟著擴
- `speech` 觸發對話交接（issue #90）
- `HumanInput`（#156）／`RemotePlayer`（見 #478）——《12》§3.3 另外兩種
  DecisionProvider 來源

## 待決（正式線）

- [x] **「…」氣泡擴大套用到行程決策已落地**（#480，2026-08-27）：`_request_next_decision()`
      套用跟 `next_line()` 同一招，細節見下方「延遲」一節
- [x] **LLM 成本上限完全沒有防護**——研究與提案已由 #395 完成（本機
      Qwen2.5-7B，6 場對話均值 7.0 輪／場，`max_dialogue_calls_per_game_day`
      旋鈕設計案見上方「每日對話呼叫上限提案」一節），落地實作見 #434
- [x] **軟壓力研究結果已確認**（#482，2026-08-23）：A/B/C 實測見「界線：軟壓力為主，
      工程安全閥兜底」一節
- [ ] **軟壓力尚未接回 `DIALOGUE_SYSTEM`**：`turns_so_far` 欄位與 C 組提示文字接進
      `prompt_builder.gd`／`build_dialogue_envelope()`，列為後續 issue
- [ ] 尚未對真正的 OpenRouter 打過請求，TLS/DNS 與真實回應格式未驗證，見 #483
- [x] 成本上限機制的具體設計——同上，見 #395／#434
- [x] **對話逐字稿暫存——拍板不做**（#485，2026-08-21）：`spoke` 訊號與
      `Conversation.turns` 現在都沒有任何暫存，也沒有已排入計畫的功能在讀取
      逐字稿（回放對話、用逐字稿重新生成記憶都還沒排）。加暫存機制屬於「為
      假設性需求先做設計」，且現有記憶系統（L2/L4）都還沒接上
      `SqliteSaveService`（見上方「不在這一版」），先不加這份新資料結構。
      等真的有具體功能要用逐字稿時，另開 issue 決定要存記憶體還是存
      SQLite——不現在先做記憶體版本，之後又要重做
- [x] `response_format`／GBNF 強制路徑，與不送 `response_format` 的純 prompt
      對照組，模型端可靠度差異（issue #245，2026-08-17；補測 2026-08-18，兩輪
      合計、可重現性資訊、逐筆原始結果見《12》§7.3）：地端 provider 對兩者
      （`supports_json_schema` 開關）各實測兩輪、合計 **100 次**，GBNF 強制
      100/100 全過零失敗，純 prompt 約束（`supports_json_schema=false`，不送
      `response_format`）97/100（第一輪 3 次 `action_not_allowed`，模型自己
      生成白名單外的 action，例如 `"work"`；第二輪 50 次全過，沒有重現），沒有
      出現社群回報過的 json_schema/grammar 衝突錯誤；合成的壞掉回應（缺欄位、
      白名單外、型別錯）也測過 layer 2/3 的退場路徑，`AISchema.validate_tasks()`
      全部正確擋下，`_decide_with_retry()` 的重試機制實測會真的觸發，不只是理論
      上存在。GBNF 文法層強制比純 prompt 約束實測更可靠，剛好是現行預設值；
      純 prompt 約束的失敗率落在個位數百分比，第一輪「6%」只是小樣本粗估

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

## 延遲：實測 2.5-4 秒，體感層面靠「…」氣泡頂著

編輯器實測「玩家靠近就打一次決策」：從靠近到角色真的有反應中間約 2.5-4 秒
（時間主要花在 llama-server 的 grammar 約束生成，不是網路或 Godot 端）。
對「玩家靠近、期待即時反應」這種互動模式來說很明顯，玩家靠近後畫面上完全
沒有回饋、3 秒後突然講話/移動的話體感會很差。正式線接對話與行程時會碰到
同一個數量級。

**體感層面的解法（#480，2026-08-27 落地；#949 B 類改呈現方式）**：
`Agent._request_next_decision()` 在確定要送出請求、真正打網路之前，套用跟
`next_line()`（Step 1 對話）完全同一招——`thinking_indicator.show_indicator()`
在角色頭上冒 dots 動畫。不縮短延遲本身，只讓觸發當下不是死寂一片。決策回來
（`_awaiting_decision = false` 之後）呼叫 `hide_indicator()` 收掉。

> [!note] 指示的收掉時機
> `thinking_indicator` 有 `MAX_VISIBLE_SECONDS` 安全上限自己收——數值從
> `AIConfig.DEFAULT_TIMEOUT` 推導：最壞情況是 provider 逾時（20 秒，#852）後
> 驗證失敗重試最多 2 次（`remote_llm_provider.gd::max_validation_retries()`），
> 1＋2 次都吃滿逾時再加 5 秒 margin，合計 65 秒。
> 正常情況下決策回來（`_awaiting_decision = false`）就主動 `hide_indicator()`，
> 撐得滿 2.5-4 秒的實測延遲。`next_line()`（對話思考）不走這個收掉點，靠
> `say()` 收——拿到台詞開口說話就是「思考結束」最準的訊號。詳見
> [[talk 動作設計]]「系統正在等的指示不塞在對話氣泡裡」。角色停下腳步做
> 「在想事情」小動作是筆記原本提過的替代方案，沒有採用。

**縮短延遲本身的槓桿（另一方向，尚未實作）**：`REASONING_INSTRUCTION` 的
100 字上限是延遲/品質的直接槓桿，往下砍會更快但決策品質會掉；其他槓桿是模型
量化等級、llama-server 的 `--parallel` 設定，會影響全部呼叫，改動範圍更大。

## 動態投放到真正依任務移動：冷卻問題已修（PR #684），真正的卡點是空任務回應沒有補救機制（2026-08-28 實測）

`_generate_words_to_creator()`（`agent.gd`／`game_manager.gd` 各一份）在
#684 之前跟第一次 plan 決策共用同一個 `AIService.Policy.SCHEDULED` 冷卻池
（當時 `Policy` enum 只有 `SCHEDULED`／`CONVERSATION`），導致投放後多等一輪
完整冷卻（當時 30 秒）才送得出第一次決策。修法（issue #682，
**實作在 PR #684，已併入 main**）：新增 `AIService.Policy.CREATION`，讓這通
一次性生成呼叫無條件豁免冷卻與每日配額，不再跟決策共用池子。現在不管走
debug 主控台 `spawn` 還是正式的 `GameManager.deploy_from_library()`，
投放到送出第一次 plan 決策只要一次網路延遲（0.6-1.9 秒，量級同上一節
#118 校準值；此數值是在 #684 分支上實測的，已隨 #684 進 main），不再有那
30 秒——透過 `Continue`（讀檔重生）真實路徑重新投放已生成過 `words_to_creator`
的角色驗證過：`AIService.get_usage()` 顯示 `calls_today: 1`，沒有被搶先
佔用冷卻。

**冷卻修掉之後（#684），角色還是可能站著不動，原因換了一個**：任務池要真的有
東西，仲裁器才有東西可選。決策回應的 `tasks` 欄位允許回傳空陣列（規格
「不更新就是空陣列」），這是合法回應，不是驗證失敗。三隻分別測試過的
角色（正式投放的 Gandalf、debug spawn 的 Gandalf（複製）、小海）在
剛投放的頭幾輪決策，`reasoning` 都類似「沒有特定計畫，等待中」，回傳
`tasks: []`——這種情況下 `_current_task` 維持空字典，**沒有「動作完成」
這件事會發生，而目前唯一接上的重排時機正是「目前任務做滿」**（見
[[行程佇列與任務仲裁]]「什麼時候會請 LLM 重排」），所以角色會無限期
卡在原地，沒有任何機制會主動再問一次。

跟這個案例外觀相似但成因不同、容易搞混的是「模型回了一筆 `idle` 任務」
（有 `duration`，會真的進池子、被選中、佔滿 `_current_task`）——這種
情況角色一樣站著不動（`idle` 本來就是原地不動的動作），但 `duration`
到期後**會**正常觸發下一次決策，不會永久卡住。原始 Gandalf 那次實測
就是這個模式：連續好幾輪 `idle`（reasoning 分別是「看不到 player，可能
有問題」「村裡沒有玩家，沒有其他事情可做」）之後才轉成一筆 `talk`
（target: player）。**空陣列回應**跟**內容是 `idle` 的正常任務**是兩種
不同的「看起來都沒在動」，只有前者是真正卡死、需要補救機制；後者只是
需要多等幾輪 `duration`。

實測方法：`game_eval` 直接呼叫 `AIService.request()`／`AISchema.parse_completion()`／
`AISchema.validate_tasks()` 逐階段拆解，搭配 `AIService.get_usage(character_id)`
的 `cooldown_left` 欄位反推冷卻是在哪個時間點被佔用的——`game_eval` 有 8 秒
執行預算，一次性的長輪詢迴圈（例如 `for i in range(200): await create_timer(0.1)`）
會被腰斬成 `EVAL_HUNG`，殘留的 coroutine 之後再存取 `get_tree()` 會回傳
`null`，把整個遊戲行程頂進 debugger break（`project_manage(op="stop")`
可解除，不是真的崩潰）；改成多次分開的短呼叫，或直接 `await` 會自己
resolve 的呼叫（例如 `debug_set_llm_decision()` 本身回傳的就是 await 完的
結果字典），不要自己手動輪詢等待。

## 角色站著不動的第三種成因：readiness 快照過期，`llm_decision_enabled` 從沒被打開（issue #728，2026-08-30 實測）

跟上一節的「冷卻」「空任務回應」是三種外觀相同（角色不做事）但成因互斥的
情況，這裡是最上游的一種：角色投放當下 `activate_llm_decision_if_ready()`
（`game_manager.gd`）判定它的 provider 沒 ready，直接沒打開
`llm_decision_enabled`，連第一次 plan 決策都沒問過——不是冷卻卡住、
也不是空陣列回應，是決策迴圈從一開始就沒被啟動。

`AIService._check_readiness_all()` 只在 `_ready()` 開機那一刻、或有人手動
呼叫 `reload_config()` 時才會真的打網路探測，結果直接快取進 `_readiness`；
另外 `activate_llm_decision_if_ready()`（`game_manager.gd`）與
`main_scene.gd::_apply_startup_ai_state()` 在讀到「沒 ready」快照時也會
事件觸發補打一次（見下面「修法」），除此之外 `get_readiness()` 只是讀
這份快照，不會自己變新。
開機那次探測如果剛好撞上暫時性
網路問題（例如 Tailscale 重連、遠端 GPU 機器重啟），即使幾秒後連線就恢復
正常，這份「沒 ready」的快照會一直錯到底——沒有背景輪詢會自己修正它，而
`activate_llm_decision_if_ready()` 原本讀到「沒 ready」就直接 `return`，
完全靜默，看不出角色為什麼變殭屍。

**對話跟排程走的是兩條獨立的路，只有後者會被這個問題卡住**：
`Agent.next_line()`（對話開場白／回話）直接呼叫 `AIService.request()`，不看
`llm_decision_enabled`；只有「今天要做什麼」這條路（`_request_next_decision()`）
需要這個開關。所以卡到這個問題的角色會表現成「叫得動、會回話，但問不到
牠打算做什麼、永遠不會自己排新任務」。

**修法**：`activate_llm_decision_if_ready()` 讀到快照顯示「沒 ready」時，
不直接放棄——補打一次 `AIService.reload_config_and_wait()`（跟 debug 主控台
`ai` 指令同一個入口，會重新讀 `user://ai_config.json` 並重新探測），再讀一次
`get_readiness()`；這次還是沒 ready 才真的放棄，並且補一行 `push_warning()`
帶上失敗原因，不再靜默。代價是同一輪迴圈裡多隻角色一起撞到「沒 ready」
時，會各自觸發一次重複探測（世代編號機制保證結果不會互相污染，只是網路
請求數變多）——這則先接受這個代價，不做成單一入口的節流。

開機那一側（`main_scene.gd::_apply_startup_ai_state()`——場景固定 NPC 走的
就是這裡，投放／讀檔生成的角色才會經過 `activate_llm_decision_if_ready()`）
也接同一個補打入口：整批沒就緒的 Agent 共用一次 `reload_config_and_wait()`
再重新判定，不是逐隻各補打一次；補打後仍沒就緒的原因照舊寫進 HUD 的
「排程模式（原因：…）」指示。

實測方法：`game_eval` 直接改寫 `AIService.get('_readiness')` 裡的快取值成
`ready: false`，模擬「開機探測剛好失敗」的情境，分兩種情境驗證：
連線其實正常時（真實 provider 可連），補打的那次探測會成功、
`llm_decision_enabled` 正確變 `true`；連線真的斷掉時（`base_url` 指到一個
不存在的位址），補打的那次探測也失敗，`llm_decision_enabled` 維持
`false`，且遊戲 log 印出 `GameManager: <角色名> 的 provider「<name>」未就緒，
llm_decision_enabled 沒有打開（<原因>）`。

## 正式版玩家的第三個補救入口：手動按鈕＋跨日背景重試（issue #824，2026-08-31 實測）

上一節的兩個補打入口（`activate_llm_decision_if_ready()`／
`_apply_startup_ai_state()`）都只在各自的觸發時機（單一角色投放、場景
開場）補打一次，救不了「已經在場上、早就被判定失敗」的既有角色——如果
玩家在開場那一刻本機 LLM 還沒下載完、之後才補好設定，場上既有角色會
卡在排程模式一整局，唯一的補救指令 `debug` 主控台的 `ai_decision` 在正式
建置整個關閉（issue #356）。

**`GameManager.recheck_ai_readiness() -> Dictionary`**：第三個補打入口，
遊戲執行期間任何時候都能呼叫。收集場上所有 `not llm_decision_enabled` 的
Agent；一個都沒有時直接回傳、完全不打網路（低頻背景重試不會造成不必要
網路負載的關鍵）；否則整批共用一次 `AIService.reload_config_and_wait()`
再逐一重判，就緒的呼叫 `debug_set_llm_decision(true)`，仍未就緒的把
`reason` 收進去重後的字典。回傳 `{checked, recovered, reasons}` 給呼叫端
組訊息。

兩個呼叫端：

- **手動**：Esc 選單新增「重新檢查 AI 連線」按鈕（`esc_menu.gd`），按下呼叫
  這個函式，依 `checked`／`recovered` 組一句狀態文字顯示在按鈕下方
  （沒有卡住的角色／N／M 位已恢復／仍未就緒），跟 `_on_exit_pressed()`
  同一種旗標＋停用按鈕擋重入寫法。
- **背景**：`GameManager._ready()` 訂閱 `GameClock.day_changed`，每遊戲日
  觸發一次 `call_deferred("recheck_ai_readiness")`——跟既有的
  `_on_day_changed_autosave()` 同一個 `call_deferred` 寫法。

實測方法：`project_run` + `game_eval` 對 `main.tscn` 活場景驗證。本機沒有
llama-server 在跑，`local` provider 的探測固定逾時（約 10 秒，
`http://127.0.0.1:8080/v1/models` 逾時連不上），三種情境都在這個「仍未
就緒」的真實條件下驗證：

- 場上沒有卡住的 Agent 時，`recheck_ai_readiness()` 立即回傳
  `{checked:0, recovered:0, reasons:{}}`，不觸發任何網路探測。
- 兩隻 Agent 同時卡在 `llm_decision_enabled=false` 時，批次呼叫回傳
  `{checked:2, recovered:0, reasons:{"逾時連不上…":true}}`，去重後的
  `reasons` 字典正確。
- Esc 選單按鈕實際點擊（`editor_screenshot(source="game")` 截圖確認排版：
  選單自動撐開容納新按鈕與狀態文字，沒有裁切），驗證過「沒有卡住角色」
  與「仍未就緒」兩種狀態文字都正確顯示。
- 手動推進 `GameClock` 跨過午夜觸發 `day_changed`：`AIService._readiness_generation`
  在每次跨日時遞增（證實真的又打了一輪網路探測，不是掛著沒動），
  探測結束後 `_pending_readiness_count` 歸零、遊戲沒有卡進 debugger break。

「連線恢復後 `llm_decision_enabled` 正確變 `true`」這條路徑沒有另外重測——
`recheck_ai_readiness()` 呼叫的 `reload_config_and_wait()` → `get_readiness()`
→ `debug_set_llm_decision(true)` 序列跟 `activate_llm_decision_if_ready()`
逐字元相同，上一節已經用真實可連的 provider 驗證過這段序列本身是對的。

## 兩隻 AI 同場互看：機制上通，但沒觀察到真的互相搭話（2026-08-28 實測）

在同一個場景同時開兩隻角色的決策迴圈（同一位置、`vision` 確認互相看得到
對方），驗證了幾件事：

- `AIService` 的用量統計（`calls_today`／`cooldown_left`／配額）是逐
  `requester_id`（`character_id`）分開算的，兩隻角色同時打不會互相污染
  彼此的冷卻或配額。`pool_size=3` 的節點池排隊行為見下一節（issue #867，
  2 隻角色的規模不足以撞到 3 個節點的上限，沒測到東西不代表沒有風險）
- `context.visible` 確實會把另一隻看得到的 NPC 列進去，`talk`／`give`／
  `persuade`／`attack` 這幾個需要 `target` 的動作理論上都能選到對方
  （不是只能選玩家）
- 但這次兩隻測試角色頭幾輪決策都回傳空 `tasks`（見上一節），沒有實際
  觀察到 NPC 對 NPC 的 `talk`/`give`/`persuade`/`attack` 真的被選中執行
  ——這條路徑機制上打得通，但端到端沒有被這次測試驗證到，需要更長的
  觀察窗（或用 `debug_push_task()` 強制塞一筆去驗執行層）才能確認

## 節點池 pool_size=3 在併發下確實會排隊，但目前 5 隻村民的規模不需要調高（issue #867，2026-09-02 實測）

- 用 `game_eval` 直接對 `AIService.request()` 發 5 筆併發 `SCHEDULED` 請求
  （跳過角色投放與 `debug_set_llm_decision()` 的 readiness 關卡，直接測
  `AIService` 自己的池子邏輯——這條路徑跟真正角色的決策請求完全共用同一個
  `request()`/`_pump()`/`_queue`，測起來等價，而且不用等真的 LLM 伺服器）：
  `_busy` 立刻頂到 3（`pool_size` 上限），剩下 2 筆進 `_queue` 排隊——
  `get_usage()` 回傳的 `in_flight`/`queued` 精確反映這個狀態，跟設計文件
  （見 `main_scene.gd::_apply_startup_ai_state()` 的註解）描述的機制一致。
- 逾時（`RESULT_TIMEOUT`）確認不會在 `AIService` 這層重試（`_interpret()`
  明寫理由：已經燒掉一整個 timeout，重試等於讓呼叫端等兩倍），所以每個
  卡住的請求只佔用節點池一次 timeout 的時間，不會因為內部重試被拉更長。
- 目前場上固定村民只有 5 隻（`npc001`／`npc002`／`npc003`／`npc004`／
  `npc006`），只有開場那一刻全部一起補打第一次決策時才可能同時逼近 5 個
  並發（`main_scene.gd` 的補打迴圈刻意不逐隻 `await`，就是為了讓池子／
  佇列自己排，見它自己的註解）；遊戲中途的排程觸發是事件驅動、不是固定
  tick，天生會錯開，正常遊玩幾乎不會有 5 隻同時打。結論：以目前的角色
  規模，`pool_size=3` 最壞情況只會讓 2 隻角色的第一次決策多等一輪
  （timeout 從 10 秒調到 20 秒之後，這個「多等一輪」的代價也從約 10 秒
  變約 20 秒——這是 #866 調高 timeout 帶來的真實副作用，量級不大但存在），
  不到需要調高 `pool_size` 的程度；角色數量之後如果明顯超過 5，這個結論
  要重新評估。

### 測試環境的連線逾時雜訊（跟上面同一批測試，不是 AIService 的問題）

刻意讓 `local` provider 連不上（不啟動 llama-server）來製造保證逾時的請求時，
觀察到 `HTTPRequest` 實際耗時遠超過設定的 `timeout`（例如把 timeout 設成
3 秒，實測要 9-10 秒才真的 `RESULT_TIMEOUT`；預設 20 秒的話超過 60 秒還
沒逾時）。用 PowerShell `Test-NetConnection 127.0.0.1:8080` 直接測純 OS
層級的 TCP 連線，同樣要 18 秒才回報連不上，證實這是**這台測試機的網路
堆疊**本身回應 ECONNREFUSED 就慢，不是 Godot `HTTPRequest.timeout` 或
`AIService` 沒有正確設定逾時。有沒有讓遊戲視窗拿到 focus 對這個延遲沒有
影響（兩種都測過），排除了《Ailley/CLAUDE.md》「headless 環境 HTTPRequest
較慢」那條警告的適用範圍——這次是在編輯器 Play 模式測的，一樣慢。

對上面 `pool_size` 的結論沒有影響——池子／佇列機制本身測得到、行為正確；
這裡只是誠實記錄「本機連不上時卡住多久」這個秒數在這台機器上量不準，
換一台機器實測可能更接近設定值。真正會影響玩家的情境（本機模型真的在
跑、只是回應慢）沒有這層環境雜訊，`timeout` 秒數本身仍然可信。

## 投放位置沒有邏輯，落在跟玩家無關的世界原點（issue #685，已修，PR 待開）

`spawn_character()` 原本完全沒有指定投放位置，動態生成的角色一律停在
`Node2D` 預設座標 `(0, 0)`。實測：玩家出生點 `(-94, 33)` 距離世界原點
約 99.6px，剛好落在角色 vision 半徑（80px，5 格 tile）之外——新投放的
角色一睜眼就看不到玩家，`context.visible` 通常是空的，這是上面「空任務
回應」問題最常見的觸發源頭：不是模型不想規劃，是它睜眼看到的世界本來
就空的。兩隻以上動態角色同時投放（例如 debug 主控台連續 `spawn`）會
全部疊在同一個 `(0,0)`，彼此看得到但一樣看不到玩家。

修法：`spawn_character()` 在 `add_child()` 之後把新角色的 `global_position`
設成 `PlaceAnchors`（`get_tree().get_first_node_in_group("place_anchors")`，
見 `places.gd`）底下 `pavilion`（涼亭）錨點的座標——規格書裡本來就是
社交聚集地，語意上最合理；錨點找不到就維持原點，不讓投放整個失敗。
實測驗證：投放後 `global_position` 精確落在 `anchors.resolve("pavilion")`
回傳的座標上。

## 真實死亡個案：決策鏈沒斷，是執行鏈斷了（2026-08-28）

玩家自建角色「000000」投放後遊戲時間過了約 28 小時（對應約 28 分鐘現實
時間）沒有離開涼亭附近，存檔顯示瀕死：

```
is_dead: false, health: 18.0
hydration: 0.0, satiety: 0.0, wakefulness: 0.0, stamina: 8.0
is_exhausted: true
today_plan: "喝水和吃飯"（從頭到尾沒變過）
```

`today_plan` 一直是「喝水和吃飯」，代表模型的判斷完全正確、也沒有放棄
這個意圖——**決策層沒有問題**。真正斷掉的是執行層：`eat`／`drink` 從
角色自己背包找東西（`_find_food_slot()`／`_find_drink_slot()`），新投放
或玩家自建角色預設背包是空的；唯一能補貨的 `buy` 又因為上一節「LLM 從
沒被告知地點清單存在」幾乎打不中。結果是模型每輪都誠實地想吃飯喝水，
每次都因為背包沒東西而執行失敗，四項核心生存數值一路歸零，health 被
拖到瀕死邊緣——**這代表 #605／PR #647（地點清單）不只是「決策內容比較
豐富」的體驗改善，是攸關新角色存活與否的必要修復**，應優先合併。

## `move_to`／`buy` 打不到：LLM 從沒被告知地點清單存在（issue #605，PR #647 進行中）

`prompt_builder.gd::build_plan_envelope()` 送給模型的 `context` 只有
`visible`／`pool`／`today_plan`／`fact_lines`／`memory`，沒有任何「這個
村子有哪些地點」的欄位。`ai_schema.gd` 對 `buy`／`move_to` 的 `place`
參數也只驗證非空字串，不驗證是否真實存在——模型因此只能盲猜地點代號
（`home`／`herb_shop`／`tavern`／`pavilion`／`god_stone`／`cemetery`
這幾個 `PlaceAnchors` 底下的真實名字），實務上幾乎不會被選中。

issue #605／PR #647（draft，跟 #644 一起修）已經在補：`prompt_builder.gd`
新增 `_shop_summary()`，把全村販賣機的 `{place: {item_id: price}}` 塞進
`_self_block()`（plan／dialogue 共用），直接解掉 `buy` 這半；`#644` 順便
把 `persuade` 的 appointment 地點也改成動態帶入 `PlaceAnchors.list()`。
**但 #647 的範圍只涵蓋販賣機清單，不是一般性的地點清單**——`move_to`
去涼亭純社交、去墓園這類不涉及購買的移動，模型依然不知道地點存在，
#647 合併後這半仍待另外驗證。

## `work` 對 AI 決策角色雙重不可達

`ai_schema.gd::ALLOWED_ACTIONS` 刻意不含 `work`（「《07》《11》的動作裡
沒有它，嚴格照 spec」），LLM 決策永遠選不到；`work` 只有場景固定 NPC
靠 `npc_schedule.json` 的 `state` 欄位觸發 `_pursue_work_task()`。動態
投放的角色（`spawn_character()` 生出來的）刻意不指派 `schedule_template`
（見 [[角色庫與投放]]），所以連這條路也走不到。目前沒有追蹤這個缺口的
issue——要讓 AI 自主決策的角色也能工作，需要另外設計「動態角色怎麼被
分配工作站」，不是單純把 `work` 加進白名單就好。

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
