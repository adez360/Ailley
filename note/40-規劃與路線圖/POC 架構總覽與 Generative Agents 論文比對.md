---
tags: [ailley, poc, generative-agents, architecture-review]
status: in-progress
created: 2026-07-24
---

# POC 架構總覽與 Generative Agents 論文比對

> [!info] 用途
> 使用者提供 `town.pdf`（Stanford *Generative Agents: Interactive Simulacra of Human Behavior*, UIST '23），要求整理目前我們手上所有 POC 的架構、跟論文原始架構比對差異，並評估風險與合併問題。背景見 [[POC 紀錄 - 導演模式 B]]、[[POC 紀錄 - 原 Ailley 多模型互動]]。

## 一、目前 POC 架構完整清單

我們手上其實是**四組獨立的自包含腳本**，彼此不 import，靠複製貼上共用邏輯，全部跑同一顆本地 llama-server（GBNF grammar 鎖 JSON 結構）：

### 1. `poc/`——導演模式 B（單一 LLM 扮演旁白/導演）
- `director_poc.py` / `continue_director_poc.py`：一次呼叫產出整場（或整批續寫）對話劇本＋`state_delta`（懷疑度、洩漏判定），逐回合播放。
- `director_poc_cloud.py`：雲端對照（OpenRouter），無 grammar。
- 大量 `continue_director_poc_*.py` / `chain_continue_*.py` 實驗分支：`repeat_guard`、`batch_regen`、`misdirect_settle`、`repeat_end`、`narrowwindow`、`natural_end`——都是針對「長鏈重複退化」的獨立修復嘗試，只有 `narrowwindow`（`RECENT_TURNS_WINDOW` 12→6）驗證有效並正式併入。
- 核心設定：`MAX_TURNS=6`、`TEMPERATURE=0.7/TOP_P=0.9/TOP_K=40`、`TOKENS_PER_TURN_BUDGET=300`、固定 `SEED` 可控制實驗變因。

### 2. `poc_mode_a/`——模式 A（雙 LLM 獨立呼叫，資訊隔離）
- `dialogue_ping_pong.py`：兩顆獨立呼叫互相對話（各自只看自己視角的 prompt，不共用導演視角）。
- `dialogue_ping_pong_memory.py`：加上「新近度＋重要性」記憶流評分（`n_predict` 上限修法的原始出處）。
- `dialogue_ping_pong_memory_embed.py`：**唯一驗證過 embedding 相關性檢索的地方**——另開 8081 embedding server（`bge-small-zh-v1.5`），存向量、算 cosine 相關性，跟新近度/重要性加總排序。**結論：相關性檢索反而會強化話題卡住的傾向，沒有正式採用。**

### 3. `poc_planning/`——Planning 最小可行 POC
- `generate_plans.py`：固定 6 時段行程規劃，grammar 鎖死結構，10/10 成功、0 重複、0 機密洩漏。品質全部 POC 裡最好，因為是單一視角任務、無「懷疑度停滯」誘因。

### 4. `poc_agent_loop/`——Agent Loop（規劃 → 行程重疊觸發相遇 → 對話 → 意識流 → 跨天記憶）
- `agent_loop.py`：整合規劃（沿用 poc_planning 邏輯）、`detect_overlap()`/`find_all_overlaps()`（文字關鍵詞比對相遇，25 配對排他邏輯）、對話（沿用 poc_mode_a 邏輯，不含停滯偵測）、意識流（獨白，簡化版）。
- `memory_store.py`：跨天持久化層，`roster.json`/`state.json`/`memories/`，`global_index` 單調遞增避免天/回合換算問題。
- **記憶檢索公式刻意只用「新近度＋重要性」**（`retrieve_memories()`），embedding 照存但不進排序——因為 `dialogue_ping_pong_memory_embed.py` 已經驗證相關性項會有副作用，這裡刻意迴避同一個坑。
- `run_multiday.py`：跨天批次執行入口。
- **反思（reflection）完全沒有實作**，四個目錄裡都沒有 `reflection.gbnf` 或對應函式，只在筆記裡做過紙上可行性評估。

### 分支狀態
`neon-POC` 已 fast-forward 到跟 `agent-loop-persistent-memory` 同一個 commit（`3707ee3`）——兩者不是分岔的兩條線，是同一條線，agent-loop 只是暫時領先一個 bugfix commit。上述四組目錄本來就同時存在於這條線的同一批 commit 歷史裡。

## 二、跟論文（Generative Agents / Smallville）架構比對

論文核心架構（Figure 5）：`Perceive → Memory Stream → Retrieve → Retrieved Memories → Act`，外圍 `Plan` 與 `Reflect` 兩個環從記憶流讀寫。三大元件：

