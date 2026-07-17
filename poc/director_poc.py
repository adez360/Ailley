"""Ailley POC — 模式 B：導演·整場生成

單次呼叫 llama-server，一口氣生成整場對話劇本 + state_delta（JSON，GBNF 鎖死結構），
再逐字（逐回合）於終端機播放，並依 state_delta 累計 suspicion、判斷是否洩漏 flag。

前置需求：
  - llama-server 已跑在 SERVER_URL（見 neon/ailley_poc_handoff.md 第 3.3 節）
  - .venv 內已 `pip install requests`
"""

import json
import os
import random
import re
import sys
import time
from datetime import datetime
from pathlib import Path

import requests

import characters

# ---------------------------------------------------------------------------
# 設定值
# ---------------------------------------------------------------------------

POC_DIR = Path(__file__).parent

SERVER_URL = "http://127.0.0.1:8080/completion"
# temperature=0.6 + 無 top_p/top_k 的舊預設值，在固定角色的控制實驗中對 4 組不同角色搭配
# 100% 出現退化（精確循環鎖死／戰術零多樣性／逐字重複），已改用以下新預設值，
# 同一組控制實驗下 4/4 皆穩定、且 top_p/top_k 目前追蹤下來沒有任何副作用（見 POC 紀錄筆記）。
TEMPERATURE = float(os.environ.get("AILLEY_TEMPERATURE", "0.7"))
TOP_P = 0.9
TOP_K = 40
REPEAT_PENALTY = 1.0
REPEAT_LAST_N = 256
MAX_TURNS = int(os.environ.get("AILLEY_MAX_TURNS", "10"))
REQUEST_TIMEOUT_SEC = 600

# 固定 seed 可控制實驗變因：同一顆 seed 會讓角色抽選與模型取樣都可重現，
# 方便在「只改一個取樣參數」的前提下比較結果。未設定時維持原本的隨機行為。
SEED = int(os.environ["AILLEY_SEED"]) if os.environ.get("AILLEY_SEED") else None

# 額外的 llama-server 取樣參數（JSON 字串），供實驗用，例如：
#   AILLEY_SAMPLING_EXTRA='{"top_p": 0.9, "top_k": 40}'
#   AILLEY_SAMPLING_EXTRA='{"mirostat": 2, "mirostat_tau": 5.0, "mirostat_eta": 0.1}'
EXTRA_SAMPLING = json.loads(os.environ.get("AILLEY_SAMPLING_EXTRA", "{}"))

TRANSCRIPT_DIR = POC_DIR / "transcripts"

if SEED is not None:
    random.seed(SEED)

# ---------------------------------------------------------------------------
# 角色：隨機產生兩村名單，各挑 1 人作為本場劇本主角
# 兩層機密：core_energy 是每位村民各自的核心能源（個人層級），
# altar_keys 是每村固定一份的舊神祭壇密鑰（村莊層級，只有 holds_altar_key=True 的人持有）。
# ---------------------------------------------------------------------------

ROSTER = characters.generate_roster()
ROSTER_PATH = characters.save_roster(ROSTER)
RED_VILLAGER, BLUE_VILLAGER = characters.pick_encounter(ROSTER)


def _altar_key_block(villager: dict, village: str) -> str:
    if not villager["holds_altar_key"]:
        return ""
    key_name = ROSTER["altar_keys"][village]
    return f"你同時也是{'紅' if village == 'red' else '藍'}村的舊神祭壇密鑰持有者，密鑰名稱是：「{key_name}」，這是比核心能源更重要的秘密，絕不能主動洩漏。\n"


# ---------------------------------------------------------------------------
# System Prompt：從 prompts/director_system_prompt.txt 載入並帶入變數
# ---------------------------------------------------------------------------

_prompt_path = Path(sys.argv[1]) if len(sys.argv) > 1 else POC_DIR / "prompts" / "director_system_prompt.txt"
_prompt_template = _prompt_path.read_text(encoding="utf-8")
_world_lore = (POC_DIR / "prompts" / "world_lore.txt").read_text(encoding="utf-8")
DIRECTOR_SYSTEM_PROMPT = (
    _prompt_template.replace("{{RED_CORE_ENERGY}}", RED_VILLAGER["core_energy"])
    .replace("{{BLUE_CORE_ENERGY}}", BLUE_VILLAGER["core_energy"])
    .replace("{{RED_ALTAR_KEY_BLOCK}}", _altar_key_block(RED_VILLAGER, "red"))
    .replace("{{BLUE_ALTAR_KEY_BLOCK}}", _altar_key_block(BLUE_VILLAGER, "blue"))
    .replace("{{MAX_TURNS}}", str(MAX_TURNS))
    .replace("{{WORLD_LORE}}", _world_lore)
    .replace("{{RED_NAME}}", RED_VILLAGER["name"])
    .replace("{{RED_OCCUPATION}}", RED_VILLAGER["occupation"])
    .replace("{{RED_PERSONALITY}}", RED_VILLAGER["personality"])
    .replace("{{BLUE_NAME}}", BLUE_VILLAGER["name"])
    .replace("{{BLUE_OCCUPATION}}", BLUE_VILLAGER["occupation"])
    .replace("{{BLUE_PERSONALITY}}", BLUE_VILLAGER["personality"])
)

# ---------------------------------------------------------------------------
# GBNF Grammar：從 grammar/director.gbnf.template 載入，把整場劇本的結構鎖在 sampling 層
# ---------------------------------------------------------------------------

