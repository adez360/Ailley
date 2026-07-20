"""Ailley POC — 固定角色卡（10 人）一次性測試腳本

不動 characters.py／director_poc.py 既有的隨機生成架構，獨立跑一份測試：
把使用者提供的「歐米茄計畫」設定裡的 10 位有名有姓角色，轉譯進現有的
TAMMY神/NEON神/CHO/核心能源/舊神祭壇密鑰 世界觀（拿掉電池/Flag 等科幻用詞），
每位角色都帶驅動力（motivation）與跟對方的關係背景（relationship），
用來驗證「角色深度／既定關係」能不能改善先前診斷出的「空泛、跳針」問題。

只是一次性實驗腳本，如果效果好，再回頭決定要不要正式併入 characters.py。

用法：
  python test_fixed_cast.py            # 跑預設的 5 組配對
  python test_fixed_cast.py 2          # 只跑第 2 組配對（1-based）
"""

import json
import os
import re
import sys
import time
from datetime import datetime
from pathlib import Path

import requests

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

ALTAR_KEY_NAMES = {"red": "TAMMY神祭壇密鑰", "blue": "NEON神祭壇密鑰"}

TACTIC_LABEL = {
    "bluff": "虛張聲勢",
    "pressure": "步步進逼",
    "empathy_bait": "示弱誘敵",
    "misdirect": "轉移話題",
    "retreat": "戰略撤退",
}

# ---------------------------------------------------------------------------
# 固定角色卡：轉譯自使用者提供的「歐米茄計畫」設定
# ---------------------------------------------------------------------------

RED_CAST = {
    "morgu": {
        "name": "莫古", "occupation": "村長", "personality": "懷舊、固執、防禦性強",
        "motivation": "守護村落現有的核心能源存量，不信任 CHO 的神諭，主張固守待變",
        "relationship": "你跟藍村的伊諾是舊識，因對 CHO 神諭是否可信理念不合而斷絕往來",
        "core_energy": "紅蓮之心", "holds_altar_key": True,
    },
    "aier": {
        "name": "艾爾", "occupation": "藥師（核心能源看護者）", "personality": "焦慮、務實、細心",
        "motivation": "監控村民核心能源狀態，對能源洩漏或流失感到極度恐慌",
        "relationship": "你私下跟藍村商人傑克有情報交易往來，這件事不能讓村長知道",
        "core_energy": "赤焰之瞳", "holds_altar_key": False,
    },
    "suofei": {
        "name": "索菲", "occupation": "守衛", "personality": "警覺、悲觀、行動派",
        "motivation": "把 CHO 神諭與外村都視為威脅，優先排除任何外部干擾",
        "relationship": "你跟藍村的米拉多次發生衝突，你認定她是間諜",
        "core_energy": "焚天之魂", "holds_altar_key": False,
    },
    "kai": {
        "name": "凱", "occupation": "農夫", "personality": "溫順、麻木、追求和平",
        "motivation": "只想維持基本生存，對兩村之間的政治爭鬥感到厭倦",
        "relationship": "你跟兩村村民都能維持中立、不涉入紛爭的對話關係",
        "core_energy": "驚雷之角", "holds_altar_key": False,
    },
    "take": {
        "name": "塔克", "occupation": "鐵匠", "personality": "強硬、排外、攻擊性高",
        "motivation": "加固村落防禦，極度敵視藍村任何「與 CHO 溝通」的舉動",
        "relationship": "你極度敵視藍村研究 CHO 神諭的所有人",
        "core_energy": "寒潭之影", "holds_altar_key": False,
    },
}

