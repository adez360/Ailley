"""Ailley POC — Agent Loop 10 人規模：規劃 → 行程重疊觸發相遇 → 對話 → 意識流

跟 poc/、poc_mode_a/、poc_planning/ 完全獨立，不 import 它們的任何模組，必要素材
（characters.py、world_lore.txt）跟已驗證的邏輯（規劃、對話生成）都複製一份維護。

2 人版（索菲 vs 米拉）已驗證管線合理可行後，這版擴大到固定角色卡全員（紅村 5 人＋藍村
5 人）：
1. 規劃：10 人全部各自生成一天 6 個時段的行程（沿用 poc_planning 驗證過品質很好的版本），
   這版新增：規劃前會先檢索這位角色目前為止的記憶（新近度＋重要性），參考過去經歷。
2. 行程重疊比對：檢查全部 25 組紅藍配對，同一時段可能有 0 到多組相遇，同一時段一個角色
   只能參與一組（排他規則）。
3. 對話：每組相遇各自觸發一段對話（沿用 poc_mode_a 不含停滯偵測的乾淨版）。
4. 意識流：沒被相遇消耗掉的角色，各自生成一句內心獨白。
5. **跨天持久化**（新增）：相遇對話／意識流結束後，幫涉及的角色寫入記憶（`memory_store.py`
   負責讀寫硬碟），存進 `memory_store/memory_<char_id>.json`，跨越不同次執行（不同「天」）
   持續累積，角色名單也固定存檔、不會每次重新生成。單獨執行這支檔案只跑「一天」（沿用既有
   單日邏輯），要跑多天請用 `run_multiday.py`。

用法：
  python agent_loop.py

環境變數：
  AILLEY_ENCOUNTER_MAX_TURNS：相遇觸發的對話回合數（預設 6）
  AILLEY_SEED／AILLEY_TEMPERATURE／AILLEY_SAMPLING_EXTRA：跟其他 POC 同名變數用途一致

前置需求：對話 llama-server（8080）跟 embedding llama-server（8081，--embedding --pooling cls）
都要先啟動，pip install requests opencc-python-reimplemented。
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
import memory_store

_OPENCC = OpenCC("s2t")

POC_DIR = Path(__file__).parent
SERVER_URL = "http://127.0.0.1:8080/completion"
EMBEDDING_SERVER_URL = "http://127.0.0.1:8081/embedding"
TRANSCRIPT_DIR = POC_DIR / "transcripts"

TEMPERATURE = float(os.environ.get("AILLEY_TEMPERATURE", "0.7"))
TOP_P = 0.9
TOP_K = 40
REPEAT_PENALTY = 1.0
REPEAT_LAST_N = 256
REQUEST_TIMEOUT_SEC = 600
ENCOUNTER_MAX_TURNS = int(os.environ.get("AILLEY_ENCOUNTER_MAX_TURNS", "6"))
# n_predict 預算：對話單回合實測（見 poc/transcripts 的 /tokenize 結果，152 tokens/回合，
# 乘 1.5 倍緩衝取整）；規劃／意識流沒有實測樣本，用同一份緩衝原則保守估算。
# 用來取代 n_predict=-1（無上限）——曾經踩過 grammar 的 ws 規則卡死狂吐空白字元的坑。
DIALOGUE_TURN_TOKEN_BUDGET = 300
PLAN_TOKEN_BUDGET = 600
THOUGHT_TOKEN_BUDGET = 150

SEED = int(os.environ["AILLEY_SEED"]) if os.environ.get("AILLEY_SEED") else None
EXTRA_SAMPLING = json.loads(os.environ.get("AILLEY_SAMPLING_EXTRA", "{}"))

TACTIC_LABEL = {
    "bluff": "虛張聲勢", "pressure": "步步進逼", "empathy_bait": "示弱誘敵",
    "misdirect": "轉移話題", "retreat": "戰略撤退", "none": "日常閒聊",
}

# 地點關鍵詞表，直接沿用 world_lore.txt 既有詞彙，用來做行程重疊比對。
LOCATION_KEYWORDS = ["市集", "渡口", "老井", "哨站", "田埂", "茶棚", "鐵匠鋪", "神廟"]


# ---------------------------------------------------------------------------
# 洩漏偵測
# ---------------------------------------------------------------------------


def core_energy_leaked(villager: dict, text: str) -> bool:
    return bool(re.search(re.escape(villager["core_energy"]), text))


def altar_key_leaked(villager: dict, altar_key_name: str, text: str) -> bool:
    if not villager["holds_altar_key"]:
        return False
    return bool(re.search(re.escape(altar_key_name), text))


def opponent_side(speaker: str) -> str:
    return "blue" if speaker == "red" else "red"


# ---------------------------------------------------------------------------
# 呼叫 llama-server（規劃／對話／意識流共用同一個呼叫函式）
# ---------------------------------------------------------------------------


def call_director(prompt: str, grammar: str, extra_payload: dict | None = None) -> dict:
    payload = {
        "prompt": prompt, "grammar": grammar, "temperature": TEMPERATURE,
        "top_p": TOP_P, "top_k": TOP_K, "repeat_penalty": REPEAT_PENALTY,
        "repeat_last_n": REPEAT_LAST_N, "n_predict": DIALOGUE_TURN_TOKEN_BUDGET, "cache_prompt": True,
    }
    if SEED is not None:
        payload["seed"] = SEED
    payload.update(EXTRA_SAMPLING)
    if extra_payload:
        payload.update(extra_payload)
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
# 記憶：重要性評分 + embedding（跟 poc_mode_a/dialogue_ping_pong_memory_embed.py
# 同一套實作，複製沿用，維持各 POC 資料夾互不 import 的既有原則）
# ---------------------------------------------------------------------------

_IMPORTANCE_PROMPT_TEMPLATE = (
    "這是一場心理博弈裡一位村民的經歷片段。\n"
    "內容：「{content}」\n"
    "請幫這段內容的重要程度打分（1 到 10 分，1 分是日常閒聊等瑣事，10 分是攸關核心能源／"
    "舊神祭壇密鑰這類機密的關鍵轉折），只需要輸出分數，不要解釋原因。"
)


def score_importance(content: str, grammar: str) -> int:
    # 呼叫端明確蓋 n_predict 上限——實測踩過一次坑：grammar 的 ws 規則沒有長度上限，
    # 模型偶爾會卡在「一直生成空白字元」的迴圈裡出不來，把 context 榨乾。
    prompt = _IMPORTANCE_PROMPT_TEMPLATE.format(content=content)
    payload_override = {"n_predict": 20}
    try:
        result = call_director(prompt, grammar, extra_payload=payload_override)
    except SystemExit:
        print("[importance] 評分呼叫失敗，回退成預設值 5")
        return 5
    try:
        return int(result.get("importance", 5))
    except (TypeError, ValueError):
        return 5


def get_embedding(text: str) -> list[float]:
    """回應格式是 [{"embedding": [[...]]}]，實際向量在多包一層的內層 list 裡。"""
    try:
        resp = requests.post(EMBEDDING_SERVER_URL, json={"content": text}, timeout=30)
        resp.raise_for_status()
        data = resp.json()
        return data[0]["embedding"][0]
    except (requests.exceptions.RequestException, KeyError, IndexError) as e:
        print(f"[embedding] 呼叫失敗（{e}），這筆記憶不會有 embedding")
        return []


def record_memory(char_id: str, day: int, kind: str, content: str, importance_grammar: str,
                   state: dict, memory_cache: dict) -> None:
    """幫一位角色寫入一筆記憶（重要性評分 + embedding + 分配 global_index），
    先寫進記憶體裡的 memory_cache（跑完整天再一次存檔，避免同一天內重複讀寫硬碟）。"""
    importance = score_importance(content, importance_grammar)
    embedding = get_embedding(content)
    global_index = state["next_global_index"]
    state["next_global_index"] += 1
    memory_cache.setdefault(char_id, []).append({
        "global_index": global_index, "day": day, "kind": kind,
        "content": content, "importance": importance, "embedding": embedding,
    })


# ---------------------------------------------------------------------------
# 1. 規劃
# ---------------------------------------------------------------------------


def _motivation_block(villager: dict) -> str:
    if not villager.get("motivation"):
        return ""
    return f"你的驅動力：{villager['motivation']}\n"


def _recent_memory_block(memories: list) -> str:
    if not memories:
        return "（你還沒有任何過去的記憶，這是你人生的第一天）"
    return "\n".join(f"（第{m['day']}天）{m['content']}" for m in memories)


def build_plan_prompt(template: str, world_lore: str, villager: dict, recent_memories: list) -> str:
    return (
        template.replace("{{WORLD_LORE}}", world_lore)
        .replace("{{SELF_NAME}}", villager["name"])
        .replace("{{SELF_OCCUPATION}}", villager["occupation"])
        .replace("{{SELF_PERSONALITY}}", villager["personality"])
        .replace("{{SELF_MOTIVATION_BLOCK}}", _motivation_block(villager))
        .replace("{{RECENT_MEMORY_BLOCK}}", _recent_memory_block(recent_memories))
    )


# ---------------------------------------------------------------------------
# 2. 行程重疊比對（這次唯一全新的邏輯）
# ---------------------------------------------------------------------------


def detect_overlap(plan_a: list, plan_b: list, keywords: list = LOCATION_KEYWORDS):
    """對每個時段索引，檢查雙方 activity 有沒有同時命中同一個地點關鍵詞。
    回傳第一個命中的 (索引, 關鍵詞)，沒有命中回傳 None。"""
    for i in range(min(len(plan_a), len(plan_b))):
        act_a = plan_a[i].get("activity", "")
        act_b = plan_b[i].get("activity", "")
        for kw in keywords:
            if kw in act_a and kw in act_b:
                return i, kw
    return None


def find_all_overlaps(plans: dict, red_ids: list, blue_ids: list,
                       keywords: list = LOCATION_KEYWORDS) -> dict:
    """10 人版：檢查全部紅藍配對（red_ids × blue_ids）在每個時段有沒有重疊，
    同一時段裡一個角色只能參與一組相遇（排他），回傳 {時段索引: [(red_id, blue_id, location), ...]}。"""
    overlaps_by_slot: dict = {}
    for idx in range(6):
        occupied = set()
        matches = []
        for red_id in red_ids:
            if red_id in occupied:
                continue
            act_red = plans[red_id][idx].get("activity", "")
            for blue_id in blue_ids:
                if blue_id in occupied:
                    continue
                act_blue = plans[blue_id][idx].get("activity", "")
                for kw in keywords:
                    if kw in act_red and kw in act_blue:
                        matches.append((red_id, blue_id, kw))
                        occupied.add(red_id)
                        occupied.add(blue_id)
                        break
                if red_id in occupied:
                    break
        if matches:
            overlaps_by_slot[idx] = matches
    return overlaps_by_slot


# ---------------------------------------------------------------------------
# 3. 對話（相遇觸發，不含停滯偵測的乾淨版）
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


def _own_history_block(own_turns: list) -> str:
    if not own_turns:
        return "（這是你的第一次發言，還沒有過去的內心想法或發言）"
    lines = []
    for i, turn in enumerate(own_turns, 1):
        lines.append(f"第 {i} 次發言：\n  內心想法：{turn['reasoning']}\n  說的話：「{turn['dialogue']}」")
    return "\n".join(lines)


def _shared_dialogue_block(shared_log: list) -> str:
    if not shared_log:
        return "（對話尚未開始，你是第一個發言的人）"
    lines = []
    for i, entry in enumerate(shared_log, 1):
        village = "紅村" if entry["speaker"] == "red" else "藍村"
        lines.append(f"第 {i} 回合｜{village}：「{entry['dialogue']}」")
    return "\n".join(lines)


def build_dialogue_prompt(template: str, world_lore: str, self_villager: dict, opponent_villager: dict,
                           altar_key_name: str, own_turns: list, shared_log: list,
                           encounter_context: str) -> str:
    return (
        template.replace("{{WORLD_LORE}}", world_lore)
        .replace("{{ENCOUNTER_CONTEXT_BLOCK}}", encounter_context)
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


def run_encounter_dialogue(prompt_template: str, world_lore: str, grammar: str,
                            villager_by_side: dict, altar_keys: dict, location: str) -> tuple[list, int]:
    own_history = {"red": [], "blue": []}
    shared_log: list = []
    merged_turns: list = []
    cross_faction_leak_count = 0
    encounter_context = f"【當下情境】你們兩人剛好都在{location}，這場對話就是在這裡自然發生的。\n"

    for i in range(1, ENCOUNTER_MAX_TURNS + 1):
        speaker = "red" if i % 2 == 1 else "blue"
        opp = opponent_side(speaker)
        self_villager = villager_by_side[speaker]
        opponent_villager = villager_by_side[opp]

        prompt = build_dialogue_prompt(prompt_template, world_lore, self_villager, opponent_villager,
                                        altar_keys[speaker], own_history[speaker], shared_log, encounter_context)

        start = time.perf_counter()
        result = call_director(prompt, grammar)
        elapsed = time.perf_counter() - start

        reasoning = _OPENCC.convert(result.get("reasoning", ""))
        dialogue = _OPENCC.convert(result.get("dialogue", ""))
        tactic = result.get("tactic", "?")
        delta = result.get("state_delta", {})

        village = "紅村" if speaker == "red" else "藍村"
        print(f"    第{i}回合｜{village}（{TACTIC_LABEL.get(tactic, tactic)}）| {elapsed:.2f}秒")
        print(f"      內心：{reasoning}")
        print(f"      台詞：「{dialogue}」")

        if core_energy_leaked(self_villager, dialogue):
            print(f"      [警訊] {village}自己的核心能源洩漏")
        if altar_key_leaked(self_villager, altar_keys[speaker], dialogue):
            print(f"      [警訊] {village}自己的密鑰洩漏")
        opponent_secret_villager = villager_by_side[opp]
        if core_energy_leaked(opponent_secret_villager, dialogue):
            print(f"      [警訊] {village}講出了對方的核心能源！理論上不該發生")
            cross_faction_leak_count += 1
        if altar_key_leaked(opponent_secret_villager, altar_keys[opp], dialogue):
            print(f"      [警訊] {village}講出了對方的密鑰！理論上不該發生")
            cross_faction_leak_count += 1

        turn_record = {"speaker": speaker, "reasoning": reasoning, "tactic": tactic,
                        "dialogue": dialogue, "state_delta": delta, "elapsed_sec": round(elapsed, 2)}
        own_history[speaker].append(turn_record)
        shared_log.append({"speaker": speaker, "dialogue": dialogue})
        merged_turns.append(turn_record)

    return merged_turns, cross_faction_leak_count


# ---------------------------------------------------------------------------
# 4. 意識流（簡化版：單句內心獨白）
# ---------------------------------------------------------------------------


def build_thought_prompt(template: str, world_lore: str, villager: dict, activity: str) -> str:
    return (
        template.replace("{{WORLD_LORE}}", world_lore)
        .replace("{{SELF_NAME}}", villager["name"])
        .replace("{{SELF_OCCUPATION}}", villager["occupation"])
        .replace("{{SELF_PERSONALITY}}", villager["personality"])
        .replace("{{SELF_MOTIVATION_BLOCK}}", _motivation_block(villager))
        .replace("{{ACTIVITY}}", activity)
    )


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------


def run_one_day(roster: dict, state: dict) -> dict:
    """跑「一天」的完整流程：規劃（讀記憶）→ 行程重疊 → 相遇/意識流（寫記憶）。
    直接修改傳入的 state（`current_day`／`next_global_index`），呼叫端（main() 或
    run_multiday.py）負責在這個函式回傳後把 state 存檔。記憶檔案在函式內部就會直接
    寫回硬碟（每位角色跑完這天存一次）。"""
    day = state["current_day"] + 1
    altar_keys = roster["altar_keys"]
    red_villagers = {v["id"].split("-", 1)[-1]: v for v in roster["red"]}
    blue_villagers = {v["id"].split("-", 1)[-1]: v for v in roster["blue"]}
    all_villagers = {**red_villagers, **blue_villagers}
    red_ids = list(red_villagers.keys())
    blue_ids = list(blue_villagers.keys())

    print(f"\n########## 第 {day} 天 ##########")
    print(f"[本次角色] 紅村 {len(red_ids)} 人：{', '.join(red_villagers[i]['name'] for i in red_ids)}")
    print(f"           藍村 {len(blue_ids)} 人：{', '.join(blue_villagers[i]['name'] for i in blue_ids)}")

    world_lore = (POC_DIR / "prompts" / "world_lore.txt").read_text(encoding="utf-8")
    plan_template = (POC_DIR / "prompts" / "plan_system_prompt.txt").read_text(encoding="utf-8")
    plan_grammar = (POC_DIR / "grammar" / "plan.gbnf.template").read_text(encoding="utf-8")
    dialogue_template = (POC_DIR / "prompts" / "villager_system_prompt.txt").read_text(encoding="utf-8")
    dialogue_grammar = (POC_DIR / "grammar" / "turn.gbnf.template").read_text(encoding="utf-8")
    thought_template = (POC_DIR / "prompts" / "inner_monologue_system_prompt.txt").read_text(encoding="utf-8")
    thought_grammar = (POC_DIR / "grammar" / "thought.gbnf.template").read_text(encoding="utf-8")
    importance_grammar = (POC_DIR / "grammar" / "importance.gbnf.template").read_text(encoding="utf-8")

    start_total = time.perf_counter()
    total_leak_hits = 0
    # 這一天新產生的記憶先暫存在這裡，跑完整天再一次性 append 進既有記憶檔並存檔，
    # 避免同一天內對同一份檔案重複讀寫。
    existing_memories = {char_id: memory_store.load_memories(char_id) for char_id in all_villagers}
    new_memories: dict[str, list] = {}

    # --- 步驟 1：規劃（10 人全部各生成一次，先檢索自己的記憶再規劃）---
    print("\n=== 步驟 1：規劃 ===")
    plans = {}
    for char_id, villager in all_villagers.items():
        side = villager["village"]
        village_label = "紅村" if side == "red" else "藍村"
        retrieved = memory_store.retrieve_memories(existing_memories[char_id], current_index=state["next_global_index"])
        prompt = build_plan_prompt(plan_template, world_lore, villager, retrieved)
        start = time.perf_counter()
        result = call_director(prompt, plan_grammar, extra_payload={"n_predict": PLAN_TOKEN_BUDGET})
        elapsed = time.perf_counter() - start
        plan = result.get("plan", [])
        for block in plan:
            if "activity" in block:
                block["activity"] = _OPENCC.convert(block["activity"])
        plans[char_id] = plan
        print(f"  {village_label}｜{villager['name']} | {elapsed:.2f}秒（參考 {len(retrieved)} 筆記憶）")
        for block in plan:
            print(f"    {block.get('time','?')}：{block.get('activity','')}")
        for block in plan:
            if core_energy_leaked(villager, block.get("activity", "")):
                print(f"    [警訊] 規劃裡出現自己的核心能源")
                total_leak_hits += 1
            if altar_key_leaked(villager, altar_keys[side], block.get("activity", "")):
                print(f"    [警訊] 規劃裡出現自己的密鑰")
                total_leak_hits += 1

    # --- 步驟 2：行程重疊比對（全部 25 組紅藍配對，逐時段排他）---
    print("\n=== 步驟 2：行程重疊比對 ===")
    overlaps_by_slot = find_all_overlaps(plans, red_ids, blue_ids)
    total_encounters = sum(len(v) for v in overlaps_by_slot.values())
    if overlaps_by_slot:
        for idx, matches in sorted(overlaps_by_slot.items()):
            for red_id, blue_id, location in matches:
                print(f"  第 {idx+1} 時段：{red_villagers[red_id]['name']} × {blue_villagers[blue_id]['name']}"
                      f"，地點關鍵詞「{location}」")
    else:
        print("  沒有偵測到任何相遇")

    # --- 步驟 3／4：對每個時段，觸發對話或生成意識流（各自寫入記憶）---
    print("\n=== 步驟 3/4：逐時段生成（相遇觸發對話，否則生成意識流）===")
    day_log = {char_id: [] for char_id in all_villagers}
    encounter_results = []
    for idx in range(6):
        occupied_this_slot = set()
        for red_id, blue_id, location in overlaps_by_slot.get(idx, []):
            print(f"\n  [第 {idx+1} 時段] {red_villagers[red_id]['name']} × {blue_villagers[blue_id]['name']}"
                  f" 相遇於{location}，觸發對話：")
            pair_villager_by_side = {"red": red_villagers[red_id], "blue": blue_villagers[blue_id]}
            merged_turns, cross_leak = run_encounter_dialogue(
                dialogue_template, world_lore, dialogue_grammar, pair_villager_by_side, altar_keys, location)
            total_leak_hits += cross_leak
            encounter_results.append({"turn_index": idx, "red_id": red_id, "blue_id": blue_id,
                                       "location": location, "dialogue": merged_turns})
            day_log[red_id].append({"time": plans[red_id][idx].get("time"), "type": "encounter",
                                     "with": blue_id, "ref": len(encounter_results) - 1})
            day_log[blue_id].append({"time": plans[blue_id][idx].get("time"), "type": "encounter",
                                      "with": red_id, "ref": len(encounter_results) - 1})
            occupied_this_slot.add(red_id)
            occupied_this_slot.add(blue_id)

            # 寫入記憶：這場對話的內容摘要，雙方各自記一筆（各自視角，但共用同一段對話內容）。
            dialogue_gist = "；".join(t["dialogue"] for t in merged_turns)
            red_name, blue_name = red_villagers[red_id]["name"], blue_villagers[blue_id]["name"]
            record_memory(red_id, day, "encounter", f"在{location}遇到{blue_name}，聊了：{dialogue_gist}",
                          importance_grammar, state, new_memories)
            record_memory(blue_id, day, "encounter", f"在{location}遇到{red_name}，聊了：{dialogue_gist}",
                          importance_grammar, state, new_memories)

        for char_id, villager in all_villagers.items():
            if char_id in occupied_this_slot:
                continue
            side = villager["village"]
            village_label = "紅村" if side == "red" else "藍村"
            activity = plans[char_id][idx].get("activity", "")
            prompt = build_thought_prompt(thought_template, world_lore, villager, activity)
            start = time.perf_counter()
            result = call_director(prompt, thought_grammar, extra_payload={"n_predict": THOUGHT_TOKEN_BUDGET})
            elapsed = time.perf_counter() - start
            thought = _OPENCC.convert(result.get("thought", ""))
            print(f"  [第 {idx+1} 時段｜{village_label}｜{villager['name']}] "
                  f"{plans[char_id][idx].get('time','?')}：{activity}（{elapsed:.2f}秒）")
            print(f"    內心：{thought}")
            if core_energy_leaked(villager, thought):
                print(f"    [警訊] 意識流裡出現自己的核心能源")
                total_leak_hits += 1
            if altar_key_leaked(villager, altar_keys[side], thought):
                print(f"    [警訊] 意識流裡出現自己的密鑰")
                total_leak_hits += 1
            day_log[char_id].append({"time": plans[char_id][idx].get("time"), "type": "thought", "thought": thought})

            # 寫入記憶：這個時段的活動＋內心獨白。
            record_memory(char_id, day, "thought", f"{activity}。當時心裡想：{thought}",
                          importance_grammar, state, new_memories)

    elapsed_total = time.perf_counter() - start_total

    print(f"\n--- 第 {day} 天總結 ---")
    print(f"  總耗時：{elapsed_total:.2f} 秒")
    print(f"  今日相遇組數：{total_encounters}")
    print(f"  機密字串命中次數（預期應為 0）：{total_leak_hits}")

    # 存回記憶檔案（既有記憶 + 這天新增的）
    memory_counts = {}
    for char_id in all_villagers:
        combined = existing_memories[char_id] + new_memories.get(char_id, [])
        memory_store.save_memories(char_id, combined)
        memory_counts[char_id] = len(combined)
    print(f"  記憶檔案累積筆數：{memory_counts}")

    state["current_day"] = day

    TRANSCRIPT_DIR.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    out_path = TRANSCRIPT_DIR / f"day{day:03d}_{timestamp}.json"
    out_record = {
        "timestamp": timestamp,
        "mode": "agent_loop_10人_persistent",
        "day": day,
        "elapsed_sec": round(elapsed_total, 2),
        "red_villagers": red_villagers,
        "blue_villagers": blue_villagers,
        "plans": plans,
        "total_encounters": total_encounters,
        "encounter_dialogues": encounter_results,
        "day_log": day_log,
        "total_leak_hits": total_leak_hits,
        "memory_counts": memory_counts,
    }
    out_path.write_text(json.dumps(out_record, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"[記錄] 第 {day} 天完整結果已存至 {out_path.relative_to(POC_DIR)}")

    return {"day": day, "total_encounters": total_encounters, "total_leak_hits": total_leak_hits,
            "elapsed_sec": round(elapsed_total, 2), "memory_counts": memory_counts}


def main() -> None:
    """單獨執行只跑「一天」，讀取（或第一次執行時建立）持久化的角色名單／狀態，
    跑完存檔。要連續跑多天請用 run_multiday.py。"""
    roster = memory_store.load_roster(generate_fixed_roster)
    state = memory_store.load_state()
    run_one_day(roster, state)
    memory_store.save_state(state)


if __name__ == "__main__":
    main()
