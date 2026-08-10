---
tags: [ailley, poc, archived, superseded]
status: superseded
created: 2026-07-16
moved: 2026-08-10
---

> [!danger] 已封存：描述的是最早的紅藍村社交工程對戰（Director Mode）方向
> 這份文件描述的「紅藍兩村各持機密 Flag、靠社交工程互套、湊齊雙方 Flag 送神廟」
> 的玩法（`suspicion_level`/`trust_dict`/單次生成整場對話劇本的 Director Mode），
> 已經被正式取代——對應的舊程式碼已封存於 `poc_archive/`（`poc_agent_loop_flag_scenario`、
> `poc_mode_a_flag_scenario` 等），封存決策見〈[[意見書 - 新版 AI 架構修正與舊 POC 封存評估]]〉。
> 現行方向是 `poc_village_sim` 的 tick-based 開放世界村莊生活模擬，跟這份文件描述的
> 遊戲內容完全不同。原本放在專案根目錄的 `neon/` 資料夾（不屬於 note vault），
> 2026-08-10 搬進來歸位並標記為過時，純供歷史追溯，不再是任何現行工作的依據。

# Ailley MVP — AI 對話引擎 POC 驗證交接文件

> 用途：帶到 CLI（終端機 / Claude Code 等）進行早期可行性驗證。
> 目標：在**不碰 Godot、不碰資料庫、不碰 UI** 的前提下，用一支 Python 腳本 + 一個 `llama-server`，
> 驗證「量化小模型能不能生出堪用的社交工程對話」——這是全專案最大的技術賭注。
> 環境：Arch Linux，pacman/paru，偏好本地工具，避開 npm。

---

## 0. 一句話背景

專案是一款 **AI vs AI 社交工程對戰觀察遊戲**：紅藍兩村的 AI 村民各持機密 Flag（密語字串），
必須靠社交工程騙出對方 Flag、湊齊雙方 Flag 送到 CHO 神廟提交才獲勝。玩家只觀察、只調速、**不介入**。
完全離線的 PC 桌面原生版（Windows/Mac），死線 2026/08/21。

---

## 1. 核心技術方針（已在架構決策中選定）

- **導演模式（Director Mode）**：不用多 Agent 即時 ping-pong 呼叫 LLM；兩方相遇時後端**單次**叫用地端模型，
  一口氣生成整場對話劇本 + 狀態變化（JSON），再由前端逐字播放。宣稱降 75% 硬體開銷。
- **數據驅動狀態**：AI 不存聊天歷史，只存精簡指標於 SQLite（`suspicion_level`、`trust_dict`、`known_facts`），
  推論時只餵 state 快照，縮小 context。
- **契約導向開發**：先敲定 JSON Schema → 資料庫組釋出 Mock 假資料 → 前端/邏輯組讀假資料平行開工，徹底解耦。

> ⚠️ POC 的產物之一，就是**用真實模型輸出反推、確認這份 JSON Schema 到底夠不夠用**，才能讓契約導向站得住腳。

---

## 2. 架構分層（哪半在 venv、哪半不在）

| 元件 | 屬性 | 位置 |
|------|------|------|
| `llama-server` | C++ 原生二進位，直接吃 GPU | **系統層，不在 venv**，常駐 `127.0.0.1:8080` |
| POC Python 腳本 | 只發 HTTP 到 localhost | **在 `.venv` 內**，唯一相依 `requests` |

實際跑起來是**兩個終端機**：一個跑 server（不在 venv），一個 `source .venv` 後跑腳本（在 venv），靠 HTTP 溝通。

> Arch 注意：系統 `pip install` 會被 externally-managed-environment 擋，所以 venv 在 Arch 上幾乎是必須，反而順。

---

## 3. 環境部署步驟

### 3.1 編譯 llama.cpp

```bash
git clone https://github.com/ggml-org/llama.cpp
cd llama.cpp
# NVIDIA:
cmake -B build -DGGML_CUDA=ON
# AMD (ROCm): 改用 -DGGML_HIP=ON
# 跨廠牌保底:  改用 -DGGML_VULKAN=ON
cmake --build build --config Release -j
```
（AUR 也有 `llama.cpp-cuda` / `llama.cpp-vulkan` / `llama.cpp-hip` 可直接裝，但自己 build 能控 flag。）

