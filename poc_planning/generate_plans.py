"""Ailley POC — Planning 最小可行版：幫固定角色卡的 10 位村民各生成一份今天的粗略行程

跟 poc/、poc_mode_a/ 完全獨立，不 import 它們的任何模組，必要素材（characters.py、
world_lore.txt）各自複製一份維護。

評估 Generative Agents（Smallville）論文四大元件在地端模型上的可行性後，這次先做
「規劃」——技術風險最低的一項：驗證模型能不能生成一份合理、扣著世界觀、不涉及機密的
一日行程。不含論文原始的遞迴分解（一天→每小時→5-15分鐘），只做最上層的粗略規劃
（固定 6 個時段），也不含空間模擬（那是純工程問題，這次評估範圍不處理）。

用法：
  python generate_plans.py

前置需求：llama-server 已跑在 SERVER_URL，pip install requests opencc-python-reimplemented。
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

from characters import ALTAR_KEY_NAMES, generate_fixed_roster

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

SEED = int(os.environ["AILLEY_SEED"]) if os.environ.get("AILLEY_SEED") else None
EXTRA_SAMPLING = json.loads(os.environ.get("AILLEY_SAMPLING_EXTRA", "{}"))


def _motivation_block(villager: dict) -> str:
    if not villager.get("motivation"):
        return ""
    return f"你的驅動力：{villager['motivation']}\n"


def build_prompt(template: str, world_lore: str, villager: dict) -> str:
    return (
        template.replace("{{WORLD_LORE}}", world_lore)
        .replace("{{SELF_NAME}}", villager["name"])
        .replace("{{SELF_OCCUPATION}}", villager["occupation"])
        .replace("{{SELF_PERSONALITY}}", villager["personality"])
        .replace("{{SELF_MOTIVATION_BLOCK}}", _motivation_block(villager))
    )


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


def secret_leak_check(villager: dict, altar_key_name: str, plan: list) -> list:
    """檢查規劃內容有沒有意外提到這位村民的核心能源或密鑰名稱（規劃是公開行程，不該出現機密）。"""
    hits = []
    for block in plan:
        activity = block.get("activity", "")
        if re.search(re.escape(villager["core_energy"]), activity):
            hits.append(f"核心能源「{villager['core_energy']}」出現在：「{activity}」")
        if villager["holds_altar_key"] and re.search(re.escape(altar_key_name), activity):
            hits.append(f"密鑰「{altar_key_name}」出現在：「{activity}」")
    return hits


def main() -> None:
    roster = generate_fixed_roster()
    altar_keys = roster["altar_keys"]
    all_villagers = roster["red"] + roster["blue"]

    world_lore = (POC_DIR / "prompts" / "world_lore.txt").read_text(encoding="utf-8")
    prompt_template = (POC_DIR / "prompts" / "plan_system_prompt.txt").read_text(encoding="utf-8")
    grammar = (POC_DIR / "grammar" / "plan.gbnf.template").read_text(encoding="utf-8")

    results = []
    total_leak_hits = 0
    start_total = time.perf_counter()

    for villager in all_villagers:
        village_label = "紅村" if villager["village"] == "red" else "藍村"
        prompt = build_prompt(prompt_template, world_lore, villager)

        start = time.perf_counter()
        result = call_director(prompt, grammar)
        elapsed = time.perf_counter() - start

        plan = result.get("plan", [])
        for block in plan:
            if "activity" in block:
                block["activity"] = _OPENCC.convert(block["activity"])

        leak_hits = secret_leak_check(villager, altar_keys[villager["village"]], plan)
        total_leak_hits += len(leak_hits)

        print(f"\n--- {village_label}｜{villager['name']}（{villager['occupation']}，{villager['personality']}）"
              f" | {elapsed:.2f}秒 ---")
        for block in plan:
            print(f"  {block.get('time','?')}：{block.get('activity','')}")
        for hit in leak_hits:
            print(f"  [警訊] {hit}")

        results.append({
            "id": villager["id"],
            "village": villager["village"],
            "name": villager["name"],
            "occupation": villager["occupation"],
            "personality": villager["personality"],
            "motivation": villager.get("motivation", ""),
            "holds_altar_key": villager["holds_altar_key"],
            "elapsed_sec": round(elapsed, 2),
            "plan": plan,
            "leak_hits": leak_hits,
        })

    elapsed_total = time.perf_counter() - start_total

    print(f"\n--- 總結 ---")
    print(f"  {len(all_villagers)} 位角色，總耗時 {elapsed_total:.2f} 秒，平均每人 {elapsed_total/len(all_villagers):.2f} 秒")
    print(f"  機密字串命中次數（預期應為 0）：{total_leak_hits}")

    TRANSCRIPT_DIR.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    out_path = TRANSCRIPT_DIR / f"{timestamp}.json"
    out_record = {
        "timestamp": timestamp,
        "mode": "planning_min_viable",
        "elapsed_sec": round(elapsed_total, 2),
        "server_url": SERVER_URL,
        "temperature": TEMPERATURE,
        "top_p": TOP_P,
        "top_k": TOP_K,
        "repeat_penalty": REPEAT_PENALTY,
        "seed": SEED,
        "extra_sampling": EXTRA_SAMPLING,
        "total_leak_hits": total_leak_hits,
        "villagers": results,
    }
    out_path.write_text(json.dumps(out_record, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"[記錄] 完整結果已存至 {out_path.relative_to(POC_DIR)}")


if __name__ == "__main__":
    main()