| 論文元件 | 論文做法 | 我們現況 | 落差 |
|---|---|---|---|
| **Memory Stream / Retrieve** | `score = α·recency + α·importance + α·relevance`（三項等權重，recency 用 0.995 指數衰減，importance 由 LLM 評 1-10，relevance 用 embedding cosine similarity），全部記憶物件（含 reflection）都進同一個 stream | `poc_agent_loop` 只用 `recency + importance`（0.95 衰減），**relevance 項刻意拿掉**；embedding 有算、有存，但不進排序公式。`dialogue_ping_pong_memory_embed.py` 驗證過三項全開會強化重複，沒有解決根因就直接砍掉一項 | 論文的「三項並重」假設在我們的長鏈重複退化病灶下不成立，我們用「拿掉一項」迴避，不是解決 |
| **Reflection** | 累積 importance 分數超過閾值（150）觸發，LLM 從最近 100 筆記憶生成問題→抽取記憶→歸納「更高層洞察」，寫回 memory stream 形成樹狀結構，供未來檢索 | **完全沒有實作**，甚至沒有最小 POC | 四大元件缺一整塊，且是論文消融實驗證明「移除 reflection 影響第二大」的元件（僅次於完整架構） |
| **Planning** | 從摘要描述 top-down 生成粗略計畫（5-8 段），再遞迴分解到小時級、5-15 分鐘級，存進 memory stream，可依觀察/反思動態重新生成 | 只做了論文的「第一層」（固定 6 時段粗略規劃），**沒有遞迴分解到分鐘級**，也**不會依當天發生的事動態重新生成**（`poc_agent_loop` 有把前一天記憶餵進規劃 prompt，但論文的「reacting → replan」機制沒做） | 規劃深度只有論文的一層，且論文強調的「觀察觸發重新規劃」完全沒有 |
| **空間模擬** | Phaser 遊戲引擎，樹狀環境表示（area→object），真實路徑移動，agent 互相「看見」才觸發互動 | 用**文字關鍵詞比對**（8 個地點詞）替代，10 人規模已驗證觸發過密（三分之一人-時段都在講話，不像自然偶遇） | 論文有真實空間約束（能不能看到、走不走得到），我們沒有任何空間/視野限制，純機率命中 |
| **對話生成** | 論文用 gpt3.5-turbo，指令微調模型本身語氣偏正式但沒有崩潰/重複退化的量化問題被提及 | 我們用本地 Qwen2.5-7B-Instruct-Q4_K_M，**長鏈重複退化（74%）、退化輸出（6.6%）、3 種 JSON 崩潰模式**都是論文完全沒遇到、我們花最多篇幅在修的問題 | 論文用的是遠比我們大/好的雲端模型，模型容量可能是根本差異，這條我們自己筆記裡也承認「沒排除模型容量上限的可能」 |
| **評估方法** | 兩階段：controlled interview 評估（5 類問題×25 agent×5 條件消融，TrueSkill 排名+Kruskal-Wallis 顯著性檢定）+ end-to-end 兩天模擬看 emergent behavior（資訊擴散、關係形成、協調） | 我們的驗證是**工程向**：完成率、JSON 解析失敗率、機密洩漏命中率、重複率百分比，**沒有「可信度（believability）」的人類評估**，也沒有消融實驗量化每個元件對品質的貢獻 | 論文的評估設計本身就是這篇論文的一大貢獻（TrueSkill + 統計檢定 + 質性編碼），我們目前完全沒有對應機制 |

## 三、風險

1. **拿掉 relevance 檢索項不是「解決」，是「繞開」**——如果之後要撐到 6 個月尺度、角色多達數十人，光靠 recency+importance 排序，長期記憶會被「常發生但不重要」的事件洗掉，論文正是用 relevance 項解決這個問題。我們現在的迴避方式（相關性會強化重複）本身也還沒真正查清楚根因是 embedding 模型選得不好、prompt 沒把相關記憶用對方式呈現，還是模型容量問題。
2. **Reflection 缺席會讓角色關係無法演化**——論文明確示範（Klaus 選 Maria 而非 Wolfgang）reflection 是「從觀察歸納高層認知」的必要元件，沒有這塊，我們的角色只能靠 recency/importance 撿到「常一起出現的人」，論文的消融實驗顯示這是繼完整架構後第二重要的元件（`no reflection` 條件顯著劣於完整架構）。
3. **規劃沒有「觀察→重新規劃」的反應迴路**——論文的 agent 會因為看到意外事件（早餐燒焦）而中斷計畫、重新規劃；我們的規劃是「早上生成完當天就固定不變」，長期模擬下角色行為會顯得死板，論文原文就提到這正是「純規劃、沒有反應機制」會出現的失真。
4. **空間模擬用關鍵詞比對，規模一大就失真**——10 人規模已驗證觸發率過密（10.6 組相遇/60 人-時段），25 人規模（比照論文 Smallville）用同一套邏輯風險是幾乎所有人整天都在講話，跟論文「agent 有自己的活動範圍、view radius」的設計精神背道而馳。
5. **對話生成品質是目前跟論文最大的落差、也是風險最高的一塊**——74% 重複率、6.6% 退化輸出，論文完全沒有這個問題（用的是遠大很多的雲端模型）。這條線已經測過 6 種修復方向都沒根治，只有限制視窗打對折。**如果之後要往「6 個月世界」推進，這塊不解決，其餘元件做得再完整，最終呈現出來的對話品質仍然是短板。**
6. **沒有可信度（believability）評估機制**——目前所有「驗證通過」都是工程指標（完成率、洩漏率、重複率），不代表玩家/使用者主觀上覺得角色行為可信。如果要往論文等級的成果推進，遲早需要類似論文的人類評估或至少質性抽樣。

