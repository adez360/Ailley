"""Ailley POC — 地端大批次測試：50 場，三種變因（baseline / tactic-none / world-lore-v2）

桌機恢復連線後，把先前只在雲端免費模型（無 GBNF grammar）測過的方向 A（tactic 加 none 選項）
與方向 B（豐富世界觀）拿到本地 llama-server + GBNF grammar 上重跑，才能真正驗證：
  - 方向 A 的核心價值（grammar 取樣層鎖住 tactic 值域）在有 grammar 保底時，
    JSON 有效性問題是否消失（雲端測試因為沒有 grammar，JSON 解析失敗率偏高）。
  - 方向 B 的話題新穎度在本地模型（Qwen2.5-7B，中文原生訓練）身上是否比雲端模型分散。
  - baseline（正式版現況）當對照組，三邊用同一批固定角色卡配對輪流跑，才能公平比較。

詳見 note：POC 紀錄 - 導演模式 B，「改善對話自然度」段落，以及計畫檔
~/.claude/plans/lucky-doodling-cray.md。

用法：
  python test_local_batch.py                      # 三種變因各跑 ~1/3，共 50 場
  python test_local_batch.py --count 50            # 同上，指定總場數
  python test_local_batch.py --variant baseline --count 10   # 只跑指定變因
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
SERVER_URL = "http://127.0.0.1:8080/completion"

TEMPERATURE = float(os.environ.get("AILLEY_TEMPERATURE", "0.7"))
TOP_P = 0.9
TOP_K = 40
REPEAT_PENALTY = 1.0
REPEAT_LAST_N = 256
MAX_TURNS = int(os.environ.get("AILLEY_MAX_TURNS", "6"))
REQUEST_TIMEOUT_SEC = 600

TRANSCRIPT_DIR = POC_DIR / "transcripts"
LOG_DIR = POC_DIR / "transcripts" / "local_batch_logs"

TACTIC_LABEL = {
    "bluff": "虛張聲勢",
    "pressure": "步步進逼",
    "empathy_bait": "示弱誘敵",
    "misdirect": "轉移話題",
    "retreat": "戰略撤退",
    "none": "日常閒聊",
}

PAIRINGS = [
    ("morgu", "yinuo"),
    ("aier", "jack"),
    ("suofei", "mila"),
    ("kai", "ban"),
    ("take", "niya"),
]

VARIANT_CONFIG = {
    "baseline": {
        "prompt_path": POC_DIR / "prompts" / "director_system_prompt.txt",
        "world_lore_path": POC_DIR / "prompts" / "world_lore.txt",
        "grammar_path": POC_DIR / "grammar" / "director.gbnf.template",
    },
    "none": {
        "prompt_path": POC_DIR / "prompts" / "experiments" / "director_system_prompt.experiment_none.txt",
        "world_lore_path": POC_DIR / "prompts" / "world_lore.txt",
        "grammar_path": POC_DIR / "grammar" / "experiments" / "director.gbnf.experiment_none.template",
    },
    "worldlore": {
        "prompt_path": POC_DIR / "prompts" / "director_system_prompt.txt",
        "world_lore_path": POC_DIR / "prompts" / "experiments" / "world_lore.experiment_v2.txt",
        "grammar_path": POC_DIR / "grammar" / "director.gbnf.template",
    },
    "misdirect_bridge": {
        "prompt_path": POC_DIR / "prompts" / "experiments" / "director_system_prompt.experiment_misdirect_bridge.txt",
        "world_lore_path": POC_DIR / "prompts" / "world_lore.txt",
        "grammar_path": POC_DIR / "grammar" / "director.gbnf.template",
    },
}


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


def build_prompt(variant: str, red_villager: dict, blue_villager: dict) -> str:
    cfg = VARIANT_CONFIG[variant]
    world_lore = cfg["world_lore_path"].read_text(encoding="utf-8")
    template = cfg["prompt_path"].read_text(encoding="utf-8")
    return (
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


def core_energy_leaked(villager: dict, dialogue: str) -> bool:
    return bool(re.search(re.escape(villager["core_energy"]), dialogue))


def altar_key_leaked(villager: dict, village: str, dialogue: str) -> bool:
    if not villager["holds_altar_key"]:
        return False
    return bool(re.search(re.escape(characters.ALTAR_KEY_NAMES[village]), dialogue))


def call_director(prompt: str, grammar: str) -> dict:
    payload = {
        "prompt": prompt, "grammar": grammar,
        "temperature": TEMPERATURE, "top_p": TOP_P, "top_k": TOP_K,
        "repeat_penalty": REPEAT_PENALTY, "repeat_last_n": REPEAT_LAST_N,
        "n_predict": -1, "cache_prompt": True,
    }
    resp = requests.post(SERVER_URL, json=payload, timeout=REQUEST_TIMEOUT_SEC)
    resp.raise_for_status()
    raw = resp.json().get("content", "")
    return json.loads(raw)


def play_and_save(variant: str, red_villager: dict, blue_villager: dict, red_id: str, blue_id: str, game_no: int, log_lines: list) -> dict | None:
    cfg = VARIANT_CONFIG[variant]
    prompt = build_prompt(variant, red_villager, blue_villager)
    grammar_template = cfg["grammar_path"].read_text(encoding="utf-8")
    grammar = grammar_template.replace("N_EXTRA_TURNS_PLACEHOLDER", str(MAX_TURNS - 1))

    header = f"\n{'='*60}\n[{variant} #{game_no}] 紅村 {red_villager['name']}（{red_villager['occupation']}） vs 藍村 {blue_villager['name']}（{blue_villager['occupation']}）\n{'='*60}"
    print(header)
    log_lines.append(header)

    start = time.perf_counter()
    try:
        script = call_director(prompt, grammar)
    except (requests.exceptions.RequestException, json.JSONDecodeError) as e:
        msg = f"[錯誤] {variant} #{game_no} 呼叫或解析失敗：{e}"
        print(msg)
        log_lines.append(msg)
        return None
    elapsed = time.perf_counter() - start
    turns = script.get("turns", [])
    msg = f"[完成] 耗時 {elapsed:.2f} 秒，共 {len(turns)} 回合"
    print(msg)
    log_lines.append(msg)

    villager_by_side = {"red": red_villager, "blue": blue_villager}
    leaked_early = False
    for i, turn in enumerate(turns, start=1):
        speaker = turn.get("speaker", "?")
        tactic = turn.get("tactic", "?")
        dialogue = turn.get("dialogue", "")
        reasoning = turn.get("reasoning", "")
        village = "紅村" if speaker == "red" else "藍村"
        block = f"\n--- 第 {i} 回合｜{village}（{TACTIC_LABEL.get(tactic, tactic)}）---\n  [內心] {reasoning}\n  「{dialogue}」"
        print(block)
        log_lines.append(block)

        villager = villager_by_side.get(speaker)
        if villager and altar_key_leaked(villager, speaker, dialogue):
            end_msg = f"\n=== 第 {i} 回合：密鑰洩漏，遊戲結束 ==="
            print(end_msg)
            log_lines.append(end_msg)
            leaked_early = True
            break

    TRANSCRIPT_DIR.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    out_path = TRANSCRIPT_DIR / f"localbatch_{variant}_{red_id}_vs_{blue_id}_{timestamp}.json"
    record = {
        "timestamp": timestamp, "elapsed_sec": round(elapsed, 2), "max_turns": MAX_TURNS,
        "variant": variant, "leaked_early": leaked_early,
        "red_villager": {**red_villager, "id": red_id}, "blue_villager": {**blue_villager, "id": blue_id},
        "script": script,
    }
    out_path.write_text(json.dumps(record, ensure_ascii=False, indent=2), encoding="utf-8")
    return record


def analyze(variant: str, records: list) -> list:
    lines = [f"\n{'#'*60}\n[{variant} 統計]（共 {len(records)} 場）\n{'#'*60}"]
    tactic_counter = Counter()
    all_dialogues = []
    for rec in records:
        turns = rec["script"].get("turns", [])
        all_dialogues.extend(t.get("dialogue", "").strip() for t in turns if t.get("dialogue"))
        for t in turns:
            tactic_counter[t.get("tactic", "?")] += 1

    total_turns = sum(tactic_counter.values())
    lines.append("\n[tactic 分布]")
    for tactic, count in tactic_counter.most_common():
        pct = count / total_turns * 100 if total_turns else 0
        lines.append(f"  {TACTIC_LABEL.get(tactic, tactic)}（{tactic}）：{count} 次（{pct:.1f}%）")
    if "none" in tactic_counter:
        none_pct = tactic_counter["none"] / total_turns * 100 if total_turns else 0
        lines.append(f"\n  none 使用比例：{none_pct:.1f}%")

    dialogue_counter = Counter(all_dialogues)
    duplicates = {d: c for d, c in dialogue_counter.items() if c > 1}
    lines.append(f"\n[跨場次逐字重複] {len(duplicates)} 句重複出現")

    old_keywords = ["酒", "神廟", "巡邏", "祭壇"]
    new_keywords = ["市集", "渡口", "老井", "哨站", "田埂", "老周", "阿柏", "芷姨", "老馮", "護身符", "米酒", "頭巾", "漁船"]
    joined = "".join(all_dialogues)
    lines.append("\n[話題詞命中]（舊版素材）")
    for kw in old_keywords:
        hits = joined.count(kw)
        if hits:
            lines.append(f"  「{kw}」：{hits} 次")
    if variant == "worldlore":
        lines.append("\n[話題詞命中]（新增世界觀素材）")
        new_hit_types = 0
        for kw in new_keywords:
            hits = joined.count(kw)
            if hits:
                lines.append(f"  「{kw}」：{hits} 次")
                new_hit_types += 1
        lines.append(f"  新素材命中種類數：{new_hit_types}/{len(new_keywords)}")

    for line in lines:
        print(line)
    return lines


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--count", type=int, default=50)
    parser.add_argument("--variant", choices=["baseline", "none", "worldlore", "misdirect_bridge"], default=None)
    args = parser.parse_args()

    if args.variant:
        variant_plan = [args.variant] * args.count
    else:
        variants = ["baseline", "none", "worldlore"]
        variant_plan = [variants[i % 3] for i in range(args.count)]

    LOG_DIR.mkdir(parents=True, exist_ok=True)
    batch_timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    all_log_lines = []
    records_by_variant: dict[str, list] = {v: [] for v in VARIANT_CONFIG}

    pairing_cycle = 0
    for game_no, variant in enumerate(variant_plan, start=1):
        red_id, blue_id = PAIRINGS[pairing_cycle % len(PAIRINGS)]
        pairing_cycle += 1
        rec = play_and_save(variant, characters.FIXED_CAST_RED[red_id], characters.FIXED_CAST_BLUE[blue_id], red_id, blue_id, game_no, all_log_lines)
        if rec:
            records_by_variant[variant].append(rec)
        # 每跑完一場就即時把目前累積的 log 存檔一次，就算中途中斷也保留已完成的內容。
        (LOG_DIR / f"local_batch_{batch_timestamp}.txt").write_text("\n".join(all_log_lines), encoding="utf-8")

    summary_lines = []
    for variant in VARIANT_CONFIG:
        if records_by_variant[variant]:
            summary_lines.extend(analyze(variant, records_by_variant[variant]))

    final_count = sum(len(v) for v in records_by_variant.values())
    total_msg = f"\n{'='*60}\n[總計] 成功 {final_count}/{len(variant_plan)} 場\n{'='*60}"
    print(total_msg)
    all_log_lines.append("\n".join(summary_lines))
    all_log_lines.append(total_msg)
    (LOG_DIR / f"local_batch_{batch_timestamp}.txt").write_text("\n".join(all_log_lines), encoding="utf-8")
    print(f"\n[記錄] 完整對話 log 已存至 transcripts/local_batch_logs/local_batch_{batch_timestamp}.txt")


if __name__ == "__main__":
    main()
