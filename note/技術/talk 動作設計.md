---
tags:
  - agent
  - 對話
scene: scenes/main.tscn
script: scripts/dialogue/conversation.gd
status: 進行中
updated: 2026-08-31
---

# talk 動作設計

`talk` 是**第一個把「動作」這個抽象逼出形狀的動作**。

`move_to` 太特殊：只有起點終點、成功失敗兩種結果，撐不出動作介面該長什麼樣。
`talk` 有對象、有前置條件、有持續狀態、有多種失敗原因、還會同時改變雙方狀態。
把它做完，其餘動作就有可以照抄的樣板。

> [!note] 現況
> 模板台詞版**已實作可跑**。LLM 版尚未接上，見 [[LLM 串接與 AI 服務層]]。

## 分層：LLM 只插在內容層

| 層 | 負責 | 現在 | 接 LLM 後 |
| --- | --- | --- | --- |
| 發起 | 誰能跟誰講、距離、可否打斷 | `character.gd` | 不變 |
| 會話 | 狀態機、輪次、結束條件 | `conversation.gd` | 不變 |
| 內容 | 講什麼 | LLM 逐輪生成（`next_line()`，issue #630） | 已接上 |
| 呈現 | 氣泡 | `bubble.gd` + `bubble.tscn` | 不變 |
| 後果 | 數值回補、記憶 | social / mood / note_meeting | 加記憶寫入 |

> [!important] 這個分層是整個設計的重點
> 內容層以外的四層跟「誰產生台詞」無關。切乾淨的話，接 LLM 那天只換內容層一個檔。
> 反過來說，把「產生台詞」寫進狀態機裡的話，之後就得整段重寫。

> [!note] 內容層可以順帶推進決策層（issue #658）
> 角色講出的話若是「講了就要做」的即時承諾（不是玩笑、不是還要對方答應的
> 提議），對話回應可以附帶選填的 `task` 欄位，直接推進講話者自己的任務池
> （`PromptBuilder.DIALOGUE_TASK_HINT`／`AISchema.validate_dialogue()`，
> 跟 `agent.gd::next_line()` 串起來）。判斷「這句話算不算承諾」交給模型
> 自己讀懂語意決定，**不是引擎事後比對台詞裡有沒有特定關鍵字**——語言表達
> 方式千變萬化，固定詞彙比對遲早漏接或誤判。欄位形狀跟驗證方式沿用
> persuade 的 `proposed_task`（#227）那套 `_validate_task_shape()`，同理
> 擋掉巢狀 `persuade`。池滿時跟一般 LLM 任務同一套處理（靜默丟棄），不像
> persuade 的 `proposed_task` 保證塞入——對話裡的口頭承諾不是對另一方的
> 正式應允，沒有信任問題。

## 會話做成獨立物件

`Conversation` 是獨立節點，狀態不塞進任一方的 Character。

對話是**兩個角色之間**的東西：塞進其中一方會讓另一方每次都要反查，
而且結束時要同步清乾淨兩邊，狀態分散在兩個節點很容易漏掉一邊。

生命週期：`Character.talk_to()` 設好雙方後把它加進場景，講完自己 `queue_free()`。
**不要直接 new 它。**

進入時雙方 `stop_moving()`；結束時 Agent 重算「現在該做什麼」而不是接續原路 ——
對話期間可能已經跨過行程的整點。

## 失敗原因碼

每個動作都要有失敗原因碼，理由是「AI 要能知道為什麼失敗才有辦法重排行程」。

| 碼 | 意義 |
| --- | --- |
| `TARGET_NOT_FOUND` | 找不到這個角色 |
| `TARGET_IS_SELF` | 不能跟自己講 |
| `TOO_FAR` | 超出搭話距離（32px = 2 格） |
| `TARGET_BUSY` | 對方已在別的對話裡 |
| `TARGET_UNINTERRUPTIBLE` | 對方目前的行程不可打斷（例如睡覺） |
| `TARGET_NOT_VISIBLE` | 在搭話距離內，但視線被擋住（見下方拍板） |

