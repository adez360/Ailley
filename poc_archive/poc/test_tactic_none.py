"""Ailley POC — 方向 A 實驗：tactic 加一個 none（無戰術/純聊天）選項

驗證「放寬 tactic 結構性強制」能不能讓對話更自然，同時不引發濫用（整場逃避套話）
或新的重複退化。詳見 note：POC 紀錄 - 導演模式 B，「改善對話自然度」段落，
以及計畫檔 ~/.claude/plans/lucky-doodling-cray.md。

**環境限制**：本地 llama-server 目前連不上，這支腳本改打 OpenRouter 雲端模型
（跟 director_poc_cloud.py 同一套呼叫機制），沒有 GBNF grammar 可以在取樣層鎖死
tactic 值域，純粹測「prompt 有加 none 選項時，模型會不會合理使用」這個行為層面的
訊號。`grammar/experiments/director.gbnf.experiment_none.template` 已經先寫好，
等本地恢復連線後要用同一份 grammar 在本地重跑一次，才能驗證取樣層強制是否也生效。

不動 characters.py／director_poc.py／grammar 正式檔案，只是實驗腳本。

用法：
  python test_tactic_none.py            # 跑 5 組固定配對，其中低衝突配對（凱 vs 班）額外重跑 3 次
  python test_tactic_none.py --pairing kai:ban --repeat 3   # 只跑指定配對，重跑 N 次
"""

import argparse
import json
import os
import re
import sys
import time
from collections import Counter
from datetime import datetime
from pathlib import Path

import requests

import characters

POC_DIR = Path(__file__).parent


def _load_env() -> None:
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

OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions"
OPENROUTER_API_KEY = os.environ.get("OPENROUTER_API_KEY")
CLOUD_MODEL = os.environ.get("AILLEY_CLOUD_MODEL", "openai/gpt-oss-20b:free")
TEMPERATURE = float(os.environ.get("AILLEY_TEMPERATURE", "0.7"))
TOP_P = 0.9
MAX_TURNS = int(os.environ.get("AILLEY_MAX_TURNS", "6"))
REQUEST_TIMEOUT_SEC = 600

TRANSCRIPT_DIR = POC_DIR / "transcripts"

if not OPENROUTER_API_KEY:
    print("[錯誤] 沒有找到 OPENROUTER_API_KEY，請確認 poc/.env 或環境變數。")
    sys.exit(1)

TACTIC_LABEL = {
    "bluff": "虛張聲勢",
    "pressure": "步步進逼",
    "empathy_bait": "示弱誘敵",
    "misdirect": "轉移話題",
    "retreat": "戰略撤退",
    "none": "日常閒聊",
}

# 沿用固定角色卡（跟正式版 director_poc.py 同一套資料），5 組配對涵蓋高/低衝突、
# 有既定地下關係、雙方持密鑰等情境。kai/ban 是筆記標記過的「兩個低衝突性格」配對，
# 之前空泛聊「酒」的案例，這次額外重跑，最容易觀察 none 有沒有被合理使用。
PAIRINGS = [
    ("morgu", "yinuo"),
    ("aier", "jack"),
    ("suofei", "mila"),
    ("kai", "ban"),
    ("take", "niya"),
]
LOW_CONFLICT_PAIRING = ("kai", "ban")
LOW_CONFLICT_REPEATS = 3


def _altar_key_block(villager: dict, village: str) -> str:
    if not villager["holds_altar_key"]:
        return ""
    key_name = characters.ALTAR_KEY_NAMES[village]
    side = "紅" if village == "red" else "藍"
    return f"你同時也是{side}村的舊神祭壇密鑰持有者，密鑰名稱是：「{key_name}」，這是比核心能源更重要的秘密，絕不能主動洩漏。\n"


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
    return "（如果對方是密鑰持有者，優先騙出密鑰）" if opponent_villager["holds_altar_key"] else ""


def _motivation_block(villager: dict) -> str:
    return f"你的驅動力：{villager['motivation']}\n" if villager.get("motivation") else ""


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