## 四、如果要合併/推進會遇到的問題

1. **四組目錄互相複製貼上，沒有共用模組**——`poc/`、`poc_mode_a/`、`poc_planning/`、`poc_agent_loop/` 各自維護一份 `characters.py`、各自的 `call_director()`/呼叫邏輯、各自的 `n_predict` 修復（這次崩潰防禦修復就是同一個 pattern 複製了 5 次）。如果要往正式版推進，勢必要決定「共用底層呼叫/記憶模組」的重構時機——現在還在 POC 階段刻意不共用是為了實驗互不干擾，但長期會變成技術債（一個 bug 要在 5 個地方各修一次）。
2. **記憶格式不統一**：`poc_mode_a` 的記憶評分（新近度+重要性，無 embedding 或有 embedding 兩種版本）、`poc_agent_loop` 的跨天持久化記憶（新近度+重要性，embedding 存但不用）——這兩條記憶邏輯是分開發展的，欄位、衰減常數（0.995 vs 0.95）、儲存格式都不完全一致，合併時要先決定哪一版是「正式版」，另一版怎麼淘汰或吸收其中的教訓（例如 embedding 副作用的發現要保留，即使程式碼本身不採用）。
3. **是否要補 Reflection 元件是架構性決策，不是修 bug**——現在完全沒有這塊，補上去牽涉到：要不要在 `poc_agent_loop` 的 memory_store 裡新增 reflection 型別的記憶物件、要不要讓 reflection 也進 retrieve_memories 的排序、觸發閾值怎麼定（論文用 importance 累積分數，我們的 importance 評分邏輯本身是否可直接沿用）。這是一塊新開發，不是整合現有兩條線就能补上的。
4. **對話重複退化沒解決前，其餘整合都是「疊加在壞地基上」**——如果現在把 `poc_agent_loop` 的規劃/記憶/相遇邏輯，跟 `poc/`、`poc_mode_a` 已經驗證過的「窄視窗緩解」正式合併（目前 agent_loop 的對話還沒套用 `RECENT_TURNS_WINDOW` 限制），至少要先把這個已知有效的緩解手段搬進去，否則合併出來的「正式版」對話品質會比兩條線裡任一條單獨測過的都差。
5. **空間模擬替代方案（關鍵詞比對）擴大到 25 人規模前需要重新設計**——這不是「合併」問題，是往論文規模推進前的**必要前置工程**，粒度/機率判定沒調整就直接套用到論文等級的人數，會讓相遇密度失真加劇。
6. **效能規模化**：10 人版一天已要 6.4 分鐘，論文是 25 人跑兩天、耗費「數千美元 token 費用、多天運算」，如果要合併所有元件（規劃+相遇+對話+意識流+反思）在 25 人規模跑，現在的架構（序列呼叫、無平行化）需要先解決效能問題，否則光是跑一次完整驗證就要數小時。

## 五、一句話總結

目前四組 POC 涵蓋了論文四大元件裡的「記憶（部分）、規劃（單層）、空間模擬（替代方案）」，**完全缺 Reflection**，且论文没有遇到、我们花最多力气在修的「對話生成品質（重複退化/崩潰）」才是真正卡住全局的瓶頸。合併這幾條線本身工程上不難（本來就在同一條 git 歷史），但合併前有兩個优先级更高的问题：(a) 決定要不要現在補 Reflection 這塊新開發，(b) 把已驗證有效的視窗限制搬進 `poc_agent_loop` 的對話流程，否則合併只是把已知的重複退化問題也一起搬進「更完整」的架構裡。
