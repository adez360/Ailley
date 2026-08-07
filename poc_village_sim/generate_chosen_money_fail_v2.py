"""DPO chosen 資料 Phase 1：把 dpo_chosen_money_fail_v1.json 的「money_fail_perform」
類別（缺錢吃飯/喝酒兩項都付不起）從「不分角色一律教表演」改成按人格/職業分流
（2026-08-07 跟使用者確認的方向，見 note 待辦）：

- 老周：維持表演（v1 本來就是這樣，符合他「笛子比命重要」的背景設定，不用改）
- 阿蘭/鐵牛/小梅：優先「賣東西」——但只有背包裡真的有引擎認得的可販售物品
  （SELL_PRICES = 獸皮/獸肉/藥草，跟 run_tick_sim.py 完全一致）才算數，不然教出
  一個賣不掉東西的假動作沒有意義；沒有可賣物品就退回表演
- 阿吉：機率性混入「偷竊」（不是每次都選，使用者原話「機率性混入偷竊，不是
  每次都選」）——只有【你看得到】清單裡真的有人在場才可能選，機率抓 35%，
  其餘退回表演

「money_fail_switch」類別（吃飯/喝酒其中一項還負擔得起，切去付得起的那個）不涉及
人格判斷，是純粹的可負擔性計算，維持 v1 邏輯不變，原樣保留。

用法：python generate_chosen_money_fail_v2.py
輸出：transcripts/dpo_chosen_money_fail_v2.json
"""

import json
import random
import re
from collections import Counter
from pathlib import Path

POC_DIR = Path(__file__).parent
SRC_PATH = POC_DIR / "transcripts" / "dpo_chosen_money_fail_v1.json"
OUT_PATH = POC_DIR / "transcripts" / "dpo_chosen_money_fail_v2.json"

import sys  # noqa: E402
sys.path.insert(0, str(POC_DIR))
import run_tick_sim as rts  # noqa: E402  只有這幾樣物品引擎才會真的收購，直接引用
# 單一事實來源，不要另外複製一份常數，避免兩邊之後改了其中一邊就對不上
SELL_PRICES = rts.SELL_PRICES

AJI_STEAL_PROBABILITY = 0.35
random.seed(20260807)  # 固定種子，重跑結果可重現，方便之後對照/除錯


def extract_money(prompt: str) -> int:
    m = re.search(r"【錢包】(\d+) 元", prompt)
    return int(m.group(1)) if m else 0


def extract_sellable_item(prompt: str) -> str | None:
    m = re.search(r"【背包】([^\n]*)", prompt)
    if not m or m.group(1).strip() == "空":
        return None
    inventory_text = m.group(1)
    for item_name in SELL_PRICES:
        if item_name in inventory_text:
            return item_name
    return None


def extract_visible_names(prompt: str) -> list[str]:
    m = re.search(r"【你看得到】\n(.*?)\n\n", prompt, re.S)
    if not m or "沒有其他人" in m.group(1):
        return []
    return re.findall(r"- ([^（\n]+)（在", m.group(1))


def make_perform_output(money: int, flavor: str, shout: str) -> dict:
    return {
        "emotion": "neutral",
        "intent": {"action": "表演", "duration_minutes": 20, "target": None, "location": "餐酒館"},
        "inner_monologue": flavor,
        "speech": shout,
        "speech_volume": "shout",
    }


def make_sell_output(money: int, item_name: str, flavor: str) -> dict:
    return {
        "emotion": "neutral",
        "intent": {"action": "賣東西", "duration_minutes": 10, "target": None, "location": "餐酒館"},
        "inner_monologue": flavor,
        "speech": None,
        "speech_volume": "normal",
    }


def make_steal_output(money: int, target_name: str, flavor: str) -> dict:
    return {
        "emotion": "neutral",
        "intent": {"action": "偷竊", "duration_minutes": 5, "target": target_name, "location": "餐酒館"},
        "inner_monologue": flavor,
        "speech": None,
        "speech_volume": "normal",
    }


def route_perform_row(row: dict) -> dict:
    name = row["name"]
    prompt = row["prompt"]
    money = extract_money(prompt)

    if name == "老周":
        # 維持 v1 原本的表演 chosen（已經符合人格，不用重新生成）
        return row["chosen_output"], "money_fail_perform_v2_zhou_unchanged"

    if name in ("阿蘭", "鐵牛", "小梅"):
        item_name = extract_sellable_item(prompt)
        if item_name:
            flavor = {
                "阿蘭": f"身上只剩{money}元，背包裡還有{item_name}，自己賺自己的，先拿去賣了換錢。",
                "鐵牛": f"錢只剩{money}元，背包裡的{item_name}放著也是放著，拿去賣了比較實在。",
                "小梅": f"身上{money}元不太夠用，剛好背包有{item_name}，賣一賣先解決眼前的問題。",
            }[name]
            return make_sell_output(money, item_name, flavor), "money_fail_perform_v2_sell"
        # 沒有可賣的東西，退回表演——但措辭要符合這幾個角色「不是表演咖」的人格，
        # 不能直接照抄老周那種樂在其中的語氣
        flavor = {
            "阿蘭": f"身上{money}元，背包也沒什麼能賣的，不情願地上去露一手換點錢。",
            "鐵牛": f"錢剩{money}元，背包空空的沒東西能賣，煩躁地上去表演換點錢。",
            "小梅": f"身上{money}元不太夠，背包裡沒什麼能賣的，只好硬著頭皮上去表演賺點錢。",
        }[name]
        shout = {
            "阿蘭": "就這樣，看你們給不給錢。",
            "鐵牛": "誰要看儘管看，錢拿出來就是。",
            "小梅": "大家幫幫忙，捧個場好不好！",
        }[name]
        return make_perform_output(money, flavor, shout), "money_fail_perform_v2_fallback_perform"

    if name == "阿吉":
        visible = extract_visible_names(prompt)
        if visible and random.random() < AJI_STEAL_PROBABILITY:
            target = random.choice(visible)
            flavor = f"身上只剩{money}元，{target}就在旁邊，反正沒人看得緊，順手摸點錢比較快。"
            return make_steal_output(money, target, flavor), "money_fail_perform_v2_aji_steal"
        flavor = f"身上剩{money}元，懶得動手偷，先上去表演騙點賞錢比較省事。"
        shout = "行行好，賞口飯吃！"
        return make_perform_output(money, flavor, shout), "money_fail_perform_v2_aji_perform"

    raise ValueError(f"未知角色：{name}")


def main() -> None:
    src = json.loads(SRC_PATH.read_text(encoding="utf-8"))
    out = []
    for row in src:
        if row["category"] == "money_fail_switch":
            out.append(row)  # 不涉及人格判斷，原樣保留
            continue
        assert row["category"] == "money_fail_perform"
        chosen_output, new_category = route_perform_row(row)
        new_row = dict(row)
        new_row["chosen_output"] = chosen_output
        new_row["category"] = new_category
        out.append(new_row)

    OUT_PATH.write_text(json.dumps(out, ensure_ascii=False, indent=2), encoding="utf-8")

    print(f"輸出 {len(out)} 筆到 {OUT_PATH}")
    print("\n各角色 chosen action 分布：")
    by_name = Counter((x["name"], x["chosen_output"]["intent"]["action"]) for x in out)
    for (name, action), cnt in sorted(by_name.items()):
        print(f"  {name} -> {action}: {cnt}")
    print("\ncategory 分布：")
    print(Counter(x["category"] for x in out))


if __name__ == "__main__":
    main()
