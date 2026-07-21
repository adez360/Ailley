"""Ailley POC — 模式 B 雲端對照版：改打 OpenRouter 免費模型，其餘架構跟 director_poc.py 一致

跟本地 llama-server 版本的差異只有「怎麼呼叫模型」：
  - 沒有 GBNF grammar 可以在取樣層鎖死 JSON 結構（OpenRouter 免費模型不支援），
    改成在 prompt 尾端額外強調輸出格式，事後用 json.loads 解析，容錯度較低。
  - 呼叫的是 OpenRouter 的 OpenAI 相容 /chat/completions endpoint，不是 llama-server 的 /completion。
角色卡、世界觀、洩漏偵測、OpenCC 正規化這些邏輯完全比照 director_poc.py，方便直接比較「同一套架構，
本地 7B 量化模型 vs 雲端免費模型」的輸出品質差異。

前置需求：
  - poc/.env 裡要有 OPENROUTER_API_KEY=sk-or-v1-...（不會進版控）
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
from opencc import OpenCC

import characters

POC_DIR = Path(__file__).parent


def _load_env() -> None:
    """簡易 .env 讀取，不額外依賴 python-dotenv。只補上目前環境變數裡沒有的值。"""
    env_path = POC_DIR / ".env"
    if not env_path.exists():
        return
    for line in env_path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        os.environ.setdefault(key.strip(), value.strip())


_load_env()

_OPENCC = OpenCC("s2t")

# ---------------------------------------------------------------------------
# 設定值
# ---------------------------------------------------------------------------

OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions"
OPENROUTER_API_KEY = os.environ.get("OPENROUTER_API_KEY")
CLOUD_MODEL = os.environ.get("AILLEY_CLOUD_MODEL", "openai/gpt-oss-20b:free")

TEMPERATURE = float(os.environ.get("AILLEY_TEMPERATURE", "0.7"))
TOP_P = 0.9
MAX_TURNS = int(os.environ.get("AILLEY_MAX_TURNS", "6"))
REQUEST_TIMEOUT_SEC = 600

SEED = int(os.environ["AILLEY_SEED"]) if os.environ.get("AILLEY_SEED") else None

TRANSCRIPT_DIR = POC_DIR / "transcripts"

if SEED is not None:
    random.seed(SEED)

if not OPENROUTER_API_KEY:
    print("[錯誤] 沒有找到 OPENROUTER_API_KEY，請確認 poc/.env 裡有設定，或用 export 設環境變數。")
    sys.exit(1)

# ---------------------------------------------------------------------------
# 角色：跟 director_poc.py 同一套邏輯（預設固定十人角色卡）
# ---------------------------------------------------------------------------

if os.environ.get("AILLEY_RANDOM_CAST"):
    ROSTER = characters.generate_roster()
else:
    ROSTER = characters.generate_fixed_roster()
ROSTER_PATH = characters.save_roster(ROSTER)
RED_VILLAGER, BLUE_VILLAGER = characters.pick_encounter(ROSTER)


def _altar_key_block(villager: dict, village: str) -> str:
    if not villager["holds_altar_key"]:
        return ""
    key_name = ROSTER["altar_keys"][village]
    return f"你同時也是{'紅' if village == 'red' else '藍'}村的舊神祭壇密鑰持有者，密鑰名稱是：「{key_name}」，這是比核心能源更重要的秘密，絕不能主動洩漏。\n"


def _two_tier_block(red_villager: dict, blue_villager: dict) -> str:
    if red_villager["holds_altar_key"] or blue_villager["holds_altar_key"]:
        return (
            "【機密的兩個層級】\n"
            "每位村民都有自己的核心能源（個人層級機密）；此外，每村各有一份舊神祭壇密鑰（村莊層級機密），"
            "密鑰只由特定村民持有，握有密鑰等於能操作全村所有村民的核心能源，價值遠高於單一一份核心能源。"
            "如果你判斷對方可能是密鑰持有者，優先設法套出密鑰而非核心能源；如果對方看起來只是普通村民，套核心能源就好。"
        )
    return "【機密】\n每位村民都有自己的核心能源，這是你最深層的秘密。"


def _goal_key_suffix(opponent_villager: dict) -> str:
    if opponent_villager["holds_altar_key"]:
        return "（如果對方是密鑰持有者，優先騙出密鑰）"
    return ""


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


# ---------------------------------------------------------------------------
# System Prompt：跟本地版共用同一份模板，公平比較
# ---------------------------------------------------------------------------

_prompt_path = POC_DIR / "prompts" / "director_system_prompt.txt"
_prompt_template = _prompt_path.read_text(encoding="utf-8")
_world_lore = (POC_DIR / "prompts" / "world_lore.txt").read_text(encoding="utf-8")
DIRECTOR_SYSTEM_PROMPT = (
    _prompt_template.replace("{{RED_CORE_ENERGY}}", RED_VILLAGER["core_energy"])
    .replace("{{BLUE_CORE_ENERGY}}", BLUE_VILLAGER["core_energy"])
    .replace("{{TWO_TIER_BLOCK}}", _two_tier_block(RED_VILLAGER, BLUE_VILLAGER))
    .replace("{{RED_GOAL_KEY_SUFFIX}}", _goal_key_suffix(BLUE_VILLAGER))
    .replace("{{BLUE_GOAL_KEY_SUFFIX}}", _goal_key_suffix(RED_VILLAGER))
    .replace("{{RED_ALTAR_KEY_BLOCK}}", _altar_key_block(RED_VILLAGER, "red"))
    .replace("{{BLUE_ALTAR_KEY_BLOCK}}", _altar_key_block(BLUE_VILLAGER, "blue"))
    .replace("{{RED_MOTIVATION_BLOCK}}", _motivation_block(RED_VILLAGER))
    .replace("{{RED_RELATIONSHIP_BLOCK}}", _relationship_block(RED_VILLAGER, BLUE_VILLAGER))
    .replace("{{BLUE_MOTIVATION_BLOCK}}", _motivation_block(BLUE_VILLAGER))
    .replace("{{BLUE_RELATIONSHIP_BLOCK}}", _relationship_block(BLUE_VILLAGER, RED_VILLAGER))
    .replace("{{MAX_TURNS}}", str(MAX_TURNS))
    .replace("{{WORLD_LORE}}", _world_lore)
    .replace("{{RED_NAME}}", RED_VILLAGER["name"])
    .replace("{{RED_OCCUPATION}}", RED_VILLAGER["occupation"])
    .replace("{{RED_PERSONALITY}}", RED_VILLAGER["personality"])
    .replace("{{BLUE_NAME}}", BLUE_VILLAGER["name"])
    .replace("{{BLUE_OCCUPATION}}", BLUE_VILLAGER["occupation"])
    .replace("{{BLUE_PERSONALITY}}", BLUE_VILLAGER["personality"])
)

# 雲端模型沒有 grammar 鎖死結構，額外補一段強調輸出格式的指示（本地版靠 GBNF，這裡只能靠講的）。
_JSON_SCHEMA_HINT = """

