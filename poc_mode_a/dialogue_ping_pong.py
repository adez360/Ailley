"""Ailley POC — 模式 A：雙 AI Ping-Pong（兩個獨立呼叫輪流扮演紅藍村民）

跟 poc/（模式 B：導演單次呼叫扮演雙方）完全獨立，不 import poc/ 的任何模組，
必要的靜態素材（characters.py、world_lore.txt）各自複製一份維護。

跟模式 B 的核心差異：每一回合都是一次獨立的模型呼叫，只知道「自己」的角色設定與秘密，
看不到對方的核心能源／密鑰，也看不到對方的 reasoning——只看得到雙方目前為止實際說出口
的台詞（shared_log）。

第一版（5 場）驗證推翻了「拆成每次只生成一句話就能避開重複退化」這個假設——5/5 場都
出現重複，且比模式 B 任何一批都更快發生。細看最早退化的案例後重新定位根因：不是「一次
呼叫要撐多長」，是「懷疑度停滯、話題沒有新進展時，模型面對幾乎一樣的輸入情境，自然傾向
產生幾乎一樣的輸出」。這版加入停滯偵測＋強制新話題注入（移植自 batch_regen v2 裡唯一
證實有效的元件 STUCK_TOPIC_HOOKS），在每一回合呼叫前偵測卡住就直接注入，不像 batch_regen
要等一整批生成完才能事後補救。

用法：
  python dialogue_ping_pong.py

環境變數：
  AILLEY_MODE_A_MAX_TURNS：總回合數上限（預設 10，紅藍輪流，紅村先開口）
  AILLEY_SEED／AILLEY_TEMPERATURE／AILLEY_SAMPLING_EXTRA：跟 poc/ 同名變數用途一致

前置需求：llama-server 已跑在 SERVER_URL，pip install requests opencc-python-reimplemented。
"""

import difflib
import json
import os
import random
import re
import sys
import time
from datetime import datetime
from pathlib import Path

import requests
from opencc import OpenCC

from characters import generate_fixed_roster, pick_encounter

_OPENCC = OpenCC("s2t")

POC_DIR = Path(__file__).parent
SERVER_URL = "http://127.0.0.1:8080/completion"
TRANSCRIPT_DIR = POC_DIR / "transcripts"

TEMPERATURE = float(os.environ.get("AILLEY_TEMPERATURE", "0.7"))
TOP_P = 0.9
TOP_K = 40
REPEAT_PENALTY = 1.0
REPEAT_LAST_N = 256
REQUEST_TIMEOUT_SEC = 600
MAX_TURNS = int(os.environ.get("AILLEY_MODE_A_MAX_TURNS", "10"))
# 單回合 token 預算：對 poc/transcripts 的完整 6 回合 dialogue blob 實測 /tokenize 得
# 915 tokens（約 152 tokens/回合），乘 1.5 倍緩衝取整。用來取代 n_predict=-1（無上限）
# ——曾經踩過 grammar 的 ws 規則卡死狂吐空白字元的坑（同一個坑 dialogue_ping_pong_memory.py
# 已經修過，這裡是同一個 pattern）。
TOKENS_PER_TURN_BUDGET = 300
STAGNATION_ENABLED = os.environ.get("AILLEY_MODE_A_STAGNATION", "1") != "0"
# 前情提要只帶最近幾回合，不把整段歷史無限制塞進 prompt——控制實驗驗證過（見
# dialogue_ping_pong_memory.py 的純視窗對照組），這個改動本身就能把重複組數降約 49%，
# 不需要疊加重要性評分也有效，是目前性價比最高的單一改動，跟模式 B 的 RECENT_TURNS_WINDOW
# 併入同一次驗證出的幅度一致（-53%）。
RECENT_TURNS_WINDOW = 6

SEED = int(os.environ["AILLEY_SEED"]) if os.environ.get("AILLEY_SEED") else None
EXTRA_SAMPLING = json.loads(os.environ.get("AILLEY_SAMPLING_EXTRA", "{}"))

TACTIC_LABEL = {
    "bluff": "虛張聲勢",
    "pressure": "步步進逼",
    "empathy_bait": "示弱誘敵",
    "misdirect": "轉移話題",
    "retreat": "戰略撤退",
    "none": "日常閒聊",
}


# ---------------------------------------------------------------------------
# 洩漏偵測
# ---------------------------------------------------------------------------


def core_energy_leaked(villager: dict, dialogue: str) -> bool:
    return bool(re.search(re.escape(villager["core_energy"]), dialogue))


