# CLAUDE.md — Ailley Godot 專案

本檔規範「在這個 Godot 專案裡怎麼工作」。
上層 `../CLAUDE.md`（note/ 筆記庫規則）與全域 `~/.claude/CLAUDE.md` 仍然有效，
衝突時以本檔為準。

## 專案概況

- Godot **4.5.1-stable**，renderer: `gl_compatibility`（2D 像素風，`default_texture_filter=0`）
- 主場景：`project.godot` 的 `run/main_scene`（以 uid 指定，目前是 `scenes/main.tscn`）
- Autoload：`GameManager`、`GameClock`、`AIService`、
  `_mcp_game_helper`（godot_ai 執行期輔助，勿手動移除）
- 已啟用外掛：`TileMapDual`、`godot_ai`

目錄：

| 路徑 | 內容 |
| --- | --- |
| `scenes/` | 全部 `.tscn`，不放腳本 |
| `scripts/core/` | autoload：時鐘、靜態資料 |
| `scripts/character/` | Character 基底、Player/Agent、Stats/Relationships/Vision 元件 |
| `scripts/world/` | NavGrid、FollowCamera |
| `scripts/dialogue/` | Conversation、DialogueLines |
| `scripts/ai/` | LLM 服務層。**全專案唯一碰網路的地方** |
| `scripts/ui/` | Bubble、ChatInput、DebugConsole、DebugOverlay、TimeLabel |
| `data/*.json` | NPC 排程、地點資料、AI 設定範本 |
| `assets/`、`addons/` | 素材、外掛 |

文件全部在 `../note/` 筆記庫：入口 `Ailley.md`、公開介面 `ai/api.md`、
設計理由看 `技術/` 底下各系統自己那則。**不要在 Godot 專案裡另開 `docs/`。**

## 核心規則：Godot 相關操作一律走 godot-ai MCP

**只要任務碰到場景、節點、資源、輸入映射、autoload、動畫、執行遊戲，
第一步就是呼叫 `mcp__godot-ai__*` 工具，不要用 Read/Edit/Bash 去猜 `.tscn` 的內容。**

理由：`.tscn`/`.tres` 是帶 uid 與內部 id 的序列化格式，手改極易產生
壞掉的 ExtResource/SubResource 參照；MCP 直接操作執行中的編輯器，
改完即時生效且由編輯器自己負責序列化。

### 每次開工的前置檢查（省略會拿到 EDITOR_NOT_READY）

1. `session_manage(op="list")` — 確認編輯器有連線
2. 多個 session 時 `session_activate` 綁定到 `project_path` 為本專案者
3. `editor_state` — 確認 `readiness=ready`、`game_status.status`、目前開啟的場景

若沒有任何 session：代表 Godot 編輯器沒開或 godot_ai 外掛沒載入。
**回報使用者請他開啟編輯器，不要改用手工編輯 .tscn 繞過。**

### 工具對照表（要做什麼 → 用哪個）

| 目的 | 用這個 | 不要用 |
|---|---|---|
| 看場景結構 | `scene_get_hierarchy` | Read `.tscn` |
| 找節點 | `node_find` | grep `.tscn` |
| 看/改節點屬性 | `node_get_properties` / `node_set_property` | 手改 `.tscn` |
| 新增/刪除/搬移/改名節點 | `node_create` / `node_manage` | 手改 `.tscn` |
| 開啟、另存、儲存場景 | `scene_open` / `scene_manage` / `scene_save` | — |
| 建立腳本並掛上節點 | `script_create` + `script_attach` | Write + 手改 `.tscn` |
| 訊號連接 | `signal_manage` | 手改 `.tscn` 的 `[connection]` |
| Autoload 增修 | `autoload_manage` | 手改 `project.godot` |
| 專案設定 | `project_manage(op="settings_get"/"settings_set")` | 手改 `project.godot` |
| 輸入映射 | `input_map_manage` | 手改 `project.godot` |
| TileMap / TileSet | `tilemap_manage` / `tileset_manage` | 手改 `.tscn` |
| 動畫 | `animation_create` / `animation_manage` | 手改 `.tres` |
| 資源、檔案總管操作 | `resource_manage` / `filesystem_manage` | `mv` / `rm` |
| 查 Godot 4.5 類別 API | `api_manage` | 憑印象寫（4.x 之間差異大） |

腳本內容：**純 GDScript 邏輯**可以用 Read + Edit 直接改（`scripts/` 底下
都是一般文字檔）；但若該檔案正被編輯器開著，改完呼叫一次
`filesystem_manage`（rescan）或 `script_manage(op="read")` 確認編輯器已同步。
需要精準片段替換時 `script_patch` 比 Edit 更安全。

### 完成後一定要驗證

不准只說「應該可以了」。依情境擇一並附上實際輸出：

- `project_run` 跑起來 → `logs_read` 檢查有無錯誤 → `project_manage(op="stop")`
- 視覺類改動：`editor_screenshot` 附上結果
- 執行期狀態查驗：`editor_manage(op="game_eval")`
- 有測試時：`test_run` → `test_manage(op="results_get")`
- 多步驟一次做完：`batch_execute`（比逐一呼叫快，但錯誤定位較難，改動大時分開做）

## 禁止事項

- 不要手動編輯 `.tscn`、`.tres`、`.import`、`.uid`、`project.godot` 的結構性內容
- 不要碰 `.godot/`（本機快取，已 gitignore）
- 不要刪除 autoload `_mcp_game_helper` 或停用 `godot_ai` 外掛
- 不要在專案根目錄亂放暫存檔（`scenes/` 只放 .tscn、腳本一律進 `scripts/<領域>/`）