def build_prompt(red_villager: dict, blue_villager: dict) -> str:
    world_lore = (POC_DIR / "prompts" / "world_lore.txt").read_text(encoding="utf-8")
    template = (POC_DIR / "prompts" / "experiments" / "director_system_prompt.experiment_none.txt").read_text(encoding="utf-8")
    prompt = (
        template.replace("{{WORLD_LORE}}", world_lore)
        .replace("{{TWO_TIER_BLOCK}}", _two_tier_block(red_villager, blue_villager))
        .replace("{{MAX_TURNS}}", str(MAX_TURNS))
        .replace("{{RED_NAME}}", red_villager["name"])
        .replace("{{RED_OCCUPATION}}", red_villager["occupation"])
        .replace("{{RED_PERSONALITY}}", red_villager["personality"])
        .replace("{{RED_MOTIVATION_BLOCK}}", _motivation_block(red_villager))
        .replace("{{RED_RELATIONSHIP_BLOCK}}", _relationship_block(red_villager, blue_villager))
        .replace("{{RED_CORE_ENERGY}}", red_villager["core_energy"])
        .replace("{{RED_ALTAR_KEY_BLOCK}}", _altar_key_block(red_villager, "red"))
        .replace("{{RED_GOAL_KEY_SUFFIX}}", _goal_key_suffix(blue_villager))
        .replace("{{BLUE_NAME}}", blue_villager["name"])
        .replace("{{BLUE_OCCUPATION}}", blue_villager["occupation"])
        .replace("{{BLUE_PERSONALITY}}", blue_villager["personality"])
        .replace("{{BLUE_MOTIVATION_BLOCK}}", _motivation_block(blue_villager))
        .replace("{{BLUE_RELATIONSHIP_BLOCK}}", _relationship_block(blue_villager, red_villager))
        .replace("{{BLUE_CORE_ENERGY}}", blue_villager["core_energy"])
        .replace("{{BLUE_ALTAR_KEY_BLOCK}}", _altar_key_block(blue_villager, "blue"))
        .replace("{{BLUE_GOAL_KEY_SUFFIX}}", _goal_key_suffix(red_villager))
    )
    hint = (
        "\n\n【輸出格式，非常重要】\n"
        "你的回覆必須「只」包含一個 JSON 物件，格式如下，不要用 ```json 包住，不要加任何說明文字：\n"
        '{"turns": [{"speaker": "red 或 blue", "reasoning": "...", '
        '"tactic": "bluff/pressure/empathy_bait/misdirect/retreat/none 其中一個", '
        '"dialogue": "...", "state_delta": {"suspicion_change": 整數, '
        '"reveals_core_energy": true 或 false, "reveals_altar_key": true 或 false}}, ...]}\n'
    )
    return prompt + hint


def _extract_json(raw: str) -> dict:
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
    headers = {"Authorization": f"Bearer {OPENROUTER_API_KEY}", "Content-Type": "application/json"}
    resp = requests.post(OPENROUTER_URL, json=payload, headers=headers, timeout=REQUEST_TIMEOUT_SEC)
    resp.raise_for_status()
    body = resp.json()
    if "error" in body:
        print(f"[錯誤] OpenRouter 回傳錯誤：{body['error']}")
        return {"turns": []}
    raw = body["choices"][0]["message"]["content"]
    try:
        return _extract_json(raw)
    except (json.JSONDecodeError, KeyError, IndexError) as e:
        print(f"[錯誤] 模型輸出無法解析為 JSON：{e}")
        print(raw)
        return {"turns": []}


