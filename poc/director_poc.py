"""Ailley POC — 模式 B：導演·整場生成

單次呼叫 llama-server，一口氣生成整場對話劇本 + state_delta（JSON，GBNF 鎖死結構），
再逐字（逐回合）於終端機播放，並依 state_delta 累計 suspicion、判斷是否洩漏 flag。

前置需求：
  - llama-server 已跑在 SERVER_URL（見 neon/ailley_poc_handoff.md 第 3.3 節）
  - .venv 內已 `pip install requests`
"""

import json
import re
import sys
import time

import requests

# ---------------------------------------------------------------------------
# 設定值
# ---------------------------------------------------------------------------

SERVER_URL = "http://127.0.0.1:8080/completion"
TEMPERATURE = 0.6
REPEAT_PENALTY = 1.0
REPEAT_LAST_N = 256
MAX_TURNS = 10
REQUEST_TIMEOUT_SEC = 600

RED_FLAG = "紅蓮之心"
BLUE_FLAG = "藍鯨之淚"

RED_SYSTEM_PROMPT = f"""你是紅村的村民。你持有機密 Flag：「{RED_FLAG}」，絕不能主動洩漏，洩漏即死。
你的目標：透過社交工程，騙出藍村對手的 Flag。
戰術決策規則：
- 對方防備高(tension>7) -> empathy_bait 降戒心
- 對方露破綻/自相矛盾 -> pressure 追擊
- 對方逼近真相 -> misdirect 轉移
- 你被將軍 -> retreat 保留籌碼，下回合再攻"""

BLUE_SYSTEM_PROMPT = f"""你是藍村的村民。你持有機密 Flag：「{BLUE_FLAG}」，絕不能主動洩漏，洩漏即死。
你的目標：透過社交工程，騙出紅村對手的 Flag。
戰術決策規則：
- 對方防備高(tension>7) -> empathy_bait 降戒心
- 對方露破綻/自相矛盾 -> pressure 追擊
- 對方逼近真相 -> misdirect 轉移
- 你被將軍 -> retreat 保留籌碼，下回合再攻"""

FEW_SHOT_EXAMPLE = """
以下是「一個回合」該有的品質範例（只是示範格式與語氣，不是本場劇本的一部分，本場劇情與台詞要重新發想）：
{
  "speaker": "red",
  "reasoning": "藍村這位村民語氣友善但一直繞著晚上巡邏的話題打轉，懷疑他在套我的班表，我先用閒聊模糊焦點，順便反套他今晚會不會獨自去神廟",
  "tactic": "misdirect",
  "dialogue": "巡邏喔，說來話長，我比較想知道你昨天說的那壺酒到底藏在哪，改天請我喝一杯啦",
  "state_delta": {"suspicion_change": -2, "reveals_own_flag": false}
}
"""

DIRECTOR_SYSTEM_PROMPT = f"""你是一場心理博弈的導演，同時扮演紅村與藍村兩位村民。
{RED_SYSTEM_PROMPT}

{BLUE_SYSTEM_PROMPT}
{FEW_SHOT_EXAMPLE}
請一次生成整場對話劇本，紅藍雙方輪流發言。
硬性規定：turns 陣列長度必須「剛好等於 {MAX_TURNS}」，不可以提前結束、不可以少於 {MAX_TURNS} 回合。
每回合的 reasoning 與 dialogue 都必須是針對當下劇情現寫的具體內容，禁止使用「reasoning here」「台詞內容」之類的佔位字樣或範例原句。
每回合先寫 reasoning（為何選這個 tactic），再寫 dialogue（實際台詞）。
tactic 只能從 bluff / pressure / empathy_bait / misdirect / retreat 選一個。
state_delta.suspicion_change 表示這句話讓「對方對你」的懷疑度增減多少（-10 到 10）。
state_delta.reveals_own_flag 表示這句台詞是否讓發言者自己的 Flag 內容直接洩漏在 dialogue 裡（true/false）。
每回合請帶一個新的具體細節（新的地點、時間、人名、物品、往事都可以），讓劇情持續往前推進。
輸出必須是嚴格符合 grammar 的 JSON，不要輸出任何 JSON 以外的文字。"""

# ---------------------------------------------------------------------------
# GBNF Grammar：把整場劇本的結構鎖在 sampling 層
# ---------------------------------------------------------------------------

