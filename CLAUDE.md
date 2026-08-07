# CLAUDE.md

## 筆記庫規則 (Obsidian Vault Rules)

本專案使用 `note/` 目錄作為 Obsidian 筆記庫 (vault)。

- **專案的所有文件都在 `note/`**，一則都不例外：想法、計畫、進度、技術決策，
  以及 API 參考、指令速查這類純查閱資料。
  唯一的例外是 repo 根目錄的 `README.md`（GitHub 入口，給還沒進 vault 的人看）。
- **不要在別的地方另開文件目錄。** 尤其不要在 Godot 專案裡開 `Ailley/docs/` ——
  文件散成兩處之後，vault 就失去「一個地方查得到全部」的意義，
  而且寫在 vault 外的 `[[wikilink]]` 全部是死的。
- 操作筆記庫時，**使用 Obsidian CLI**（`obsidian <subcommand>`，需 Obsidian app 執行中）
  來讀取、建立、搬移、搜尋與管理筆記。
- 撰寫筆記時使用 Obsidian Flavored Markdown：wikilinks（`[[...]]`）、embeds、callouts、frontmatter properties、tags。
- 在開始或推進任何工作前，先到 `note/` 查閱相關筆記；完成後把進度與決策更新回筆記庫。

### vault 結構

依**誰讀**分三層。分類靠資料夾 + frontmatter，不要再引入編號資料夾
（曾經的 `10-` / `30-` 只是把第一個 tag 再寫一次）。

| 資料夾 | 讀者 | 裝什麼 |
| --- | --- | --- |
| `交流/` | **人類** | 現況、決策、待拍板的問題。**不寫技術細節** |
| `技術/` | 人類與 AI | 各系統怎麼運作、為什麼這樣設計、踩過的坑 |
| `ai/` | **AI** | 密集格式的參考資料。不必是散文，人類不必讀 |

入口是 `note/Ailley.md`，新增筆記後回去對應表格加一列。

```yaml
---
tags: [技術, character]
status: 已實作        # 已實作 / 進行中 / 規劃中 / 現況 / 參考
scene: scenes/main.tscn
script: scripts/character/vision.gd
updated: 2026-08-07
---
```

### 寫筆記的規則

- **寫現況，不要寫流水帳。** 事情改了就改內容 ——
  不要在後面追加一節說「前面那段已過時」，那會讓查資料的人讀到錯的東西。
- **不要留考古內容。** 已經刪掉的程式碼、已經放棄的方案，除非還在影響現在的決策，
  否則不要在筆記裡描述它們。
- 需要人類拍板的問題寫進 `交流/決策.md` 的「需要你決定」。
