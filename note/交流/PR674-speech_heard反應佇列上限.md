---
tags: [決策, character, AI]
issue: "#669"
pr: "#674"
status: 待拍板
date: 2026-08-28
---

# PR #674：`_pending_reaction_lines` 要不要設上限

## 問題

CodeRabbit 在 PR #674 上提出（`Ailley/scripts/character/agent.gd` 附近
`_on_speech_heard()`）：`_pending_reaction_lines` 沒有筆數上限，`_queue_reaction_fact_line()`
無條件往裡面塞。等待中的一次決策請求（`_awaiting_decision=true`）期間，
新進的 `speech_heard`／`noise_heard`／`spotted` 事件雖然不會另外觸發新請求
（`_request_next_decision()` 的 `_awaiting_decision` 重入檢查會直接短路），
但照樣會被排進 `_pending_reaction_lines`；累積的內容要等下一次自然觸發的
決策請求（例如排程重算）才會被一次送出，中間若堆積很多筆事實句，`fact_lines`
payload 可能一次塞進大量內容。

這個機制本身（`_pending_reaction_lines` 無上限）不是這次新加的——`noise_heard`／
`spotted` 從 #407／#433 就是這樣，只是聲音／視覺事件天生稀疏（按鍵觸發、
初次相遇各一次），實際上很難堆積。這次新增的 `speech_heard`（issue #669）
接在 `Character.say()`，一般聊天、`talk_to()` 對話每一句都會觸發，頻率
遠高於前兩者，让"一次决策等待期间堆積多筆"從理論風險變成實際可能發生
的情境（例如玩家在等待 NPC 回應決策時連續打好幾句話、或多個 NPC 同時在
3 格範圍內交談）。

## 為什麼不自己決定

`CLAUDE.md`〈遊戲機制規格：AI 自主性自檢〉：「常發生」不是「不重要」的
理由——CodeRabbit 建議的修法是「加入佇列上限或合併語音事件」，這兩種都
代表拿掉一部分事實句、不讓 AI 看到完整內容，且理由是「太常發生會讓
payload 過大」，是成本論證。這正是規則要求先拋出來讓使用者拍板、不能
自己直接判定「這些事件不重要可以丟」的情況。

## 選項（初步列出，供拍板參考）

1. **維持現況，不設上限**：跟既有 `noise_heard`／`spotted` 架構一致，
   接受這是既有架構的已知延伸風險，不在 #669／PR #674 這裡處理，另開
   issue 追蹤（若要處理，範圍應該是 `_pending_reaction_lines` 整體機制，
   不只是 speech 這個新來源）。
2. **設筆數/字數上限，超過時捨棄最舊的**：明確接受「太密集的事實句會
   有資訊漏失」，把這個取捨攤在檯面上讓使用者確認可接受。
3. **決策請求完成後立刻檢查佇列、非空就自動觸發下一輪**（不等排程重算）：
   降低累積視窗，不捨棄任何事件，但會增加 LLM 呼叫頻率——本身也是一種
   成本／自主性取捨，一樣要明講。
4. 其他使用者想到的方向。

## 相關檔案

- `Ailley/scripts/character/agent.gd`：`_pending_reaction_lines`／
  `_queue_reaction_fact_line()`／`_fact_lines_summary()`／`_request_next_decision()`
- `note/技術/聽覺感測.md`
- `note/規格書/01-3_Prompt注入與資料傳送.md`§3（事實句機制，`_pending_reaction_lines`
  不在文件列的九條事實句清單內，這份規格沒有直接管到它）