def altar_key_leaked(villager: dict, altar_key_name: str, dialogue: str) -> bool:
    if not villager["holds_altar_key"]:
        return False
    return bool(re.search(re.escape(altar_key_name), dialogue))


def opponent_side(speaker: str) -> str:
    return "blue" if speaker == "red" else "red"


# ---------------------------------------------------------------------------
# 停滯偵測 + 強制新話題注入
# 移植自 poc/continue_director_poc_batch_regen.py 裡唯一證實有效的元件：
# STUCK_TOPIC_HOOKS／build_stuck_topic_instruction()（複製過來，不 import，維持獨立）。
# 這裡改成逐回合呼叫前判斷，而不是模式 B 那種「一整批生成完才能事後補救」。
# ---------------------------------------------------------------------------

STAGNATION_REPEAT_THRESHOLD = 0.8
STAGNATION_SELF_WINDOW = 4  # 看自己最近幾次發言有沒有近乎重複
STAGNATION_SUSPICION_WINDOW = 4  # 看自己最近幾次發言的懷疑度淨變動
STAGNATION_SUSPICION_THRESHOLD = 5  # 這個窗口內淨變動量 <= 這個數字才算「卡住」

STUCK_TOPIC_HOOKS = [
    "老周最近在渡口說，他新釀的一批米酒特別香，已經有不少人向他打聽訣竅。",
    "後山老井最近排隊取水的人變多了，聽說是因為豐收季快到了。",
    "芷姨在市集又聽到什麼消息，逢人就想聊上兩句。",
    "阿柏這幾天在碼頭修一艘新來的漁船，船身的記號跟平常見過的不太一樣。",
    "哨站的守衛換班時，提到昨晚巡邏時聽到田埂那邊有點動靜。",
    "老馮的鐵匠鋪這幾天在趕製一批農具，說是豐收季前大家都來得急。",
    "集市日前一天，村口大榕樹下已經有人搶著佔位子擺攤了。",
    "芷姨新織的頭巾用了少見的藍紫色染料，市集裡好幾個人在問哪裡買得到。",
    "渡口的茶棚今天特別多人，聽說是在等一艘晚到的漁船。",
]


def detect_self_repetition(own_turns: list, window: int = STAGNATION_SELF_WINDOW,
                            threshold: float = STAGNATION_REPEAT_THRESHOLD) -> bool:
    """比對自己最近 window 次發言的 reasoning/dialogue 有沒有近乎重複。"""
    recent = own_turns[-window:]
    for i in range(len(recent)):
        for j in range(i + 1, len(recent)):
            for field in ("dialogue", "reasoning"):
                a, b = recent[i].get(field, ""), recent[j].get(field, "")
                if not a or not b:
                    continue
                if difflib.SequenceMatcher(None, a, b).ratio() >= threshold:
                    return True
    return False


def detect_suspicion_stagnation(own_turns: list, window: int = STAGNATION_SUSPICION_WINDOW,
                                 threshold: int = STAGNATION_SUSPICION_THRESHOLD) -> bool:
    """看自己最近 window 次發言的懷疑度淨變動量是否卡住（樣本不足時視為未卡住）。"""
    recent = own_turns[-window:]
    if len(recent) < window:
        return False
    movement = sum(t.get("state_delta", {}).get("suspicion_change", 0) for t in recent)
    return abs(movement) <= threshold


_DEGENERATE_STRIP_PATTERN = re.compile(r"[^\w一-龥]")


def is_degenerate_output(text: str) -> bool:
    """去除標點符號後，剩餘的中文/英數字元太少（例如「...」「。」空字串），
    判定為生成失敗，不是正常的短內容。"""
    return len(_DEGENERATE_STRIP_PATTERN.sub("", text)) < 2


def build_stuck_topic_instruction(hook: str) -> str:
    return (
        "【強制規定：這一回合必須帶入一個新話題切入點，這不是可以自行選擇的事】\n"
        "外部系統判斷：最近的對話已經在原地打轉，光靠換句話說沒有用，需要真正新的素材才能讓"
        "對話繼續往前推進。具體規定：這一回合請自然帶出以下這件近況、當作新話題的切入點"
        "（可以搭配你的個性自由發揮怎麼講、用什麼態度講，但這件事本身一定要出現，這不是機密，"
        "只是尋常的日常近況）：\n"
        f"「{hook}」"
    )


