---
tags:
  - 技術
  - agent
  - llm
status: 進行中
script: scripts/ai/llama_sidecar.gd, scripts/ai/model_downloader.gd
updated: 2026-09-02
---

# LLM Sidecar 啟動（issue #772／#989，《16》§2.2）

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

正式版玩家拿到的檔案怎麼落到這兩個目錄，見下面「首次啟動主動下載」——
不是建置時打包進安裝包，是遊戲執行期自己下載（issue #989，推翻《16》B3）。

之後真的要做 Steam 發布（阻塞在《16》B7，Steamworks 帳號還沒申請）時，
`sidecar/` 目錄結構不用為了那一步改——`ModelDownloader` 落地的檔案位置
本來就跟這裡定義的目錄慣例一致。

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

## 已驗證：匯出版自動拉起（2026-09-02）

拿一份真的 `llama-server.exe`（含全部 `ggml-*.dll`／`llama-*.dll` 依賴）放進
匯出版執行檔旁的 `sidecar/windows/`、一份 7.5B 參數的 gguf 放進
`sidecar/models/`，`ai_config` 的 `local` provider 指到同一個檔名，實機跑
`export_presets.cfg` 匯出的獨立 `.exe`（不透過編輯器）：

- 遊戲啟動後 5 秒內 `llama-server.exe` 子進程確實被拉起
- 約 10 秒 `http://127.0.0.1:8080/v1/models` 回 200，遠低於
  `STARTUP_TIMEOUT_SEC`（30 秒），確認載進的是正確的模型檔
- 啟動參數（`--host 127.0.0.1 --port <port> --parallel <POOL_SIZE> -c 16000`）
  正確傳遞

《16》§2.2 驗收「匯出後的獨立執行檔能自動拉起 `llama-server` 並連線成功」
這半段（自動拉起＋連線成功）到此驗證過。**還沒驗證的部分**：真正對話/決策
走完整趟 `AIService` 流程（這次只測到 sidecar 自己回應 `/v1/models`，
沒實際觸發一次遊戲內決策）；用的也不是專案指定的 Qwen2.5-7B-Instruct，
是隨手可取得的另一顆模型，純粹測拉起機制本身，不代表正式要打包的模型
也是這個效能/相容性。

## 首次啟動主動下載（issue #989）

`ModelDownloader`（`scripts/ai/model_downloader.gd`）不是 autoload——玩家
點下「下載本機 AI 模型」時才由呼叫端 `ModelDownloader.new()` 生一個、
`add_child()`、接上 `progress_updated`／`finished` 訊號、呼叫 `start()`。
目標路徑呼叫 `LlamaSidecar.get_sidecar_dir()`／`get_platform_subdir()`／
`get_binary_name()` 這三個公開介面，不重寫一套路徑邏輯（原本是
`LlamaSidecar` 的私有函式，issue #989 開了公開包裝）。

下載來源：

- `llama-server` 執行檔：`ggml-org/llama.cpp` GitHub release（MIT），目前
  釘住 `LLAMA_CPP_RELEASE_TAG` 常數指定的版本，asset 命名
  `llama-<tag>-bin-win-cpu-x64.zip`。**只有 Windows**——macOS／Linux 的
  release asset 是 `.tar.gz`，Godot 內建 `ZIPReader` 解不開，這兩個平台
  `ModelDownloader.is_platform_supported()` 回 `false`，UI 端要另外顯示
  手動安裝引導
- 模型：Hugging Face `Qwen/Qwen2.5-7B-Instruct-GGUF`（Apache-2.0），目前
  預設抓 `qwen2.5-7b-instruct-q3_k_m.gguf`——單一檔案，避開 Q4_K_M 以上
  量化版都是分割檔（`-00001-of-0000N.gguf`）、目前 bundle 的 `llama-server`
  版本支不支援分割檔直讀還沒驗證過的不確定性。之後真的驗證過可以換更高
  量化版時，只需要改 `MODEL_FILENAME` 這一個常數（`ai_config.gd` 的
  `_DEFAULT_LOCAL_MODEL` 要跟著一起改，兩邊有註解互相提醒）

流程：查 `Content-Length`（查不到就跳過大小核對）→ `HTTPRequest.download_file`
串流下載 → zip 用 `ZIPReader` 解壓到 `sidecar/windows/` → 下載模型檔到
`sidecar/models/` → 檢查實際檔案大小是否符合 `Content-Length` → 成功後呼叫
`AIConfig.update_provider_model()` 把 `local` provider 的 `model` 欄位改成
實際抓到的檔名 → 呼叫 `LlamaSidecar.retry_launch()`，不用重開遊戲就能接上。

失敗（網路錯誤、磁碟空間不足、解壓失敗、檔案大小對不上）走 `finished(false,
reason)` 訊號，重試上限比照 `AIService.RETRY_LIMIT` 的既有慣例。磁碟空間
檢查目前是「試寫一個小檔案」這種保守判斷，不是精確查詢剩餘容量——Godot
沒有跨平台的容量查詢原生 API，精確查詢留給之後真的需要再做。

## 尚未驗證

上面「首次啟動主動下載」這段是 2026-09-02 寫的，還沒有實機跑過一次真的
下載（`HTTPRequest` 串流寫檔、`ZIPReader` 解壓、寫回 `ai_config.json`
這條完整鏈路）——目前只做過語法檢查（`--check-only`），沒有連進真的
Godot editor session 驗證過執行期行為。UI 觸發入口（建角面板旁的下載
按鈕、主選單/設定畫面的入口）也還沒做，需要連進這個 worktree 專屬的
Godot editor 才能用 `godot-ai` MCP 建立場景，見《技術/平行 Worktree 與
Godot MCP》。

## 相關

- [[LLM 串接與 AI 服務層]] —— `AIConfig`／`AIService` 的完整設計，`provider`
  的資料結構、`_probe_models()` 就緒探測
- 《規格書/16_打包與發布規格書》§1 B3／§2.2 —— 這則功能對應的架構決策
  （B3 推翻紀錄）與驗收標準
- issue #989 —— 首次啟動主動下載，`ModelDownloader` 本體
- issue #982 —— 建角面板「沒有可用 provider」的提示文字，下載入口預計
  接在同一個位置旁邊
- Steam depot 拆分（《16》B4／§2.6）目前暫緩，見《16》§1 B4