> [!warning] 結束原因不是失敗原因
> `Conversation.REASON_*`（正常講完、走太遠、被打斷）與上面那組**不可混用**。
> 混在一起的話 AI 會把「正常講完」當成「動作失敗」而反覆重試。
>
> 這條之後套用到所有動作：**正常終止與失敗是兩種東西**。

> [!note] 這些碼是橫跨全部行為的共用詞彙，翻成人話見 [[在地化]]
> `TARGET_NOT_FOUND`／`TOO_FAR` 這類碼不是 `talk` 專屬——`work`／`buy`／
> `eat`／`drink`／`give`／`haul`／`attack` 用的是同一組扁平字串（見
> `character.gd` 開頭那些 `*_OK`／`*_TOO_FAR`… 常數）。`Character.
> report_action_failure(action_label, reason)`（issue #180）把碼翻成
> `FAIL_*` 的可讀訊息、顯示在角色自己的 Bubble，同一張表全部行為共用，
> 不用每個動作各自維護一份對照。

## 數值系統做成資料驅動

`Stats` 是一張 `SPEC` 表而不是一組寫死的變數：

```gdscript
"mood": {"label": "心情", "drift": 0.5, "toward": 50.0, "start": 50.0, "is_need": false}
```

`drift` / `toward` 讓需求（漂向 0，會餓會累）與心情（漂回 50，會平復）用同一套機制表達。
`is_need` 把「低了就該去解決」跟「只是狀態」分開 —— 心情不會被 `get_lowest_need()` 選中。

**加一項數值只要加一列**，連主控台的顯示都會自己跟上（它直接掃 `Stats.SPEC` 讀 `label`）。

關係是「對某個人」而不是「角色自己的數值」，所以獨立成 `Relationships`，
key 用對方的 `character_id` 而不是 name —— name 會改，用它當 key 等於改名即失憶。
每筆存成 Dictionary 而不是單一浮點數：欄位是 `met_count`／
`appearance_cache`（規格《01》3-1、《99》P-08）／`appearance_state`（#498，
見下方外觀異動偵測）／`last_seen`（#497，見下方），印象標籤之後要加也一樣
不用改結構。

## 上次見面時間（#497）

`last_seen`：上次 `note_meeting()`（好好講完一場話）當下的 `GameClock.day`，
-1 表示從沒見過。只有 `note_meeting()` 會寫入，跟 `met_count` 同一次更新，
判斷「有沒有上次見面」要查 `Relationships.has_met()`，不要拿 -1 當合法天數
去算差值。

送進 `context.listener` 時壓成中文事實句（`prompt_builder.gd::_last_seen_sentence()`），
不送原始時間戳讓模型自己算——跟 `_today_plan_sentence()` 同一種「輸入端一律
注入、但壓成自然語言句子」做法（2026-08-27 issue #497 拍板）。只陳述天數差
（「你上次見到 TAMMY 是 3 天前」／「你今天已經見過 TAMMY 了」／「你還沒見過
TAMMY」），不加「好久不見」這類情緒推測，符合《00》原則二。

只落地 JSON 存檔路徑（`Character.get_save_data()`／`load_save_data()` 通用
機制自動涵蓋，不用改）。SQLite 路徑（`npc_relations` 表）目前連既有的
`met_count` 都存不進去（見 `sqlite_save_service.gd` 檔尾「schema 缺口」清單），
`last_seen` 一併登記在同一個缺口清單，不單獨補 schema——要不要幫 SQLite 補
這兩個欄位是《99》待規劃項目，不是這則 issue 的範圍。

### 驗證

`test_run(suite="relationships")`：6/6 通過（`get_last_seen()`／
`load_save_data()` 型別驗證與退回預設值邏輯，不依賴 GameClock）。全套件
31/33 通過，唯二失敗是既有的 `test_shout_reaches_player.gd`（issue #624
追蹤），與本次改動無關。

`project_run` + `game_eval` 對主 checkout 動態 spawn 一隻 Agent，直接呼叫
`player.relationships.note_meeting()` 與 `PromptBuilder._listener_block()`
驗證三種情境的實際字串：從沒見過（「你還沒見過 TestLastSeen。」）、剛見過面
（`note_meeting()` 當下同一天，「你今天已經見過 TestLastSeen 了。」）、倒回
3 天前（手動改 `last_seen` 欄位模擬，「你上次見到 TestLastSeen 是 3 天前。」）。
另外驗證 `get_save_data()`／`load_save_data()` round-trip 保留 `last_seen`。

