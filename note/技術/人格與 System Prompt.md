---
tags:
  - 技術
  - character
  - ai
status: 進行中
script: scripts/character/personality.gd
updated: 2026-08-17
---

# 人格與 System Prompt

HEXACO 六維進去，兩份東西出來：引擎算成功率用的 10 項數字，跟送給 LLM 讀的一段中文。
規格是《[[01-1_人格生成規格書]]》§3～§5 與《[[01_角色數值規格書]]》§2。

## 為什麼是兩份而不是一份

| 誰 | 讀什麼 | 為什麼 |
| --- | --- | --- |
| 引擎 | `personality` 10 項數字 | 算成功率（`_roll_success()`）、算記憶衰減率 |
| LLM | `system_prompt` 的行為準則文字 | 本地模型看到 `curiosity: 60` 沒有基準，不知道 60 是高是低，也分不出 60 跟 55 |

**10 項數值不注入 prompt。** 這不是省 token，是那個數字對模型沒有意義。
兩份產出來自同一份 HEXACO 輸入，不會互相矛盾。

## 資料放哪

`npc_schedule.json` 的 `identities`，跟 `character_id` / `character_name` 同一筆：

```json
"Agent": {
  "character_id": "aji",
  "character_name": "阿吉",
  "hexaco": { "hex_honesty": 50, "hex_emotionality": 15, ... },
  "character": "崩塌前是機房維修員，獨自活過三次斷電。…"
}
```

跟身分同一筆而不是另開一個檔：`identities` 這張表回答的就是「我是誰」，
人格是那個問題的一部分。另開一份的話會多一張節點名對照表，而那正是
`identities` 已經在做的事。

文案表在 `data/hexaco_traits.json`，36 條（6 維 × 兩端 × 3 變體），
照《01-1》§4 逐字抄。要調文字或增補變體改那個檔就好，不用動程式碼。

## 三個實作上的取捨

**只有極端維度產生文字。** ≤25 或 ≥75 才輸出一條行為準則，26~74 **整條略過**——
不是輸出「普通」。中間值就是留給 AI 的自主空間，寫一句「你的外向程度普通」
反而是在規定它。

**變體用種子挑，不是真隨機。** 每一端有 3 種語氣變體，避免 50 個 NPC 讀起來
千篇一律。但 `system_prompt` 的設計前提是「組好之後逐字元不變」——那是
llama-server 每個 slot 命中 KV cache 的條件，也是角色人格穩定的前提。
真隨機的話同一隻角色每次開遊戲的個性文案都不一樣。所以拿 `character_id`
當種子，`hash(seed + 欄位名)` 決定抽哪一條。

> [!warning] 種子一定要帶欄位名
> 六個維度共用同一個種子的話，它們會一起抽到同一個索引，三種變體等於只有一種。

**空區塊整段不輸出。** 行為準則、`character` 自述、外觀文字三個區塊，任一為空
就連標題一起省掉。留一個「【這個人】」後面接空字串，模型會自己編一個。

## 組裝順序不可調換

```
① 人格段（character.system_prompt）    ← 逐字元不變，可命中 KV cache
② 遊戲規則 + 輸出格式（PromptBuilder 的 DIALOGUE_SYSTEM / PLAN_SYSTEM / REFLECTION_SYSTEM）
```

`PromptBuilder._system()` 負責接這兩段，dialogue／plan／reflection 三種信封共用。
人格段一定在最前面（《[[01-3_Prompt注入與資料傳送]]》§5）。

完全沒有人格資料的角色（Player、`spawn_character()` 動態生成的）拿到的是
只有開場白與結尾句的最小版本，**不是空字串**——空字串會讓 `AIService` 整個
略過 system 訊息，模型連「你在扮演一個遊戲角色」都不知道。

## 現在做到哪

| 項目 | 狀態 |
| --- | --- |
| 六維 → 10 項轉換（§3） | 已實作 |
| 極端值映射表（§4，36 條文案） | 已實作 |
| `build_system_prompt()`（§5） | 已實作 |
| 注入 dialogue / plan / reflection 三種信封 | 已實作 |
| `personality` 接上成功率公式的人格項 | 已實作（`_roll_success()` 讀 `personality[trait]`） |
| 外觀文字區塊 | **沒有資料來源**，一律傳空字串。《01》§1-2 的 slot 清單仍是【待規劃】 |
| `words_to_creator` | 沒做，`/generate/words` 端點還不存在 |
| [[建角面板]] 的輸出接進這條管線 | 沒接。面板還沒有任何地方會開它，角色庫也還不存在 |
| 睡眠反思時 `personality` 單項 ±3（《01》§2-2） | 沒做 |
| 人格資料進存檔 | 沒做，存檔系統本身還沒開工 |

## 怎麼驗

```
persona <name>
```

主控台指令，印出這隻角色的 `system_prompt`（送進 LLM 的那一段）跟 10 項
`personality`。兩個都印是刻意的：這條管線的重點就是「同一份輸入產出兩種表達，
讀者不同」，只印一個看不出它們是同一份資料的兩面。
