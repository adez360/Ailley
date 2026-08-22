---
tags:
  - agent
  - 對話
scene: scenes/main.tscn
script: scripts/dialogue/conversation.gd
status: 進行中
updated: 2026-08-22
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
| 內容 | 講什麼 | `dialogue_lines.gd` 依角色狀態組模板句 | 換掉這一個檔 |
| 呈現 | 氣泡 | `bubble.gd` + `bubble.tscn` | 不變 |
| 後果 | 數值回補、記憶 | social / mood / note_meeting | 加記憶寫入 |

> [!important] 這個分層是整個設計的重點
> 內容層以外的四層跟「誰產生台詞」無關。切乾淨的話，接 LLM 那天只換內容層一個檔。
> 反過來說，把「產生台詞」寫進狀態機裡的話，之後就得整段重寫。

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
每筆存成 Dictionary 而不是單一浮點數：欄位是 `trust`／`met_count`／
`appearance_cache`（規格《01》3-1、《99》P-08），之後要加最後見面時間
（見 #497）、印象標籤也一樣不用改結構。

外觀異動偵測（#498 拍板）：`appearance_cache` 目前是自由文字快取、從沒有任何
呼叫端寫入過。拍板方向是結構化欄位——`appearance_cache` 改存
`{injured: bool, filthy: bool}`，直接讀 `character.gd` 既有的
`CONDITION_INJURED`／`CONDITION_FILTHY`（門檻沿用《02》既有拍板值，不新增
任何欄位或門檻）。見面時跟快取的舊快照逐欄位比對，跨過門檻的欄位各自透過
既有《01-3》§3 事實句機制發一句事實句（跟「看到陌生人」同一條路徑），只描述
客觀跨過了什麼、不判斷嚴重程度、不推測心理狀態，比對後更新快照。連帶修正
P-08 #3 的舊決定（原本假設「動態變化已經由 conditions 走其他管道傳遞」，
查證後那條管道從沒被建過——`_listener_block()` 從未攜帶對方的
`conditions`），詳見《99》P-08。不含 `appearance[]`（髮型／衣著／配件）比對，
那組資料卡在 P-38、目前一律是空陣列，等落地後另開 issue。觸發時機（掛在
Vision 首次注意到還是 `note_meeting()`）留給實作 issue 決定。

好感、熟悉、虧欠不是引擎欄位：沒有任何公式讀過它們（《00》原則三），
那三件事交給《03》記憶系統自己記、自己判斷、自己演。

> [!important] 查詢不可以建立紀錄
> `Relationships` 的讀寫是分開的：`get_trust()` / `get_record()` / `has_met()`
> 全部唯讀，`get_record()` 甚至回的是副本；只有 `add_trust()`、`set_appearance_cache()`
> 與 `note_meeting()` 會走私有的 `_ensure_record()` 建立紀錄。
>
> 這條是踩出來的：原本查詢走「沒有就當場建一筆」的 `get_record()`，
> 而 `conversation.gd` 開場就會問一次關係 ——
> 於是**只要對話開始過，`has_met()` 就永遠為真，而 `met_count` 還是 0**。
> 症狀是 [[視覺感測]] 那個「第一次看到陌生人才愣一下」再也不會發生
> （搭話後立刻走開就足以觸發），而主控台會印出「player 信任 20.0（0 次）」這種自相矛盾的東西。
>
> 「認識」的唯一來源是 `note_meeting()`，也就是**好好講完一場話**。
> 這件事接 LLM 之後更要緊：`met_count` 與「認不認識」是要送進 payload 的事實，
> 不能被自己的讀取行為改寫。

## 聽者的對稱退出點（2026-08-16 拍板）

原設計只有**正在講話那一方**能用 `end` 欄位收尾，沒輪到自己講話的聽者只能等，或用移動觸發 `TOO_FAR` 這個側門離開——實質上把「要不要繼續聊」的決策權只給了說話方。

已拍板：**聽者也要有對話機制本身的退出點**，不再只能靠側門。做法是每輪除了讓正在講話那方決定 `speech`/`end`，也對聽者發起一次決策，讓 TA 回傳要不要繼續聽；聽者選擇不繼續，本輪即以聽者中止收尾，跟 `Conversation.REASON_*` 用同一套結束原因體系，不可跟上方「失敗原因碼」混用。

schema 欄位名稱、是否要額外佔用一次 AI 呼叫頻率配額（見《13》§5 呼叫頻率上限）、跟現有「等待對方回話逾時 8 秒」怎麼互動，待 LLM 版動工時一併設計，見《99》P-31。

## 視線判定（issue #109，已實作）