> [!important] 舊存檔過渡態（`has_met=true`、`last_seen=-1`）不能算天數差（PR #641 review 抓到）
> `_last_seen_sentence()` 原本只查 `has_met`，沒有另外擋 `last_seen_day < 0`——
> #497 之前的存檔只有 `met_count`、沒有 `last_seen` 欄位，讀回來時
> `has_met()` 為真（`met_count > 0`）但 `last_seen` 退回預設值 `-1`，
> 會算出 `GameClock.day - (-1)` 這種編造出來的天數，往後每次決策都送出
> 錯誤事實句，直到下次真的 `note_meeting()` 才自癒。已補上
> `last_seen_day < 0` 判斷，這種過渡態一律退回「你還沒見過」。
> `game_eval` 對 `PromptBuilder._last_seen_sentence()` 四種情境實測：
> `(has_met=false, -1)` → 「你還沒見過阿吉。」；
> `(has_met=true, last_seen_day=-1)`（過渡態）→ 「你還沒見過阿吉。」（修復前會算成假天數）；
> `(has_met=true, last_seen_day=GameClock.day)` → 「你今天已經見過阿吉了。」；
> `(has_met=true, last_seen_day=GameClock.day-3)` → 「你上次見到阿吉是 3 天前。」。

外觀異動偵測（#498 拍板）：`appearance_cache`（自由文字、初次相遇的外觀描述，
P-08 已拍板但從沒有任何呼叫端寫入過）繼續維持原樣不動，這次新增一個獨立欄位
`appearance_state: {injured: bool, filthy: bool}`，直接讀 `character.gd` 既有
的 `CONDITION_INJURED`／`CONDITION_FILTHY`（門檻沿用《02》既有拍板值，不新增
任何欄位或門檻）。兩個欄位語意不同、不合併：`appearance_cache` 是「這個人
長什麼樣子」的一次性靜態描述，`appearance_state` 是「跟上次見到比，動態狀態
有沒有變」的比對快照。見面時跟 `appearance_state` 快取的舊快照逐欄位比對，
跨過門檻的欄位各自透過既有《01-3》§3 事實句機制發一句事實句（跟「看到陌生
人」同一條路徑）：

| 轉變 | 事實句 |
| --- | --- |
| `injured` false→true | 「TAMMY 身上有傷。」 |
| `injured` true→false | 「TAMMY 身上已經沒有傷了。」 |
| `filthy` false→true | 「TAMMY 現在看起來不乾淨，跟你上次見到不一樣。」 |
| `filthy` true→false | 「TAMMY 現在看起來乾淨了，跟你上次見到不一樣。」 |

只描述布林值本身翻成中文的客觀狀態，不加程度／恢復過程等額外語氣詞（CodeRabbit
review 抓到：「髒兮兮」「乾淨多了」「傷已經好了」這幾種措辭帶了布林快照本身
證明不了的程度或病程語意，跟「不判斷嚴重程度」的原則衝突，改成上表這種純
狀態陳述）。比對後更新快照。

> [!important] 沒有舊快照時只建立 baseline，不發事實句（CodeRabbit review 抓到）
> 第一次見到這個人（或快照因任何原因缺失／無效）時，沒有「上次」可比較——
> 這種情況只把目前的 `injured`／`filthy` 存進快照當 baseline，不產生任何事實句。
> 不能把「沒有舊快照」當成「舊值是 false」處理，否則初次見面時若對方剛好
> `injured = true`，會被誤判成「false→true」而發出「有異動」的事實句，
> 但其實這是這個人第一次被觀察到的既有狀態，不是變化。
>
> 這條規則要對「缺失」的所有成因一視同仁：欄位整個不存在、只有一半欄位、
> 型別不對、舊格式存檔——通通算「沒有 baseline」，一律只建立新 baseline、
> 不比對、不發事實句，不能退回 `{injured: false, filthy: false}` 這種看似
> 合法的預設值再拿去比對（那樣等於偷偷假造了一個「上次見到時沒受傷也不髒」
> 的假歷史）。這點刻意不跟 `Relationships` 其餘欄位（`met_count`／`appearance_cache`
> 型別不對時退回 `DEFAULT_RECORD` 的預設值）同一套處理——那些欄位的預設
> 值本身就是合法的初始狀態，`appearance_state` 的「不存在」跟「存在且是
> false」語意不同，不能共用退回預設值那條路。具體的讀檔/型別驗證程式碼留給
> 實作 issue 寫，這裡只定住這條語意規則，避免照抄其他欄位的驗證模式時
> 順手做錯。

