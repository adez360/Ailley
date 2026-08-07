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
    時兩邊都要改。

    2026-08-07：member 名稱改成對齊隊友 Ru 的正式規格書（07 地點與行動規格書 §4）
    的英文動詞（例如 CAPTURE→arrest、ANNOUNCE→shout、ZONE_OUT→idle），只改左邊的
    識別字，value（中文字串，grammar 實際比對用）完全不動。`hunt` 是唯一沒有精確
    對應的一個——規格書把打獵拆成 hunt_small／hunt_large 兩種，POC 目前的「打獵」
    沒有這個區分，先保留單一 `hunt`，等 POC 這邊也拆分大小型獵物再對齊。"""
    speak = "說話"
    shout = "喊話"
    whisper = "悄悄話"
    handshake = "握手"
    hug = "擁抱"
    give_item = "送禮"
    give_money = "給錢"
    marry = "結婚"
    divorce = "離婚"
    steal = "偷竊"
    rob = "搶劫"
    break_item = "破壞樂器"
    attack = "攻擊"
    arrest = "抓捕"
    report = "舉報"
    hunt = "打獵"  # 規格書拆 hunt_small/hunt_large，POC 尚未區分，見上方說明
    gather = "採草藥"
    fish = "釣魚"
    perform = "表演"
    buy = "買東西"
    sell = "賣東西"
    heal = "治療"
    eat = "吃飯"
    drink = "喝酒"
    move_to = "移動"
    run_to = "奔跑"
    crouch = "蹲下"
    cover_head = "抱頭"
    raise_hand = "舉手"
    scream = "大叫"
    throw_item = "摔東西"
    blow_kiss = "飛吻"
    follow = "跟隨"
    show_item = "展示物品"
    patrol = "巡邏"
    surrender = "自首"
    sleep = "睡覺"
    idle = "發呆"


class SharedLocation(str, Enum):
    """跟 run_tick_sim.SHARED_LOCATIONS 保持一致——只涵蓋公用地點，不含「家」，
    家的部分見 location_to_english()。

    2026-08-07：member 名稱全部改小寫，對齊 Ru 的正式規格書（07 §1）的
    `location_id`（拿掉 `loc_` 前綴，前綴留給之後真的要組回 `loc_xxx` 格式的地方
    再加，理由同 Action 那邊的說明）：REFORM_HOUSE→jail（規格書 `loc_jail` 就是
    洗心革面所）、WEDDING_HALL→chapel（`loc_chapel`）、HERB_PATCH→herb_field
    （`loc_herb_field`）、HERBALIST→herb_shop（`loc_herb_shop`）、
    VILLAGE_SQUARE→square（`loc_square`）。`divine_stone`（甘道夫石）沿用舊名但
    改英文——規格書 07 §1-1 說這其實**不是地點，是可移動物件**
    （`obj_divine_stone`），正式要拆出 SharedLocation 之外自成一類，這次範圍只
    處理命名，不動資料結構，先照舊放在這裡，拆分留待之後。"""
    tavern = "餐酒館"
    pavilion = "涼亭"
    lake = "湖泊"
    bench = "長椅"
    forest = "森林"
    herb_field = "藥草叢"
    clothing_shop = "服裝鋪"
    herb_shop = "藥草鋪"
    jail = "洗心革面所"
    chapel = "結婚禮堂"
    divine_stone = "甘道夫石"
    square = "村莊廣場"


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
        {"kind": "SHARED", "shared_location": "herb_shop", "owner_id": None}
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