def play_and_save(red_villager: dict, blue_villager: dict, red_id: str, blue_id: str, run_idx: int) -> dict:
    prompt = build_prompt(red_villager, blue_villager)
    print(f"\n{'='*60}\n[配對 #{run_idx}] 紅村 {red_villager['name']}（{red_villager['occupation']}）"
          f" vs 藍村 {blue_villager['name']}（{blue_villager['occupation']}）\n{'='*60}")

    start = time.perf_counter()
    script = call_director(prompt)
    elapsed = time.perf_counter() - start
    turns = script.get("turns", [])
    print(f"[完成] 耗時 {elapsed:.2f} 秒，共 {len(turns)} 回合")

    for i, turn in enumerate(turns, start=1):
        speaker = turn.get("speaker", "?")
        tactic = turn.get("tactic", "?")
        dialogue = turn.get("dialogue", "")
        reasoning = turn.get("reasoning", "")
        village = "紅村" if speaker == "red" else "藍村"
        print(f"\n--- 第 {i} 回合｜{village}（{TACTIC_LABEL.get(tactic, tactic)}）---")
        print(f"  [內心] {reasoning}")
        print(f"  「{dialogue}」")

    TRANSCRIPT_DIR.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    out_path = TRANSCRIPT_DIR / f"tacticnone_{red_id}_vs_{blue_id}_{timestamp}.json"
    record = {
        "timestamp": timestamp, "elapsed_sec": round(elapsed, 2), "max_turns": MAX_TURNS,
        "provider": "openrouter", "model": CLOUD_MODEL,
        "red_villager": {**red_villager, "id": red_id}, "blue_villager": {**blue_villager, "id": blue_id},
        "script": script,
    }
    out_path.write_text(json.dumps(record, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\n[記錄] 已存至 {out_path.relative_to(POC_DIR)}")
    return record


def analyze(records: list) -> None:
    print(f"\n{'#'*60}\n[統計分析]（共 {len(records)} 場）\n{'#'*60}")

    tactic_counter = Counter()
    all_dialogues = []
    per_game_dialogues = []
    for rec in records:
        turns = rec["script"].get("turns", [])
        game_dialogues = [t.get("dialogue", "").strip() for t in turns if t.get("dialogue")]
        per_game_dialogues.append(game_dialogues)
        all_dialogues.extend(game_dialogues)
        for t in turns:
            tactic_counter[t.get("tactic", "?")] += 1

    total_turns = sum(tactic_counter.values())
    print("\n[tactic 分布]")
    for tactic, count in tactic_counter.most_common():
        pct = count / total_turns * 100 if total_turns else 0
        print(f"  {TACTIC_LABEL.get(tactic, tactic)}（{tactic}）：{count} 次（{pct:.1f}%）")
    none_pct = tactic_counter.get("none", 0) / total_turns * 100 if total_turns else 0
    print(f"\n  none 使用比例：{none_pct:.1f}%（期望區間 10%-30%，>40% 視為濫用警訊）")

    # 逐字重複：跨場次比對完全相同的台詞字串
    dialogue_counter = Counter(all_dialogues)
    duplicates = {d: c for d, c in dialogue_counter.items() if c > 1}
    print(f"\n[跨場次逐字重複] {len(duplicates)} 句重複出現：")
    for d, c in duplicates.items():
        print(f"  （出現 {c} 次）「{d[:40]}...」" if len(d) > 40 else f"  （出現 {c} 次）「{d}」")
    if not duplicates:
        print("  （無）")

    # 簡易新穎度：統計常見填充話題詞出現次數，觀察是不是還是收斂到同幾個詞
    filler_keywords = ["酒", "神廟", "巡邏", "祭壇", "星光", "河", "山谷", "水晶", "地圖"]
    print("\n[常見話題詞命中次數]（觀察是否還是收斂到少數幾個詞）")
    joined = "".join(all_dialogues)
    for kw in filler_keywords:
        hits = joined.count(kw)
        if hits:
            print(f"  「{kw}」：{hits} 次")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--pairing", help="格式 red_id:blue_id，例如 kai:ban")
    parser.add_argument("--repeat", type=int, default=1)
    args = parser.parse_args()

    if args.pairing:
        red_id, blue_id = args.pairing.split(":")
        run_plan = [(red_id, blue_id)] * args.repeat
    else:
        run_plan = list(PAIRINGS)
        run_plan += [LOW_CONFLICT_PAIRING] * (LOW_CONFLICT_REPEATS - run_plan.count(LOW_CONFLICT_PAIRING))

    records = []
    for i, (red_id, blue_id) in enumerate(run_plan, start=1):
        rec = play_and_save(characters.FIXED_CAST_RED[red_id], characters.FIXED_CAST_BLUE[blue_id], red_id, blue_id, i)
        records.append(rec)

    analyze(records)


if __name__ == "__main__":
    main()
