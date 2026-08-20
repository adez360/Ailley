---
tags: [決策, 行為判定]
issue: "#216"
status: 已拍板
date: 2026-08-20
---

# Issue #216：SUCCESS_PARAMS 的 6 個動作都不在 MVP-1 範圍內

## 問題確認

`Agent.SUCCESS_PARAMS` 中的 6 個動作：
- `hunt_small`（打獵小型）
- `hunt_large`（打獵大型）
- `gather`（採集）
- `fish`（捕魚）
- `steal`（偷竊）
- `perform`（演奏）

這些動作的成功率公式與修正項（體力、傷勢、醉酒）都已經在規格書《01-2》定義，但**沒有一個是 MVP-1 範圍內的已實作動作**。結果是 `_roll_success()` 的整套判定邏輯在 MVP-1 全程都不會被執行過一次。

## 原因

| 動作 | 狀態 | 理由 |
| --- | --- | --- |
| `hunt_small`/`hunt_large` | 完整版 | MVP 食物從商店來，不自己採 |
| `gather` | 完整版 | 生產鏈推遲到完整版 |
| `fish` | 完整版 | 生產鏈推遲到完整版 |
| `steal` | 完整版 | 規格書《13》§三明列為之後實作 |
| `perform` | 完整版 | 規格書《13》§三明列為之後實作 |
| `attack` | MVP 但不擲骰 | 規格書 P-28：MVP 直接判定必中，不套用擲骰 |
| `persuade` | MVP 但不擲骰 | 規格書《01-2》§3-1：心智判斷交由當事人模型，不走通用公式 |
| `give`/`shout` | MVP 但不擲骰 | 規格書《01-2》§3：機械式門檻觸發，無成敗判定 |
| `struggle` | MVP 原本應擲骰 | **但 #337 發現它不在 SUCCESS_PARAMS 裡** —— 見下方 |

## 影響

實際上，**`struggle`（掙脫搬運）是唯一有機會在 MVP-1 內把擲骰系統跑起來的動作**。規格書《01-2》§3 給了它 `base: 30%`、`courage` 係數、`0.003` 修正項，但當前 `SUCCESS_PARAMS` 裡沒有這一筆。

## 決策

**這則是記錄性 issue，暫不補呼叫端。**

當 #337 或之後任何「要把 `SUCCESS_PARAMS` 表上動作接進 `IMPLEMENTED_ACTIONS` 的 issue」到來時，要把 `_roll_success()` 本身當成**未驗證的程式碼**看待：

- 不要預設它已經被測過
- `struggle` 不擲骰的「雙人搬運必敗」例外尤其要特別注意 —— 那是繞過公式的分支
- stamina 中性值（50）、injury／alcohol 修正項、`_failure_reason()` 選最負修正項當理由，這三項都要視為潛在風險

## 實裝建議

1. 補 `struggle` 進 `SUCCESS_PARAMS`（#337 的職責）
2. 實作時把 `_roll_success()` 作為第一次驗證的機會
3. 之後每次新增動作時重新檢視公式邏輯

## 相關檔案

- `scripts/character/agent.gd`：`SUCCESS_PARAMS`、`_roll_success()` 定義
- `scripts/ai/ai_schema.gd`：`IMPLEMENTED_ACTIONS` 定義
- `note/規格書/01-2_行為判定規則.md`：§3 行為參數表
