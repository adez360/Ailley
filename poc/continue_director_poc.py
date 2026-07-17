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

from characters import ALTAR_KEY_NAMES

POC_DIR = Path(__file__).parent
SERVER_URL = "http://127.0.0.1:8080/completion"

TEMPERATURE = float(os.environ.get("AILLEY_TEMPERATURE", "0.7"))
TOP_P = 0.9
TOP_K = 40
REPEAT_PENALTY = 1.0
REPEAT_LAST_N = 256
REQUEST_TIMEOUT_SEC = 600

SEED = int(os.environ["AILLEY_SEED"]) if os.environ.get("AILLEY_SEED") else None
EXTRA_SAMPLING = json.loads(os.environ.get("AILLEY_SAMPLING_EXTRA", "{}"))

TRANSCRIPT_DIR = POC_DIR / "transcripts"

TACTIC_LABEL = {
    "bluff": "虛張聲勢",
    "pressure": "步步進逼",
    "empathy_bait": "示弱誘敵",
    "misdirect": "轉移話題",
    "retreat": "戰略撤退",
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

    return {"suspicion": suspicion, "revealed": revealed, "altar_key_revealed": altar_key_revealed}


def _prior_turns_block(turns: list) -> str:
    lines = []
    for i, turn in enumerate(turns, start=1):
        village = "紅村" if turn.get("speaker") == "red" else "藍村"
        lines.append(f"第 {i} 回合｜{village}：「{turn.get('dialogue', '')}」")
    return "\n".join(lines)


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


def call_director(prompt: str, grammar: str) -> dict:
    payload = {
        "prompt": prompt,
        "grammar": grammar,
        "temperature": TEMPERATURE,
        "top_p": TOP_P,
        "top_k": TOP_K,
        "repeat_penalty": REPEAT_PENALTY,
        "repeat_last_n": REPEAT_LAST_N,
        "n_predict": -1,
        "cache_prompt": True,
    }
    if SEED is not None:
        payload["seed"] = SEED
    payload.update(EXTRA_SAMPLING)
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

    world_lore = (POC_DIR / "prompts" / "world_lore.txt").read_text(encoding="utf-8")
    prompt_template = (POC_DIR / "prompts" / "continue_system_prompt.txt").read_text(encoding="utf-8")
    prompt = (
        prompt_template.replace("{{WORLD_LORE}}", world_lore)
        .replace("{{RED_NAME}}", red_villager["name"])
        .replace("{{RED_OCCUPATION}}", red_villager["occupation"])
        .replace("{{RED_PERSONALITY}}", red_villager["personality"])
        .replace("{{RED_CORE_ENERGY}}", red_villager["core_energy"])
        .replace("{{RED_ALTAR_KEY_BLOCK}}", _altar_key_block(red_villager, "red"))
        .replace("{{BLUE_NAME}}", blue_villager["name"])
        .replace("{{BLUE_OCCUPATION}}", blue_villager["occupation"])
        .replace("{{BLUE_PERSONALITY}}", blue_villager["personality"])
        .replace("{{BLUE_CORE_ENERGY}}", blue_villager["core_energy"])
        .replace("{{BLUE_ALTAR_KEY_BLOCK}}", _altar_key_block(blue_villager, "blue"))
        .replace("{{PRIOR_TURNS_BLOCK}}", _prior_turns_block(prior_turns))
        .replace("{{CURRENT_STATE_BLOCK}}", _current_state_block(state, red_villager, blue_villager))
        .replace("{{EXTRA_TURNS}}", str(extra_turns))
    )

    grammar_template = (POC_DIR / "grammar" / "director.gbnf.template").read_text(encoding="utf-8")
    grammar = grammar_template.replace("N_EXTRA_TURNS_PLACEHOLDER", str(extra_turns - 1))

    print(f"[續寫] 讀取 {transcript_path.name}（既有 {len(prior_turns)} 回合），請模型接續生成 {extra_turns} 回合...")
    start = time.perf_counter()
    result = call_director(prompt, grammar)
    elapsed = time.perf_counter() - start
    new_turns = result.get("turns", [])
    print(f"[完成] 續寫呼叫耗時 {elapsed:.2f} 秒，共生成 {len(new_turns)} 個新回合。")

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

        print(f"  [state] suspicion(紅)={suspicion['red']} suspicion(藍)={suspicion['blue']}")

        if altar_key_revealed["red"] or altar_key_revealed["blue"]:
            loser = "紅村" if altar_key_revealed["red"] else "藍村"
            print(f"\n=== 第 {i} 回合：{loser}的舊神祭壇密鑰洩漏，全村核心能源淪陷，遊戲結束 ===")
            break
        if revealed["red"] and revealed["blue"]:
            print(f"\n=== 第 {i} 回合：雙方核心能源均已洩漏，遊戲結束 ===")
            break
    else:
        print(f"\n=== 新增的 {len(new_turns)} 回合跑完，未分出勝負 ===")


if __name__ == "__main__":
    main()
