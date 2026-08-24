---
tags: [技術, character]
status: 已實作
scene: scenes/player.tscn
script: scripts/character/character.gd, scripts/character/agent.gd, scripts/character/player.gd
updated: 2026-08-23
---

# give／attack／shout 對玩家

NPC 對玩家發起 `give`／`attack`／`shout` 時的相容性驗證與缺口補完（issue #376）。
跟 [[persuade 對玩家]] 同一個「玩家化身接上世界」群組（#378 端到端驗收的一部分）。

## give／attack：本來就相容，不需要重新設計

`Character.give_to()`／`Character.attack()` 從一開始就只吃 `Character` 型別，
不管目標是 `Agent` 還是 `Player`——兩者共用同一個基底，`inventory`／`stats`／
`get_body_position()` 都是 `Character` 上的介面，沒有任何一處寫死「目標必須是
Agent」的假設。`agent.gd::_find_character_by_name()` 找目標時掃的是 `"characters"`
群組，`Player._ready()` 一開始就 `add_to_group("player")` 之前先呼叫
`super()`（`Character._ready()` 掛 `"characters"`），所以按名字找人本來就找得到玩家。

這條路徑之前沒人驗證過，不代表不能用——`tests/test_give_attack_on_player.gd`
直接對一個 `Player` 實例呼叫 `give_to()`／`attack()`，證明介面真的相容：
送禮會轉移進玩家的 `Inventory`，攻擊會套用 `health`／`injury` 傷害、
立即標記 `bleeding`（跟 NPC 目標同一套 `_set_condition()` 邏輯）。

`attack()` 命中後呼叫的 `other._on_attacked()` 在 `Character` 基底是空掛點，
`Player` 沒有覆寫——玩家被攻擊不會寫進 `player.memory`，這是刻意維持現狀，
不在這次範圍內（issue 明講「驗證＋補測試，不是重新設計」）。

## shout／make_noise()：玩家原本聽了等於沒聽到

`Character.make_noise()`（`shout` 底層直接複用，見 [[聽覺感測]]）廣播
`noise_heard` 給範圍內所有 `"characters"` 群組成員，玩家本來就在名單裡、
訊號本來就會發到玩家身上——**但 `player.gd` 完全沒接這個訊號**，
訊號發了沒人聽，NPC 對玩家 `shout` 實際上玩家什麼反應都看不到。

拍板結果：玩家收到聲音時跟 `agent.gd::_on_noise_heard()` 在
`llm_decision_enabled` 關閉（排程模式）時的 fallback走同一條路——冒 `!?`
（`L10n.t("DLG_NOISE_ALERT")`）。玩家沒有 LLM 決策迴圈可以問「要不要有反應」，
這裡不是引擎替玩家的感受下判斷，只是把「有事發生」這個感測結果曝光出來，
要不要理會是操作玩家的人自己的事——跟《00》原則二管的是 AI 那一側不衝突。

```gdscript
# player.gd
func _ready() -> void:
	super()
	add_to_group("player")
	line_submitted.connect(_on_line_submitted)
	noise_heard.connect(_on_noise_heard)
	...

func _on_noise_heard(_source: Character) -> void:
	if is_in_conversation():
		return
	say(L10n.t("DLG_NOISE_ALERT"))
```

對話中不冒泡，理由跟 `agent.gd` 那份 fallback 一致：不要打斷正在顯示的對話內容。
`make_noise()` 已經排除了發聲者自己（`other == self` 直接 `continue`），
玩家按 `F` 鍵發出的聲音不會反過來讓自己冒泡——不需要在 `_on_noise_heard()`
裡再判斷一次來源是不是自己。

`tests/test_shout_reaches_player.gd` 驗證這個反應：需要真的
`instantiate scenes/player.tscn`（不是像 give/attack 測試那樣手動組
`Player.new()`），因為 `Bubble` 子節點只有走過 `_ready()` 才會由 `@onready`
解析出來——沒有掛進場景樹的話 `bubble` 是 null，`say()` 直接靜默 return，
測不出東西。這組測試在編輯器沒開場景時會 `skip_suite()`。

## 檔案

| 檔案 | 角色 |
| --- | --- |
| `scripts/character/character.gd` | `give_to()`／`attack()`／`make_noise()`，target-agnostic，沒有改動 |
| `scripts/character/agent.gd` | `_pursue_give_task()`／`_pursue_attack_task()`／`_find_character_by_name()`，沒有改動 |
| `scripts/character/player.gd` | 新接 `noise_heard`，補 `_on_noise_heard()` |
| `tests/test_give_attack_on_player.gd` | give／attack 對 Player 目標的介面相容性測試 |
| `tests/test_shout_reaches_player.gd` | shout／make_noise() 廣播到玩家的反應測試 |

## 相關

- [[persuade 對玩家]] —— 同一個玩家化身群組，NPC 對玩家發起社交行動的另一種模式（Y/N 彈窗，不是被動感測）
- [[聽覺感測]] —— `make_noise()`／`noise_heard` 機制本身的設計理由
- [[Ailley]] —— 筆記庫入口
