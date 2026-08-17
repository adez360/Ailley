---
tags:
  - 技術
  - workflow
status: 現況
updated: 2026-08-17
---

# 平行 Worktree 與 Godot MCP

多個 issue 同時開 worktree、各自跑一個 Claude Code session 處理時，
git 檔案層完全隔離（各 worktree 是獨立目錄），不會撞；
但 godot-ai MCP 跟「兩個 worktree 剛好重疊做同一件事」這兩塊要注意。

## godot-ai session 是怎麼隔離的

`godot-ai` MCP server 是本機共用的單一 process，每個**連進來的 Godot editor**
各自登記成一個 `session_id`（例如 `ailley@45f9`），帶著自己的 `project_path`。
只要每個 worktree 各自開一個專屬的 Godot editor 視窗（指向該 worktree 自己的
`project.godot`），不同 worktree 的操作就會落在不同的 `session_id` 上，
彼此的 `create_script`／`node_create`／`run_project` 不會互相打到對方的
live editor —— 實測過 2 個平行 worktree 同時操作，log 乾淨分離。

† 每個 worktree 是完整 checkout，`.godot/` 快取天生分開，不會有檔案鎖定衝突
† 純文件/設計類 issue 不需要開 Godot editor，省一份 300MB\~1GB 的 RAM

## 真正的風險：「active session」是全域的，不是每個 Claude session 專屬的

`session_activate` 設定的「目前作用中 session」是 MCP server 的全域可變狀態，
被所有連上同一個 server 的 Claude session 共用。呼叫 godot-ai 工具時若省略
`session_id`（預設空字串＝目前 active session），拿到的其實是「不知道被誰
最後動過」的那個 session。

† 每個 worktree 的 Claude session 開工時，先 `session_manage(op="list")` 找到
  自己 `project_path` 對應的 `session_id`，之後每次呼叫**明確帶 `session_id`**，
  不要依賴空值 —— 空值在平行多 session 時會被別人的 `session_activate` 蓋掉
† 沒有任何 session 對應到自己的 `project_path`：代表這個 worktree 沒開專屬
  editor，照 `Ailley/CLAUDE.md` 的規則回報使用者去開，不要因為「反正有 session
  可以連」就借用別人的

## 另一個坑：平行跑有相依關係的 issue，會各自重造同一份東西

跟 MCP 無關，是規劃面的坑，但表現形式很像「Godot 撞了」：如果 issue A 是
基礎建設（例如存檔骨架），issue B 依賴 A 但兩者同時開 worktree 平行跑，
B 分岔出去時手上還沒有 A 的成果，B 的 agent 為了測自己的功能，往往會照著
同一份規格書把 A 也重做一份 —— 曾經實測出兩個 worktree 各自生出逐字元相同、
連 Godot 自動產生的 `uid` 都一樣的腳本，加上 `project.godot` 的 `[autoload]`
也各自加了一份同名項目，合併時保證衝突。

† 開有依賴關係的平行 issue 前，先確認基礎建設那個 issue 有沒有機會先合併；
  真的要平行跑，跟依賴方的 agent 講清楚「骨架已經在 #N 做，不要重做，
  之後 rebase」，不要讓兩邊各自從同一份規格文件重新生一次
