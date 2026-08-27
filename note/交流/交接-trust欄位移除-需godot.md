---
tags: [交流, 交接]
status: 進行中
updated: 2026-08-27
---

# 交接：issue #601 trust 欄位移除（需要 Godot 編輯器）

分支 `chore/remove-relations-trust-field` 已從 issue #601 開好、推上 origin，
並且已經 rebase 對齊最新 main（commit `edb4197`）。先
`git fetch && git checkout chore/remove-relations-trust-field` 接續，不要重開
分支，也不用再 rebase（已經是最新的）。

## 背景

`relations.trust` 全庫查證零引擎消費者：`persuade` 已於 issue #177（《00》原則四）
改成不擲骰、完全交給被說服者自己的模型判斷 `persuaded`，從沒讀過 trust；PR #489
（已合併）把僅存的三個固定公式加減（深度對話+2／被攻擊-50／被救助+15）也改成
事實句陳述，`trust` 因此變成只寫不讀的死欄位，違反《00》原則三「除了餵給LLM讀，
引擎自己有沒有拿它算東西」。這次要比照 2026-08-16 拿掉 affinity/familiarity/debt
的做法把 trust 整條拿掉。追蹤於《99》P-60——但 P-60 目前只存在另一個未合併的
PR #557（全專案稽核分支）裡，還沒進 main。**這則 PR 刻意不動
`note/規格書/99_待規劃項目清單.md`**（避免跟 43-commit 的 #557 搶著改同一段，
等 #557 合併時一起帶入「已解決」狀態），只在 PR 描述裡文字引用《99》P-60，
不要自己加一份新的 P-60 條目進 99 檔案。

## 已完成

- [x] `Ailley/scripts/character/relationships.gd`（commit `edb4197`）：拿掉 trust
  欄位、`get_trust()`/`add_trust()`、`TRUST_MIN`/`MAX`，`load_save_data()` 已清理
- [x] `NPCRelationsSchema.gd`：移除 `relations_trust` 欄位＋CHECK
- [x] `DatabaseSchema.gd`：`CURRENT_VERSION` 8→9，新增 migration v9
  `_migrate_v9_drop_relations_trust`（改名→重建→明確列欄位複製→刪暫存表，
  不能用 `_migrate_rebuild_single_table` 因為欄位數變了）。開發時版號跟 PR #607
  撞號取 8，#607 先合併，rebase 時重編為 9（照 repo v6/v7 撞號慣例）
- [x] `MigrationV9Test.gd`（新增，比照 `MigrationV6Test.gd`）：17 項全 PASS，
  含驗證 v7 舊資料庫（真的帶 `relations_trust` 資料）一路跑過 migration 8／9
  不中止的完整鏈測試
- [x] `sqlite_save_service.gd`：`get_character()`／`_replace_relationships()`／docstring 拿掉 trust 映射
- [x] `prompt_builder.gd`：`_listener_block()` 移除 trust
- [x] `character.gd`：`get_state_snapshot()` 的 `relations` 拿掉 trust；相關 `_on_rescued`/
  `_on_attacked`/haul 註解校正
- [x] `debug_console.gd` + `locale/console.csv`：`CON_RELATION_ENTRY` 拿掉 trust 顯示
- [x] `DatabaseCRUDTest.gd`：npc_relations 測試 insert 拿掉 `relations_trust`
- [x] `dialogue_lines.gd`/`conversation.gd`：trust 相關註解校正
- [x] `note/規格書/01_角色數值規格書.md` §3-1：整段改寫成現況（relations 無引擎數值，
  只剩 met_count／appearance_cache），移除 trust 變動表與兩個 callout

## 驗證狀態（都過了）

- headless `--quit-after` 整專案開機：無 parse/script error，`Migration 8 ... applied`、
  `26 schemas created, schema version 8`
- `MigrationV8Test`（headless）：12 項全 PASS——欄位消失、其餘欄位與資料保留、FK 生效、
  索引重建、`foreign_key_check` 乾淨
- 編輯器內 `project_run` + `game_eval`（`ailley@381b`，2026-08-27）：
  - 遊戲執行期 DB `npc_relations` 欄位＝`[relation_id, character_id, target_id,
    relations_appearance_cache, updated_at]`，`user_version=8`
  - `Relationships.DEFAULT_RECORD`／`get_record()` 無 `trust` key
  - `get_state_snapshot()` 的 `relations` ＝`{<id>: {met_count}}`
  - `PromptBuilder._listener_block()` ＝`{name, met_count}`
  - `SqliteSaveService` 存讀 round-trip：`save_character` 回 true、`get_character`
    讀回 `{<id>: {appearance_cache}}`，都沒有因為缺 `relations_trust` 報錯
  - debug console `status <name>` 顯示「關係  aji（1 次）   alan（1 次）」，無 trust
