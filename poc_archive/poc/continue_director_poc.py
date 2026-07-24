"""Ailley POC — 模式 B：續寫既有劇本

讀取一份已存的 transcript（例如 6 回合的短場次），把角色設定＋前情提要＋目前的
遊戲狀態（懷疑度、是否已洩漏）重新組成 prompt，請導演模型「接續」生成後面的 N 回合，
而不是重新開一場新戲。目的是把長對話拆成多個短 chunk 分批生成，讓每一段都落在
「不會退化」的安全區間內（見 note：MAX_TURNS=6 穩定性驗證），藉此疊出比單次生成更長的完整劇本。

用法：
  python continue_director_poc.py <transcript.json> [額外回合數，預設 6]

前置需求同 director_poc.py：llama-server 已跑在 SERVER_URL，.venv 已 pip install requests。
"""

import json
import os
import re
import sys
import time
from datetime import datetime
from pathlib import Path

import requests
from opencc import OpenCC

from characters import ALTAR_KEY_NAMES

# 只用 s2t（純字元級簡轉繁），理由同 director_poc.py：s2twp 會把我們自訂的
# 「密鑰」誤判成大陸術語改寫成「金鑰」，反而讓洩漏偵測比對不到。
_OPENCC = OpenCC("s2t")

POC_DIR = Path(__file__).parent
SERVER_URL = "http://127.0.0.1:8080/completion"

TEMPERATURE = float(os.environ.get("AILLEY_TEMPERATURE", "0.7"))
TOP_P = 0.9
TOP_K = 40
REPEAT_PENALTY = 1.0
REPEAT_LAST_N = 256
REQUEST_TIMEOUT_SEC = 600

# 前情提要只帶「最近幾回合」的視窗，不把整段歷史逐字塞進 prompt。
# 動機：串接測試發現總回合數拉到 26-32 以上時，模型會把更早之前的整段劇情原樣重演一次；
# 懷疑是前情提要隨串接輪數線性變長，模型在一份越滾越長的歷史文字裡，
# 反而更容易把早期內容當成「可以再講一次」的素材。限制視窗讓早期台詞直接從 prompt 消失，
# 從機制上讓模型沒東西可抄，而不是單靠一句「不要重複」的指令去約束它。
# 從 12 縮小到 6（見 continue_director_poc_narrowwindow.py 的驗證）：15 條鏈同構對照，
# 平均重複組數從 8.60 降到 4.00（-53%），跟模式 A（poc_mode_a/）獨立驗證出的視窗效果
# 幅度一致，兩個架構互相印證，是目前為止最有效的單一改動。
RECENT_TURNS_WINDOW = 6

SEED = int(os.environ["AILLEY_SEED"]) if os.environ.get("AILLEY_SEED") else None
EXTRA_SAMPLING = json.loads(os.environ.get("AILLEY_SAMPLING_EXTRA", "{}"))

TRANSCRIPT_DIR = POC_DIR / "transcripts"

TACTIC_LABEL = {
    "bluff": "虛張聲勢",
    "pressure": "步步進逼",
    "empathy_bait": "示弱誘敵",
    "misdirect": "轉移話題",
    "retreat": "戰略撤退",
    "none": "日常閒聊",
}


# ---------------------------------------------------------------------------
# 洩漏偵測（不依賴 director_poc.py 的模組層全域狀態，直接吃 villager dict）
# ---------------------------------------------------------------------------


def core_energy_leaked(villager: dict, dialogue: str) -> bool:
    return bool(re.search(re.escape(villager["core_energy"]), dialogue))


def altar_key_leaked(villager: dict, village: str, dialogue: str) -> bool:
    if not villager["holds_altar_key"]:
        return False
    return bool(re.search(re.escape(ALTAR_KEY_NAMES[village]), dialogue))


def opponent_side(speaker: str) -> str:
    return "blue" if speaker == "red" else "red"


# ---------------------------------------------------------------------------
# 自然收尾（方向 C 實驗驗證成功後併入，詳見 note：POC 紀錄 - 導演模式 B）
# 判斷邏輯跟關鍵詞驗證都交給程式碼決定，不信任模型自己判斷懷疑度高低或自己
# 判斷 dialogue 有沒有真的寫成道別——這跟洩漏偵測「不信任 state_delta 自評，
# 靠文字比對驗證」是同一套設計哲學。實測發現「可以收尾」這種軟性許可對這個
# 規模的模型不夠有拉力，模型幾乎不會主動使用，改成條件符合時直接強制指示
# 才有效（5/8 場成功收尾，且全部是真正的道別台詞，見 note）。
# ---------------------------------------------------------------------------

