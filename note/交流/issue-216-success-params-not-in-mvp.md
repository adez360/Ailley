---
tags: [決策, 行為判定]
issue: "#216"
status: 已拍板
date: 2026-08-20
---

# Issue #216：SUCCESS_PARAMS 動作接上執行層前要當作未驗證程式碼看待

## 問題確認

`Agent.SUCCESS_PARAMS` 原本列了 6 個動作，成功率公式與修正項（體力、傷勢、醉酒）都已經在規格書《01-2》定義，但直到 2026-08-20 為止**沒有一個是已實作、真的被 `resolve()` 擲骰過的動作**——這些動作都不在當時的 `IMPLEMENTED_ACTIONS` 上，`_roll_success()` 本身雖然會被 MVP-1 其他動作呼叫，但一律在 `params.is_empty()` 那關直接放行，成功率公式那段分支從沒被執行過。

`gather`（採集）已於 2026-08-24 拉進 MVP、issue #574 接上執行層，是這 6 個動作裡第一個真正跑過 `_roll_success()` 擲骰的——落地時發現的坑（`resolve()` 不能只在 llm 來源才呼叫、`_pursue_gather_task()` 移動順序要先驗證再走）印證了下面「決策」段落的警告，其餘 5 個仍待接上：

## 原因

| 動作 | 狀態 | 理由 |
| --- | --- | --- |
| `hunt_small`/`hunt_large` | 完整版 | MVP 食物從商店來，不自己採 |
| `fish` | 完整版 | 生產鏈推遲到完整版 |
| `steal` | 完整版 | 規格書《13》§三明列為之後實作 |
| `perform` | 完整版 | 規格書《13》§三明列為之後實作 |
| `attack` | MVP 但不擲骰 | 規格書 P-28：MVP 直接判定必中，不套用擲骰 |
| `persuade` | MVP 但不擲骰 | 規格書《01-2》§3-1：心智判斷交由當事人模型，不走通用公式 |
| `give`/`shout` | MVP 但不擲骰 | 規格書《01-2》§3：機械式門檻觸發，無成敗判定 |
| `struggle` | MVP 原本應擲骰 | **但 #337 發現它不在 SUCCESS_PARAMS 裡** —— 見下方 |

## 影響

`struggle`（掙脫搬運）仍未補進 `SUCCESS_PARAMS`。規格書《01-2》§3 給了它 `base: 30%`、`courage` 係數、`0.003` 修正項，但當前表上沒有這一筆。

## 決策

**這則是記錄性 issue，只記警告，不代替實作 issue 補呼叫端。**

當 #337 或之後任何「要把 `SUCCESS_PARAMS` 表上動作接進 `IMPLEMENTED_ACTIONS` 的 issue」到來時，要把 `_roll_success()` 本身當成**未驗證的程式碼**看待：

- 不要預設它已經被測過
- `struggle` 不擲骰的「雙人搬運必敗」例外尤其要特別注意 —— 那是繞過公式的分支
- stamina 中性值（50）、injury／alcohol 修正項、`_failure_reason()` 選最負修正項當理由，這三項都要視為潛在風險
- 排程來源（`source == "schedule"`）任務若也可能落到這個動作，成功或失敗都要記得掛 `_mark_schedule_retry_backoff()`——沒有 satiety 那種會隨動作完成自然下降的分數時，同一窗期內每個遊戲分鐘都可能被立即重選中、重複執行（`gather` 落地時發現的坑）

## 實裝建議

1. 補 `struggle` 進 `SUCCESS_PARAMS`（#337 的職責）
2. 實作時把 `_roll_success()` 作為第一次驗證的機會
3. 之後每次新增動作時重新檢視公式邏輯

## 相關檔案

- `Ailley/scripts/character/agent.gd`：`SUCCESS_PARAMS`、`_roll_success()` 定義
- `Ailley/scripts/ai/ai_schema.gd`：`IMPLEMENTED_ACTIONS` 定義
- `note/規格書/01-2_行為判定規則.md`：§3 行為參數表
