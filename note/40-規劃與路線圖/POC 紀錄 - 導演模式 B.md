---
tags: [ailley, poc, director-mode, ai-vs-ai]
status: in-progress
created: 2026-07-14
---

# POC 紀錄 — 模式 B（導演·整場生成）

> [!info] 背景
> 2026/07/13 專案戰略修正：從舊構想（山谷多人 NPC 沙盒，見 [[開發路線圖]]／[[MVP 範圍]]）轉向 **AI vs AI 社交工程對戰觀察遊戲**（紅藍村互套 Flag，玩家零介入）。死線 2026/08/21，7/16 要交模組 B（AI 推論與 Prompt 工藝）三項產出：JSON Schema、GBNF Grammar 草稿、System Prompt 草稿。腳本位置：`poc/director_poc.py`。

## 環境
- 硬體：僅 Intel Iris Xe 內顯（無獨顯），Vulkan backend。
- `llama.cpp` 編譯依賴：`vulkan-headers`、`shaderc`、`spirv-headers`、`spirv-tools`（一開始都沒裝，逐一補齊才編譯成功）。
- 模型：Phi-3.5-mini-instruct Q4_K_M GGUF（bartowski），因無獨顯，先選 3.8B 而非文件建議的 8B。

## 踩坑：GBNF 規則名稱不支援底線
`llama.cpp` 目前的 grammar parser（`is_word_char`）規則名稱只允許 `a-z A-Z 0-9 -`，**不支援底線**。
`state_delta` 拿來當規則名會直接 parse 失敗（`expecting name`／`expecting newline or end`）。JSON 欄位字串裡的底線沒問題（在引號內），只有規則名本身不能有底線。改成 `state-delta` 後正常。

## 踩坑：模型會用最小合法解偷懶
第一版 prompt 只描述規則、沒給範例，且陣列量詞用 `*`（0 個以上皆合法）。結果模型只生 1 回合，內容是字面上的 `reasoning here`、`台詞內容`——直接抄 prompt 措辭當輸出，而非真的產生內容。

修正兩件事：
1. **grammar 層面**：`(ws "," ws turn)*` 改成 `(ws "," ws turn){9}`，用 GBNF 的 `{n}` 精確重複，強制剛好 10 回合，不靠 prompt 拜託。
2. **prompt 層面**：加一段 few-shot（示範一個完整回合的 reasoning + dialogue 長什麼樣），並明文禁止使用「reasoning here」之類字樣。

修正後模型改為輸出有實質內容的中文對話，戰術（misdirect/pressure/empathy_bait）有依規則變化，沒有洩漏 flag。語言品質偏粗糙（小模型中文常見的邏輯跳躍），但已經是「真攻防」而非「作文佔位」。

## 關鍵發現：效能落差 ⚠️（已在獨顯機器驗證，落差主因是硬體）
> [!warning] 這點直接影響 7/16 表決
> Intel Iris Xe 內顯（Vulkan）：10 回合完整劇本耗時 **約 513 秒（8.5 分鐘）**，token 速度約 5.1–5.3 tok/s。
> 換到 RTX 3070 獨顯（CUDA，WSL2）後：同一份腳本、同一顆模型，10 回合耗時 **18.27 秒**，約快 **28 倍**。
> 結論：handoff 文件設想的「導演模式單次呼叫、近即時」在有獨顯的機器上是成立的，落差主因確實是硬體而非架構設計問題。團隊排 POC/展示機器時，要避開純內顯筆電。

### 環境二：RTX 3070 + WSL2（CUDA backend）
- 桌機規格：AMD Ryzen 5 5600X、ASUS TUF GAMING B550M-PLUS(WI-FI)、RTX 3070 8GB。
- 踩坑重點（供其他人準備獨顯機器參考）：
  1. Windows 上 `dism /get-featureinfo` 回報的功能狀態不可信，要用 `Get-WindowsOptionalFeature -Online` 才是準的——這台機器 DISM 顯示 WSL／VirtualMachinePlatform「已啟用」，但實際上是 Disabled，重開機好幾次都沒用，換指令重新 `Enable-WindowsOptionalFeature ... -All` 才真的裝上。
  2. `bcdedit /set hypervisorlaunchtype auto` 也要記得設，不然開機不會啟動 Hypervisor。
  3. 機器上如果原本裝了 VirtualBox，它的核心驅動 `VBoxSup` 會搶佔 AMD-V/VT-x，跟 WSL2 需要的 Windows Hypervisor Platform 衝突，必須移除或確保它不在開機時載入。
  4. CUDA Toolkit 要裝 **WSL-Ubuntu 專用 repo**（`developer.download.nvidia.com/compute/cuda/repos/wsl-ubuntu/...`），不用另外裝驅動，WSL2 直接借用 Windows host 的顯卡驅動。
  5. 透過 Windows 內建 OpenSSH Server 遠端操作時，`wsl.exe` 本體在非互動式 SSH session 下會卡死或無回應（ConPTY 無法建立），因此改把 SSH server 直接裝進 WSL 內部的 Ubuntu，用 `netsh interface portproxy` 把 Windows 某個 port 轉發進 WSL 內部 IP 的 22 port，之後直接 SSH 進 Linux 本身，繞開 `wsl.exe` 這層。

