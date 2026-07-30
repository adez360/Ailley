---
tags: [ailley, poc, village-sim, reference, io-schema]
status: draft
created: 2026-07-28
updated: 2026-07-31
---

# poc_village_sim 輸入輸出欄位總覽

> [!info] 用途
> 這是目前 `poc_village_sim` 實際在跑的輸入／輸出欄位，直接從 `characters/*.json`、
> prompt 模板、grammar 檔跟真實 transcript 拉出來的，不是規劃階段的理想欄位。相關背景見
> [[POC 紀錄 - poc_village_sim 五人整合試跑（新版 AI 架構首測）]]。
>
> **涵蓋範圍**：`run_tick_sim.py`（固定 tick）／`run_des_sim.py`（DES，變動時長＋中斷機制，
> 目前多數測試在跑這支）／`server.py`（給 Godot 端串接的 API）三支引擎共用的欄位都收在這裡，
> 有差異的地方會註明是哪一支才有。詳細的中英文對照表見
> [[poc_village_sim 中英文對照表 - Action／Location]]。

## 一、輸入（Snapshot，餵給 LLM 的資料）

來源分兩種：**角色資料模型**（`characters/<id>.json`，開局固定或緩慢漂移）跟**即時運算**
（`run_tick_sim.py` 每個 tick 現場算出來，套進 `villager_system_prompt.txt` 的 `{{...}}`
佔位符）。

### 1a. 角色資料模型（靜態／緩慢漂移）

| 欄位 | 型別 | 範圍/選項 | 說明 | 範例（鐵牛） |
|---|---|---|---|---|
| `name` | string | — | 角色名字 | `"鐵牛"` |
| `personality.diligence` 等 6 項 | int | 0-100 | 六維人格，開局固定，只有睡眠反思會微調（單項±3，單晚總和±6） | `bravery: 95` |
| `personality_text` | string／null | — | 手寫人格敘述，人格一旦漂移就改用數值套表產生，不再用這欄 | 見角色卡 |
| `physiology.hunger` | int | 0-100 | 飢餓度，每 tick +2 | `58` |
| `physiology.thirst` | int | 0-100 | 口渴度，每 tick +2 | `71` |
| `physiology.stamina` | int | 0-100 | 體力，依動作分級增減 | `25` |
| `physiology.boredom` | int | 0-100 | 無聊度，Specify2 §7.3 公式 | `30` |
| `physiology.money` | int | ≥0 | 錢 | `95` |
| `physiology.health` | int | 0-100 | 生命值，跟體力分開，流血/重傷才會扣 | `100` |
| `physiology.bleeding`／`severe_injury`／`sprained_ankle`／`hand_cut`／`recovering` | bool | — | 傷病狀態旗標 | `bleeding: true` |
| `physiology.incarcerated`／`ex_convict`／`vigilant` | bool | — | 目前**沒有任何邏輯在動這三個欄位**，只是資料模型裡存在 | `false` |
| `physiology.inventory[]` | list | `{item, qty, note}` | 背包，**目前沒有任何動作會真的增減這個清單** | `狼皮 x1` |
| `location` | string | 動態 enum | 上一刻所在地點 | `"森林出口"` |
| `last_emotion` | string | 8 選一 | 上一刻宣告的情緒 | `"angry"` |
| `last_action_result` | string | — | 上一動作結果文字（含攻擊命中/揮空判定） | `"獵狼 → 成功但流血"` |
| `background` | string | — | 手寫背景故事，**目前沒有塞進 prompt**，只在角色卡裡當參考 | 見角色卡 |

### 1b. 即時運算（每 tick 現場產生）

| 佔位符 | 說明 | 範例 |
|---|---|---|
| `{{WORLD_LORE}}` | 世界觀，目前是測試用臨時文字 | `"（測試用臨時世界觀…）"` |
| `{{SELF_NAME}}` | 角色名 | `鐵牛` |
| `{{SELF_HOME}}` | 角色專屬的家，動態算出 `"XX家"` | `鐵牛家` |
| `{{SELF_PERSONALITY_BLOCK}}` | 人格敘述（手寫或套表產生） | 六行敘述 |
| `{{CURRENT_TIME}}` | 遊戲內時間，含日夜判定 | `第 3 天 19:40（夜晚）` |
| `{{BODY_STATUS_BLOCK}}` | 飢餓/口渴/體力/無聊＋中文形容詞＋體力/無聊度分級警示句 | `飢餓 58（有點餓）…` |
| `{{INJURY_BLOCK}}` | 傷病狀態＋生命值＋生命值分級警示句 | `流血（生命值 15）你開始頭暈…` |
| `{{MONEY}}` | 錢 | `95` |
| `{{INVENTORY_BLOCK}}` | 背包清單文字 | `狼皮 x1（值錢，明早會爛）…` |
| `{{LOCATION}}` | 目前位置 | `森林出口` |
| `{{LOCATION_LIST}}` | 全部合法地點清單（公用地點＋每人的家，動態） | `餐酒館、涼亭…阿蘭家、老周家…` |
| `{{VISIBLE_BLOCK}}` | 視野內的人＋在做什麼＋好感度描述 | `- 阿吉（在「森林」）（死敵，−60）你恨他。` |
| `{{RECENT_EVENT_BLOCK}}` | 上一刻視野內是否有人對你做了什麼（延遲一拍） | `上一刻，老周對你做了「攻擊」的動作` |
| `{{LAST_EMOTION}}` | 上一刻情緒（連續 5 tick 不變會重置成 neutral 再顯示） | `angry` |
| `{{LAST_ACTION_RESULT_BLOCK}}` | 上一動作結果（含攻擊命中/揮空、guardrail 失敗原因） | `攻擊（對 阿吉） → 打中了` |
| `{{RECENT_MEMORY_BLOCK}}` | 睡眠反思產物。**兩個引擎邏輯已分岔**：`run_tick_sim.py` 用「新近度（0.95 指數衰減）+重要性」排序撈最相關 6 筆；`run_des_sim.py` 簡化成單純依重要性排序取前 3 筆，沒有新近度衰減 | `- 阿吉的行為讓我明白…` |
| `{{TODAY_PLAN_BLOCK}}` | 2026-07-30 新增的「計畫層」——睡眠反思（或體力耗盡強制昏睡，見下方「三、計畫層」）時產生的當日意圖，跨整個遊戲日持續存在，不是每次決策重新生成 | `想去藥草鋪把傷處理好，也想找機會跟阿吉把話說開（這是你自己想做的事，不是任務清單…）` |

