"""推理鷹架實驗（100字版，2026-08-10）：介於長版（不限字數，品質最好但延遲最高，
平均12.96s尖峰）跟壓縮版（40字上限，延遲壓到接近基準值但反覆卡頓次數變多、
「需要錢」的推理常常沒接到動作選擇上）之間，找時間/品質的平衡點。
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

_REASONING_INSTRUCTION_100 = (
    "\n\n【新增欄位：reasoning，必須寫在最前面，上限100字】\n"
    "在你決定 intent 之前，先用 `reasoning` 欄位寫一段分析：現在最大的問題是什麼、"
    "有哪些辦法可以解決、你打算選哪一個、為什麼。**不超過100字**，把因果關係講完整"
    "（例如「A做不到 → 所以需要B」），但不用鉅細靡遺列出每一個考慮過的選項。\n"
    "這段要先想清楚再寫 intent，不能寫完 intent 之後才回頭補理由。\n"
    "如果最大的問題是「身上沒錢，好幾件事都做不了」，記得：再試一次原本做不到的事"
    "解決不了缺錢問題，需要的是「能換到錢」的辦法（打獵/採草藥/賣東西/表演這類），"
    "但最終還是由你自己的個性跟處境判斷。\n"
) + des.DURATION_INSTRUCTION

des.DURATION_INSTRUCTION = _REASONING_INSTRUCTION_100


def main() -> None:
    target_game_minutes = int(sys.argv[1]) if len(sys.argv) > 1 else 120
    template = (POC_DIR / "prompts" / "villager_system_prompt.txt").read_text(encoding="utf-8")
    grammar = (POC_DIR / "grammar" / "turn_reasoning_experiment.gbnf.template").read_text(encoding="utf-8")
    reflection_template = (POC_DIR / "prompts" / "sleep_reflection_system_prompt.txt").read_text(encoding="utf-8")
    reflection_grammar = (POC_DIR / "grammar" / "reflection.gbnf.template").read_text(encoding="utf-8")
    importance_grammar = (POC_DIR / "grammar" / "importance.gbnf.template").read_text(encoding="utf-8")

    result = des.run_one_simulation(
        1, target_game_minutes, template, grammar,
        reflection_template, reflection_grammar, importance_grammar,
    )

    print("\n========== 阿吉的完整決策序列（推理鷹架100字版）==========")
    work_actions = {"打獵", "採草藥", "賣東西", "表演", "偷竊"}
    pivoted = False
    for ev in result["events"]:
        if ev.get("name") != "阿吉":
            continue
        out = ev.get("output") or {}
        intent = out.get("intent") or {}
        action = intent.get("action")
        reasoning = out.get("reasoning", "")
        money = ev.get("physiology_before", {}).get("money")
        print(f"  {ev.get('current_time')} {action} 錢={money}")
        if reasoning:
            print(f"      推理({len(reasoning)}字): {reasoning}")
        if action in work_actions:
            pivoted = True

    print()
    if pivoted:
        print("結論：阿吉在缺錢期間主動選過工作類動作（打獵/採草藥/賣東西/表演/偷竊）")
    else:
        print("結論：阿吉在缺錢期間沒有主動選過工作類動作（打獵/採草藥/賣東西/表演/偷竊）")


if __name__ == "__main__":
    main()