連帶修正 P-08 #3 的舊決定（原本假設「動態變化已經由 conditions 走其他管道
傳遞」，查證後那條管道從沒被建過——`_listener_block()` 從未攜帶對方的
`conditions`），詳見《99》P-08。不含 `appearance[]`（髮型／衣著／配件）比對，
那組資料卡在《99》P-38、目前一律是空陣列，等落地後另開 issue。觸發時機（掛
在 Vision 首次注意到還是 `note_meeting()`）留給實作 issue 決定。

> [!note] 存檔路徑跟 `appearance_cache` 相同，不是新流程（CodeRabbit review 抓到）
> `appearance_state` 是同一筆 `relations` 記錄裡的欄位，跟 `appearance_cache`
> 一樣要接上 `NPCRelationsSchema.gd`（多一欄）與 `sqlite_save_service.gd` 的
> `get_character()`／`save_character()`（`relations_appearance_cache` 那兩處
> 讀寫的旁邊）——這是既有欄位新增的既定模式，不是這次要另外設計一套新的存檔
> 流程。讀到沒有這個欄位的舊存檔（欄位不存在）時，直接套用上面的「沒有
> baseline」規則：不當成任何合法值，只在下次見面時重新建立 baseline，不會
> 因為讀不到欄位而報錯或誤判成異動。具體的 schema migration 寫法留給實作
> issue。

好感、熟悉、虧欠、信任都不是引擎欄位：沒有任何公式讀過它們（《00》原則三），
這幾件事交給《03》記憶系統自己記、自己判斷、自己演（信任／`trust` 是最後
拿掉的一個，見 issue #601）。

> [!important] 查詢不可以建立紀錄
> `Relationships` 的讀寫是分開的：`get_record()` / `has_met()` 全部唯讀，
> `get_record()` 甚至回的是副本；只有 `set_appearance_cache()` 與
> `note_meeting()` 會走私有的 `_ensure_record()` 建立紀錄。
>
> 這條是踩出來的：原本查詢走「沒有就當場建一筆」的 `get_record()`，
> 而 `conversation.gd` 開場就會問一次關係 ——
> 於是**只要對話開始過，`has_met()` 就永遠為真，而 `met_count` 還是 0**。
> 症狀是 [[視覺感測]] 那個「第一次看到陌生人才愣一下」再也不會發生
> （搭話後立刻走開就足以觸發），而主控台會印出「player（0 次）」卻同時判定
> `has_met()` 為真，這種見過面次數是 0 但「已認識」的自相矛盾狀態。
>
> 「認識」的唯一來源是 `note_meeting()`，也就是**好好講完一場話**。
> 這件事接 LLM 之後更要緊：`met_count` 與「認不認識」是要送進 payload 的事實，
> 不能被自己的讀取行為改寫。

## 聽者的對稱退出點（issue #691，《99》P-31，已實作）

原設計只有**正在講話那一方**能用 `end` 欄位收尾，沒輪到自己講話的聽者只能等，或用移動觸發 `TOO_FAR` 這個側門離開——實質上把「要不要繼續聊」的決策權只給了說話方。