- 註：本機沒有 `obsidian` CLI，`01` 那份筆記是直接用文字編輯改的
- 註：headless / 遊戲執行已把 `D:/Projects/Ailley` 的 dev DB 推到 schema v8——同目錄切回
  v7 以下的分支跑會被 `initialize()` 的「版本比程式新，拒絕開啟」擋下（設計如此）
- 註：`JsonSaveService` 是目前 autoload 的存檔實作，根本不碰 `npc_relations`；
  `SqliteSaveService`（這次改的）是平行開發中的實作，測試時直接 `.new()` 起來驗

### rebase 到最新 main 後續（PR #607 先合併走了 migration 8）

PR #607 合併，`CURRENT_VERSION` 在 main 上已經是 8（npc/location NOT NULL 重建）。
rebase 過來後把這條的 migration 改編成 **9**，`MigrationV8Test.gd`／`.uid` 保留 #607
那份（衝突時 `--ours`），本來的測試檔另存成 `MigrationV9Test.gd`。

順帶修好一個 rebase 才浮現的相容性坑：#607 的 migration 8 重建 `npc_relations` 時
呼叫的是活的 `NPCRelationsSchema`；這條拿掉 `relations_trust` 之後，任何
`user_version ≤ 7` 的舊資料庫會在 migration 8 就因為欄位形狀對不上而中止整個
`initialize()`。改法：`_migrate_v8_notnull_primary_keys()` 動態判斷舊表實際上有沒有
`relations_trust`，有就用新增的 `_migrate_v8_create_npc_relations_with_trust()`
（凍結 #601 之前的形狀）重建，留給 migration 9 拿掉；沒有則維持原本行為。
`MigrationV9Test.gd` 新增 `_run_v7_chain_test()` 專門驗證這條路徑。

編輯器內驗證（`ailley@905f`，2026-08-27，臨時場景 `_tmp_migration_v9_test.tscn`
掛 `MigrationV9Test.gd`，跑完即刪）：
- 真實 dev DB（原本停在 v8）：`Migration 9 ... applied`、`schema version 9`，正常升級
- `MigrationV9Test` 隔離測試（`user_version=8` 起跑）：9 項全 PASS
- `MigrationV9Test._run_v7_chain_test()`（`user_version=7` 起跑，真的帶 `relations_trust`
  資料）：`Migration 8 ... applied` 接著 `Migration 9 ... applied`，全程沒有中止，
  5 項全 PASS
- 總計 `PASS: 17 FAIL: 0`

分支已經 rebase 到最新 main（原本落後 20 個 commit），力度推送（history 改寫過）
前記得跟使用者確認一次。

## 完成後開 PR

- Push 到 `chore/remove-relations-trust-field`，開 PR 標題用英文、內文中文，
  `Closes #601`，PR 描述裡引用《99》P-60 說明背景（可參考 issue #601 本文）
- **文件範圍刻意窄**：只改了《01》§3-1。04／06／01-3／00／02／10／11／13 與
  `ai/`、`技術/` 筆記裡的 trust 留給 #557（`docs/full-project-audit`）——#557 在那些
  行上加了 `[!warning]` callout，兩邊動同一批行會衝突。使用者交代：**每次接續
  要先問 #557 合併了沒；合併後回去確認 #557 那邊 trust 有沒有改全面，沒改到的
  補進這條 PR 或另開收尾。**（同步在自動記憶）
- 依照這個專案既有 workflow：開 PR 後 `gh pr comment <N> --body "@coderabbitai
  full review"` 觸發審查，逐項判斷 CodeRabbit 意見（不需要修正就回覆說明理由，
  需要修正就修完回覆「已修復」，新 commit 觸發下一輪 review，重複到沒有新意見）
- 確認可合併：用一次 GraphQL query 把 review 狀態、statusCheckRollup、
  reviewThreads 的 isResolved 一起撈出來，確認最新一筆 CodeRabbit review 是
  APPROVED 且全部 thread 都 resolved，都過就留言「已自審完成」，不用另外叫
  subagent 自審
- 過程中若呼叫 `@coderabbitai full review` 累計 5 次都未獲回應：停止再等，
  留言註明「CodeRabbit 逾時未回應」，回報使用者

## 完成這則後，同一台有 Godot 的機器上還有別的事可以撿

這幾則都需要 godot-ai，這個 session 一直卡在沒有連線，如果 Windows 那邊順利，
處理完 #601 可以繼續往下：

- **#391**（per-character home assignment）：OPEN，無 PR，要在地圖上擺房子、
  建角時指派 `home_location_id`
- **#455**（auto re-embody player character on save load）：OPEN，無 PR
- **#384**（life_highlights 彙整）：OPEN，無 PR，但依賴的死亡/墓園系統已合併，
  現在可以動工了
- **#477**（Task.preconditions）：已有 PR #530，`CHANGES_REQUESTED`——**使用者
  先前指示過這則先不要處理**，除非使用者另外交代，否則跳過

有任何需要拍板的設計問題（例如 migration 版本號怎麼排、schema 欄位怎麼刪）
隨時停下來問使用者，不要自己猜。
