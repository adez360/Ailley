"""村莊模擬版「導演模式」——單次呼叫，一口氣生成兩位角色之間完整N回合的對話（預設6回合，
依7月導演模式B實驗結論：5-6回合內容扎實，7回合後容易退化重複，見
note/40-規劃與路線圖/POC 紀錄 - 導演模式 B.md）。

這是跟主線run_des_sim.py/run_tick_sim.py逐拍決策迴圈分開的一條路，用意是讓「對話」單獨
成為一次有上下文呼應、高品質的生成，而不是被塞進每次決策JSON裡的附屬單句`speech`欄位。

沿用characters.py既有的人格/關係渲染邏輯，不重新發明；grammar/prompt改編自
poc_archive/poc/director_poc.py（原本是紅藍村社交工程對戰用途，這裡拿掉flag/密鑰/
suspicion/tactic那套機制，只保留「單次呼叫、GBNF {n} 精確鎖定回合數」這個核心架構）。

用法：python3 dialogue_poc.py <角色A id> <角色B id> [觸發原因文字]
例如：python3 dialogue_poc.py zhou mei "老周在餐酒館撞見小梅，兩人四目相對"
"""
import json
import sys
import time
from pathlib import Path

import requests

import characters as c
import run_tick_sim as rts

try:
    from opencc import OpenCC
    _OPENCC = OpenCC("s2t")
except ImportError:
    _OPENCC = None
POC_DIR = Path(__file__).parent
SERVER_URL = "http://127.0.0.1:8080/completion"
MAX_TURNS = 6
TOKENS_PER_TURN_BUDGET = 300
TEMPERATURE = 0.7
TOP_P = 0.9
TOP_K = 40
REPEAT_PENALTY = 1.0
REPEAT_LAST_N = 256
REQUEST_TIMEOUT_SEC = 600

if len(sys.argv) < 3:
    print("用法: python3 dialogue_poc.py <角色A id> <角色B id> [觸發原因文字]")
    sys.exit(1)
id_a, id_b = sys.argv[1], sys.argv[2]
trigger_context = sys.argv[3] if len(sys.argv) > 3 else "兩人剛好在同一個地方遇到，很自然地聊了起來。"

cast = c.load_all_characters()
relationships = c.load_relationships()
villager_a, villager_b = cast[id_a], cast[id_b]


def status_block(villager: dict) -> str:
    phys = villager["physiology"]
    return (
        c.render_body_status_block(phys) + "\n"
        f"【傷病】{c.render_injury_block(phys)}\n"
        f"【位置】{villager['location']}"
    )


template = (POC_DIR / "prompts" / "dialogue_system_prompt.txt").read_text(encoding="utf-8")
world_lore = rts.WORLD_LORE_PLACEHOLDER

prompt = (
    template
    .replace("{{WORLD_LORE}}", world_lore)
    .replace("{{NAME_A}}", villager_a["name"])
    .replace("{{NAME_B}}", villager_b["name"])
    .replace("{{PERSONALITY_A}}", c.render_personality_block(villager_a))
    .replace("{{PERSONALITY_B}}", c.render_personality_block(villager_b))
    .replace("{{AFFECTION_A_TO_B}}", c.render_affection_line(c.get_affection(relationships, id_a, id_b)))
    .replace("{{AFFECTION_B_TO_A}}", c.render_affection_line(c.get_affection(relationships, id_b, id_a)))
    .replace("{{STATUS_A}}", status_block(villager_a))
    .replace("{{STATUS_B}}", status_block(villager_b))
    .replace("{{BACKGROUND_A}}", villager_a.get("background") or "（沒有特別的事）")
    .replace("{{BACKGROUND_B}}", villager_b.get("background") or "（沒有特別的事）")
    .replace("{{TRIGGER_CONTEXT}}", trigger_context)
    .replace("{{FIRST_SPEAKER}}", villager_a["name"])
    .replace("{{MAX_TURNS}}", str(MAX_TURNS))
)

grammar_template = (POC_DIR / "grammar" / "dialogue.gbnf.template").read_text(encoding="utf-8")
grammar = (
    grammar_template
    .replace("SPEAKER_A_ID_PLACEHOLDER", id_a)
    .replace("SPEAKER_B_ID_PLACEHOLDER", id_b)
    .replace("N_EXTRA_TURNS_PLACEHOLDER", str(MAX_TURNS - 1))
)

payload = {
    "prompt": prompt, "grammar": grammar, "temperature": TEMPERATURE, "top_p": TOP_P,
    "top_k": TOP_K, "repeat_penalty": REPEAT_PENALTY, "repeat_last_n": REPEAT_LAST_N,
    "n_predict": MAX_TURNS * TOKENS_PER_TURN_BUDGET, "cache_prompt": True,
}

print(f"[對話生成] {villager_a['name']} x {villager_b['name']}，觸發原因：{trigger_context}")
t0 = time.perf_counter()
resp = requests.post(SERVER_URL, json=payload, timeout=REQUEST_TIMEOUT_SEC)
resp.raise_for_status()
raw = resp.json().get("content", "")
try:
    script = json.loads(raw)
except json.JSONDecodeError as e:
    print(f"[錯誤] JSON解析失敗：{e}")
    print(raw)
    sys.exit(1)
elapsed = time.perf_counter() - t0

if _OPENCC is not None:
    for turn in script.get("turns", []):
        if "dialogue" in turn:
            turn["dialogue"] = _OPENCC.convert(turn["dialogue"])
        if "reasoning" in turn:
            turn["reasoning"] = _OPENCC.convert(turn["reasoning"])

print(f"[完成] 耗時 {elapsed:.2f} 秒，共 {len(script.get('turns', []))} 回合")
name_by_id = {id_a: villager_a["name"], id_b: villager_b["name"]}
for i, turn in enumerate(script.get("turns", []), start=1):
    speaker_name = name_by_id.get(turn.get("speaker"), turn.get("speaker"))
    print(f"\n--- 第{i}回合｜{speaker_name} ---")
    print(f"  [內心] {turn.get('reasoning')}")
    print(f"  「{turn.get('dialogue')}」")
    print(f"  [關係變化] {turn.get('relationship_delta')}")

out_path = POC_DIR / "transcripts" / f"dialogue_{id_a}_{id_b}_{int(time.time())}.json"
out_path.parent.mkdir(exist_ok=True)
out_path.write_text(json.dumps({
    "id_a": id_a, "id_b": id_b, "trigger_context": trigger_context,
    "elapsed_sec": round(elapsed, 2), "max_turns": MAX_TURNS, "script": script,
}, ensure_ascii=False, indent=2), encoding="utf-8")
print(f"\n[記錄] 已存至 {out_path}")