現況：`conversation.gd::_run()` 每輪（turn 0 除外——turn 0 的「listener」是發起對話的一方，且已經有 `engage` 欄位在管要不要理會這次搭話）先呼叫 `listener.wants_to_continue(speaker, _turns)`，聽者回 `false` 就以 `REASON_ENDED_BY_LISTENER` 立即結束，不等 `speaker.next_line()` 的 provider 逾時（`ai_config.gd` 預設 20 秒；退出優先於逾時）。`Character` 基底預設一律回 `true`（Player 沒有 LLM 可問，退出交給玩家自己走遠或站著不理）；`Agent.wants_to_continue()` 才是真正的 LLM 決策，`PromptBuilder.build_listener_continue_envelope()` 組信封，沿用 `AISchema.validate_checkpoint()`（`{"continue": bool}`，跟長動作中止檢查點同一種「純布林是非題」形狀，不另開一組只差一個字的 schema）。失敗/逾時一律視為「想繼續」，不能讓一次網路抖動就把整場對話腰斬。

新增 `AIService.Policy.LISTENER`：完全豁免每日對話配額（`max_dialogue_calls_per_game_day`）且不計帳——這是對話機制本身的一部分，不是額外多打一通電話；佇列出隊順序也跟 `CONVERSATION` 同等優先（`_next_job_index()`），因為它一樣卡在同一條對話輪次迴圈裡等結果。

## 視線判定（issue #109，已實作）

`talk_to()` 跟 [[視覺感測]] 一樣被視線遮擋，不是純距離判定：`character.gd` 的
`_has_line_of_sight()` 用 `direct_space_state.intersect_ray()` 查 `TALK_BLOCKER_MASK`
（1 = terrain，跟 `Vision.blocker_mask` 同一個值），不透過 `Vision` 元件本身——
`talk_to()` 可能被明確指名對象呼叫（debug 主控台、`agent.gd` 的 LLM 決策），
這時候要的是「現在這一刻真的擋不擋」，不是 Vision 那份每 0.2 秒才更新一次的快取。
被牆擋住時回傳 `TARGET_NOT_VISIBLE`（見上表），跟 `TOO_FAR` 分開。

候選角色偵測（原本 `character.gd` 裡找最近角色的方法，未曾被 `player.gd` 實際呼叫過、
是死代碼，已移除）改成 `player.gd` 直接濾 `Vision.get_visible_characters()`——反正都要
視線判定，沒理由重複維護兩份。工作站的候選則改用 `player.gd` 新增的
`InteractArea`（`Area2D`，半徑 `maxf(WORK_RANGE, TALK_RANGE, BUY_RANGE)`，動態算不寫死），
偵測 `project.godot` 新增的 `interactable` collision layer（`workstation.tscn` 的
`collision_layer` 從純 `terrain` 改成 `terrain | interactable`，NavGrid 的障礙判定
只查 `terrain`，不受影響），取代原本每次呼叫都掃過整個 group 的寫法。商店（issue #572
後不再是場上物件）不走這條 `InteractArea` 路徑，`_nearest_shop_place()` 直接對
`SHOP_PLACES` 逐一比 `PlaceAnchors` 錨點距離，見 [[販賣機]]。

## 已定案的參數

| 項目 | 值 | 備註 |
| --- | --- | --- |
| 搭話距離 | 32px（2 格） | `Character.TALK_RANGE` |
| 散場距離 | 48px | 比搭話門檻寬鬆，講到一半才不會動不動就散 |
| 面對面 | `talk_to()` 本身不要求（debug 主控台、`agent.gd` 的 LLM 決策直接指名對象呼叫） | 操作上太苛；但玩家按 `E` 走 `player.gd::_nearest_facing()` 候選篩選時仍會排除沒面向的目標（`FACING_DOT_THRESHOLD`，見 #102） |
| 互動鍵 | `E` | |
| 被搭話者的行程 | 暫停後重算 | 不是接續原路 |
| 回補 | social +25、mood +5 | 只有正常講完才發；關係只記 `note_meeting()`，不寫入任何評價數值 |
| 等待對方回話逾時 | provider 逾時（`ai_config.gd` 預設 20 秒） | 沒有對話專屬的獨立逾時常數——`next_line()` 走 `AIService` 的 provider timeout，provider 設定檔可覆蓋、缺值退回 `ai_config.gd::DEFAULT_TIMEOUT`（20 秒），見《04》§6。逾時走 fallback（靜默結束、不補台詞，issue #949）。真人玩家的回話等待秒數留到 MVP-2 玩家加入後再定——現在真人不參與 `talk`，不急 |

## 呈現層的坑

