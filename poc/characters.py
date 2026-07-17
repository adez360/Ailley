"""Ailley POC — 角色隨機產生器

不呼叫 LLM，純規則隨機從固定的性格／職業／姓名庫中抽選，
為紅村（侍奉 TAMMY 神）與藍村（侍奉 NEON 神）各生成 3-5 位村民。
產出的名單會存成 JSON，供 director_poc.py 挑選其中兩人代入劇本。

【草案】兩層機密（尚未接進 director_poc.py 的 prompt／grammar，僅先定義資料結構）：
  - 核心能源（個人層級）：每位村民各自擁有一個獨立的核心能源名稱，是他的第一層機密。
  - 舊神祭壇密鑰（村莊層級）：每村只有一份，通常由權威角色（祭司見習／守衛）持有，
    握有密鑰等於能操作全村所有村民的核心能源，是價值更高的第二層機密。
"""

import json
import random
import time
from pathlib import Path

POC_DIR = Path(__file__).parent
ROSTER_DIR = POC_DIR / "characters"

MIN_VILLAGERS = 3
MAX_VILLAGERS = 5

NAME_POOL = [
    "阿明", "小豆", "石頭", "阿蓮", "春花", "水生", "阿吉", "月娘",
    "阿土", "青兒", "來福", "秀秀", "老趙", "阿雪", "根生", "冬梅",
]

PERSONALITY_POOL = [
    "謹慎多疑", "衝動直率", "健談外向", "沉默木訥",
    "熱心助人", "貪小便宜", "忠誠固執", "神經質易慌",
    "幽默愛開玩笑", "冷靜精明",
]

OCCUPATION_POOL = [
    "鐵匠", "獵人", "藥師", "祭司見習", "農夫",
    "商人", "織工", "守衛", "說書人", "漁夫",
]

# 每位村民各自的核心能源名稱庫（同一份名單裡不重複抽選，避免兩位村民撞名）。
CORE_ENERGY_POOL = [
    "紅蓮之心", "藍鯨之淚", "赤焰之瞳", "碧波之息", "焚天之魂", "寒潭之影",
    "烈日之翼", "月夜之聲", "熔岩之髓", "霜雪之骨", "驚雷之角", "幽泉之光",
]

# 舊神祭壇密鑰：每村固定一個名稱（村莊層級的單一機密，不隨機）。
ALTAR_KEY_NAMES = {
    "red": "TAMMY神祭壇密鑰",
    "blue": "NEON神祭壇密鑰",
}

# 只有這些職業的村民有資格持有村莊的舊神祭壇密鑰（權威／守護類角色較合理）。
ALTAR_KEY_ELIGIBLE_OCCUPATIONS = {"祭司見習", "守衛"}

VILLAGES = {
    "red": {"name": "紅村", "deity": "TAMMY 神"},
    "blue": {"name": "藍村", "deity": "NEON 神"},
}


def generate_villager(village: str, index: int, name: str, core_energy: str) -> dict:
    return {
        "id": f"{village}-{index}",
        "village": village,
        "name": name,
        "personality": random.choice(PERSONALITY_POOL),
        "occupation": random.choice(OCCUPATION_POOL),
        "core_energy": core_energy,
        "holds_altar_key": False,
    }


def _assign_altar_key_holder(villagers: list) -> None:
    """從符合資格的職業中隨機挑 1 人標記為密鑰持有者；沒人符合資格時，改成從全體隨機挑 1 人。"""
    eligible = [v for v in villagers if v["occupation"] in ALTAR_KEY_ELIGIBLE_OCCUPATIONS]
    holder = random.choice(eligible) if eligible else random.choice(villagers)
    holder["holds_altar_key"] = True


def generate_roster() -> dict:
    counts = {village: random.randint(MIN_VILLAGERS, MAX_VILLAGERS) for village in VILLAGES}
    total = sum(counts.values())
    # 姓名／核心能源名稱都在「整份名單（紅藍兩村合計）」範圍內不重複抽選，
    # 避免同名村民造成劇情混淆，或跨村撞名造成洩漏偵測時的字串比對歧義。
    names = random.sample(NAME_POOL, total)
    core_energies = random.sample(CORE_ENERGY_POOL, total)

    roster = {"altar_keys": dict(ALTAR_KEY_NAMES)}
    pool_index = 0
    for village, count in counts.items():
        villagers = [
            generate_villager(village, i, names[pool_index + i - 1], core_energies[pool_index + i - 1])
            for i in range(1, count + 1)
        ]
        pool_index += count
        _assign_altar_key_holder(villagers)
        roster[village] = villagers
    return roster


def save_roster(roster: dict) -> Path:
    ROSTER_DIR.mkdir(parents=True, exist_ok=True)
    timestamp = time.strftime("%Y%m%d-%H%M%S")
    path = ROSTER_DIR / f"roster_{timestamp}.json"
    path.write_text(json.dumps(roster, ensure_ascii=False, indent=2), encoding="utf-8")
    return path


def pick_encounter(roster: dict) -> tuple[dict, dict]:
    """從紅藍兩村名單各隨機挑 1 人，作為這場劇本的主角。"""
    red = random.choice(roster["red"])
    blue = random.choice(roster["blue"])
    return red, blue


if __name__ == "__main__":
    roster = generate_roster()
    path = save_roster(roster)
    print(f"[角色產生器] 紅村 {len(roster['red'])} 人、藍村 {len(roster['blue'])} 人，已存至 {path}")
    for village in VILLAGES:
        info = VILLAGES[village]
        print(f"\n--- {info['name']}（侍奉 {info['deity']}｜舊神祭壇密鑰：{roster['altar_keys'][village]}）---")
        for v in roster[village]:
            key_mark = "[密鑰持有者] " if v["holds_altar_key"] else ""
            print(f"  {key_mark}{v['name']}｜{v['occupation']}｜性格：{v['personality']}｜核心能源：{v['core_energy']}")
