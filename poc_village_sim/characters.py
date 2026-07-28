"""Ailley POC — 村莊模擬村民資料模型（讀取層 + 渲染層 + prompt 組裝）

角色資料本身不放在這個檔案裡，放在 characters/<id>.json（一人一檔，方便日後單獨新增／
調整某個角色，不用改 Python 程式碼、不會動到其他角色）。這個檔案只放：
- 讀取角色卡／好感矩陣的 loader
- 把數值轉成中文形容詞句子的 renderer（Specify1/2 規定數值一定要附形容詞才能餵給 LLM）
- 把角色資料套進 villager_system_prompt.txt 的組裝函式（沿用 poc_agent_loop/agent_loop.py
  裡 build_plan_prompt() 那套 template.replace() 的寫法）

對應 neon/Specify1.md、neon/Specify2.md 的四層資料模型（人格／生理／關係／情緒）。
跟已封存的 poc_agent_loop_flag_scenario/characters.py 完全不同的資料結構：
沒有 core_energy／holds_altar_key 這種機密欄位，換成六維人格數值、生理狀態、好感矩陣。
"""

import json
from pathlib import Path

POC_DIR = Path(__file__).parent
CHARACTERS_DIR = POC_DIR / "characters"
RELATIONSHIPS_FILE = CHARACTERS_DIR / "relationships.json"

PERSONALITY_DIMENSIONS = [
    "diligence",             # 勤勉度
    "bravery",                # 膽識度
    "sociability",             # 社交性
    "morality",                 # 道德感
    "emotional_stability",       # 情緒穩定
    "romance",                    # 浪漫藝術
]

# ---------------------------------------------------------------------------
# 讀取層：一人一個 json 檔，新增角色只要多丟一個檔案進 characters/，不用碰這支程式
# ---------------------------------------------------------------------------

def load_character(char_id: str) -> dict:
    path = CHARACTERS_DIR / f"{char_id}.json"
    data = json.loads(path.read_text(encoding="utf-8"))
    data["id"] = char_id
    return data


def load_all_characters() -> dict:
    """讀 characters/ 底下除了 relationships.json 以外的所有角色卡。"""
    result = {}
    for path in sorted(CHARACTERS_DIR.glob("*.json")):
        if path.stem == "relationships":
            continue
        result[path.stem] = load_character(path.stem)
    return result


def load_relationships() -> dict:
    return json.loads(RELATIONSHIPS_FILE.read_text(encoding="utf-8"))


def get_affection(relationships: dict, observer_id: str, target_id: str) -> int:
    return relationships[observer_id][target_id]


# ---------------------------------------------------------------------------
# 渲染層：數值 -> 附中文形容詞的自然語言（Specify1 §9 兩個必要條件之一）
# ---------------------------------------------------------------------------

# 給「沒有手寫 personality_text」的新角色用的通用轉譯表（Specify2 §3.1）。
# 現有五人（alan/zhou/mei/tie/aji）都已經有手寫敘述，優先用 personality_text，不會走到這裡。
PERSONALITY_DESC_TABLE = {
    "diligence": {
        "high": "你閒不下來，看別人發呆會覺得浪費生命。",
        "mid": "你做事還算勤快，但也不會逼自己太緊。",
        "low": "你能不動就不動，寧可餓一點也不想爬起來工作。",
    },
    "bravery": {
        "high": "你不怕森林深處，危險反而讓你興奮。",
        "mid": "你不算特別勇敢，但正常狀況不會退縮。",
        "low": "你天生膽小，寧可繞路也不靠近有聲音的地方。",
    },
    "sociability": {
        "high": "你看到人就想搭話，獨處會讓你煩躁。",
        "mid": "你跟人相處還算自在，但不主動找話題。",
        "low": "你不喜歡人多，能一個人待著最好。",
    },
    "morality": {
        "high": "你受不了不守規矩的人，看到就想舉報。",
        "mid": "你大致守規矩，但不會多管別人的事。",
        "low": "規則對你來說只是建議，只要拿得到手就是你的。",
    },
    "emotional_stability": {
        "high": "你很難被激怒，事情發生了先想再說。",
        "mid": "你偶爾會被惹毛，但通常很快冷靜下來。",
        "low": "你一點就著，小摩擦也會讓你失控。",
    },
    "romance": {
        "high": "你相信生活需要音樂與愛，沒有這些活著沒意思。",
        "mid": "你對表演和調情沒什麼特別想法，看心情。",
        "low": "你覺得表演和調情都是浪費時間。",
    },
}


