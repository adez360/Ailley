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

# ---------------------------------------------------------------------------
# 固定角色卡（10 人）：轉譯自使用者提供的「歐米茄計畫」角色設定，拿掉電池/Flag
# 等科幻用詞，套進現有的 TAMMY神/NEON神/CHO/核心能源/舊神祭壇密鑰 世界觀。
# 比起隨機生成，這 10 位角色帶有明確的驅動力（motivation）與跟對手的既定
# 關係背景（relationship），測試證實能讓對話更聚焦、較少空泛閒聊
# （見 note：POC 紀錄 - 導演模式 B，固定角色卡測試段落）。目前預設使用這套。
# ---------------------------------------------------------------------------

# relationship 欄位有些是寫死指名對方的（例如索菲指名米拉），這種要另外標記
# relationship_target（對方的 id），實際組 prompt 時只有真的抽到那個人才會帶出這句話，
# 抽到別人就只帶 motivation、不提這段關係，避免講出「對方根本不在場」的矛盾台詞。
# 沒有標記 relationship_target 的，代表這句話是泛用的態度陳述（不是指名特定某人），
# 不管抽到誰都可以講。
FIXED_CAST_RED = {
    "morgu": {
        "name": "莫古", "occupation": "村長", "personality": "懷舊、固執、防禦性強",
        "motivation": "守護村落現有的核心能源存量，不信任 CHO 的神諭，主張固守待變",
        "relationship": "你跟藍村的伊諾是舊識，因對 CHO 神諭是否可信理念不合而斷絕往來",
        "relationship_target": "yinuo",
        "core_energy": "紅蓮之心", "holds_altar_key": True,
    },
    "aier": {
        "name": "艾爾", "occupation": "藥師（核心能源看護者）", "personality": "焦慮、務實、細心",
        "motivation": "監控村民核心能源狀態，對能源洩漏或流失感到極度恐慌",
        "relationship": "你私下跟藍村商人傑克有情報交易往來，這件事不能讓村長知道",
        "relationship_target": "jack",
        "core_energy": "赤焰之瞳", "holds_altar_key": False,
    },
    "suofei": {
        "name": "索菲", "occupation": "守衛", "personality": "警覺、悲觀、行動派",
        "motivation": "把 CHO 神諭與外村都視為威脅，優先排除任何外部干擾",
        "relationship": "你跟藍村的米拉多次發生衝突，你認定她是間諜",
        "relationship_target": "mila",
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

FIXED_CAST_BLUE = {
    "niya": {
        "name": "妮雅", "occupation": "藥師", "personality": "理性、冷靜、目標導向",
        "motivation": "想破解 CHO 神諭背後的真相，主張主動獻祭核心能源以求突破現狀",
        "relationship": "你需要紅村鐵匠塔克手上的資源或情報才能繼續研究",
        "relationship_target": "take",
        "core_energy": "碧波之息", "holds_altar_key": False,
    },
    "jack": {
        "name": "傑克", "occupation": "商人", "personality": "狡詐、投機、社交能力強",
        "motivation": "在兩村的混亂局勢中獲利，隱瞞雙方情報藉此操弄局勢",
        "relationship": "你是兩村之間檯面下的地下聯繫人，私下跟紅村藥師艾爾有情報交易往來",
        "relationship_target": "aier",
        "core_energy": "烈日之翼", "holds_altar_key": False,
    },
    "yinuo": {
        "name": "伊諾", "occupation": "祭司見習", "personality": "虔誠、狂熱、煽動性強",
        "motivation": "堅信 CHO 神諭是全村唯一的救贖，極力推動村民獻祭核心能源",
        "relationship": "你跟紅村村長莫古是舊識，因對 CHO 神諭是否可信理念不合而斷絕往來",
        "relationship_target": "morgu",
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
        "relationship_target": "suofei",
        "core_energy": "霜雪之骨", "holds_altar_key": False,
    },
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


def generate_fixed_roster() -> dict:
    """回傳固定的 10 人角色卡名單（每村 5 人），資料結構跟 generate_roster() 一致，
    可以直接餵給 pick_encounter()。角色本身已經寫死 core_energy／holds_altar_key，
    不需要再隨機抽選。"""
    roster = {"altar_keys": dict(ALTAR_KEY_NAMES)}
    roster["red"] = [{"id": f"red-{key}", "village": "red", **data} for key, data in FIXED_CAST_RED.items()]
    roster["blue"] = [{"id": f"blue-{key}", "village": "blue", **data} for key, data in FIXED_CAST_BLUE.items()]
    return roster


def save_roster(roster: dict) -> Path:
    ROSTER_DIR.mkdir(parents=True, exist_ok=True)
    timestamp = time.strftime("%Y%m%d-%H%M%S")
    path = ROSTER_DIR / f"roster_{timestamp}.json"
    path.write_text(json.dumps(roster, ensure_ascii=False, indent=2), encoding="utf-8")
    return path


def pick_encounter(roster: dict) -> tuple[dict, dict]:
    """從紅藍兩村名單各獨立隨機挑 1 人，作為這場劇本的主角。
    固定角色卡的 relationship 欄位如果有標記 relationship_target，
    組 prompt 時只有真的抽到那個人才會帶出那句話，抽到別人就不提，
    所以這裡不需要限制配對，兩村可以完全獨立抽選。"""
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