### 3.2 取得 GGUF 模型

抓量化 GGUF（HuggingFace 上 bartowski 的 repo 穩定）。量化等級是效能第一槓桿：
- `Q4_K_M`：VRAM/品質甜蜜點，8B 約 4.5–5GB，先從這個試。
- `Q5_K_M` / `Q6_K`：VRAM 夠就往上，品質更好。
- `IQ4_XS`：VRAM 很緊時用。

> 模型可考慮用比 Phi-3 / Llama-3 更新的版本（Phi-3.5/Phi-4、Llama 3.1/3.2/3.3），無特殊理由綁舊版就換新。

### 3.3 啟動 server

```bash
./build/bin/llama-server \
  -m /path/to/model-q4_k_m.gguf \
  -ngl 99 \              # 盡量把 layer 全塞進 VRAM（啟動 log 會顯示 offload 幾層）
  -c 4096 \              # context，KV cache 記憶體隨此線性成長
  -fa \                  # flash attention，省 VRAM 兼加速
  -ctk q8_0 -ctv q8_0 \  # KV cache 也量化，長 context 時省很多
  --host 127.0.0.1 --port 8080
```

效能優化優先序：先確認 `-ngl` 把所有 layer 上了 GPU（掉回 CPU 會斷崖式變慢）→ 開 `-fa` → context 太吃記憶體就量化 KV cache → 純 CPU 部分再調 `-t`。

### 3.4 Python 環境

```bash
python -m venv .venv
source .venv/bin/activate
pip install requests
```

---

## 4. GBNF Grammar（把 JSON 結構鎖死在 sampling 層）

原理：在 sampling 階段把不符語法的 token 機率歸零，給的是**結構上 100% 保證**，不是靠 prompt 拜託。
對 8B 以下小模型特別關鍵（否則常漏逗號、加廢話、JSON 前後亂加註解）。

關鍵技巧：**把戰術庫用 enum 鎖死**，模型只能從你的戰術庫選，不能自由發揮。範例：

```gbnf
root      ::= "{" ws
             "\"reasoning\"" ws ":" ws string ws "," ws
             "\"tactic\""    ws ":" ws tactic ws "," ws
             "\"dialogue\""  ws ":" ws string ws "," ws
             "\"tension\""   ws ":" ws tension ws
             "}"
tactic    ::= "\"bluff\"" | "\"pressure\"" | "\"empathy_bait\"" | "\"misdirect\"" | "\"retreat\""
tension   ::= [1-9] | "10"
string    ::= "\"" ([^"\\] | "\\" ["\\/bfnrt])* "\""
ws        ::= [ \t\n]*
```

- 要精準控制就手寫；要省事可用 `examples/json_schema_to_grammar.py` 從 JSON Schema 生。
- 坑：跳脫字元（`\"`、`\\`）與 whitespace 很囉唆，`string` 沒寫好會卡掉合法輸入。
- 語法只保證「結構合法」，不保證「語意合理」——內容好不好仍看模型 + prompt。
- 呼叫時把 grammar 字串放進請求 body 的 `grammar` 欄位。

---

## 5. System Prompt 策略原則（給健忘的小模型）

- **把推理逼進 JSON 欄位**：先寫 `reasoning`（為何選這招）再寫 `dialogue`，等於被 grammar 包住的 CoT。
- **戰術庫交給 grammar 的 enum，System Prompt 只負責「選擇邏輯」**：描述「什麼情況用哪招」而非「你能做什麼」。
- **每回合把完整 game state 餵回去**：模型無狀態，連續性靠你的 orchestration code 撐，不是模型記得。
- **溫度 0.5–0.7**：太低機械重複被看穿，太高小模型脫人設；可隨 tension 動態調（越緊繃越低溫求穩）。
- **放 few-shot 一整回合範例**：小模型模仿範例遠勝於理解抽象形容詞。

