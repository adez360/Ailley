---
tags:
  - 技術
  - workflow
status: 現況
updated: 2026-08-27
---

# 平行 Worktree 與 Godot MCP

多個 issue 同時開 worktree、各自跑一個 Claude Code session 處理時，
工作目錄內容彼此隔離（各 worktree 是獨立目錄）；但 git repository metadata、
branch/ref 操作與後續 merge/rebase 仍可能衝突，加上 godot-ai MCP 跟「兩個
worktree 剛好重疊做同一件事」這兩塊也要注意。

## godot-ai session 是怎麼隔離的

`godot-ai` MCP server 是本機共用的單一 process，每個**連進來的 Godot editor**
各自登記成一個 `session_id`（例如 `ailley@45f9`），帶著自己的 `project_path`。
只要每個 worktree 真的各自開了一個專屬的 Godot editor 視窗（指向該 worktree
自己的 `project.godot`），不同 worktree 的操作就會落在不同的 `session_id` 上，
彼此的 `create_script`／`node_create`／`run_project` 不會互相打到對方的
live editor —— 實測過 2 個平行 worktree 同時操作，log 乾淨分離。

- 每個 worktree 是完整 checkout，`.godot/` 快取天生分開，不會有檔案鎖定衝突
- 純文件/設計類 issue 不需要開 Godot editor，省一份 300MB\~1GB 的 RAM

> [!warning] 「各自開一個專屬 Godot editor 視窗」這一步本身有兩個坑（issue #455 踩過）
> **坑一：Godot Project Manager 清單裡兩個 worktree 的專案名稱顯示相同**
> （都取自 `project.godot` 的 `application/config/name`），只有路徑不同，
> 很容易點錯、切到既有那個視窗而不是真的另開一個。用 OS 層級直接確認在跑的
> process 最準：
> ```powershell
> Get-CimInstance Win32_Process -Filter "Name LIKE 'Godot%'" |
>   Select-Object ProcessId, CommandLine
> ```
> `--path` 參數就是那個 process 實際綁定的專案路徑，比 `session_manage(op="list")`
> 回報的 `project_path` 更可信——後者在切換過程中觀察到會回傳上一個 session
> 的舊快取值，不會即時更新。
>
> **坑二：`godot_ai` 外掛自己的伺服器 port 設定與 PID 檔都不是 worktree 隔離的**
> ——port 讀寫走 `EditorSettings`（`client_configurator.gd::ws_port()`／
> `http_port()`），這是整個 Godot 安裝共用的全域設定，不分專案；伺服器的
> `--pid-file` 是 `user://godot_ai_server.pid`（`plugin.gd::SERVER_PID_FILE`），
> 而 `user://` 只認 `project.godot` 的專案名稱，兩個 worktree 名稱相同時
> 一樣共用同一份，跟 JSON 存檔在多 worktree 下互相覆寫是同一個病根
> （見 [[存檔]]「`user://` 只認 project name，不分 worktree」）。第二個編輯器
> 啟動時會看到第一個編輯器留下的 PID 記錄還活著，嘗試「adopt」而不是另開一個
> 獨立的伺服器，實際觀察到的症狀是兩個編輯器互搶同一個 port、`session_manage`
> 只會看到其中一個（通常是最後寫入設定的那個）。
>
> **目前唯一可靠的解法是啟動順序**：兩個編輯器都完全關閉（整個 process，不是
> 切場景）→ 只開目標 worktree 的編輯器，等它完全啟動、用上面的 PowerShell
> 指令或 `session_manage(op="list")` 確認 `project_path` 正確 → 再開回另一個。
> 手動在外掛設定面板裡改 port 不能解決根本問題（EditorSettings 是全域的，
> 兩邊改的其實是同一份），只會讓症狀變得更難預測。這不是「理論上會撞」，
> 是實測撞到、追蹤原始碼確認後才排除的。

## 真正的風險：「active session」是全域的，不是每個 Claude session 專屬的

`session_activate` 設定的「目前作用中 session」是 MCP server 的全域可變狀態，
被所有連上同一個 server 的 Claude session 共用。呼叫 godot-ai 工具時若省略
`session_id`（預設空字串＝目前 active session），拿到的其實是「不知道被誰
最後動過」的那個 session。

- 每個 worktree 的 Claude session 開工時，先 `session_manage(op="list")` 找到
  自己 `project_path` 對應的 `session_id`，之後每次呼叫**明確帶 `session_id`**，
  不要依賴空值 —— 空值在平行多 session 時會被別人的 `session_activate` 蓋掉
- 沒有任何 session 對應到自己的 `project_path`：代表這個 worktree 沒開專屬
  editor，照 `Ailley/CLAUDE.md` 的規則回報使用者去開，不要因為「反正有 session
  可以連」就借用別人的

## 另一個坑：平行跑有相依關係的 issue，會各自重造同一份東西

跟 MCP 無關，是規劃面的坑，但表現形式很像「Godot 撞了」：如果 issue A 是
基礎建設（例如存檔骨架），issue B 依賴 A 但兩者同時開 worktree 平行跑，
B 分岔出去時手上還沒有 A 的成果，B 的 agent 為了測自己的功能，往往會照著
同一份規格書把 A 也重做一份 —— 曾經實測出兩個 worktree 各自生出逐字元相同、
連 Godot 自動產生的 `uid` 都一樣的腳本，加上 `project.godot` 的 `[autoload]`
也各自加了一份同名項目，合併時可能衝突或產生重複，需在合併後檢查。

- 開有依賴關係的平行 issue 前，先確認基礎建設那個 issue 有沒有機會先合併；
  真的要平行跑，跟依賴方的 agent 講清楚「骨架已經在 #N 做，不要重做，
  之後 rebase」，不要讓兩邊各自從同一份規格文件重新生一次
