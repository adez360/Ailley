"""Ailley POC — 方向 B 實驗：豐富世界觀素材密度（地點/慣例/次要NPC/物品）

只換 world_lore.txt，其餘沿用正式版 director_system_prompt.txt（不含方向 A 的 none 選項，
兩個方向分開測，避免混淆是哪個因素造成效果）。詳見 note：POC 紀錄 - 導演模式 B，
「改善對話自然度」段落，以及計畫檔 ~/.claude/plans/lucky-doodling-cray.md。

環境限制同 test_tactic_none.py：本地 llama-server 連不上，改打 OpenRouter 雲端模型。

用法：
  python test_world_lore_v2.py
"""

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
}

PAIRINGS = [
    ("morgu", "yinuo"),
    ("aier", "jack"),
    ("suofei", "mila"),
    ("kai", "ban"),
    ("take", "niya"),
]


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
    world_lore = (POC_DIR / "prompts" / "experiments" / "world_lore.experiment_v2.txt").read_text(encoding="utf-8")
    template = (POC_DIR / "prompts" / "director_system_prompt.txt").read_text(encoding="utf-8")
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
        '"tactic": "bluff/pressure/empathy_bait/misdirect/retreat 其中一個", '
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


def play_and_save(red_villager: dict, blue_villager: dict, red_id: str, blue_id: str) -> dict:
    prompt = build_prompt(red_villager, blue_villager)
    print(f"\n{'='*60}\n[配對] 紅村 {red_villager['name']}（{red_villager['occupation']}）"
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
    out_path = TRANSCRIPT_DIR / f"worldlorev2_{red_id}_vs_{blue_id}_{timestamp}.json"
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
    for rec in records:
        turns = rec["script"].get("turns", [])
        all_dialogues.extend(t.get("dialogue", "").strip() for t in turns if t.get("dialogue"))
        for t in turns:
            tactic_counter[t.get("tactic", "?")] += 1

    total_turns = sum(tactic_counter.values())
    print("\n[tactic 分布]")
    for tactic, count in tactic_counter.most_common():
        pct = count / total_turns * 100 if total_turns else 0
        print(f"  {TACTIC_LABEL.get(tactic, tactic)}（{tactic}）：{count} 次（{pct:.1f}%）")

    dialogue_counter = Counter(all_dialogues)
    duplicates = {d: c for d, c in dialogue_counter.items() if c > 1}
    print(f"\n[跨場次逐字重複] {len(duplicates)} 句重複出現：")
    for d, c in duplicates.items():
        print(f"  （出現 {c} 次）「{d[:40]}...」" if len(d) > 40 else f"  （出現 {c} 次）「{d}」")
    if not duplicates:
        print("  （無）")

    # 新舊素材命中次數對照：舊版只有「酒/神廟/巡邏」這幾個詞可用，
    # 新版額外加了市集/渡口/老井/老周/阿柏/芷姨/老馮/護身符等，統計新素材有沒有真的被用到。
    old_keywords = ["酒", "神廟", "巡邏", "祭壇"]
    new_keywords = ["市集", "渡口", "老井", "哨站", "田埂", "老周", "阿柏", "芷姨", "老馮", "護身符", "米酒", "頭巾", "漁船"]
    joined = "".join(all_dialogues)
    print("\n[舊版既有話題詞命中次數]")
    for kw in old_keywords:
        hits = joined.count(kw)
        if hits:
            print(f"  「{kw}」：{hits} 次")
    print("\n[新增世界觀素材命中次數]（>0 代表新素材真的被自然用到，不是塞了沒用）")
    new_hit_count = 0
    for kw in new_keywords:
        hits = joined.count(kw)
        if hits:
            print(f"  「{kw}」：{hits} 次")
            new_hit_count += 1
    print(f"\n  新素材命中種類數：{new_hit_count}/{len(new_keywords)}")


def main() -> None:
    records = []
    for red_id, blue_id in PAIRINGS:
        rec = play_and_save(characters.FIXED_CAST_RED[red_id], characters.FIXED_CAST_BLUE[blue_id], red_id, blue_id)
        records.append(rec)
    analyze(records)


if __name__ == "__main__":
    main()