> [!warning] Label 開 autowrap 後，minimum size 會反過來吃掉你設的尺寸
> `get_minimum_size()` 在 autowrap 開啟時回傳的是「最窄可接受寬度」，
> 中文等於一行一個字，拿它當寬度會得到 25x692 的氣泡。
> 改用 `font.get_string_size()` 直接量。
>
> 但光改量測還不夠：Control 的 `size` 不能小於 `get_combined_minimum_size()`。
> 解法是 Label 設 `clip_text = true` —— 這會讓它的 min size 退成 1x1，
> 指定的尺寸才作數。

> [!warning] `get_multiline_string_size()` 不含 Label 的 `line_spacing`
> 少算的話最後一行會被裁掉。要自己補 `line_spacing * (行數 - 1)`。

> [!important] 箭嘴固定在右下角，所以氣泡往左上長，不是置中
> `TAIL_INSET_FROM_RIGHT = 9` 把箭嘴尖端對到說話者頭上，框體再從那裡往左上展開。
> 想要左向箭嘴得另外準備鏡像素材，或把 Box 的 `scale.x` 設 -1 再把文字翻回來。

> [!important] 角色站在鏡頭可視範圍邊界附近時，氣泡會夾制回畫面內（issue #742）
> 上面那條「往左上展開」的框體只認角色頭上的錨點，完全沒管鏡頭看不看得到——
> 角色站在地圖邊緣、房屋邊界這類鏡頭視野受限的位置說話時，往左上長出去的
> 那塊會直接被螢幕邊緣裁掉，看起來像是「AI 講到一半斷掉」（一開始真的被
> 誤判成生成長度限制或模型品質問題，實測截圖比對才確認是顯示區域跑出畫面，
> 文字本身沒有被截斷）。
>
> `_clamp_to_camera_view()` 拿 `get_viewport().get_camera_2d()` 的
> `get_screen_center_position()` 跟 `get_viewport().get_visible_rect().size /
> cam.zoom` 算出目前鏡頭的可視世界座標範圍，把 `box` 的全域矩形夾回這個範圍
> 內——只平移 `box.position`，不動 `Bubble` 節點自己的 `global_position`
> （那是角色頭上的錨點）。**不是只在 `_render()` 算一次**：角色（鏡頭跟著）
> 移動後畫面範圍就變了，`_process()` 顯示期間每幀重跑一次，起點固定用
> `_render()` 記下的 `_unclamped_box_position`，不是 `box.position` 本身——
> 不然每幀的偏移會疊加，回到可視範圍內時也不會自動歸零。`get_viewport()`
> 在節點沒進場景樹時是 `null`（例如 `tests/test_shout_reaches_player.gd`
> 手動組 `Bubble` 測試），要先擋過這關才能再問 `get_camera_2d()`。代價是
> 夾制生效的那幾幀，箭嘴（烤在 `box` 的九宮格材質裡，跟著整個框體一起
> 平移）不會再精準指向角色頭上；沒有鏡頭時整段跳過，維持原本行為。

素材是 `assets/ui/chatbox-1.png`（48x48），九宮格參數
`region_rect = Rect2(6.07, 6.37, 39.01, 37.63)`、margin 10 / 9 / 11 / 12。

## 玩家輸入框

`scenes/chat_input.tscn` + `scripts/ui/chat_input.gd`。
Enter 開啟／送出，Esc 取消。不在對話中就是單純冒一句氣泡（`player.say()`）；
在對話中的話，這句要送進 `conversation.gd` 的輪次，見下面「玩家的回合」。

跟除錯主控台是兩件事：那個是打指令給遊戲，這個是讓角色說話。

> [!warning] 兩者都吃 Enter，需要守衛
> 主控台的 `LineEdit` 有焦點時，Enter 要送出指令，不能同時把說話框叫出來。
> `chat_input.gd` 開啟前會檢查 `gui_get_focus_owner()`。
>
> 反方向不用處理：說話框自己有焦點時，Enter 會先被 `LineEdit` 吃掉走
> `text_submitted`，不會冒到 `_unhandled_input`。

## 玩家的回合：輸入緩衝與被動狀態提示（issue #207）