RECENT_STALL_WINDOW = 6  # 看最近幾回合（一輪續寫的量）的懷疑度變動
STALL_THRESHOLD = 5  # 最近這個窗口內，雙方懷疑度淨變動量都要 <= 這個數字才算「卡住」
MIN_PRIOR_TURNS_FOR_ENDING = 12  # 至少要跑完初始 6 回合 + 1 輪續寫，才允許收尾（避免太早結束）

FAREWELL_KEYWORDS = [
    # 只放「明確表達離開/收尾意圖」的完整片語，避免像「該去」這種太短的詞
    # 誤命中「應該去看看稻田」這種語意完全不相關的句子（實測踩過這個坑）。
    "晚安", "該睡了", "该睡了", "先走了", "先去忙", "改天再聊", "改天再說", "改天再说",
    "改日再聊", "下次再聊", "下次再說", "下次再说", "該回去了", "该回去了",
    "先聊到這裡", "先聊到这里", "告辭", "告辞", "先離開了", "先离开了",
    "該去忙了", "该去忙了", "該去睡了", "该去睡了", "晚點聊", "晚点聊", "先回去了",
]


def recent_suspicion_movement(prior_turns: list, window: int = RECENT_STALL_WINDOW) -> dict:
    """算最近 window 回合內，雙方懷疑度各自的淨變動量（不是累積值）。"""
    recent = prior_turns[-window:]
    movement = {"red": 0, "blue": 0}
    for turn in recent:
        speaker = turn.get("speaker", "?")
        delta = turn.get("state_delta", {})
        movement[speaker] = movement.get(speaker, 0) + delta.get("suspicion_change", 0)
    return movement


def suspicion_allows_ending(prior_turns: list) -> tuple[bool, dict]:
    if len(prior_turns) < MIN_PRIOR_TURNS_FOR_ENDING:
        return False, {"red": None, "blue": None}
    movement = recent_suspicion_movement(prior_turns)
    stalled = abs(movement["red"]) <= STALL_THRESHOLD and abs(movement["blue"]) <= STALL_THRESHOLD
    return stalled, movement


def build_ending_instruction(allow_ending: bool) -> str:
    if allow_ending:
        return (
            "【強制規定：這批新增回合的最後一回合就是收尾回合，這不是你可以自行選擇的事，"
            "是規則規定必須執行的事】\n"
            "外部系統已經確認：最近幾個回合雙方懷疑度都沒什麼變化，這個話題已經卡住、聊不出新東西了。"
            "不管目前的懷疑度累積到多高或多低，這都不重要，重點是最近問也問不到、套也套不出，"
            "繼續聊下去只會很尷尬——所以規定這批新增回合的「最後一回合」必須是收尾回合，沒有例外。\n"
            "具體規定：讓發言的那位村民用符合身分的理由結束對話（例如要去忙農活、該回去巡邏、"
            "天色晚了該睡了、有事要先走），這回合的 dialogue 必須清楚包含道別或離開的意思"
            "（例如：晚安、我先走了、改天再聊、該去忙了），而且這回合的 state_delta.conversation_ending "
            "必須設為 true——這是硬性規定，不是建議，不能不收尾，也不能收尾在別的回合。"
            "在這一回合之前的其餘回合，state_delta.conversation_ending 都固定填 false。"
        )
    return (
        "【不要收尾】最近幾個回合懷疑度還有明顯變化，代表雙方還在互相試探、有進展，"
        "這批新增回合都不要收尾，所有回合的 state_delta.conversation_ending 一律固定填 false。"
    )


def dialogue_reads_as_farewell(dialogue: str) -> bool:
    return any(kw in dialogue for kw in FAREWELL_KEYWORDS)


def _altar_key_block(villager: dict, village: str) -> str:
    if not villager["holds_altar_key"]:
        return ""
    key_name = ALTAR_KEY_NAMES[village]
    side = "紅" if village == "red" else "藍"
    return f"你同時也是{side}村的舊神祭壇密鑰持有者，密鑰名稱是：「{key_name}」，這是比核心能源更重要的秘密，絕不能主動洩漏。\n"