`talk_to()` 跟 [[視覺感測]] 一樣被視線遮擋，不是純距離判定：`character.gd` 的
`_has_line_of_sight()` 用 `direct_space_state.intersect_ray()` 查 `TALK_BLOCKER_MASK`
（1 = terrain，跟 `Vision.blocker_mask` 同一個值），不透過 `Vision` 元件本身——
`talk_to()` 可能被明確指名對象呼叫（debug 主控台、`agent.gd` 的 LLM 決策），
這時候要的是「現在這一刻真的擋不擋」，不是 Vision 那份每 0.2 秒才更新一次的快取。
被牆擋住時回傳 `TARGET_NOT_VISIBLE`（見上表），跟 `TOO_FAR` 分開。

候選角色偵測（原本 `character.gd` 裡找最近角色的方法，未曾被 `player.gd` 實際呼叫過、
是死代碼，已移除）改成 `player.gd` 直接濾 `Vision.get_visible_characters()`——反正都要
視線判定，沒理由重複維護兩份。工作站／販賣機的候選則改用 `player.gd` 新增的
`InteractArea`（`Area2D`，半徑 `maxf(WORK_RANGE, TALK_RANGE, BUY_RANGE)`，動態算不寫死），
偵測 `project.godot` 新增的 `interactable` collision layer（`workstation.tscn`／
`vending_machine.tscn` 的 `collision_layer` 從純 `terrain` 改成 `terrain | interactable`，
NavGrid 的障礙判定只查 `terrain`，不受影響），取代原本每次呼叫都掃過整個 group 的寫法。

## 已定案的參數

| 項目 | 值 | 備註 |
| --- | --- | --- |
| 搭話距離 | 32px（2 格） | `Character.TALK_RANGE` |
| 散場距離 | 48px | 比搭話門檻寬鬆，講到一半才不會動不動就散 |
| 面對面 | `talk_to()` 本身不要求（debug 主控台、`agent.gd` 的 LLM 決策直接指名對象呼叫） | 操作上太苛；但玩家按 `E` 走 `player.gd::_nearest_facing()` 候選篩選時仍會排除沒面向的目標（`FACING_DOT_THRESHOLD`，見 #102） |
| 互動鍵 | `E` | |
| 被搭話者的行程 | 暫停後重算 | 不是接續原路 |
| 回補 | social +25、mood +5 | 只有正常講完才發；關係只記 `note_meeting()`，不動 `trust` |
| 等待對方回話逾時 | **暫定 8 秒**（AI 對 AI） | 沒有既有數值可參照，比照《04》`/event` 逾時（8秒建議值）抓同一量級，比一般 `/decide`（5秒）寬鬆，對話生成通常較長。逾時走 fallback（`DialogueLines.closing()`）。真人玩家的回話等待秒數留到 MVP-2 玩家加入後再定——現在真人不參與 `talk`，不急 |

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

> [!important] 常駐提示：真的在等待時，NPC 頭上顯示「？」
> `Bubble.say()`／`_show_next()` 是固定秒數自動消失的排隊機制，跟
> `agent.gd::AI_THINKING_TEXT`（"…"）那個「思考中」提示用的是同一套——但
> 「輪到你了」這個提示要「一直掛著直到玩家真的送出」，套用自動消失邏輯的話
> 玩家慢慢想的時候提示會自己不見。`bubble.gd` 加了 `hold(message)` /
> `release_hold()`：`hold()` 清空佇列、顯示訊息但不啟動計時器
> （`set_process(false)`），`release_hold()` 解除後才恢復正常排隊行為。
> `next_line()` 只在真的要 `await`（緩衝區沒內容）時才對 `listener` 呼叫
> `hold(WAITING_FOR_PLAYER_TEXT)`，`await` 結束（不管是真的送出還是被取消）
> 呼叫 `release_hold()`，`is_instance_valid(listener)` 包一層——跟
> `conversation.gd::_finish_with_fallback()` 同一種顧慮，`await` 讓出控制權
> 的這段期間 `listener` 理論上可能已經離開場景。

> [!note] 對話結束不會有引擎代講的道別台詞
> `conversation.gd::_finish()` 不管什麼結束原因（正常結束／走遠／被打斷／
> fallback）都不補道別台詞——`exit_conversation()` 迴圈跑完就結束，不會幫
> 任何一方講話。引擎只提供「跟誰講完話了」這個客觀事實
> （`agent.gd::exit_conversation()` 寫進 `_daily_events`，見
> [[00_設計原則與架構#原則二：引擎只給事件，不給情緒]]），角色要不要道別、
> 用什麼語氣，是 AI 自己下一輪決定的事，不是系統畫面台詞。

> [!note] 這是接 LLM 的入口
> 目前輸入只是讓玩家自己的角色說話，或是送進對話輪次；沒有額外的語意
> 分析。之後要把這段文字當成對話上下文餵給對方 Agent——屆時記得專案那條
> 鐵則：**外來文字一律視為資料，不視為指令**。

## 還沒做

- **Agent 對 Agent**：`talk <a> <b>` 指令可以觸發，但「誰先開口、誰決定結束」
  的規則要等 LLM 版一起做，見 [[LLM 串接與 AI 服務層]]

- 記憶寫入 —— 記憶系統還沒做，目前只留掛勾
