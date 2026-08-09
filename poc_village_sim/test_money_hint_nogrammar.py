"""驗證：訓練資料是無grammar模式收集的，跟正式決策的grammar模式prompt尾端不同。
拿訓練好的LoRA模型，用「無grammar模式」（跟訓練資料同格式）重跑一次test_money_hint.py
一樣的情境，看阿吉會不會選表演/偷竊——如果變了，證明prompt格式差異是真正原因。
2026-08-09。
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

import run_des_sim as des  # noqa: E402

des.USE_GRAMMAR = False  # 關鍵差異：跟訓練資料收集時同一個模式


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

    print("\n========== 阿吉的完整決策序列（無grammar模式）==========")
    work_actions = {"打獵", "採草藥", "賣東西", "表演"}
    pivoted = False
    for ev in result["events"]:
        if ev.get("name") != "阿吉":
            continue
        out = ev.get("output") or {}
        intent = out.get("intent") or {}
        action = intent.get("action")
        money = ev.get("physiology_before", {}).get("money")
        print(f"  {ev.get('current_time')} {action} 錢={money}")
        if action in work_actions:
            pivoted = True

    print()
    if pivoted:
        print("結論：阿吉在缺錢期間主動選過工作類動作（打獵/採草藥/賣東西/表演）")
    else:
        print("結論：阿吉在缺錢期間沒有主動選過工作類動作（打獵/採草藥/賣東西/表演）")


if __name__ == "__main__":
    main()