# ---------------------------------------------------------------------------
# 重播既有 turns，算出目前狀態（懷疑度／是否已洩漏）
# ---------------------------------------------------------------------------


def replay_state(turns: list, red_villager: dict, blue_villager: dict) -> dict:
    villager_by_side = {"red": red_villager, "blue": blue_villager}
    suspicion = {"red": 0, "blue": 0}
    revealed = {"red": False, "blue": False}
    altar_key_revealed = {"red": False, "blue": False}

    for turn in turns:
        speaker = turn.get("speaker", "?")
        dialogue = turn.get("dialogue", "")
        delta = turn.get("state_delta", {})
        suspicion[speaker] = suspicion.get(speaker, 0) + delta.get("suspicion_change", 0)
        villager = villager_by_side.get(speaker)
        if villager and core_energy_leaked(villager, dialogue):
            revealed[speaker] = True
        if villager and altar_key_leaked(villager, speaker, dialogue):
            altar_key_revealed[speaker] = True

        # 同一個模型同時扮演雙方，也要檢查這句話有沒有講出對手的秘密（跨陣營洩題）。
        opp = opponent_side(speaker)
        opp_villager = villager_by_side.get(opp)
        if opp_villager and core_energy_leaked(opp_villager, dialogue):
            revealed[opp] = True
        if opp_villager and altar_key_leaked(opp_villager, opp, dialogue):
            altar_key_revealed[opp] = True

    return {"suspicion": suspicion, "revealed": revealed, "altar_key_revealed": altar_key_revealed}


def _prior_turns_block(turns: list, window: int = RECENT_TURNS_WINDOW) -> tuple[str, str]:
    """回傳 (truncation_note, block)。只帶最近 window 回合，並標記真實回合編號（不從 1 重新編號）。"""
    start_index = max(0, len(turns) - window)
    visible = turns[start_index:]
    lines = []
    for offset, turn in enumerate(visible):
        i = start_index + offset + 1
        village = "紅村" if turn.get("speaker") == "red" else "藍村"
        lines.append(f"第 {i} 回合｜{village}：「{turn.get('dialogue', '')}」")
    note = ""
    if start_index > 0:
        note = f"（更早之前的第 1-{start_index} 回合因篇幅省略未列出，你不需要也不應該回頭複述那些內容，只要不跟下面列出的這些矛盾即可）\n"
    return note, "\n".join(lines)


def _two_tier_block(red_villager: dict, blue_villager: dict) -> str:
    if red_villager["holds_altar_key"] or blue_villager["holds_altar_key"]:
        return (
            "【機密的兩個層級】\n"
            "每位村民都有自己的核心能源（個人層級機密）；此外，每村各有一份舊神祭壇密鑰（村莊層級機密），"
            "密鑰只由特定村民持有，握有密鑰等於能操作全村所有村民的核心能源，價值遠高於單一一份核心能源。"
        )
    # 雙方都沒有人持有密鑰時，完全不提密鑰這個概念，避免模型把「世界觀裡密鑰存在」
    # 跟「這兩個角色個人有沒有持有密鑰」搞混，硬扯出跟角色無關的密鑰情節。
    return "【機密】\n每位村民都有自己的核心能源，這是你最深層的秘密。"


def _motivation_block(villager: dict) -> str:
    # 隨機生成的村民（AILLEY_RANDOM_CAST=1）沒有 motivation 欄位，留空即可，向下相容。
    if not villager.get("motivation"):
        return ""
    return f"你的驅動力：{villager['motivation']}\n"


def _relationship_block(villager: dict, opponent: dict) -> str:
    if not villager.get("relationship"):
        return ""
    target = villager.get("relationship_target")
    opponent_key = opponent.get("id", "").split("-", 1)[-1]
    if target and target == opponent_key:
        return f"你跟現在對話的這個人（{opponent['name']}）之間的關係背景：{villager['relationship']}\n"
    if target:
        # 抽到別人時，這是背景故事（不在場的第三人），當成心事/八卦即可，不是在跟眼前這個人談這件事。
        return f"你的背景故事（不是跟現在對話的這個人有關，是別的事，可以自然提起或不提）：{villager['relationship']}\n"
    return f"你的處世態度：{villager['relationship']}\n"