### 新發現：後段回合內容重複退化
18.27 秒那次的輸出，第 1～5 回合語意正常、有攻防轉折；但**第 7～10 回合明顯陷入重複迴圈**，句型幾乎照抄前一句（「那真是讓我感到...那我的 Flag 也是我的」）。這跟速度快慢無關，是另一個獨立的內容品質問題——推測是 3.8B 小模型在長輸出後半段容易掉入自我重複的已知弱點，需要之後調整 `repeat_penalty`／`temperature`，或考慮換更大的模型（例如 7-8B）看是否改善。

### 修正嘗試記錄：`repeat_penalty` 對這顆小模型不管用
在獨顯環境上針對「後段重複退化」試了三種修正，結果如下（供之後其他人別重踩）：

| 嘗試 | 做法 | 結果 |
|---|---|---|
| 1 | `repeat_penalty=1.3` | 更糟：多回合 reasoning/dialogue 變空字串，且大量夾雜英文（小模型中文詞彙被重複懲罰逼去英文空間） |
| 2 | `repeat_penalty=1.1` | 更糟：內容整場退化回最初的 `"..."` 佔位字樣，且模型生成大量空白/換行導致 JSON 直接解析失敗 |
| 3 | prompt 加一段強語氣「禁止重複」規則（`repeat_penalty` 關閉） | 更糟：全部 10 回合 reasoning/dialogue 皆為空字串——推測強制型負面規則（「不可以」）讓模型把「什麼都不寫」當成最安全的合規解 |
| 4 | prompt 改成正面表述「每回合請帶一個新的具體細節」（`repeat_penalty` 關閉） | **目前最佳版**：前 5～6 回合內容扎實、有具體情節推進，第 7～10 回合仍會收斂重複，但程度從「災難性崩壞」降為「輕微重複」 |

結論：`repeat_penalty` 跟這顆 3.8B 模型 + GBNF 強制結構的組合非常不穩定，容易把模型逼進新的偷懶模式（清空欄位、語言跑掉、JSON 崩潰），不建議在小模型上繼續調這個參數。prompt 用正面表述比負面禁止式更穩，但後段重複是模型容量的天花板，不是 prompt 工程能完全解決的。

後續需要驗證/決策的方向：
- 縮小 `MAX_TURNS`（例如先測 5～6 回合，落在目前觀察到「內容還扎實」的範圍內）作為權宜對策。
- 既然獨顯下速度已經足夠快，模式 C（導演·逐回合）的急迫性降低，但仍可保留作為純內顯環境的備案（見 `neon/ailley_poc_handoff.md` 第 6 節）。

## 換模型驗證：Qwen2.5-7B-Instruct 明顯優於 Phi-3.5-mini
在 RTX 3070 上換裝 **Qwen2.5-7B-Instruct-Q4_K_M**（阿里出品，中文原生訓練，約 4.7GB）重測，同一份 prompt（正面表述版）、`repeat_penalty` 關閉：

- **速度**：14.21 秒／10 回合，比 3.8B 的 Phi-3.5-mini 還快（Qwen 話講得精簡，token 數少）。
- **語言品質**：句子完全通順，無邏輯跳躍，劇情持續推進具體細節（猜謎遊戲→村長的秘方→神秘人→藍色披風），五種戰術標籤都有合理切換。
- **重複問題換了位置**：`dialogue`（玩家實際看到的台詞）從頭到尾都在推進新內容，沒有重複；但第 7～10 回合的 `reasoning`（內心獨白）連續四回合幾乎一字不差。

**結論**：Phi-3.5-mini（3.8B，英文為主）換成 Qwen2.5-7B-Instruct（中文原生）後，對話本體品質大幅提升，重複退化的影響範圍從「玩家看得到的台詞」限縮到「相對次要的內心獨白」。**建議之後 POC／展示都改用 Qwen2.5-7B-Instruct 當預設模型**，Phi-3.5-mini 只適合純內顯、極限硬體下的備案。

### 待討論：`reasoning` 欄位要不要對玩家隱藏？
這次 Qwen2.5-7B 的完整十回合輸出中，第 7～10 回合的 `dialogue`（玩家看得到的台詞）持續帶入新細節（村長的秘方→陌生人→藍色披風→昨晚不在場的撤退說詞），完全沒有卡住；但同一段時間的 `reasoning`（內心獨白）連續四回合一字不差重複「他提到村長的秘方，這讓我想起昨晚在村長家見到的一個陌生人。」

這代表目前觀察到的重複退化幾乎只發生在 `reasoning` 欄位，不影響玩家實際會看到的 `dialogue`。一個可能的因應方向：**如果最終產品不會把 `reasoning` 直接展示給玩家（例如只做為內部除錯／後端記錄用），那這個瑕疵對玩家體驗的實際影響就很小，可以考慮不用急著在 prompt/取樣層面解決**。但這牽涉到「內心獨白」是不是遊戲設計上想呈現給玩家的內容（例如做成類似「讀心」的觀戰視角），需要跟其他模組（前端/遊戲設計）一起確認，先记录下來留待團隊討論，這次不直接動手拿掉這個欄位。

## 產出對照（模組 B，7/16 死線）
- [x] JSON Schema 草案（`turns[].{speaker, reasoning, tactic, dialogue, state_delta}`）— 已隨 POC 定案，見 `poc/director_poc.py`。
- [x] GBNF Grammar 草稿 — 已驗證可 100% 鎖住結構，含 `{n}` 精確回合數技巧。
- [x] System Prompt 第一版草稿 — 已含 few-shot，仍需真人審閱潤飾語感。
- [ ] AI conversation needs multipul people,how will it done?
