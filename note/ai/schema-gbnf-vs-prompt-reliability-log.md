---
tags: [ai, reference]
status: 現況
updated: 2026-08-18
---

# GBNF 強制 vs 純 prompt 約束：可靠度測試歷史彙總報告

供 [[12_決策來源抽象與執行架構規格書]] §7.3 引用。人類不必讀這份，
只是歷史彙總報告的存檔，回答「當時到底測了什麼」。

## 測試環境

- model：`Qwen2.5-7B-Instruct-Q4_K_M.gguf`（7.6B 參數，Q4_K_M 量化）
- llama.cpp build：`b1-aff6eb6`（`/props` 的 `build_info`）
- endpoint：`http://100.85.79.25:8080/v1/chat/completions`（遠端 GPU 機器，見
  [[30-技術/遠端GPU機器連線手冊-替換用]]）
- sampling：request 沒有帶自訂參數，用 server 預設值——
  `temperature=0.8`、`top_p=0.95`、`top_k=40`、`min_p=0.05`、`repeat_penalty=1.0`
- seed：沒有固定——`AIService._build_body()` 不送 `seed` 欄位，每次請求用
  server 端隨機值（`/props` 回報的 `4294967295` 是 llama.cpp「未指定」的
  sentinel，不是真的固定種子）
- 測試方法：透過真正的決策路徑（`PromptBuilder.build_plan_envelope()` →
  `LocalLLMProvider.decide()` → `AISchema.parse_completion()` →
  `AISchema.validate_tasks()`），不是繞過驗證層的合成測試；每次請求用不同的
  `requester_id`（`reliability_test_true_N`／`reliability_test_false_N`）避開
  `AIService` 的每日配額與冷卻限制，不代表真正遊戲內會這樣連續呼叫
- `supports_json_schema` 開關直接改 `AIService.config.providers["local"]`
  的執行期屬性切換，不改設定檔

## 第一輪（issue #245，2026-08-17，schema commit 469f54d／141278e）

| 組別 | 樣本數 | 通過 | 失敗原因 |
|---|---|---|---|
| GBNF 強制（`supports_json_schema=true`） | 50 | 50 | — |
| 純 prompt 約束（`supports_json_schema=false`） | 50 | 47 | 3 次 `action_not_allowed`（模型自己生成 `"work"`，不在白名單內） |

第一輪為歷史彙總報告：測試當時只記錄了總樣本數與失敗原因統計，沒有保留逐筆的 sample index、stage、failure detail。因測試時未固定 random seed（見上述「測試環境」），歷史樣本無法透過重新執行再現。

## 第二輪（2026-08-18，同一個 schema/prompt 版本，commit 99be6cd，補測可重現性資訊用）

| 組別 | 樣本數 | 通過 | 失敗原因 |
|---|---|---|---|
| GBNF 強制（`supports_json_schema=true`） | 50 | 50 | — |
| 純 prompt 約束（`supports_json_schema=false`） | 50 | 50 | — |

第二輪為歷史彙總報告：測試過程中並未保存逐筆的樣本資料（如 sample index、stage、per-request failure detail），僅記錄兩組各 50 次請求的通過／失敗統計。100 筆請求全部通過驗證（`stage="ok"`），無失敗案例。因測試時未固定 random seed（見上述「測試環境」），歷史樣本無法透過重新執行再現。如需逐筆原始資料，可用同一套測試方法重新執行並記錄每次請求的完整 response 與驗證結果——見上面「測試方法」。

## 兩輪合計

| 組別 | 樣本數 | 通過 | 失敗率 |
|---|---|---|---|
| GBNF 強制 | 100 | 100 | 0% |
| 純 prompt 約束 | 100 | 97 | 3% |

第二輪沒有重現第一輪的 `action_not_allowed` 失敗——樣本數還小，這在 6% 真實
失敗率下（二項分布）本來就有約 4.7% 的機率連續 50 次全過，不是「問題消失了」
的證據。兩輪合計後純 prompt 約束仍有非零失敗率，GBNF 強制仍是零失敗，結論
方向沒變：GBNF 文法層強制比純 prompt 約束可靠，只是原本「6%」這個數字在
更大樣本下會往下修正，不是精確值。

## 附帶觀察

第二輪第 27 次請求（GBNF 強制組）觸發過一次 `ai_schema.gd:102` 的
`Exponent too high` 警告——跟第一輪記錄的那次一樣，是 priority 欄位飆出
離譜大指數值的症狀（`AISchema` 的 `parse_object()` 解析數字時的邊界情況）。
這個分支的 schema 仍是重構前的版本（`priority`/`duration` 型別是
`"number"`，見 #267 的發現：GBNF 對 `"number"` 型別不擋 `minimum`/`maximum`），
跟這次觀察到的異常值一致；`AISchema.validate_tasks()` 的 `is_finite()` 檢查
（#224 加的）在這個分支上已存在，最終還是被 layer 3 擋下，沒有讓壞值流進
仲裁器。
