"""驗證「可行性失敗缺錢提示改列舉工作選項」有沒有真的改變模型行為（2026-08-07）。

強制阿吉一開局錢=3、飢餓值=90（跟上次巢狀分類實驗撞到的死循環情境對齊），跑
120 分鐘，觀察他在觸發「吃飯/喝酒可行性失敗」看到新提示之後，會不會主動選
打獵/採草藥/賣東西/表演，而不是像之前一樣一路卡到被強制發呆。

用法：python test_money_hint.py [遊戲分鐘數上限，預設 120]
"""

import sys
from pathlib import Path

POC_DIR = Path(__file__).parent
sys.path.insert(0, str(POC_DIR))

import characters as c

_orig_load_all_characters = c.load_all_characters


def _patched_load_all_characters():
    cast = _orig_load_all_characters()
    if "aji" in cast:
        cast["aji"]["physiology"]["money"] = 3
        cast["aji"]["physiology"]["hunger"] = 90
    return cast


c.load_all_characters = _patched_load_all_characters

import run_des_sim as des  # noqa: E402  在 patch 套用之後才 import


def main() -> None:
    target_game_minutes = int(sys.argv[1]) if len(sys.argv) > 1 else 120
    template = (POC_DIR / "prompts" / "villager_system_prompt.txt").read_text(encoding="utf-8")
    grammar = (POC_DIR / "grammar" / "turn_duration_experiment.gbnf.template").read_text(encoding="utf-8")
    reflection_template = (POC_DIR / "prompts" / "sleep_reflection_system_prompt.txt").read_text(encoding="utf-8")
    reflection_grammar = (POC_DIR / "grammar" / "reflection.gbnf.template").read_text(encoding="utf-8")
    importance_grammar = (POC_DIR / "grammar" / "importance.gbnf.template").read_text(encoding="utf-8")

    result = des.run_one_simulation(
        1, target_game_minutes, template, grammar,
        reflection_template, reflection_grammar, importance_grammar,
    )

    print("\n========== 阿吉的完整決策序列 ==========")
    work_actions = {"打獵", "採草藥", "賣東西", "表演"}
    pivoted = False
    for ev in result["events"]:
        if ev.get("name") != "阿吉":
            continue
        intent = ev.get("output", {}).get("intent", {})
        action = intent.get("action")
        forced = ev.get("system_forced", False)
        marker = "（引擎強制）" if forced else ""
        print(f"  [{ev['current_time']}] {action}{marker} 錢={ev['physiology_before'].get('money')}")
        if action in work_actions and not forced:
            pivoted = True

    print(f"\n結論：阿吉在缺錢期間{'有' if pivoted else '沒有'}主動選過工作類動作（打獵/採草藥/賣東西/表演）")


if __name__ == "__main__":
    main()