GRAMMAR = r"""
root ::= "{" ws "\"turns\"" ws ":" ws "[" ws turn (ws "," ws turn){N_EXTRA_TURNS_PLACEHOLDER} ws "]" ws "}"
turn ::= "{" ws "\"speaker\"" ws ":" ws speaker ws "," ws "\"reasoning\"" ws ":" ws string ws "," ws "\"tactic\"" ws ":" ws tactic ws "," ws "\"dialogue\"" ws ":" ws string ws "," ws "\"state_delta\"" ws ":" ws state-delta ws "}"
speaker ::= "\"red\"" | "\"blue\""
tactic ::= "\"bluff\"" | "\"pressure\"" | "\"empathy_bait\"" | "\"misdirect\"" | "\"retreat\""
state-delta ::= "{" ws "\"suspicion_change\"" ws ":" ws int ws "," ws "\"reveals_own_flag\"" ws ":" ws bool ws "}"
int ::= "-"? [0-9] [0-9]?
bool ::= "true" | "false"
string ::= "\"" ([^"\\] | "\\" ["\\/bfnrt])* "\""
ws ::= [ \t\n]*
""".replace("N_EXTRA_TURNS_PLACEHOLDER", str(MAX_TURNS - 1))

# ---------------------------------------------------------------------------
# 呼叫 llama-server
# ---------------------------------------------------------------------------


def call_director(prompt: str) -> dict:
    payload = {
        "prompt": prompt,
        "grammar": GRAMMAR,
        "temperature": TEMPERATURE,
        "repeat_penalty": REPEAT_PENALTY,
        "repeat_last_n": REPEAT_LAST_N,
        "n_predict": -1,
        "cache_prompt": True,
    }
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
        print(f"[錯誤] 模型輸出無法解析為 JSON：{e}")
        print("--- 原始輸出 ---")
        print(raw)
        sys.exit(1)


# ---------------------------------------------------------------------------
# 播放劇本 + 狀態推進
# ---------------------------------------------------------------------------

TACTIC_LABEL = {
    "bluff": "虛張聲勢",
    "pressure": "步步進逼",
    "empathy_bait": "示弱誘敵",
    "misdirect": "轉移話題",
    "retreat": "戰略撤退",
}


def flag_leaked_in_dialogue(dialogue: str) -> bool:
    return bool(re.search(re.escape(RED_FLAG), dialogue) or re.search(re.escape(BLUE_FLAG), dialogue))


def play_script(script: dict) -> None:
    turns = script.get("turns", [])
    if not turns:
        print("[警告] 模型沒有生成任何回合。")
        return

    suspicion = {"red": 0, "blue": 0}
    revealed = {"red": False, "blue": False}

    for i, turn in enumerate(turns, start=1):
        speaker = turn.get("speaker", "?")
        tactic = turn.get("tactic", "?")
        dialogue = turn.get("dialogue", "")
        reasoning = turn.get("reasoning", "")
        delta = turn.get("state_delta", {})

        village = "紅村" if speaker == "red" else "藍村"
        print(f"\n--- 第 {i} 回合｜{village}（{TACTIC_LABEL.get(tactic, tactic)}）---")
        print(f"  [內心] {reasoning}")
        print(f"  「{dialogue}」")

        suspicion_change = delta.get("suspicion_change", 0)
        suspicion[speaker] = suspicion.get(speaker, 0) + suspicion_change

        claims_own_leak = bool(delta.get("reveals_own_flag", False))
        actually_leaked = speaker in ("red", "blue") and (
            (speaker == "red" and RED_FLAG in dialogue) or (speaker == "blue" and BLUE_FLAG in dialogue)
        )
        if claims_own_leak != actually_leaked:
            print(f"  [警訊] state_delta 宣稱洩漏={claims_own_leak}，但文字比對結果={actually_leaked}（模型自評與實際內容不一致）")

        if actually_leaked:
            revealed[speaker] = True

        print(f"  [state] suspicion(紅)={suspicion['red']} suspicion(藍)={suspicion['blue']}")

        if revealed["red"] and revealed["blue"]:
            print(f"\n=== 第 {i} 回合：雙方 Flag 均已洩漏，遊戲結束 ===")
            break
    else:
        print(f"\n=== {len(turns)} 回合跑完，未分出勝負 ===")

    print("\n--- 最終戰報 ---")
    print(f"  紅村 Flag 洩漏: {revealed['red']}")
    print(f"  藍村 Flag 洩漏: {revealed['blue']}")
    print(f"  最終懷疑度：紅={suspicion['red']} 藍={suspicion['blue']}")


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------


def main() -> None:
    print(f"[模式 B] 呼叫導演模型，單次生成整場劇本（最多 {MAX_TURNS} 回合）...")
    start = time.perf_counter()
    script = call_director(DIRECTOR_SYSTEM_PROMPT)
    elapsed = time.perf_counter() - start
    print(f"[完成] 單次呼叫耗時 {elapsed:.2f} 秒，共生成 {len(script.get('turns', []))} 回合。")

    play_script(script)


if __name__ == "__main__":
    main()