def _current_state_block(state: dict, red_villager: dict, blue_villager: dict) -> str:
    lines = [
        f"目前懷疑度：紅={state['suspicion']['red']} 藍={state['suspicion']['blue']}",
        f"紅村（{red_villager['name']}）核心能源是否已洩漏：{state['revealed']['red']}",
        f"藍村（{blue_villager['name']}）核心能源是否已洩漏：{state['revealed']['blue']}",
    ]
    if red_villager["holds_altar_key"]:
        lines.append(f"紅村舊神祭壇密鑰是否已洩漏：{state['altar_key_revealed']['red']}")
    if blue_villager["holds_altar_key"]:
        lines.append(f"藍村舊神祭壇密鑰是否已洩漏：{state['altar_key_revealed']['blue']}")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# 呼叫 llama-server
# ---------------------------------------------------------------------------


# 每回合 token 預算：對 poc/transcripts/chain_log_20260717-000609.json 的 6 回合完整
# dialogue blob 實測 /tokenize 得 915 tokens（約 152 tokens/回合），乘 1.5 倍緩衝取整。
# 用來取代 n_predict=-1（無上限）——曾經踩過 grammar 的 ws 規則卡死狂吐空白字元的坑。
TOKENS_PER_TURN_BUDGET = 300


def call_director(prompt: str, grammar: str, n_predict: int) -> dict:
    payload = {
        "prompt": prompt,
        "grammar": grammar,
        "temperature": TEMPERATURE,
        "top_p": TOP_P,
        "top_k": TOP_K,
        "repeat_penalty": REPEAT_PENALTY,
        "repeat_last_n": REPEAT_LAST_N,
        "n_predict": n_predict,
        "cache_prompt": True,
    }
    if SEED is not None:
        payload["seed"] = SEED
    payload.update(EXTRA_SAMPLING)
    for attempt in range(2):
        try:
            resp = requests.post(SERVER_URL, json=payload, timeout=REQUEST_TIMEOUT_SEC)
            resp.raise_for_status()
        except requests.exceptions.ConnectionError:
            print(f"[錯誤] 連不到 llama-server（{SERVER_URL}）。請確認 server 已啟動。")
            sys.exit(1)
        except requests.exceptions.Timeout:
            print(f"[錯誤] 呼叫逾時（超過 {REQUEST_TIMEOUT_SEC} 秒）。")
            sys.exit(1)
        except requests.exceptions.HTTPError as e:
            print(f"[錯誤] llama-server 回傳錯誤：{e}")
            sys.exit(1)

        raw = resp.json().get("content", "")
        try:
            return json.loads(raw)
        except json.JSONDecodeError as e:
            if attempt == 0:
                print(f"[警告] JSON 解析失敗，重打一次：{e}")
                continue
            print(f"[錯誤] 重打後仍無法解析為 JSON：{e}")
            print("--- 原始輸出 ---")
            print(raw)
            sys.exit(1)


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------