def render_personality_block(villager: dict) -> str:
    """優先用手寫的 personality_text；沒有的話用六維數值套表產生。"""
    if villager.get("personality_text"):
        return villager["personality_text"]
    lines = []
    for dim in PERSONALITY_DIMENSIONS:
        score = villager["personality"][dim]
        tier = "high" if score >= 70 else "low" if score <= 30 else "mid"
        lines.append(PERSONALITY_DESC_TABLE[dim][tier])
    return "\n".join(lines)


def _tier_adjective(value: int, low_word: str, mid_word: str, high_word: str) -> str:
    if value >= 70:
        return high_word
    if value >= 35:
        return mid_word
    return low_word


def stamina_tier_text(stamina: int) -> str:
    """體力越低，提示越強烈——不強制角色去睡覺，只是把處境講得更清楚（軟性提示，不覆蓋選擇權）。"""
    if stamina <= 5:
        return "你隨時都可能昏倒，真的該躺下了。"
    if stamina <= 15:
        return "你快撐不住了，眼皮很重，動作開始遲鈍。"
    if stamina <= 30:
        return "你覺得很累，該找個地方休息或睡覺了。"
    return ""


def boredom_tier_text(boredom: int) -> str:
    """原樣沿用 Specify2 §7.3 的提示語，數值早就有在算，這次補上一直漏掉的文字注入。"""
    if boredom >= 85:
        return "你受不了了，你必須去做點沒做過的事，或去找還沒說過話的人。"
    if boredom >= 60:
        return "你覺得今天很無聊，一直重複做一樣的事讓你煩躁。"
    return ""


def health_tier_text(health: int) -> str:
    """生命值越低，提示越急迫——一樣是軟性提示，會不會真的去治療還是角色自己決定。"""
    if health <= 5:
        return "我要死了……"
    if health <= 10:
        return "你眼前發黑、意識逐漸模糊，再不治療真的會死。"
    if health <= 20:
        return "你開始頭暈意識模糊，雖然治療很貴，但還是需要趕快去藥草鋪治療。"
    return ""


def render_body_status_block(physiology: dict) -> str:
    hunger, thirst = physiology["hunger"], physiology["thirst"]
    stamina, boredom = physiology["stamina"], physiology["boredom"]
    hunger_word = _tier_adjective(hunger, "不太餓", "有點餓", "很餓")
    thirst_word = _tier_adjective(thirst, "不太渴", "有點渴", "很渴")
    stamina_word = _tier_adjective(100 - stamina, "體力充沛", "體力普通", "快沒力了")
    boredom_word = _tier_adjective(boredom, "沒什麼無聊感", "有點無聊", "非常無聊")
    line = (
        f"飢餓 {hunger}（{hunger_word}） 口渴 {thirst}（{thirst_word}） "
        f"體力 {stamina}（{stamina_word}） 無聊 {boredom}（{boredom_word}）"
    )
    extra = [t for t in (stamina_tier_text(stamina), boredom_tier_text(boredom)) if t]
    if extra:
        line += "\n" + "".join(extra)
    return line


