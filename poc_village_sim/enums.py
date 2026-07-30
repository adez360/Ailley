"""中文字串（LLM 輸出／grammar 用）跟英文代號（後端／Godot 用）的對照層。

刻意不改 grammar／prompt——LLM 還是用中文思考、輸出中文的 action／location 字串，
這套已經跑過大量驗證。這裡只是在 Python 這端加一層轉換：把 grammar 保證合法的中文字串
對照到一個英文 Enum 代號，讓後端／API 消費端可以用型別化的 Enum 做資料驗證跟比對，
不用在自己的程式碼裡到處比對中文字串常數。

地點比較特殊：公用地點是固定清單（SharedLocation），但每個角色的「家」是依當下角色
名單動態產生的（例如「阿蘭家」）。2026-07-31 修正：原本把「家」編成 f"HOME_{角色ID}"
這種單一 enum 字串，會導致合法值集合隨角色名單變動——不利於資料庫/Godot 端做固定
schema 驗證（角色名單本來就會成長，不該綁進 enum 定義裡）。改成拆兩層：`LocationKind`
是永遠固定的封閉集合（只有 SHARED／HOME 兩種），角色 ID 則是外鍵性質的獨立欄位，
交給角色資料表自己的驗證機制處理，不混進地點 enum。
"""
from enum import Enum


class LocationKind(str, Enum):
    """地點的種類，永遠只有這兩種，跟角色名單無關，可以放心刻進固定 schema。"""
    SHARED = "SHARED"
    HOME = "HOME"


class Action(str, Enum):
    """member 名稱是英文代號，value 是 grammar 裡實際會出現的中文字串。
    跟 grammar/turn.gbnf.template 等檔案的 action 清單必須保持一致——新增/刪除動作
    時兩邊都要改。"""
    SPEAK = "說話"
    ANNOUNCE = "喊話"
    WHISPER = "悄悄話"
    HANDSHAKE = "握手"
    HUG = "擁抱"
    GIVE_GIFT = "送禮"
    GIVE_MONEY = "給錢"
    MARRY = "結婚"
    DIVORCE = "離婚"
    STEAL = "偷竊"
    ROB = "搶劫"
    SABOTAGE_INSTRUMENT = "破壞樂器"
    ATTACK = "攻擊"
    CAPTURE = "抓捕"
    REPORT = "舉報"
    HUNT = "打獵"
    GATHER_HERBS = "採草藥"
    FISH = "釣魚"
    PERFORM = "表演"
    BUY = "買東西"
    SELL = "賣東西"
    HEAL = "治療"
    EAT = "吃飯"
    DRINK = "喝酒"
    MOVE = "移動"
    RUN = "奔跑"
    CROUCH = "蹲下"
    HOLD_HEAD = "抱頭"
    RAISE_HAND = "舉手"
    SCREAM = "大叫"
    THROW_ITEM = "摔東西"
    BLOW_KISS = "飛吻"
    FOLLOW = "跟隨"
    SHOW_ITEM = "展示物品"
    PATROL = "巡邏"
    SURRENDER = "自首"
    SLEEP = "睡覺"
    ZONE_OUT = "發呆"


class SharedLocation(str, Enum):
    """跟 run_tick_sim.SHARED_LOCATIONS 保持一致——只涵蓋公用地點，不含「家」，
    家的部分見 location_to_english()。"""
    TAVERN = "餐酒館"
    PAVILION = "涼亭"
    LAKE = "湖泊"
    BENCH = "長椅"
    FOREST = "森林"
    HERB_PATCH = "藥草叢"
    CLOTHING_SHOP = "服裝鋪"
    HERBALIST = "藥草鋪"
    REFORM_HOUSE = "洗心革面所"
    WEDDING_HALL = "結婚禮堂"
    GANDALF_STONE = "甘道夫石"
    VILLAGE_SQUARE = "村莊廣場"


def action_to_english(action_cn: str) -> str:
    """中文動作字串 -> 英文代號。輸入不合法（不在 grammar 允許清單內）時丟
    ValueError——這本身就是一種資料驗證：grammar 理論上保證輸出合法，但如果哪裡邏輯
    有漏洞讓不合法字串流進來，這裡會直接爆錯而不是悄悄放行。"""
    return Action(action_cn).name


def build_home_lookup(cast: dict) -> dict[str, str]:
    """回傳 {"阿蘭家": "alan", ...}——依當下角色名單動態產生，因為家的地點名稱
    跟角色名單綁定，不是固定清單。"""
    return {f"{v['name']}家": cid for cid, v in cast.items()}


def location_to_english(location_cn: str, cast: dict) -> dict:
    """中文地點字串 -> 結構化英文資料，不是單一扁平字串：
        {"kind": "SHARED", "shared_location": "HERBALIST", "owner_id": None}
        {"kind": "HOME", "shared_location": None, "owner_id": "alan"}
    `kind` 永遠是固定的封閉集合（驗證用 LocationKind）；`shared_location` 命中時驗證
    用 SharedLocation（固定 12 個）；`owner_id` 命中時驗證交給角色資料表自己的機制
    （這裡只查目前傳進來的 cast，不在這個函式裡假設角色名單固定不變）。
    輸入不合法時丟 ValueError（理由同 action_to_english）。"""
    try:
        return {
            "kind": LocationKind.SHARED.value,
            "shared_location": SharedLocation(location_cn).name,
            "owner_id": None,
        }
    except ValueError:
        pass
    home_lookup = build_home_lookup(cast)
    if location_cn in home_lookup:
        return {
            "kind": LocationKind.HOME.value,
            "shared_location": None,
            "owner_id": home_lookup[location_cn],
        }
    raise ValueError(f"未知的地點字串，不在公用地點清單也不是任何角色的家：{location_cn!r}")
