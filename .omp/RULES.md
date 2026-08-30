# RULES

- 動 `Ailley/`（Godot 專案）底下任何檔案前，先讀 `Ailley/CLAUDE.md`。
- `.tscn`／`.tres`／`.import`／`.uid`／`project.godot` 一律走 `godot-ai` MCP
  （`node_create`／`node_manage`／`node_set_property`／`scene_save`），禁止 Read/Edit 手改。
- 開工前置：`session_manage(op="list")` → `editor_state`；沒有 session 就回報使用者，不要繞過。
- `.gd` 可以 Read+Edit，改完 `filesystem_manage(op="scan")` 讓編輯器同步。
- 文件一律進 `note/`（Obsidian vault），不在專案裡另開 `docs/`。
