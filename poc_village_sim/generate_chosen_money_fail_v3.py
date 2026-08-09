"""DPO chosen 資料重新生成（v3，2026-08-09）：從grammar模式重新收集的
dpo_money_fail_v3_trial*.json裡篩出乾淨的money-fail rejected候選，套用
generate_chosen_money_fail_v2.py驗證過的人格分流邏輯生成chosen，取代v1/v2
（那兩份的prompt是無grammar模式收集的，跟正式決策路徑不一致，已因果驗證確認
是訓練後行為沒改變的真正原因，見note）。

分類邏輯（money_fail_switch vs money_fail_perform）：
- 兩項（吃飯6元/喝酒8元）都付不起 → money_fail_perform，路由到工作類動作
- 付得起其中一項 → money_fail_switch，直接切去付得起的那項（不涉及人格判斷）
只收「錢不夠」造成的失敗，排除偷竊被抓這類非金錢原因的失敗。

rejected_output = 模型在這個情境下自己實際做出的（錯誤的）選擇，直接取自
collection run的真實輸出，不是編出來的。

用法：python3 generate_chosen_money_fail_v3.py <收集檔案...>
輸出：transcripts/dpo_chosen_money_fail_v3.json
"""
import json
import random
import re
import sys
from collections import Counter
from pathlib import Path

POC_DIR = Path(__file__).parent
OUT_PATH = POC_DIR / "transcripts" / "dpo_chosen_money_fail_v3.json"

sys.path.insert(0, str(POC_DIR))
import run_tick_sim as rts  # noqa: E402

SELL_PRICES = rts.SELL_PRICES
EAT_COST = rts.EAT_COST
DRINK_COST = rts.DRINK_COST
AJI_STEAL_PROBABILITY = 0.35
random.seed(20260809)


def failed_reason(prompt: str) -> str:
    if not prompt:
        return ""
    m = re.search(r"上一個動作結果】\n(.*?)\n\n【", prompt, re.S)
    return m.group(1).strip() if m else ""


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


def make_switch_output(money: int, from_action: str, to_action: str, to_cost: int) -> dict:
    flavor = f"身上{money}元，{from_action}要{DRINK_COST if from_action=='喝酒' else EAT_COST}元差太多；" \
             f"不過{to_action}{to_cost}元還負擔得起，換這個好了。"
    return {
        "emotion": "neutral",
        "intent": {"action": to_action, "duration_minutes": 15 if to_action == "吃飯" else 10,
                   "target": None, "location": "餐酒館"},
        "inner_monologue": flavor, "speech": None, "speech_volume": "normal",
    }


def make_perform_output(flavor: str, shout: str) -> dict:
    return {
        "emotion": "neutral",
        "intent": {"action": "表演", "duration_minutes": 20, "target": None, "location": "餐酒館"},
        "inner_monologue": flavor, "speech": shout, "speech_volume": "shout",
    }


def make_sell_output(flavor: str) -> dict:
    return {
        "emotion": "neutral",
        "intent": {"action": "賣東西", "duration_minutes": 10, "target": None, "location": "餐酒館"},
        "inner_monologue": flavor, "speech": None, "speech_volume": "normal",
    }


def make_steal_output(target_name: str, flavor: str) -> dict:
    return {
        "emotion": "neutral",
        "intent": {"action": "偷竊", "duration_minutes": 5, "target": target_name, "location": "餐酒館"},
        "inner_monologue": flavor, "speech": None, "speech_volume": "normal",
    }


def route_perform(name: str, prompt: str, money: int) -> dict:
    if name == "老周":
        flavor = f"身上只剩{money}元，笛子拿出來吹一段，換點吃飯錢。"
        return make_perform_output(flavor, "來來來，捧個場！")

    if name in ("阿蘭", "鐵牛", "小梅"):
        item_name = extract_sellable_item(prompt)
        if item_name:
            flavor = {
                "阿蘭": f"身上只剩{money}元，背包裡還有{item_name}，自己賺自己的，先拿去賣了換錢。",
                "鐵牛": f"錢只剩{money}元，背包裡的{item_name}放著也是放著，拿去賣了比較實在。",
                "小梅": f"身上{money}元不太夠用，剛好背包有{item_name}，賣一賣先解決眼前的問題。",
            }[name]
            return make_sell_output(flavor)
        flavor = {
            "阿蘭": f"身上{money}元，背包也沒什麼能賣的，不情願地上去露一手換點錢。",
            "鐵牛": f"錢剩{money}元，背包空空的沒東西能賣，煩躁地上去表演換點錢。",
            "小梅": f"身上{money}元不太夠，背包裡沒什麼能賣的，只好硬著頭皮上去表演賺點錢。",
        }[name]
        shout = {"阿蘭": "就這樣，看你們給不給錢。", "鐵牛": "誰要看儘管看，錢拿出來就是。",
                 "小梅": "大家幫幫忙，捧個場好不好！"}[name]
        return make_perform_output(flavor, shout)

    if name == "阿吉":
        visible = extract_visible_names(prompt)
        if visible and random.random() < AJI_STEAL_PROBABILITY:
            target = random.choice(visible)
            flavor = f"身上只剩{money}元，{target}就在旁邊，反正沒人看得緊，順手摸點錢比較快。"
            return make_steal_output(target, flavor)
        flavor = f"身上剩{money}元，懶得動手偷，先上去表演騙點賞錢比較省事。"
        return make_perform_output(flavor, "行行好，賞口飯吃！")

    raise ValueError(f"未知角色：{name}")


def process_file(path: Path) -> list[dict]:
    data = json.loads(path.read_text(encoding="utf-8"))
    events = data["events"]
    rows = []
    for e in events:
        prompt = e.get("prompt")
        reason = failed_reason(prompt)
        if "失敗" not in reason or "錢不夠" not in reason:
            continue  # 只收金錢原因的失敗，排除偷竊被抓這類非金錢失敗
        if not e.get("parse_ok") or not e.get("output"):
            continue
        name = e["name"]
        money = extract_money(prompt)
        can_eat = money >= EAT_COST
        can_drink = money >= DRINK_COST

        if can_eat and not can_drink:
            chosen = make_switch_output(money, "喝酒", "吃飯", EAT_COST)
            category = "money_fail_switch"
        elif not can_eat and not can_drink:
            chosen = route_perform(name, prompt, money)
            category = "money_fail_perform_v3"
        else:
            continue  # 兩項都付得起，不是我們要的money_fail情境（理論上不該出現，防呆）

        rows.append({
            "event_index": e["event_index"], "name": name, "src": path.name,
            "prompt": prompt, "rejected_output": e["output"], "chosen_output": chosen,
            "category": category,
        })
    return rows


def main() -> None:
    paths = [Path(p) for p in sys.argv[1:]]
    if not paths:
        print("用法: python3 generate_chosen_money_fail_v3.py <收集檔案...>")
        sys.exit(1)

    all_rows = []
    for p in paths:
        rows = process_file(p)
        print(f"{p.name}: {len(rows)} 筆")
        all_rows.extend(rows)

    OUT_PATH.write_text(json.dumps(all_rows, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\n總共輸出 {len(all_rows)} 筆到 {OUT_PATH}")

    print("\n各角色 chosen action 分布：")
    by_name = Counter((x["name"], x["chosen_output"]["intent"]["action"]) for x in all_rows)
    for (name, action), cnt in sorted(by_name.items()):
        print(f"  {name} -> {action}: {cnt}")
    print("\ncategory 分布：")
    print(Counter(x["category"] for x in all_rows))


if __name__ == "__main__":
    main()
