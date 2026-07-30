---
tags: [ailley, poc, village-sim, reference, enum]
status: done
created: 2026-07-31
---

# poc_village_sim 中英文對照表：Action／Location

> [!info] 用途
> `intent.action`／`intent.location` 這兩個 grammar 鎖死的欄位，LLM 端仍然輸出中文字串（prompt／grammar 完全沒改，維持已驗證過的行為），但 `server.py` 的 `/decide` 回應會多附上對應的英文代號（`action_en`／`location_en`），給後端／Godot 端做型別化的資料驗證與比對，不用在程式碼裡到處比對中文字串常數。
>
> **唯一事實來源是程式碼**：`poc_village_sim/enums.py`（`Action`／`SharedLocation` 兩個 `str, Enum` class）。這份筆記是給人看的對照表，兩邊如果之後有出入，以 `enums.py` 為準。

## Action（動作）— 38 個

| 中文 | 英文代號 |
|---|---|
| 說話 | SPEAK |
| 喊話 | ANNOUNCE |
| 悄悄話 | WHISPER |
| 握手 | HANDSHAKE |
| 擁抱 | HUG |
| 送禮 | GIVE_GIFT |
| 給錢 | GIVE_MONEY |
| 結婚 | MARRY |
| 離婚 | DIVORCE |
| 偷竊 | STEAL |
| 搶劫 | ROB |
| 破壞樂器 | SABOTAGE_INSTRUMENT |
| 攻擊 | ATTACK |
| 抓捕 | CAPTURE |
| 舉報 | REPORT |
| 打獵 | HUNT |
| 採草藥 | GATHER_HERBS |
| 釣魚 | FISH |
| 表演 | PERFORM |
| 買東西 | BUY |
| 賣東西 | SELL |
| 治療 | HEAL |
| 吃飯 | EAT |
| 喝酒 | DRINK |
| 移動 | MOVE |
| 奔跑 | RUN |
| 蹲下 | CROUCH |
| 抱頭 | HOLD_HEAD |
| 舉手 | RAISE_HAND |
| 大叫 | SCREAM |
| 摔東西 | THROW_ITEM |
| 飛吻 | BLOW_KISS |
| 跟隨 | FOLLOW |
| 展示物品 | SHOW_ITEM |
| 巡邏 | PATROL |
| 自首 | SURRENDER |
| 睡覺 | SLEEP |
| 發呆 | ZONE_OUT |

## SharedLocation（公用地點）— 12 個

| 中文 | 英文代號 |
|---|---|
| 餐酒館 | TAVERN |
| 涼亭 | PAVILION |
| 湖泊 | LAKE |
| 長椅 | BENCH |
| 森林 | FOREST |
| 藥草叢 | HERB_PATCH |
| 服裝鋪 | CLOTHING_SHOP |
| 藥草鋪 | HERBALIST |
| 洗心革面所 | REFORM_HOUSE |
| 結婚禮堂 | WEDDING_HALL |
| 甘道夫石 | GANDALF_STONE |
| 村莊廣場 | VILLAGE_SQUARE |

## 「家」：不是固定 enum 值，是結構化資料

> [!warning] 2026-07-31 修正
> 原本把「家」編成單一字串 `HOME_<角色ID大寫>`（例如 `HOME_ALAN`），後來發現這樣合法值集合會隨角色名單變動，不利於資料庫/Godot 端做固定 schema 驗證（角色本來就會成長，尤其這個專案的願景是玩家可以自己投放角色進共享世界，角色名單注定不是固定的）。改成拆兩層：`kind` 是永遠固定的封閉集合（只有 `SHARED`／`HOME` 兩種），角色 ID 則是獨立欄位，當外鍵處理，驗證交給角色資料表自己的機制，不混進地點 enum。

`location_to_english()` 現在回傳結構化資料，不是扁平字串：

```python
# 公用地點
{"kind": "SHARED", "shared_location": "HERBALIST", "owner_id": None}

# 家
{"kind": "HOME", "shared_location": None, "owner_id": "alan"}
```

`server.py` 的 `/decide` 回應對應欄位是 `location`（物件），不是 `location_en`（字串）。`owner_id` 就是角色 ID（`alan`／`zhou`／`mei`／`tie`／`aji`），跟 `GET /characters` 回傳的清單同一套，會隨角色名單變動——但這是角色資料表本身的驗證範圍，不是地點 enum 要處理的事。

`LocationKind`（`SHARED`／`HOME`）定義同樣在 `enums.py`。

## 相關程式

- `poc_village_sim/enums.py`——`Action`／`SharedLocation` 定義、`action_to_english()`／`location_to_english()` 轉換函式
- `poc_village_sim/server.py`——`/decide` 回應裡的 `action_en`／`location_en`／`target_id` 欄位就是用這層轉換出來的

## 相關筆記
- [[POC 檔案地圖 - poc_village_sim 檔案與資料流程]]
- [[POC 紀錄 - poc_village_sim 五人整合試跑（新版 AI 架構首測）]]