`chat_input.gd::_on_submitted()` 在對話中會走 `player.line_submitted.emit(text)`
而不是直接叫 `conversation.gd`——玩家不知道、也不該知道自己現在是不是在
一場 `Conversation` 物件裡，只知道「我打字、我的角色講話」。

> [!important] 玩家提早打字要緩衝，不能直接找有沒有人在等
> `player.gd::next_line()` 是 `conversation.gd` 每輪呼叫的介面，內部
> `await turn_resolved` 等玩家打字。原本的寫法是 `_on_line_submitted()`
> 收到字就無條件 `turn_resolved.emit()`——如果這時候根本沒有任何
> `next_line()` 在等（例如輪到 NPC 講話、NPC 還在等 LLM 回應），這個 emit
> 發進沒人接的地方，訊號憑空消失：等真正輪到玩家、`next_line()` 才第一次
> 開始 `await`，等的是一個不會再來的訊號，直接卡住（已重現）。
>
> 修法是加一層緩衝：`_turn_waiting` 記著現在是不是真的有 `next_line()` 在
> 等。`_on_line_submitted()` 只有 `_turn_waiting` 時才直接 `emit`，否則存進
> `_pending_line`。`next_line()` 開頭先檢查緩衝區有沒有內容，有就立刻用掉、
> 完全不 `await`；沒有才設 `_turn_waiting = true` 開始等。`exit_conversation()`
> 同一套邏輯：有人在等就 `emit(ok=false)` 取消，沒有就只清掉可能殘留的緩衝，
> 不讓上一場對話沒送出的半句話流進下一場。

> [!important] 排隊上限（issue #843）：打太快要鎖輸入框，不能無限緩衝
> `_pending_lines` 原本沒有上限——玩家可以趁 NPC／LLM 還沒回應時連續打好
> 幾句排隊，體驗上會跟對話實際節奏脫節（打的話已經不是在回應剛剛聽到的
> 內容）。`player.gd` 加了 `const MAX_PENDING_LINES := 3` 與
> `can_queue_line()`：真的輪到玩家（`_turn_waiting`）永遠放行，不是輪到
> 玩家時才看緩衝區還有沒有位置。`chat_input.gd::_unhandled_input()` 開啟
> 輸入框前呼叫 `can_queue_line()`，滿了就不開框，改用
> `player.say(L10n.t("DLG_TOO_FAST"), true, false)` 在玩家頭上冒一句
> 「等等村民回覆啦，太快了」——跟 `DLG_SURPRISE`／`DLG_NOISE_ALERT` 那類
> 系統提示同一種做法，`broadcast=false` 是同一個理由。沒有另外做「解鎖」
> 事件：`can_queue_line()` 每次都是即時看緩衝區大小，`next_line()` 消化掉
> 排隊的句子、`_pending_lines.size()` 降到上限以下，下次玩家按開輸入框自然
> 就通過了。

> [!important] 常駐提示：真的在等待時才顯示，撐到有結果才收
> `Bubble.say()`／`_show_next()` 是固定秒數自動消失的排隊機制——秒數由文字
> 長度算，單一符號（「…」「？」）會被夾到下限 1.2 秒，撐不過一次 LLM 等待
> （`ai_config.gd` 預設逾時 10 秒），泡泡會比答案早收掉，玩家會看到一段
> 「看起來像沒理你」的空窗（實際踩過：`agent.gd::next_line()` 開頭顯示的
> 「思考中」提示 `AI_THINKING_TEXT`）。凡是「要撐到某個明確事件發生才能收」
> 的提示都改用 `bubble.gd` 的 `hold(message)` / `release_hold()`：`hold()`
> 清空佇列、顯示訊息但不跑自動消失的計時（`_process()` 裡用 `_holding` 擋掉
> 計時，處理本身開著是為了 #742 的每幀重夾位置），`release_hold()` 解除後才
> 恢復正常排隊行為。目前兩處在用：
> - `player.gd::next_line()` 只在真的要 `await`（緩衝區沒內容）時才對
>   `listener` 呼叫 `hold(WAITING_FOR_PLAYER_TEXT)`（NPC 頭上顯示「？」），
>   `await` 結束（不管是真的送出還是被取消）呼叫 `release_hold()`，
>   `is_instance_valid(listener)` 包一層——跟
>   `conversation.gd::_finish_with_fallback()` 同一種顧慮，`await` 讓出
>   控制權的這段期間 `listener` 理論上可能已經離開場景。
> - `agent.gd::next_line()` 一開頭 `bubble.hold(AI_THINKING_TEXT)`。收掉的
>   時機交給 `character.gd::exit_conversation()`（對話不管什麼原因結束都會
>   呼叫到，唯一的收斂點）統一 `release_hold()`；正常拿到台詞或 fallback 時，
>   `say(interrupt=true)` 內部的 `bubble.clear()` 會先解除 hold 換成真台詞，
>   `exit_conversation()` 之後再呼叫 `release_hold()` 純粹是 no-op。