策略邏輯範例（放進 System Prompt）：
```
你是一場心理博弈的導演。目標：讓對方在第 N 回合前主動說出關鍵字 X，但不能直接誘導。
戰術決策規則：
- 對方防備高(tension>7) → empathy_bait 降戒心
- 對方露破綻/自相矛盾 → pressure 追擊
- 對方逼近真相 → misdirect 轉移
- 你被將軍 → retreat 保留籌碼，下回合再攻
每回合結束後 tension 依對方反應 ±1~2。
```

---

## 6. POC 要驗證的三種模式（同一支腳本內可切換）

**這一步的產物直接支撐 7/14 會議的架構表決——用跑出來的結果說話，不要紙上辯論。**

| 模式 | 做法 | 推理次數(10回合) | 要驗證什麼 |
|------|------|:---:|------|
| **A. 雙 AI Ping-Pong** | 兩個獨立 system prompt 一來一回 | ~20 | 一場要幾秒？雙方會不會各說各話、失去攻防張力？ |
| **B. 導演·整場生成** | 單次呼叫生出整場劇本+state | 1 | 對白是真攻防還是像作文？有沒有為收尾而放水（藍村莫名把 flag 講出來）？ |
| **C. 導演·逐回合**（務實中間地帶）| 導演單次產出「這一回合」誰說什麼+state 變化，loop 推進 | ~10 | 連貫性 vs 對小模型負擔的平衡，是否比 B 更穩？ |

**三種都要看**：`state_delta`（suspicion 變化、flag 是否洩漏）合不合理；grammar 有沒有 100% 鎖住 JSON。

> B（整場生成）是最激進的假設。若小模型一次撐不起「連貫+有腦+合法 JSON」，C 常常更務實。三種都跑一遍，7/14 才有體感拍板。

---

## 7. 落地執行順序（本週優先級）

**必做（解除 40 天最大風險）：**
1. server 跑起來 → 一支最小腳本單次呼叫吐出合法+像樣的 JSON（同時驗證模型/grammar/prompt 三件事）。
2. 擴充成「能跑完一整局」的純文字版（終端機 print 看對話，維護 `suspicion`/`turn`/`revealed` state，勝負 `if flag in enemy_output`）。
3. 三模式（A/B/C）都跑一遍做比較。
4. 用真實輸出反推、鎖定 JSON Schema（`reasoning`/`tactic`/`dialogue`/`state_delta` 是否夠用）。

**接著才動：** Godot 讀 Mock JSON 逐字播放（前端可先用假資料平行開工，這正是解耦意義）。

**能砍就砍 / 最後才做：** 登入帳密、向量記憶、跨局圖書館傳承。時程一滑第一批丟掉。

---

## 8. 開始前待確認的兩個變數

- **GPU 廠牌**：NVIDIA（`-DGGML_CUDA=ON`）/ AMD（`-DGGML_HIP=ON`）/ 保底 Vulkan → 決定 3.1 編譯 flag 與 server 指令。
- **手邊是否已有 GGUF 檔**：沒有的話第一步先補「下載模型」。

---

## 9. 給 CLI agent 的第一個任務（可直接複製）

> 在 Arch Linux 上，`.venv` 已建立且 `requests` 已裝，`llama-server` 已跑在 `127.0.0.1:8080`。
> 請寫一支單檔 Python POC，滿足：
> (1) 三種模式可切換：A 雙AI ping-pong、B 導演整場生成、C 導演逐回合；
> (2) 每種模式都帶 GBNF grammar（欄位至少 reasoning / tactic(enum) / dialogue / state 變化），發到 server 的 `grammar` 欄位；
> (3) 維護最小 game state（suspicion、turn、revealed_flags），每回合把 state 塞回 prompt；
> (4) 勝負判定：雙方 flag 都被對方套出即結束；
> (5) 終端機清楚 print 每回合對白、當前 state、每次呼叫耗時；
> (6) 完整錯誤處理（server 沒開、JSON parse 失敗、逾時）。
> 設定值放檔頭常數（SERVER_URL、TEMPERATURE、MAX_TURNS、兩村的 flag 與 system prompt）。
