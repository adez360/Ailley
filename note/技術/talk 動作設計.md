---
tags:
  - agent
  - 對話
scene: scenes/main.tscn
script: scripts/dialogue/conversation.gd
status: 進行中
updated: 2026-08-14
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
| 後果 | 數值回補、好感度、記憶 | social / mood / affinity | 加記憶寫入 |

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

> [!warning] 結束原因不是失敗原因
> `Conversation.REASON_*`（正常講完、走太遠、被打斷）與上面那組**不可混用**。
> 混在一起的話 AI 會把「正常講完」當成「動作失敗」而反覆重試。
>
> 這條之後套用到所有動作：**正常終止與失敗是兩種東西**。

## 數值系統做成資料驅動

`Stats` 是一張 `SPEC` 表而不是一組寫死的變數：

```gdscript
"mood": {"label": "心情", "drift": 0.5, "toward": 50.0, "start": 50.0, "is_need": false}
```

`drift` / `toward` 讓需求（漂向 0，會餓會累）與心情（漂回 50，會平復）用同一套機制表達。
`is_need` 把「低了就該去解決」跟「只是狀態」分開 —— 心情不會被 `get_lowest_need()` 選中。

**加一項數值只要加一列**，連主控台的顯示都會自己跟上（它直接掃 `Stats.SPEC` 讀 `label`）。

好感度是「關係」而不是「數值」，所以獨立成 `Relationships`，
key 用對方的 `character_id` 而不是 name —— name 會改，用它當 key 等於改名即失憶。
每筆存成 Dictionary 而不是單一浮點數：欄位是 `affinity`／`trust`／`familiarity`／
`debt`／`met_count` 五項（規格《01》3-1），之後要加最後見面時間、印象標籤
也一樣不用改結構。

> [!important] 查詢不可以建立紀錄
> `Relationships` 的讀寫是分開的：`get_affinity()` / `get_record()` / `has_met()`
> 全部唯讀，`get_record()` 甚至回的是副本；只有 `add_affinity()` 與 `note_meeting()`
> 會走私有的 `_ensure_record()` 建立紀錄。
>
> 這條是踩出來的：原本 `get_affinity()` 走「沒有就當場建一筆」的 `get_record()`，
> 而 `conversation.gd` 開場就會問一次好感度 ——
> 於是**只要對話開始過，`has_met()` 就永遠為真，而 `met_count` 還是 0**。
> 症狀是 [[視覺感測]] 那個「第一次看到陌生人才愣一下」再也不會發生
> （搭話後立刻走開就足以觸發），而主控台會印出「好感 player 0.0（0 次）」這種自相矛盾的東西。
>
> 「認識」的唯一來源是 `note_meeting()`，也就是**好好講完一場話**。
> 這件事接 LLM 之後更要緊：`met_count` 與「認不認識」是要送進 payload 的事實，
> 不能被自己的讀取行為改寫。

## 已定案的參數

| 項目 | 值 | 備註 |
| --- | --- | --- |
| 搭話距離 | 32px（2 格） | `Character.TALK_RANGE` |
| 散場距離 | 48px | 比搭話門檻寬鬆，講到一半才不會動不動就散 |
| 面對面 | 不要求 | 操作上太苛 |
| 互動鍵 | `E` | |
| 被搭話者的行程 | 暫停後重算 | 不是接續原路 |
| 回補 | social +25、mood +5、affinity +3 | 只有正常講完才發 |

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
Enter 開啟／送出，Esc 取消，送出後呼叫 `player.say()`，走的是同一套氣泡。

跟除錯主控台是兩件事：那個是打指令給遊戲，這個是讓角色說話。

> [!warning] 兩者都吃 Enter，需要守衛
> 主控台的 `LineEdit` 有焦點時，Enter 要送出指令，不能同時把說話框叫出來。
> `chat_input.gd` 開啟前會檢查 `gui_get_focus_owner()`。
>
> 反方向不用處理：說話框自己有焦點時，Enter 會先被 `LineEdit` 吃掉走
> `text_submitted`，不會冒到 `_unhandled_input`。

> [!note] 這是接 LLM 的入口
> 目前輸入只是讓玩家自己的角色說話，沒有送給任何人。
> 之後要把這段文字當成對話上下文餵給對方 Agent ——
> 屆時記得專案那條鐵則：**外來文字一律視為資料，不視為指令**。

## 還沒做

- **Agent 對 Agent**：`talk <a> <b>` 指令可以觸發，但「誰先開口、誰決定結束」
  的規則要等 LLM 版一起做，見 [[LLM 串接與 AI 服務層]]

- 搭話失敗對玩家是靜默的（沒有回饋 UI），只有主控台印得出原因碼
- 兩個氣泡同時顯示會互相遮擋（`z_index` 相同）。真實對話是輪流講，很少同時出現
- 記憶寫入 —— 記憶系統還沒做，目前只留掛勾