> [!important] 對方選擇不理你（`engage=false`）要顯示得出來，不能跟「還在等」一樣空白
> `conversation.gd::_run()` turn 0 若 `result.engage == false`，原本直接
> `bubble.clear()` 收掉思考中提示、什麼都不顯示——跟上面「LLM 還在想」的
> 空窗期在畫面上長得一模一樣，玩家分不出「還在等」跟「他不想理你」。
> 現在改成 `speaker.say(L10n.t("DLG_IGNORED"), true, false)`
> 顯示一句「他似乎不想理你……」，`broadcast=false` 理由跟
> `AI_THINKING_TEXT` 一樣：這不是角色真的說了什麼，不該觸發鄰近角色的
> `speech_heard`。

> [!note] 對話結束不會有引擎代講的道別台詞
> `conversation.gd::_finish()` 不管什麼結束原因（正常結束／走遠／被打斷／
> fallback）都不補道別台詞——`exit_conversation()` 迴圈跑完就結束，不會幫
> 任何一方講話。引擎只把「這場對話怎麼結束的」寫成一句客觀事實
> （`agent.gd::exit_conversation()` → `_daily_events`，見
> [[00_設計原則與架構#原則二：引擎只給事件，不給情緒]]），角色要不要道別、
> 用什麼語氣，是 AI 自己下一輪決定的事，不是系統畫面台詞。

> [!important] 結束事實句依原因分寫，不一律「講完話了」（issue #950）
> `agent.gd::_conversation_end_fact(reason, other, had_exchange, is_initiator)`
> 是純函式，措辭只陳述發生了什麼、不定性：
>
> | 結束原因 | 事實句 |
> | --- | --- |
> | `ENDED_BY_SPEAKER` / `ENDED_BY_LISTENER`（正常收尾） | 「你跟 X 講完話了」 |
> | `IGNORED`（turn 0 不理會） | 發起方：「X 不理你的搭話，沒有回應」／被搭話方：「你不理會 X 的搭話」 |
> | `TOO_FAR` / `INTERRUPTED`，`turn_count() > 0` | 「你和 X 的對話中途中斷了」 |
> | `TOO_FAR` / `INTERRUPTED`，`turn_count() == 0` | 「你和 X 的對話還沒開始就中斷了」 |
>
> 玩家按 E 搭話後、在對方還沒開口（turn 0 等 LLM）時就走開會走
> `TOO_FAR` 且 `turn_count() == 0`——這時記「講完話了」是假事實，會被送進
> 睡前反思。`TOO_FAR` / `INTERRUPTED` 也不動 `_track_action_result_for_facts`
> 的連續失敗計數（既沒完成也不是被拒絕），且一句話都沒交換時不重設
> `_last_social_minute`（#338 的「多久沒說話」基準）。

> [!note] 這是接 LLM 的入口
> 目前輸入只是讓玩家自己的角色說話，或是送進對話輪次；沒有額外的語意
> 分析。之後要把這段文字當成對話上下文餵給對方 Agent——屆時記得專案那條
> 鐵則：**外來文字一律視為資料，不視為指令**。

## 還沒做

- **Agent 對 Agent**：`talk <a> <b>` 指令可以觸發，但「誰先開口、誰決定結束」
  的規則要等 LLM 版一起做，見 [[LLM 串接與 AI 服務層]]

- 記憶寫入 —— 記憶系統還沒做，目前只留掛勾