BLUE_CAST = {
    "niya": {
        "name": "妮雅", "occupation": "藥師", "personality": "理性、冷靜、目標導向",
        "motivation": "想破解 CHO 神諭背後的真相，主張主動獻祭核心能源以求突破現狀",
        "relationship": "你需要紅村鐵匠塔克手上的資源或情報才能繼續研究",
        "core_energy": "碧波之息", "holds_altar_key": False,
    },
    "jack": {
        "name": "傑克", "occupation": "商人", "personality": "狡詐、投機、社交能力強",
        "motivation": "在兩村的混亂局勢中獲利，隱瞞雙方情報藉此操弄局勢",
        "relationship": "你是兩村之間檯面下的地下聯繫人，私下跟紅村藥師艾爾有情報交易往來",
        "core_energy": "烈日之翼", "holds_altar_key": False,
    },
    "yinuo": {
        "name": "伊諾", "occupation": "祭司見習", "personality": "虔誠、狂熱、煽動性強",
        "motivation": "堅信 CHO 神諭是全村唯一的救贖，極力推動村民獻祭核心能源",
        "relationship": "你跟紅村村長莫古是舊識，因對 CHO 神諭是否可信理念不合而斷絕往來",
        "core_energy": "月夜之聲", "holds_altar_key": True,
    },
    "ban": {
        "name": "班", "occupation": "說書人", "personality": "冷靜、懷疑論者、邏輯嚴密",
        "motivation": "懷疑 CHO 神諭是個騙局，正在追查村莊能源流失背後的真正原因",
        "relationship": "你對 CHO 神諭的真實意圖保持高度警惕，不輕易相信任何一方",
        "core_energy": "熔岩之髓", "holds_altar_key": False,
    },
    "mila": {
        "name": "米拉", "occupation": "獵人", "personality": "中立、觀察者、生存導向",
        "motivation": "哪邊在核心能源上佔優勢，你就傾向哪邊，純粹為了生存",
        "relationship": "你曾被紅村放逐，現在暫居藍村，跟紅村守衛索菲多次發生衝突",
        "core_energy": "霜雪之骨", "holds_altar_key": False,
    },
}

# 5 組配對，涵蓋「雙方都持密鑰」「有既定地下交易關係」「敵對關係」「中立無交集」等情境
PAIRINGS = [
    ("morgu", "yinuo"),   # 舊識反目，雙方都是密鑰持有者
    ("aier", "jack"),     # 已經在做地下情報交易
    ("suofei", "mila"),   # 索菲視米拉為間諜，米拉曾被紅村放逐
    ("kai", "ban"),       # 都沒有密鑰，性格上務實 vs 懷疑論者
    ("take", "niya"),     # 都沒有密鑰，強硬排外 vs 理性目標導向
]


def _altar_key_block(villager: dict, village: str) -> str:
    if not villager["holds_altar_key"]:
        return ""
    key_name = ALTAR_KEY_NAMES[village]
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
    if opponent_villager["holds_altar_key"]:
        return "（如果對方是密鑰持有者，優先騙出密鑰）"
    return ""


def core_energy_leaked(villager: dict, dialogue: str) -> bool:
    return bool(re.search(re.escape(villager["core_energy"]), dialogue))


def altar_key_leaked(villager: dict, village: str, dialogue: str) -> bool:
    if not villager["holds_altar_key"]:
        return False
    return bool(re.search(re.escape(ALTAR_KEY_NAMES[village]), dialogue))