def render_injury_block(physiology: dict) -> str:
    injuries = []
    if physiology.get("bleeding"):
        injuries.append("流血")
    if physiology.get("severe_injury"):
        injuries.append("重傷")
    if physiology.get("sprained_ankle"):
        injuries.append("扭到腳（不能跑，走得很慢）")
    if physiology.get("hand_cut"):
        injuries.append("割傷手（打獵和表演變差）")
    if physiology.get("recovering"):
        injuries.append("正在藥草鋪治療後恢復中")

    health = physiology.get("health", 100)
    if not injuries and health >= 100:
        return "無"

    label = "、".join(injuries) if injuries else "無外傷"
    text = f"{label}（生命值 {health}）"
    tier = health_tier_text(health)
    if tier:
        text += f" {tier}"
    return text


def render_inventory_block(physiology: dict) -> str:
    items = physiology.get("inventory") or []
    if not items:
        return "空"
    parts = []
    for it in items:
        label = f"{it['item']} x{it['qty']}"
        if it.get("note"):
            label += f"（{it['note']}）"
        parts.append(label)
    return "、".join(parts)


AFFECTION_LABELS = [
    (80, 100, "摯愛/至交", "你願意為他擋刀。"),
    (20, 79, "友好", "你挺喜歡他的。"),
    (-19, 19, "中立", "你對他沒什麼特別感覺。"),
    (-79, -20, "嫌隙", "你看他不太順眼。"),
    (-100, -80, "死敵", "你恨他。"),
]


def render_affection_line(score: int) -> str:
    for low, high, label, desc in AFFECTION_LABELS:
        if low <= score <= high:
            return f"（{label}，{score}）{desc}"
    return f"（{score}）"


def render_visible_block(relationships: dict, self_id: str, visible: list) -> str:
    """visible: [{"id": "zhou", "activity": "正在演奏"}, ...] 視野內看得到的人跟他在做的事。"""
    if not visible:
        return "（附近沒有其他人）"
    lines = []
    for entry in visible:
        other = load_character(entry["id"])
        score = get_affection(relationships, self_id, entry["id"])
        lines.append(f"  - {other['name']}（{entry['activity']}）{render_affection_line(score)}")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# 組裝層：把角色資料 + 當下情境套進 villager_system_prompt.txt
# ---------------------------------------------------------------------------

def home_name(villager_name: str) -> str:
    return f"{villager_name}家"


def build_villager_prompt(template: str, world_lore: str, villager: dict, relationships: dict, *,
                           current_time: str, location: str, visible: list,
                           recent_event: str, last_emotion: str, last_action_result: str,
                           recent_memory: str, location_list: str) -> str:
    """沿用 poc_agent_loop/agent_loop.py 的 build_plan_prompt() 寫法：template.replace() 逐一替換。
    location_list 由呼叫端組好傳進來（要看整個角色名單才知道有哪些人的家，這裡只有單一
    villager，組不出完整清單）。"""
    physiology = villager["physiology"]
    return (
        template
        .replace("{{WORLD_LORE}}", world_lore)
        .replace("{{SELF_NAME}}", villager["name"])
        .replace("{{SELF_HOME}}", home_name(villager["name"]))
        .replace("{{SELF_PERSONALITY_BLOCK}}", render_personality_block(villager))
        .replace("{{CURRENT_TIME}}", current_time)
        .replace("{{BODY_STATUS_BLOCK}}", render_body_status_block(physiology))
        .replace("{{INJURY_BLOCK}}", render_injury_block(physiology))
        .replace("{{MONEY}}", str(physiology["money"]))
        .replace("{{INVENTORY_BLOCK}}", render_inventory_block(physiology))
        .replace("{{LOCATION}}", location)
        .replace("{{LOCATION_LIST}}", location_list)
        .replace("{{VISIBLE_BLOCK}}", render_visible_block(relationships, villager["id"], visible))
        .replace("{{RECENT_EVENT_BLOCK}}", recent_event)
        .replace("{{LAST_EMOTION}}", last_emotion)
        .replace("{{LAST_ACTION_RESULT_BLOCK}}", last_action_result)
        .replace("{{RECENT_MEMORY_BLOCK}}", recent_memory)
    )