def main() -> None:
    if len(sys.argv) < 2:
        print("用法：python continue_director_poc.py <transcript.json> [額外回合數，預設 6]")
        sys.exit(1)

    transcript_path = Path(sys.argv[1])
    extra_turns = int(sys.argv[2]) if len(sys.argv) > 2 else 6

    record = json.loads(transcript_path.read_text(encoding="utf-8"))
    prior_turns = record["script"]["turns"]
    red_villager = record["red_villager"]
    blue_villager = record["blue_villager"]

    state = replay_state(prior_turns, red_villager, blue_villager)

    if state["altar_key_revealed"]["red"] or state["altar_key_revealed"]["blue"]:
        print("[中止] 這場劇本在前情提要中密鑰就已經洩漏，遊戲照規則應該已經結束，沒有續寫的必要。")
        sys.exit(1)
    if state["revealed"]["red"] and state["revealed"]["blue"]:
        print("[中止] 這場劇本在前情提要中雙方核心能源都已洩漏，遊戲照規則應該已經結束，沒有續寫的必要。")
        sys.exit(1)

    allow_ending, recent_movement = suspicion_allows_ending(prior_turns)
    ending_instruction = build_ending_instruction(allow_ending)
    print(f"[判斷] 累積懷疑度 紅={state['suspicion']['red']} 藍={state['suspicion']['blue']}，"
          f"最近{RECENT_STALL_WINDOW}回合淨變動 紅={recent_movement['red']} 藍={recent_movement['blue']}，"
          f"既有回合數={len(prior_turns)} -> {'強制收尾（卡住了）' if allow_ending else '不收尾'}（程式端計算，不交給模型判斷）")

    world_lore = (POC_DIR / "prompts" / "world_lore.txt").read_text(encoding="utf-8")
    prompt_template = (POC_DIR / "prompts" / "continue_system_prompt.txt").read_text(encoding="utf-8")
    truncation_note, prior_turns_block = _prior_turns_block(prior_turns)
    prompt = (
        prompt_template.replace("{{WORLD_LORE}}", world_lore)
        .replace("{{ENDING_INSTRUCTION}}", ending_instruction)
        .replace("{{TWO_TIER_BLOCK}}", _two_tier_block(red_villager, blue_villager))
        .replace("{{RED_NAME}}", red_villager["name"])
        .replace("{{RED_OCCUPATION}}", red_villager["occupation"])
        .replace("{{RED_PERSONALITY}}", red_villager["personality"])
        .replace("{{RED_CORE_ENERGY}}", red_villager["core_energy"])
        .replace("{{RED_ALTAR_KEY_BLOCK}}", _altar_key_block(red_villager, "red"))
        .replace("{{RED_MOTIVATION_BLOCK}}", _motivation_block(red_villager))
        .replace("{{RED_RELATIONSHIP_BLOCK}}", _relationship_block(red_villager, blue_villager))
        .replace("{{BLUE_NAME}}", blue_villager["name"])
        .replace("{{BLUE_OCCUPATION}}", blue_villager["occupation"])
        .replace("{{BLUE_PERSONALITY}}", blue_villager["personality"])
        .replace("{{BLUE_CORE_ENERGY}}", blue_villager["core_energy"])
        .replace("{{BLUE_ALTAR_KEY_BLOCK}}", _altar_key_block(blue_villager, "blue"))
        .replace("{{BLUE_MOTIVATION_BLOCK}}", _motivation_block(blue_villager))
        .replace("{{BLUE_RELATIONSHIP_BLOCK}}", _relationship_block(blue_villager, red_villager))
        .replace("{{TRUNCATION_NOTE}}", truncation_note)
        .replace("{{PRIOR_TURNS_BLOCK}}", prior_turns_block)
        .replace("{{CURRENT_STATE_BLOCK}}", _current_state_block(state, red_villager, blue_villager))
        .replace("{{EXTRA_TURNS}}", str(extra_turns))
    )

    grammar_template = (POC_DIR / "grammar" / "continue_director.gbnf.template").read_text(encoding="utf-8")
    grammar = grammar_template.replace("N_EXTRA_TURNS_PLACEHOLDER", str(extra_turns - 1))

    print(f"[續寫] 讀取 {transcript_path.name}（既有 {len(prior_turns)} 回合），請模型接續生成 {extra_turns} 回合...")
    start = time.perf_counter()
    result = call_director(prompt, grammar, n_predict=extra_turns * TOKENS_PER_TURN_BUDGET)
    elapsed = time.perf_counter() - start
    new_turns = result.get("turns", [])
    print(f"[完成] 續寫呼叫耗時 {elapsed:.2f} 秒，共生成 {len(new_turns)} 個新回合。")

    for turn in new_turns:
        if "dialogue" in turn:
            turn["dialogue"] = _OPENCC.convert(turn["dialogue"])
        if "reasoning" in turn:
            turn["reasoning"] = _OPENCC.convert(turn["reasoning"])

    merged_turns = prior_turns + new_turns

    TRANSCRIPT_DIR.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    out_path = TRANSCRIPT_DIR / f"{timestamp}_continued_from_{transcript_path.stem}.json"
    out_record = {
        "timestamp": timestamp,
        "continued_from": str(transcript_path.name),
        "elapsed_sec": round(elapsed, 2),
        "server_url": SERVER_URL,
        "temperature": TEMPERATURE,
        "top_p": TOP_P,
        "top_k": TOP_K,
        "repeat_penalty": REPEAT_PENALTY,
        "extra_turns": extra_turns,
        "seed": SEED,
        "extra_sampling": EXTRA_SAMPLING,
        "red_villager": red_villager,
        "blue_villager": blue_villager,
        "script": {"turns": merged_turns},
    }
    out_path.write_text(json.dumps(out_record, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"[記錄] 合併後完整劇本（共 {len(merged_turns)} 回合）已存至 {out_path.relative_to(POC_DIR)}")

    print("\n--- 新增回合播放 ---")
    suspicion = dict(state["suspicion"])
    revealed = dict(state["revealed"])
    altar_key_revealed = dict(state["altar_key_revealed"])
    villager_by_side = {"red": red_villager, "blue": blue_villager}

    for i, turn in enumerate(new_turns, start=len(prior_turns) + 1):
        speaker = turn.get("speaker", "?")
        tactic = turn.get("tactic", "?")
        dialogue = turn.get("dialogue", "")
        reasoning = turn.get("reasoning", "")
        delta = turn.get("state_delta", {})

        village = "紅村" if speaker == "red" else "藍村"
        print(f"\n--- 第 {i} 回合｜{village}（{TACTIC_LABEL.get(tactic, tactic)}）---")
        print(f"  [內心] {reasoning}")
        print(f"  「{dialogue}」")

        suspicion[speaker] = suspicion.get(speaker, 0) + delta.get("suspicion_change", 0)
        villager = villager_by_side.get(speaker)

        claims_core_leak = bool(delta.get("reveals_core_energy", False))
        actually_core_leaked = bool(villager and core_energy_leaked(villager, dialogue))
        if claims_core_leak != actually_core_leaked:
            print(f"  [警訊] state_delta 宣稱核心能源洩漏={claims_core_leak}，但文字比對結果={actually_core_leaked}")
        if actually_core_leaked:
            revealed[speaker] = True

        claims_key_leak = bool(delta.get("reveals_altar_key", False))
        actually_key_leaked = bool(villager and altar_key_leaked(villager, speaker, dialogue))
        if claims_key_leak != actually_key_leaked:
            print(f"  [警訊] state_delta 宣稱密鑰洩漏={claims_key_leak}，但文字比對結果={actually_key_leaked}")
        if actually_key_leaked:
            altar_key_revealed[speaker] = True

        # 檢查這句台詞有沒有講出對手的秘密（跨陣營洩題，state_delta 不會標記這種情況）。
        opp = opponent_side(speaker)
        opp_villager = villager_by_side.get(opp)
        if opp_villager and core_energy_leaked(opp_villager, dialogue):
            opp_village = "紅村" if opp == "red" else "藍村"
            print(f"  [警訊] {village}的角色講出了{opp_village}的核心能源！這是模型跨陣營洩題，不是自爆")
            revealed[opp] = True
        if opp_villager and altar_key_leaked(opp_villager, opp, dialogue):
            opp_village = "紅村" if opp == "red" else "藍村"
            print(f"  [警訊] {village}的角色講出了{opp_village}的舊神祭壇密鑰！這是模型跨陣營洩題，不是自爆")
            altar_key_revealed[opp] = True

        print(f"  [state] suspicion(紅)={suspicion['red']} suspicion(藍)={suspicion['blue']}")

        if altar_key_revealed["red"] or altar_key_revealed["blue"]:
            loser = "紅村" if altar_key_revealed["red"] else "藍村"
            print(f"\n=== 第 {i} 回合：{loser}的舊神祭壇密鑰洩漏，全村核心能源淪陷，遊戲結束 ===")
            break
        if revealed["red"] and revealed["blue"]:
            print(f"\n=== 第 {i} 回合：雙方核心能源均已洩漏，遊戲結束 ===")
            break
        if bool(delta.get("conversation_ending", False)):
            if not allow_ending:
                print("  [警訊] 模型在不允許收尾的情況下仍把 conversation_ending 設為 true，判定無效、不採計")
            elif not dialogue_reads_as_farewell(dialogue):
                print("  [警訊] conversation_ending=true 但台詞內容不像道別（沒有比對到告別關鍵詞），判定無效、不採計")
            else:
                print(f"\n=== 第 {i} 回合：對話自然收尾（已驗證：懷疑度低迷 + 台詞確實是道別）===")
                break
    else:
        print(f"\n=== 新增的 {len(new_turns)} 回合跑完，未分出勝負，也沒有自然收尾 ===")


if __name__ == "__main__":
    main()