# ---------------------------------------------------------------------------
# prompt 組裝
# ---------------------------------------------------------------------------


def _two_tier_block(self_villager: dict) -> str:
    if self_villager["holds_altar_key"]:
        return (
            "【機密的兩個層級】\n"
            "你有自己的核心能源（個人層級機密）；此外你村莊還有一份舊神祭壇密鑰（村莊層級機密），"
            "只有特定村民持有，握有密鑰等於能操作全村所有村民的核心能源，價值遠高於單一一份核心能源。"
            "你剛好就是密鑰持有者，這是比核心能源更重要的秘密。"
        )
    return "【機密】\n你有自己的核心能源，這是你最深層的秘密。"


def _altar_key_block(self_villager: dict, altar_key_name: str) -> str:
    if not self_villager["holds_altar_key"]:
        return ""
    return f"你同時也是舊神祭壇密鑰持有者，密鑰名稱是：「{altar_key_name}」，這是比核心能源更重要的秘密，絕不能主動洩漏。\n"


def _motivation_block(villager: dict) -> str:
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
        return f"你的背景故事（不是跟現在對話的這個人有關，是別的事，可以自然提起或不提）：{villager['relationship']}\n"
    return f"你的處世態度：{villager['relationship']}\n"


def _own_history_block(own_turns: list, window: int = RECENT_TURNS_WINDOW) -> str:
    if not own_turns:
        return "（這是你的第一次發言，還沒有過去的內心想法或發言）"
    start_index = max(0, len(own_turns) - window)
    visible = own_turns[start_index:]
    lines = []
    if start_index > 0:
        lines.append(f"（更早之前的第 1-{start_index} 次發言因篇幅省略，不需要也不應該回頭複述）")
    for offset, turn in enumerate(visible):
        i = start_index + offset + 1
        lines.append(f"第 {i} 次發言：\n  內心想法：{turn['reasoning']}\n  說的話：「{turn['dialogue']}」")
    return "\n".join(lines)


def _shared_dialogue_block(shared_log: list, window: int = RECENT_TURNS_WINDOW) -> str:
    if not shared_log:
        return "（對話尚未開始，你是第一個發言的人）"
    start_index = max(0, len(shared_log) - window)
    visible = shared_log[start_index:]
    lines = []
    if start_index > 0:
        lines.append(f"（更早之前的第 1-{start_index} 回合因篇幅省略，不需要也不應該回頭複述）")
    for offset, entry in enumerate(visible):
        i = start_index + offset + 1
        village = "紅村" if entry["speaker"] == "red" else "藍村"
        lines.append(f"第 {i} 回合｜{village}：「{entry['dialogue']}」")
    return "\n".join(lines)


def build_prompt(template: str, world_lore: str, speaker: str, self_villager: dict, opponent_villager: dict,
                  altar_key_name: str, own_turns: list, shared_log: list, stuck_instruction: str = "") -> str:
    return (
        template.replace("{{WORLD_LORE}}", world_lore)
        .replace("{{STUCK_INSTRUCTION_BLOCK}}", stuck_instruction)
        .replace("{{TWO_TIER_BLOCK}}", _two_tier_block(self_villager))
        .replace("{{SELF_NAME}}", self_villager["name"])
        .replace("{{SELF_OCCUPATION}}", self_villager["occupation"])
        .replace("{{SELF_PERSONALITY}}", self_villager["personality"])
        .replace("{{SELF_CORE_ENERGY}}", self_villager["core_energy"])
        .replace("{{SELF_ALTAR_KEY_BLOCK}}", _altar_key_block(self_villager, altar_key_name))
        .replace("{{SELF_MOTIVATION_BLOCK}}", _motivation_block(self_villager))
        .replace("{{SELF_RELATIONSHIP_BLOCK}}", _relationship_block(self_villager, opponent_villager))
        .replace("{{OPPONENT_NAME}}", opponent_villager["name"])
        .replace("{{OPPONENT_OCCUPATION}}", opponent_villager["occupation"])
        .replace("{{OPPONENT_PERSONALITY}}", opponent_villager["personality"])
        .replace("{{OWN_HISTORY_BLOCK}}", _own_history_block(own_turns))
        .replace("{{SHARED_DIALOGUE_BLOCK}}", _shared_dialogue_block(shared_log))
    )


# ---------------------------------------------------------------------------
# 呼叫 llama-server
# ---------------------------------------------------------------------------


