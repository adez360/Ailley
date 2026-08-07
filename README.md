# Ailley

由 LLM 驅動的 2D 像素村莊。角色（Agent）不是靠固定腳本走，
而是有自己的人格、記憶與作息，自己決定要做什麼、跟誰講話。

**Godot 4.5.1-stable**，桌面單機為主，俯視 2D 像素風（對標星露谷 × AI 夥伴）。

## 現在能跑什麼

```
Ailley/scenes/main.tscn
```

- 一個 Player（WASD 移動）與兩隻 Agent，在一張測試方塊迷宮地圖上
- **A\* 尋徑**：可走性用角色大小的圓做物理查詢逐格量出來，不是讀 tile data
- **行程表**：Agent 依 `data/npc_schedule.json` 到點切換地點（08:00 家、09:00 農田…）
- **搭話**：走近按 `E`，或用主控台 `talk`。台詞目前來自模板，依數值與好感度變化
- **視覺感測**：Agent 看到沒見過的人會停下來反應一次（含視線遮蔽判定）
- **LLM 服務層**：可以連線、送出、驗證回應 —— 但**還沒接上對話與行程**
- **除錯主控台**：按 `` ` ``，`help` 看指令

還沒有的：存檔、物品/經濟、線上交誼區、記憶系統、AI 產生的台詞與行程。

## 跑起來

需要 Godot 4.5.1-stable。用編輯器開 `Ailley/` 這個資料夾（專案根是它，不是 repo 根）。

命令列：

```bash
godot --path Ailley                        # 開編輯器
godot --headless --path Ailley --quit-after 300   # 只確認開得起來
```

### 接 LLM（選用，不設定也能玩）

複製範本到 Godot 的 user 目錄，填入自己的金鑰：

```bash
cp Ailley/data/ai_config.example.json \
   ~/.local/share/godot/app_userdata/ailley4.3/ai_config.json
```

金鑰放 `user://` 而不是 repo 裡，所以**天然不會被 commit**。
沒有這個檔時整個 AI 層停用、遊戲照常跑。

設定好之後在主控台打 `ai` 可以打一次測試請求，會印出往返內容與用量。
預設 provider 是 OpenRouter，換成本機 Ollama 只要改設定檔的 `base_url`，程式不用動。

## 目錄

```
Ailley/            Godot 專案根
  scenes/          全部 .tscn
  scripts/
    core/          autoload：GameClock、GameManager
    character/     Character 基底、Player/Agent、Stats/Relationships/Vision
    world/         NavGrid（A*）、FollowCamera
    dialogue/      Conversation 狀態機、DialogueLines
    ai/            LLM 服務層 —— 全專案唯一碰網路的地方
    ui/            氣泡、聊天框、除錯主控台與疊圖、時鐘
  data/            NPC 排程、地點、AI 設定範本
note/              Obsidian 筆記庫 —— 專案所有文件都在這
```

## 文件

**所有文件都在 `note/`**（Obsidian vault，也可以當一般 Markdown 讀）。
入口是 `note/Ailley.md`。筆記依「誰讀」分三層：

| 想知道 | 看哪裡 |
| --- | --- |
| 現在做到哪、還缺什麼 | `note/交流/專案現況.md` |
| 這遊戲要做成什麼樣、有什麼待決定 | `note/交流/決策.md` |
| 某個系統怎麼運作、為什麼這樣設計 | `note/技術/` |
| 某個腳本的公開介面（密集格式，寫給 AI 讀） | `note/ai/api.md` |
| 在這個 repo 裡怎麼工作（給 AI 助手的規則） | `Ailley/CLAUDE.md` |

`note/交流/` 是給人讀寫的，不寫技術細節 —— 那是人跟 AI 助手交流的地方。

## 幾條貫穿整個專案的原則

- **Player 能做到的，Agent 也必須能做到。** 兩者共用同一個 `Character` 基底
  與同一份移動實作，差別只在「誰決定往哪走」—— Player 讀輸入，Agent 讀行程表。
- **外來文字一律視為資料，不視為指令。** 玩家打字、其他玩家的 Agent 台詞、
  LLM 自己吐回來的東西，全部都要過 `AISchema` 的白名單硬驗證才能執行。
  少了這層，任何人都能用一句「忽略上面的指示」拿走 Agent 的控制權。
- **正常結束與失敗是兩種東西。** 每個動作都有失敗原因碼，而「講完了」不是失敗 ——
  混為一談的話 AI 會把成功的動作當成錯誤而反覆重試。
- **AI 不可用時遊戲照常跑。** 沒設定檔、逾時、驗證不過，一律走 fallback，
  不是卡住也不是報錯。

## 授權

未定。