## 二、輸出（LLM 回傳的 JSON，grammar 鎖死格式）

實際欄位順序（2026-07-28 調整過，`intent` 排在 `inner_monologue` 前面，原因見
[[POC 紀錄 - poc_village_sim 五人整合試跑（新版 AI 架構首測）]] 的「grammar 欄位重排序」
一節）。**`intent` 底下有沒有時長欄位、時長欄位叫什麼名字，三支引擎不一樣**：

| 引擎 | grammar 檔 | 時長欄位 | 單位 |
|---|---|---|---|
| `run_tick_sim.py` | `turn.gbnf.template` | 無（固定 15 分鐘一個 tick） | — |
| `run_des_sim.py` | `turn_duration_experiment.gbnf.template` | `duration_minutes` | 分鐘（1-999，故意不加語意提示，看 AI 自然填什麼） |
| `server.py` | `turn_duration_ticks.gbnf.template` | `duration_ticks` | 10 秒一個 tick（例如填 2 代表 20 秒），prompt 裡有補單位說明 |

以 `run_des_sim.py` 的格式為例：

```json
{
  "emotion": "angry",
  "intent": {
    "action": "發呆",
    "duration_minutes": 15,
    "target": null,
    "location": "森林"
  },
  "inner_monologue": "這輩子從來沒有比今天還累的了，要不是森林出口附近沒東西可以撈，我早就在那邊睡著了。",
  "speech": null,
  "speech_volume": "normal"
}
```



| 欄位 | 型別 | 範圍/選項 | 說明 |
|---|---|---|---|
| `emotion` | string | `excited`／`happy`／`in_love`／`terrified`／`burnout`／`angry`／`sad`／`neutral` 8 選一 | 固定 enum，跟人格無關，LLM 自主宣告 |
| `intent.action` | string | **38** 個固定動作（說話/喊話/悄悄話/握手/擁抱/送禮/給錢/結婚/離婚/偷竊/搶劫/破壞樂器/攻擊/抓捕/舉報/打獵/採草藥/釣魚/表演/買東西/賣東西/治療/吃飯/喝酒/移動/奔跑/蹲下/抱頭/舉手/大叫/摔東西/飛吻/跟隨/展示物品/巡邏/自首/睡覺/發呆） | 靜態封閉 enum。英文代號對照表見 [[poc_village_sim 中英文對照表 - Action／Location]] |
| `intent.duration_minutes`／`intent.duration_ticks` | int | 見上表 | 只有 `run_des_sim.py`／`server.py` 有，`run_tick_sim.py` 沒有這個欄位 |
| `intent.target` | string／null | 視野內真實存在的人名，或 `null` | **動態**生成——每次呼叫依當下視野現場組出封閉 enum，不可能是幻覺人名或視野外的人 |
| `intent.location` | string | 公用地點＋每人的家 | **動態**生成——依角色名單現場算出的封閉 enum |
| `inner_monologue` | string | 自由文字 | 唯一要求：不能用佔位字樣、要用道地口語、必須針對已選定的 `intent` 在寫 |
| `speech` | string／null | 自由文字或 null | 沒有要說話就填 null |
| `speech_volume` | string | `normal`／`shout`／`whisper` 3 選一 | speech 為 null 時固定填 normal（引擎忽略） |

### `server.py` 額外附加的欄位（不是 LLM 輸出，是後製加工出來的）

`/decide` 回應在 `output`（上面那包原始 JSON）外面還包了一層，完整規格見
[[poc_village_sim 中英文對照表 - Action／Location]]：`character_id`／`elapsed_seconds`／
`action_start_offset_seconds`／`action_duration_seconds`／`prompt_truncated`／`action_en`／
`location`（`{"kind","shared_location","owner_id"}` 結構化物件，不是扁平字串）／`target_id`。

## 三、目前完全沒接上、資料模型有欄位但沒邏輯的部分

給組員規劃新架構時參考——這些是「看起來存在但實際上是死欄位」：
- `incarcerated`／`ex_convict`／`vigilant`：資料模型有，沒有任何機制讀寫
- `inventory[]`：沒有任何動作會真的增減背包內容物（吃飯/打獵/買賣目前都只動數值，不動清單）
- `background`：手寫背景故事完全沒進 prompt，只是角色卡裡的參考文字
- 舉報／抓捕／洗心革面所：動作存在於允許清單，但沒有任何機制效果（討論過、還沒做）

## 四、機制／流程說明不在這份筆記裡

排程怎麼跑、中斷機制怎麼觸發、DES 引擎的設計取捨——這些是「怎麼做／為什麼」，不是欄位
清單，記在 [[poc_village_sim 驗證引擎邏輯總覽]]，不重複寫在這裡。這份筆記只回答「有哪些
欄位、型別、範圍、誰在用」，設計背景跟逐次實驗數據另外查
[[POC 紀錄 - poc_village_sim 五人整合試跑（新版 AI 架構首測）]]。