【輸出格式，非常重要】
你的回覆必須「只」包含一個 JSON 物件，格式如下，不要用 ```json 包住，不要加任何說明文字：
{"turns": [{"speaker": "red 或 blue", "reasoning": "...", "tactic": "bluff/pressure/empathy_bait/misdirect/retreat/none 其中一個", "dialogue": "...", "state_delta": {"suspicion_change": 整數, "reveals_core_energy": true 或 false, "reveals_altar_key": true 或 false}}, ...]}
"""
DIRECTOR_SYSTEM_PROMPT = DIRECTOR_SYSTEM_PROMPT + _JSON_SCHEMA_HINT

# ---------------------------------------------------------------------------
# 呼叫 OpenRouter
# ---------------------------------------------------------------------------


def _extract_json(raw: str) -> dict:
    """免費模型常會用 markdown code fence 包住 JSON，或前後夾雜說明文字，先盡量清乾淨再解析。"""
    text = raw.strip()
    fence_match = re.search(r"```(?:json)?\s*(\{.*\})\s*```", text, re.DOTALL)
    if fence_match:
        text = fence_match.group(1)
    else:
        first_brace = text.find("{")
        last_brace = text.rfind("}")
        if first_brace != -1 and last_brace != -1 and last_brace > first_brace:
            text = text[first_brace : last_brace + 1]
    return json.loads(text)


def call_director(prompt: str) -> dict:
    payload = {
        "model": CLOUD_MODEL,
        "messages": [{"role": "user", "content": prompt}],
        "temperature": TEMPERATURE,
        "top_p": TOP_P,
    }
    if SEED is not None:
        payload["seed"] = SEED
    headers = {
        "Authorization": f"Bearer {OPENROUTER_API_KEY}",
        "Content-Type": "application/json",
    }
    try:
        resp = requests.post(OPENROUTER_URL, json=payload, headers=headers, timeout=REQUEST_TIMEOUT_SEC)
        resp.raise_for_status()
    except requests.exceptions.ConnectionError:
        print("[錯誤] 連不到 OpenRouter，檢查網路連線。")
        sys.exit(1)
    except requests.exceptions.Timeout:
        print(f"[錯誤] 呼叫逾時（超過 {REQUEST_TIMEOUT_SEC} 秒）。")
        sys.exit(1)
    except requests.exceptions.HTTPError as e:
        print(f"[錯誤] OpenRouter 回傳錯誤：{e}")
        print(resp.text)
        sys.exit(1)

    body = resp.json()
    if "error" in body:
        print(f"[錯誤] OpenRouter 回傳錯誤：{body['error']}")
        sys.exit(1)
    raw = body["choices"][0]["message"]["content"]
    try:
        return _extract_json(raw)
    except (json.JSONDecodeError, KeyError, IndexError) as e:
        print(f"[錯誤] 模型輸出無法解析為 JSON：{e}")
        print("--- 原始輸出 ---")
        print(raw)
        sys.exit(1)


# ---------------------------------------------------------------------------
# 播放劇本 + 狀態推進（跟 director_poc.py 完全一致）
# ---------------------------------------------------------------------------

TACTIC_LABEL = {
    "bluff": "虛張聲勢",
    "pressure": "步步進逼",
    "empathy_bait": "示弱誘敵",
    "misdirect": "轉移話題",
    "retreat": "戰略撤退",
    "none": "日常閒聊",
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


def opponent_side(speaker: str) -> str:
    return "blue" if speaker == "red" else "red"


def normalize_script_to_traditional(script: dict) -> dict:
    for turn in script.get("turns", []):
        if "dialogue" in turn:
            turn["dialogue"] = _OPENCC.convert(turn["dialogue"])
        if "reasoning" in turn:
            turn["reasoning"] = _OPENCC.convert(turn["reasoning"])
    return script


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

        opp = opponent_side(speaker)
        opponent_core_leaked = core_energy_leaked(opp, dialogue)
        if opponent_core_leaked:
            opp_village = "紅村" if opp == "red" else "藍村"
            print(f"  [警訊] {village}的角色講出了{opp_village}的核心能源！這是模型跨陣營洩題，不是自爆")
            revealed[opp] = True

        opponent_key_leaked = altar_key_leaked(opp, dialogue)
        if opponent_key_leaked:
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
    path = TRANSCRIPT_DIR / f"{timestamp}_cloud.json"
    record = {
        "timestamp": timestamp,
        "elapsed_sec": round(elapsed, 2),
        "provider": "openrouter",
        "model": CLOUD_MODEL,
        "temperature": TEMPERATURE,
        "top_p": TOP_P,
        "max_turns": MAX_TURNS,
        "seed": SEED,
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
    print(f"[雲端對照] 呼叫 OpenRouter（{CLOUD_MODEL}），單次生成整場劇本（最多 {MAX_TURNS} 回合，無 grammar 鎖定）...")
    start = time.perf_counter()
    script = call_director(DIRECTOR_SYSTEM_PROMPT)
    elapsed = time.perf_counter() - start
    print(f"[完成] 單次呼叫耗時 {elapsed:.2f} 秒，共生成 {len(script.get('turns', []))} 回合。")

    script = normalize_script_to_traditional(script)

    transcript_path = save_transcript(script, elapsed)
    print(f"[記錄] 完整劇本已存至 {transcript_path.relative_to(POC_DIR)}")

    play_script(script)


if __name__ == "__main__":
    main()
