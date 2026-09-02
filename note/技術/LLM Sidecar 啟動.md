---
tags:
  - 技術
  - agent
  - llm
status: 進行中
script: scripts/ai/llama_sidecar.gd
updated: 2026-08-31
---

# LLM Sidecar 啟動（issue #772，《16》§2.2）

開機自動拉起隨遊戲附帶的 `llama-server` 子進程，讓玩家不用自己手動啟動就能用
本機 AI。跟 [[LLM 串接與 AI 服務層]] 是分工關係：`LlamaSidecar`（autoload）
只管「把子進程叫起來、盯著它有沒有活著」，真正的 HTTP 就緒探測仍然是
`AIService._probe_models()` 那一套，兩邊不重工。

## 只在需要時才拉起

`AIConfig.get_local_provider()`／`has_local_provider()`：掃 `providers` 找
第一個 `base_url` 指向本機 loopback（127.0.0.1／localhost／`[::1]`）的
provider。玩家把本機 provider 拿掉、只留雲端時，`LlamaSidecar._ready()`
直接跳過，不平白多開一個背景進程。判斷條件看 `base_url` 指到哪裡，不是
provider 的 key 是不是叫 `"local"`——那個名字是玩家自訂代號，見
`ai_config.gd::get_provider_by_model()` 的說明。

自拉的 `--host` 與探針 URL 都寫死 `127.0.0.1`，所以 sidecar 自拉只支援
127.0.0.1／localhost 兩種寫法：provider host 是 `[::1]` 等其他 loopback
寫法時標記 `Status.UNSUPPORTED_HOST` 並 `push_warning`，不自動啟動、也不
靜默錯連——手動開著的服務不受影響，`AIService` 照常連它。

## 目錄慣例（issue #772 拍板，尚未有實體檔案進版控）

```
res://sidecar/<platform>/llama-server[.exe]     platform: windows / macos / linux
res://sidecar/models/<model 檔名>                檔名取 provider.model，跟 ai_config.json 對齊
```

`sidecar/` 整個目錄 `.gitignore` 掉，執行檔與模型檔由開發者自己放進去測試連線
——這兩種檔案體積太大、也因平台/量化版本而異，不適合進版控，跟
`THIRD_PARTY_LICENSES/` 的授權文字（那個要進版控）是兩回事。

`include_filter` 收進 .pck 的檔案只有 `res://` 讀得到，而 `llama_sidecar.gd`
在匯出版解析的是「執行檔旁的真實檔案系統路徑」再 `OS.create_process()`——
.pck 內資源不是磁碟檔案，exec 不了，所以 sidecar 執行檔（各平台預編譯
`llama-server`）與模型檔**不隨 Godot 匯出自動打包**，`export_presets.cfg`
的 `include_filter` 維持 `data/*.json`。

正式版發布時以建置後步驟放置：匯出後複製到執行檔旁 `sidecar/` 目錄，或發布
管線的 content 步驟（Steam depot content root，見《16》B4／issue #793）。

之後真的要切 Steam 獨立 depot（《16》B4）時，整個 `sidecar/` 目錄就是預定的
depot content root，這裡的路徑不用為了那一步再改——depot 拆分與上架設定另開
issue，見下方「相關」。

### 兩種路徑解析（開發／匯出分開判斷）

`OS.has_feature("editor")` 為真（編輯器 Play 模式）時用
`ProjectSettings.globalize_path("res://sidecar")`，讓開發者直接把測試檔案放進
專案目錄就地測試；`OS.get_executable_path()` 在編輯器模式下指到的是編輯器
本體，不是這個專案，不能拿來算路徑。匯出版才用「執行檔旁邊的 `sidecar/`
資料夾」這個慣例（`OS.get_executable_path().get_base_dir()`）。

## 啟動流程

1. 開機前先探測目標埠（`_probe_port()`，輕量 HTTP GET，連得上且回 2xx 才算
   有服務在聽，判定比照 `AIService._probe_models()`）——已經有東西在聽就
   沿用，不重複啟動一份（`Status.ALREADY_RUNNING`），涵蓋開發者手動已經
   開著一份 `llama-server` 的既有測試情境
2. 執行檔／模型檔用 `FileAccess.file_exists()` 檢查，缺一個就 `push_warning`
   並停在 `Status.MISSING_BINARY`／`MISSING_MODEL`，不嘗試拉起