def call_director(prompt: str, grammar: str, seed_override: int | None = None, n_predict: int = TOKENS_PER_TURN_BUDGET) -> dict:
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
    if seed_override is not None:
        payload["seed"] = seed_override
    elif SEED is not None:
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
    if SEED is not None:
        random.seed(SEED)
    roster = generate_fixed_roster()
    red_villager, blue_villager = pick_encounter(roster)
    altar_keys = roster["altar_keys"]
    villager_by_side = {"red": red_villager, "blue": blue_villager}

    print(f"[本場主角] 紅村：{red_villager['name']}（{red_villager['occupation']}，{red_villager['personality']}）"
          f" vs 藍村：{blue_villager['name']}（{blue_villager['occupation']}，{blue_villager['personality']}）")
    if red_villager["holds_altar_key"]:
        print(f"  紅村持有密鑰：{altar_keys['red']}")
    if blue_villager["holds_altar_key"]:
        print(f"  藍村持有密鑰：{altar_keys['blue']}")

    world_lore = (POC_DIR / "prompts" / "world_lore.txt").read_text(encoding="utf-8")
    prompt_template = (POC_DIR / "prompts" / "villager_system_prompt.txt").read_text(encoding="utf-8")
    grammar = (POC_DIR / "grammar" / "turn.gbnf.template").read_text(encoding="utf-8")

    own_history = {"red": [], "blue": []}
    shared_log: list = []
    merged_turns: list = []
    suspicion = {"red": 0, "blue": 0}
    revealed = {"red": False, "blue": False}
    altar_key_revealed = {"red": False, "blue": False}
    cross_faction_leak_count = 0
    used_hooks = {"red": set(), "blue": set()}

    start_total = time.perf_counter()

    for i in range(1, MAX_TURNS + 1):
        speaker = "red" if i % 2 == 1 else "blue"
        opp = opponent_side(speaker)
        self_villager = villager_by_side[speaker]
        opponent_villager = villager_by_side[opp]

        village_label = "紅村" if speaker == "red" else "藍村"
        self_repeat = STAGNATION_ENABLED and detect_self_repetition(own_history[speaker])
        suspicion_stuck = STAGNATION_ENABLED and detect_suspicion_stagnation(own_history[speaker])
        stuck_instruction = ""
        if self_repeat or suspicion_stuck:
            reason = "自我重複+懷疑度停滯" if (self_repeat and suspicion_stuck) else (
                "自我重複" if self_repeat else "懷疑度停滯")
            available_hooks = [h for h in STUCK_TOPIC_HOOKS if h not in used_hooks[speaker]] or STUCK_TOPIC_HOOKS
            hook = random.choice(available_hooks)
            used_hooks[speaker].add(hook)
            stuck_instruction = build_stuck_topic_instruction(hook)
            print(f"[stagnation] 判定{village_label}第{i}回合卡住（{reason}），加入強制新話題指令：「{hook}」")

        prompt = build_prompt(prompt_template, world_lore, speaker, self_villager, opponent_villager,
                               altar_keys[speaker], own_history[speaker], shared_log, stuck_instruction)

        for attempt in range(1, 4):
            # 固定 seed 的控制實驗模式下，重試要跟著換 seed，否則同一個 seed 重打
            # 會拿到一模一樣的退化輸出（llama-server 對同一組 prompt+seed 是決定性的）。
            seed_override = (SEED + attempt - 1) if SEED is not None and attempt > 1 else None
            start = time.perf_counter()
            result = call_director(prompt, grammar, seed_override=seed_override)
            elapsed = time.perf_counter() - start
            reasoning = _OPENCC.convert(result.get("reasoning", ""))
            dialogue = _OPENCC.convert(result.get("dialogue", ""))
            if not is_degenerate_output(reasoning) and not is_degenerate_output(dialogue):
                break
            print(f"[degenerate] 第 {attempt} 次嘗試輸出退化（reasoning={reasoning!r}, dialogue={dialogue!r}），重新生成...")
        else:
            print("[degenerate] 已達最大重試次數，仍是退化輸出，採用最後一次結果")

        tactic = result.get("tactic", "?")
        delta = result.get("state_delta", {})

        village = "紅村" if speaker == "red" else "藍村"
        print(f"\n--- 第 {i} 回合｜{village}（{TACTIC_LABEL.get(tactic, tactic)}）| {elapsed:.2f}秒 ---")
        print(f"  [內心] {reasoning}")
        print(f"  「{dialogue}」")

        suspicion[speaker] += delta.get("suspicion_change", 0)

        claims_core_leak = bool(delta.get("reveals_core_energy", False))
        actually_core_leaked = core_energy_leaked(self_villager, dialogue)
        if claims_core_leak != actually_core_leaked:
            print(f"  [警訊] state_delta 宣稱核心能源洩漏={claims_core_leak}，但文字比對結果={actually_core_leaked}")
        if actually_core_leaked:
            revealed[speaker] = True

        claims_key_leak = bool(delta.get("reveals_altar_key", False))
        actually_key_leaked = altar_key_leaked(self_villager, altar_keys[speaker], dialogue)
        if claims_key_leak != actually_key_leaked:
            print(f"  [警訊] state_delta 宣稱密鑰洩漏={claims_key_leak}，但文字比對結果={actually_key_leaked}")
        if actually_key_leaked:
            altar_key_revealed[speaker] = True

        # 資訊隔離驗證：self 沒看過 opponent 的秘密字串，理論上不可能講出來，
        # 這裡保留檢查只是為了確認這件事真的成立（預期恆為 0）。
        opponent_villager_secret = villager_by_side[opp]
        if core_energy_leaked(opponent_villager_secret, dialogue):
            print(f"  [警訊] {village}的角色講出了對方的核心能源！理論上不該發生（資訊隔離失效）")
            cross_faction_leak_count += 1
            revealed[opp] = True
        if altar_key_leaked(opponent_villager_secret, altar_keys[opp], dialogue):
            print(f"  [警訊] {village}的角色講出了對方的舊神祭壇密鑰！理論上不該發生（資訊隔離失效）")
            cross_faction_leak_count += 1
            altar_key_revealed[opp] = True

        print(f"  [state] suspicion(紅)={suspicion['red']} suspicion(藍)={suspicion['blue']}")

        turn_record = {
            "speaker": speaker,
            "reasoning": reasoning,
            "tactic": tactic,
            "dialogue": dialogue,
            "state_delta": delta,
            "elapsed_sec": round(elapsed, 2),
        }
        own_history[speaker].append(turn_record)
        shared_log.append({"speaker": speaker, "dialogue": dialogue})
        merged_turns.append(turn_record)

        if altar_key_revealed["red"] or altar_key_revealed["blue"]:
            loser = "紅村" if altar_key_revealed["red"] else "藍村"
            print(f"\n=== 第 {i} 回合：{loser}的舊神祭壇密鑰洩漏，全村核心能源淪陷，遊戲結束 ===")
            break
        if revealed["red"] and revealed["blue"]:
            print(f"\n=== 第 {i} 回合：雙方核心能源均已洩漏，遊戲結束 ===")
            break
    else:
        print(f"\n=== 跑滿 {MAX_TURNS} 回合，未分出勝負 ===")

    elapsed_total = time.perf_counter() - start_total

    print(f"\n--- 最終戰報 ---")
    print(f"  總耗時：{elapsed_total:.2f} 秒（{len(shared_log)} 回合，平均每回合 {elapsed_total/max(len(shared_log),1):.2f} 秒）")
    print(f"  紅村（{red_villager['name']}）核心能源洩漏：{revealed['red']}")
    print(f"  藍村（{blue_villager['name']}）核心能源洩漏：{revealed['blue']}")
    print(f"  跨陣營洩題次數（預期應為 0）：{cross_faction_leak_count}")
    print(f"  最終懷疑度：紅={suspicion['red']} 藍={suspicion['blue']}")

    TRANSCRIPT_DIR.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    out_path = TRANSCRIPT_DIR / f"{timestamp}.json"
    out_record = {
        "timestamp": timestamp,
        "mode": "A_ping_pong",
        "elapsed_sec": round(elapsed_total, 2),
        "server_url": SERVER_URL,
        "temperature": TEMPERATURE,
        "top_p": TOP_P,
        "top_k": TOP_K,
        "repeat_penalty": REPEAT_PENALTY,
        "max_turns": MAX_TURNS,
        "seed": SEED,
        "extra_sampling": EXTRA_SAMPLING,
        "red_villager": red_villager,
        "blue_villager": blue_villager,
        "cross_faction_leak_count": cross_faction_leak_count,
        "own_history": own_history,
        "script": {"turns": merged_turns},
    }
    out_path.write_text(json.dumps(out_record, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"[記錄] 完整劇本已存至 {out_path.relative_to(POC_DIR)}")


if __name__ == "__main__":
    main()