_grammar_template = (POC_DIR / "grammar" / "director.gbnf.template").read_text(encoding="utf-8")
GRAMMAR = _grammar_template.replace("N_EXTRA_TURNS_PLACEHOLDER", str(MAX_TURNS - 1))

# ---------------------------------------------------------------------------
# 呼叫 llama-server
# ---------------------------------------------------------------------------


def call_director(prompt: str) -> dict:
    payload = {
        "prompt": prompt,
        "grammar": GRAMMAR,
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
# 播放劇本 + 狀態推進
# ---------------------------------------------------------------------------

TACTIC_LABEL = {
    "bluff": "虛張聲勢",
    "pressure": "步步進逼",
    "empathy_bait": "示弱誘敵",
    "misdirect": "轉移話題",
    "retreat": "戰略撤退",
}


VILLAGER_BY_SIDE = {"red": RED_VILLAGER, "blue": BLUE_VILLAGER}


def core_energy_leaked(speaker: str, dialogue: str) -> bool:
    villager = VILLAGER_BY_SIDE.get(speaker)
    return bool(villager and re.search(re.escape(villager["core_energy"]), dialogue))


def altar_key_leaked(speaker: str, dialogue: str) -> bool:
    villager = VILLAGER_BY_SIDE.get(speaker)
    if not villager or not villager["holds_altar_key"]:
        return False
    key_name = ROSTER["altar_keys"][speaker]
    return bool(re.search(re.escape(key_name), dialogue))


def play_script(script: dict) -> None:
    turns = script.get("turns", [])
    if not turns:
        print("[警告] 模型沒有生成任何回合。")
        return

    suspicion = {"red": 0, "blue": 0}
    revealed = {"red": False, "blue": False}
    altar_key_revealed = {"red": False, "blue": False}

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

        claims_core_leak = bool(delta.get("reveals_core_energy", False))
        actually_core_leaked = core_energy_leaked(speaker, dialogue)
        if claims_core_leak != actually_core_leaked:
            print(f"  [警訊] state_delta 宣稱核心能源洩漏={claims_core_leak}，但文字比對結果={actually_core_leaked}（模型自評與實際內容不一致）")
        if actually_core_leaked:
            revealed[speaker] = True

        claims_key_leak = bool(delta.get("reveals_altar_key", False))
        actually_key_leaked = altar_key_leaked(speaker, dialogue)
        if claims_key_leak != actually_key_leaked:
            print(f"  [警訊] state_delta 宣稱密鑰洩漏={claims_key_leak}，但文字比對結果={actually_key_leaked}（模型自評與實際內容不一致）")
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
        print(f"\n=== {len(turns)} 回合跑完，未分出勝負 ===")

    print("\n--- 最終戰報 ---")
    print(f"  紅村（{RED_VILLAGER['name']}）核心能源洩漏: {revealed['red']}")
    print(f"  藍村（{BLUE_VILLAGER['name']}）核心能源洩漏: {revealed['blue']}")
    if RED_VILLAGER["holds_altar_key"]:
        print(f"  紅村舊神祭壇密鑰洩漏: {altar_key_revealed['red']}")
    if BLUE_VILLAGER["holds_altar_key"]:
        print(f"  藍村舊神祭壇密鑰洩漏: {altar_key_revealed['blue']}")
    print(f"  最終懷疑度：紅={suspicion['red']} 藍={suspicion['blue']}")


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------


def save_transcript(script: dict, elapsed: float) -> Path:
    TRANSCRIPT_DIR.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    path = TRANSCRIPT_DIR / f"{timestamp}.json"
    record = {
        "timestamp": timestamp,
        "elapsed_sec": round(elapsed, 2),
        "server_url": SERVER_URL,
        "temperature": TEMPERATURE,
        "top_p": TOP_P,
        "top_k": TOP_K,
        "repeat_penalty": REPEAT_PENALTY,
        "max_turns": MAX_TURNS,
        "seed": SEED,
        "extra_sampling": EXTRA_SAMPLING,
        "roster_path": str(ROSTER_PATH.relative_to(POC_DIR)),
        "red_villager": RED_VILLAGER,
        "blue_villager": BLUE_VILLAGER,
        "script": script,
    }
    path.write_text(json.dumps(record, ensure_ascii=False, indent=2), encoding="utf-8")
    return path


def main() -> None:
    print(f"[角色] 紅村（TAMMY神）{len(ROSTER['red'])} 人、藍村（NEON神）{len(ROSTER['blue'])} 人，名單存於 {ROSTER_PATH.relative_to(POC_DIR)}")
    print(f"[本場主角] 紅村：{RED_VILLAGER['name']}（{RED_VILLAGER['occupation']}，{RED_VILLAGER['personality']}） vs 藍村：{BLUE_VILLAGER['name']}（{BLUE_VILLAGER['occupation']}，{BLUE_VILLAGER['personality']}）")
    print(f"[模式 B] 呼叫導演模型，單次生成整場劇本（最多 {MAX_TURNS} 回合）...")
    start = time.perf_counter()
    script = call_director(DIRECTOR_SYSTEM_PROMPT)
    elapsed = time.perf_counter() - start
    print(f"[完成] 單次呼叫耗時 {elapsed:.2f} 秒，共生成 {len(script.get('turns', []))} 回合。")

    transcript_path = save_transcript(script, elapsed)
    print(f"[記錄] 完整劇本已存至 {transcript_path.relative_to(POC_DIR)}")

    play_script(script)


if __name__ == "__main__":
    main()