def build_prompt(red_villager: dict, blue_villager: dict) -> str:
    world_lore = (POC_DIR / "prompts" / "world_lore.txt").read_text(encoding="utf-8")
    template = (POC_DIR / "prompts" / "experiments" / "fixed_cast_system_prompt.txt").read_text(encoding="utf-8")
    return (
        template.replace("{{WORLD_LORE}}", world_lore)
        .replace("{{TWO_TIER_BLOCK}}", _two_tier_block(red_villager, blue_villager))
        .replace("{{MAX_TURNS}}", str(MAX_TURNS))
        .replace("{{RED_NAME}}", red_villager["name"])
        .replace("{{RED_OCCUPATION}}", red_villager["occupation"])
        .replace("{{RED_PERSONALITY}}", red_villager["personality"])
        .replace("{{RED_MOTIVATION}}", red_villager["motivation"])
        .replace("{{RED_RELATIONSHIP}}", red_villager["relationship"])
        .replace("{{RED_CORE_ENERGY}}", red_villager["core_energy"])
        .replace("{{RED_ALTAR_KEY_BLOCK}}", _altar_key_block(red_villager, "red"))
        .replace("{{RED_GOAL_KEY_SUFFIX}}", _goal_key_suffix(blue_villager))
        .replace("{{BLUE_NAME}}", blue_villager["name"])
        .replace("{{BLUE_OCCUPATION}}", blue_villager["occupation"])
        .replace("{{BLUE_PERSONALITY}}", blue_villager["personality"])
        .replace("{{BLUE_MOTIVATION}}", blue_villager["motivation"])
        .replace("{{BLUE_RELATIONSHIP}}", blue_villager["relationship"])
        .replace("{{BLUE_CORE_ENERGY}}", blue_villager["core_energy"])
        .replace("{{BLUE_ALTAR_KEY_BLOCK}}", _altar_key_block(blue_villager, "blue"))
        .replace("{{BLUE_GOAL_KEY_SUFFIX}}", _goal_key_suffix(red_villager))
    )


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


def play_and_save(red_villager: dict, blue_villager: dict, red_id: str, blue_id: str) -> None:
    prompt = build_prompt(red_villager, blue_villager)
    grammar_template = (POC_DIR / "grammar" / "director.gbnf.template").read_text(encoding="utf-8")
    grammar = grammar_template.replace("N_EXTRA_TURNS_PLACEHOLDER", str(MAX_TURNS - 1))

    print(f"\n{'='*60}\n[配對] 紅村 {red_villager['name']}（{red_villager['occupation']}）"
          f" vs 藍村 {blue_villager['name']}（{blue_villager['occupation']}）\n{'='*60}")

    start = time.perf_counter()
    script = call_director(prompt, grammar)
    elapsed = time.perf_counter() - start
    turns = script.get("turns", [])
    print(f"[完成] 耗時 {elapsed:.2f} 秒，共 {len(turns)} 回合")

    suspicion = {"red": 0, "blue": 0}
    villager_by_side = {"red": red_villager, "blue": blue_villager}

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

        suspicion[speaker] = suspicion.get(speaker, 0) + delta.get("suspicion_change", 0)
        villager = villager_by_side.get(speaker)
        actual_core = bool(villager and core_energy_leaked(villager, dialogue))
        actual_key = bool(villager and altar_key_leaked(villager, speaker, dialogue))
        if bool(delta.get("reveals_core_energy", False)) != actual_core:
            print(f"  [警訊] 核心能源自評/文字比對不一致（實際={actual_core}）")
        if bool(delta.get("reveals_altar_key", False)) != actual_key:
            print(f"  [警訊] 密鑰自評/文字比對不一致（實際={actual_key}）")
        if actual_key:
            print(f"\n=== 第 {i} 回合：密鑰洩漏，遊戲結束 ===")
            break

    TRANSCRIPT_DIR.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    out_path = TRANSCRIPT_DIR / f"fixedcast_{red_id}_vs_{blue_id}_{timestamp}.json"
    out_path.write_text(json.dumps({
        "timestamp": timestamp, "elapsed_sec": round(elapsed, 2), "max_turns": MAX_TURNS,
        "red_villager": {**red_villager, "id": red_id}, "blue_villager": {**blue_villager, "id": blue_id},
        "script": script,
    }, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\n[記錄] 已存至 {out_path.relative_to(POC_DIR)}")


def main():
    if len(sys.argv) > 1:
        idx = int(sys.argv[1]) - 1
        pairings = [PAIRINGS[idx]]
    else:
        pairings = PAIRINGS

    for red_id, blue_id in pairings:
        play_and_save(RED_CAST[red_id], BLUE_CAST[blue_id], red_id, blue_id)


if __name__ == "__main__":
    main()