3. `OS.create_process(binary_path, args, false)`，`args` 帶 `-m <model_path>
   --host 127.0.0.1 --port <port> --parallel <AIService.POOL_SIZE> -c 16000`
   （`--parallel` 引用 `AIService.POOL_SIZE` 同一份常數、兩邊不脫鉤，對齊
   關係見《04 Godot與AI資料介接規格》§1）
4. 叫起後先等 `CRASH_CHECK_SEC`（2 秒）觀察窗——沒撐過這段代表根本起不來
   （最常見原因是埠被佔用、`bind()` 失敗立刻結束），標記 `Status.CRASHED`
5. 撐過觀察窗後改成輪詢 `_probe_port()`，`STARTUP_TIMEOUT_SEC`（30 秒）內
   探測到回應就標記 `Status.READY`，補一次就緒套用：先等
   `AIService.reload_config_and_wait()` 的探測真的回來，再遍歷 `agents`
   group、對還沒打開 `llm_decision_enabled` 的 Agent 重跑一次
   `GameManager.activate_llm_decision_if_ready()`——開機那批套用
   （`main_scene.gd::_apply_startup_ai_state()`）打在 sidecar 都還沒起來的
   時間點，沒人在這個時機重新套用的話，這一局不會有 LLM 決策，正式建置又
   停用 debug 主控台，玩家沒有救回路徑；逾時仍未回應則標記
   `Status.START_TIMEOUT`

## 失敗處理：現有容錯路徑，不另立新 UI

所有失敗分支（provider host 不支援自拉／缺執行檔／缺模型／`create_process()`
失敗／啟動後崩潰／逾時）一律 `push_warning` 到 log，並把 `status`／
`status_reason` 記在
`LlamaSidecar` 自己身上（可用 `game_eval` 直接讀）。**刻意不另外做彈窗或
玩家可見的錯誤通知**——本機 AI 連不上時，遊戲既有的「AI 未就緒→排程模式」
容錯行為本來就會接手（跟 `ai_config.json` 找不到、格式錯誤等既有失敗情境
是同一條路），正式版給玩家看的 AI 狀態 UI 是 issue #356 的範圍，不在這裡
重新發明一套。

## 關閉：引擎拆樹時才收，不搶在 GameManager 存檔之前

引擎真的拆樹時（`_exit_tree()`，`NOTIFICATION_EXIT_TREE`）呼叫
`OS.kill(_pid)`。`game_manager.gd` 收到 `NOTIFICATION_WM_CLOSE_REQUEST` 負責
存檔與 `get_tree().quit()`，await 期間可能長達數十秒（等的是還在飛的睡眠
反思請求）——autoload 順序 GameManager 第一、`LlamaSidecar` 最後，若在同一個
通知就同步殺子進程，會把 GameManager 還在等的服務提前殺掉；改在 EXIT_TREE
（存檔完成、引擎拆樹）才收，兩邊互不等待的分工不變。

> [!warning] 編輯器 Play 模式按 Stop 鍵不會走拆樹這條路徑
> Stop 鍵是強制砍掉整個編輯器子行程，收不到 `NOTIFICATION_EXIT_TREE`，
> 子進程可能變成孤兒、留在背景繼續跑。跟遠端 GPU 機器的 SSH tunnel「機器
> 關機／重開會中止」是同一種已知的開發期限制，沒有更好的解法，開發者自己
> 用工作管理員／`kill` 清理。

## 尚未驗證

這次落地時本機沒有放真的 `llama-server` 執行檔／模型檔進 `sidecar/`
測試——《16》§2.2 驗收要求的「匯出後的獨立執行檔能自動拉起 `llama-server`
並連線成功」需要開發者自己放進實體檔案後在編輯器或匯出版裡實測一次；
這裡只驗證過「檔案不存在」那條路徑（`Status.MISSING_BINARY`／
`MISSING_MODEL`）不會讓遊戲卡死或崩潰。

## 相關

- [[LLM 串接與 AI 服務層]] —— `AIConfig`／`AIService` 的完整設計，`provider`
  的資料結構、`_probe_models()` 就緒探測
- 《規格書/16_打包與發布規格書》§2.2 —— 這則功能對應的架構決策與驗收標準
- Steam depot 拆分（《16》B4／§2.6）的實際落地建議另開 issue 追蹤，不在這裡
