---
tags: [技術, packaging, ai]
status: 現況
updated: 2026-09-02
---

# 打包雲端 AI 驗證

匯出後的獨立執行檔（不透過編輯器）在純雲端 `RemoteLLM` 設定下的連線驗證方法與結果。
對應 issue：#981（純雲端驗證，部分完成——GUI 主選單與真 key 對話／決策未驗）、
#581（Local＋Cloud 兩半，Local 半仍未驗證）。

## 匯出前置：Git LFS 必須已實體化

repo 的美術／字型資產走 Git LFS（`Ailley/.gitattributes`）。乾淨 clone／新 worktree
如果 LFS 沒 pull，`assets/` 下的 `.png`／`.ttf` 是 132-byte 的 pointer 文字檔，後果：

- `godot --headless --import` 會卡死在 FreeType 錯誤迴圈（每秒數百行
  `ERROR: FreeType: Error loading font: ''`，進度停在掃描初期不前進，100% CPU）；
- 就算硬匯出，包進 `.pck` 的也是壞的資源。

解法（每個新 worktree 做一次）：

```bash
git lfs install --local
git lfs pull
```

## 匯出流程（Linux）

```bash
cd Ailley
godot --headless --import          # 先同步 import 快取
godot --headless --export-release "Linux" /tmp/ailley-export/ailley.x86_64
```

2026-09-02 實測：匯出成功，產出 74.8 MB 執行檔（`binary_format/embed_pck=true`，
`.pck` 內嵌）。`.pck` 內含 `data/ai_config.example.json` 與 `THIRD_PARTY_LICENSES/*`、
不含真實 `data/ai_config.json`（《16》§2.1 紅線核對通過，以 `strings` 掃執行檔確認）。

注意：Godot 4.5 會把 GDExtension 的 `libgdsqlite.linux.template_release.x86_64.so`
自動帶到執行檔旁邊——這與 §2.1「不含 GDExtension 匯出」的舊拍板不一致（專案實際上
已接上 SQLite，見《14》），該段落要等下一次規格書同步收斂。

## 首次啟動自動產生設定檔（§2.3，已驗證）

匯出版在乾淨的 `user://` 下啟動，會自動寫出
`user://ai_config_<CheckoutIsolation hash>.json`（匯出版的 hash 取自執行檔所在目錄，
見 `scripts/core/checkout_isolation.gd`），內容是內建 sidecar 預設值：
`default_provider: "local"`、`http://127.0.0.1:8080/v1`。玩家自己填雲端 key 才會走
`RemoteLLM`——雲端不在自動產生範圍，跟 §2.3 的拍板一致。

## 雲端連線驗證（#981 的核心）

驗證方式：把設定檔換成只含一個 OpenRouter provider（無本機 provider），headless 跑
匯出檔 50 秒，用 `ss -tnp` 每秒輪詢該行程的連線，並以本機 mock 端點比對應用層請求。

結果（2026-09-02）：

- **TCP／TLS 通**：遊戲行程對 `104.18.2.115:443`（openrouter.ai）建立連線，
  輪詢穩定抓到；遊戲 log 0 ERROR。
- **應用層請求內容正確**：把 provider `base_url` 指向本機 mock
  （`http://127.0.0.1:8899/v1`），mock 收到
  `GET /v1/models`，帶 `Authorization: Bearer sk-or-v1-…` 與
  `User-Agent: GodotEngine/4.5.1.stable.official (Linux)`——即
  `AIService._probe_models()` 的開機就緒探測，金鑰從 `user://` 設定檔正確注入。
- **純雲端模式不拉 sidecar**：設定檔沒有 loopback provider 時，log 沒有任何
  `[LlamaSidecar]` 訊息（`NOT_ATTEMPTED` 靜默路徑，對照 `llama_sidecar.gd::_maybe_launch()`）。
- **缺 sidecar 不閃退**：預設設定檔（local provider）下，缺
  `sidecar/linux/llama-server` 只有一行 warning
  （`找不到內建的 llama-server 執行檔…這次不會自動啟動本機 AI`），遊戲照常開機。

### 沒驗證到的

- **真金鑰的端到端對話／決策**：這台機器沒有真實 OpenRouter key。用假 key 打
  auth 管制的端點會得到預期失敗（curl 實測 `POST /chat/completions` →
  `401 {"error":{"message":"User not found."}}`）；`GET /models` 是公開端點、
  假 key 也回 200，所以開機探測在假 key 下就會報 ready。真 key 的完整對話／決策
  屬 #581 的 Cloud 半，等有真實 key 的環境再驗。
- **GUI 開機到主選單**：本 session 沒有可用的顯示器存取權，以 headless 開機
  （45–50 秒穩定運行、0 ERROR、場景載入無錯）替代，未做畫面確認。

## Local 半（#581 剩下的）

本機沒有 `sidecar/` 目錄（llama-server 與模型檔）。§2.2 的執行期下載（issue #989）
已落地，但僅支援 Windows；Linux 的手動安裝流程也沒有隨包文件。所以「llama-server
隨遊戲拉起」這半在本 Linux 機無法驗證——Local 半待 Windows 環境或 sidecar 檔
到位再補。