## 搬移或改名檔案

MCP 兩邊都**沒有**搬檔的 op，所以只能用 `git mv`。流程固定，順序不能改：

1. 關掉編輯器（`editor_manage(op="quit")`）
2. `git mv` 檔案與它的 `.uid` / `.import` sidecar（一定要一起搬，uid 存在裡面）
3. `--headless --path . --import` 重建 uid 快取
4. 重開編輯器，把每個受影響的場景 `scene_open` + `scene_save` 一次
5. 手動改字串路徑 —— `load("res://...")` 這種沒有任何工具會幫你改

> 開著編輯器搬檔會壞：它把搬檔前的場景副本留在記憶體，之後任何一次存檔
> 都會寫回舊路徑。實際踩過 —— 它把 `ext_resource` 的 `uid=` 整個拿掉，
> 只留下已經失效的 `path=`，而且 `force_reload` 也叫不回來。

## Headless 驗證

Godot 執行檔不在 PATH，`mcp__godot__launch_editor` 因此也用不了。
不需要編輯器連線就能驗兩件事：

```bash
G=$(command -v godot || echo /usr/share/godot/Godot_v4.5.1-stable_linux.x86_64)
$G --headless --path . --check-only --script scripts/<領域>/x.gd   # 語法
$G --headless --path . --quit-after 300                            # 開得起來嗎
```

> [!warning] `--check-only` 認不得 autoload 與新註冊的 class
> 它只 parse 單一檔案，所以引用 `GameManager`／`GameClock`／`AIService` 的檔案
> 一定會報 `Identifier not found`，那是模式限制不是程式錯誤。
> 剛加了新的 `class_name` 也一樣 —— 要先 `filesystem_manage(op="scan")`
> 讓編輯器把它註冊進 global class 快取，否則整個檔案都是 Parse Error。

結尾的 `RID allocations ... leaked at exit` / `ObjectDB instances leaked`
是 `--quit-after` 強制結束的正常雜訊，不是專案錯誤。

> [!warning] Headless 測不到時間相關的邏輯
> 沒有視窗時幀率不受限，`--quit-after 300` 可能連 1 秒真實時間都不到。
> 任何靠 `_process` 計時、`create_timer`、或訊號節流的行為都不會觸發 ——
> 這種一定要在編輯器裡用 `project_run` + `game_eval` 驗。

> [!warning] `-s <script>.gd` 自訂主迴圈一樣認不得 autoload，跟 `--check-only` 同一個病根
> 想寫一支 throwaway 的 `extends SceneTree` 腳本、`instantiate()` main.tscn
> 來做端到端驗證時，只要場景裡任何一個腳本引用了 `GameClock`／`AIService`
> 這類 autoload，一樣會在 `_initialize()` 階段直接 `Identifier not found`
> 編譯失敗——用 `print(GameClock.day)` 這種最小化腳本就能重現，跟你自己的
> 改動無關。原因是 autoload 掛進場景樹、註冊成 GDScript 編譯器認得的全域
> 名字，發生在引擎正常開機流程的某個時間點；`-s` 模式下你的腳本**取代了
> 主迴圈**，`_initialize()` 執行的時機比那個時間點早，`await process_frame`
> 也救不回來——卡編譯期的那一行本身就已經編譯失敗了，跟後面有沒有 await
> 無關。這種端到端驗證目前**只能靠 `--quit-after` 完整開機**（main_scene
> 走正常流程載入，autoload 會就緒）或編輯器 Play，`-s` 這條路走不通。

> [!warning] headless 裡帶執行緒的 `HTTPRequest` 完成時間不可信，比正常環境慢很多
> 用 `--quit-after` 驗證真的打網路的流程（例如 `AIService.request()`）時，
> 同一個請求用 `curl` 測不到 1 秒回應，在 headless 裡卻可能卡超過 20 秒才
> 觸發 `request_completed`——不是請求真的卡死，是**headless 環境下
> `use_threads = true` 的 `HTTPRequest` 完成得比正常視窗模式慢很多**，
> 具體慢多少沒有穩定數字。踩過一次：把 `--quit-after` 的秒數設得跟正常
> 網路延遲差不多（例如 20 秒），結果請求還沒回來視窗就先關了，看起來像
> 「卡住」，其實只是等得不夠久。
>
> 這是上面那條「headless 測不到時間相關邏輯」的同類問題，但這裡具體到
> **連 HTTP 逾時／回應時間都不能拿正常環境的直覺去估**。要驗證真的打網路
> 的流程，`--quit-after` 的秒數要抓寬（例如平常 3 秒內會回的請求，
> 給到 30-60 秒的窗口），或乾脆在編輯器裡 Play 驗，那邊的時間感才準。

## 備援與疑難排解

- 另有 `mcp__godot__*`（@coding-solo/godot-mcp）server。它只能做基本操作
  且不需要編輯器連線；**預設用 `godot-ai`**，只有在 godot-ai 完全連不上、
  且任務只是 `get_project_info` / `launch_editor` 這類簡單事情時才用它。
- 寫入被擋 `EDITOR_NOT_READY (state=playing)`：先 `editor_state` 同步快取，
  再重試；仍不行就 `project_manage(op="stop")`。
- `game_status.status="break"`：遊戲卡在遠端偵錯中斷（常見於開機期 parse error），
  不會自己恢復，呼叫 `project_manage(op="stop")`。
- 改了外掛程式碼：`editor_reload_plugin`。

## 筆記

依上層規則，所有文件寫進 `../note/` Obsidian vault，
用 `obsidian <subcommand>` CLI 操作（需 Obsidian app 執行中），不要寫在程式碼註解。
