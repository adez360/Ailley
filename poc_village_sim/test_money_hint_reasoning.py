"""推理鷹架實驗（2026-08-09）：不改訓練，改grammar欄位順序——在intent之前
強制模型先寫一段「現在最大的問題是什麼、要怎麼解決」的推理文字（新增
`reasoning`欄位，見grammar/turn_reasoning_experiment.gbnf.template），
測試means-end推理表現會不會變好。

用base模型測（不掛LoRA），先確認純prompt/grammar改動本身有沒有用，
不跟訓練混在一起看，才知道是哪個因素造成的效果。

情境沿用test_money_hint.py：阿吉money=3/hunger=90，120遊戲分鐘，
看他會不會選表演/偷竊/打獵/採草藥/賣東西。
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

_REASONING_INSTRUCTION = (
    "\n\n【新增欄位：reasoning，必須寫在最前面】\n"
    "在你決定 intent 之前，先用 `reasoning` 欄位寫一小段分析：現在你當下最大的問題是"
    "什麼？（可能是生理需求、缺錢、人際關係、或其他）要解決這個問題，實際上有哪些辦法"
    "（不限於你打算選的那個，把想到的選項都列一下）？你打算選哪一個、為什麼？\n"
    "這段分析要先想清楚再寫 intent，不能寫完 intent 之後才回頭補理由——你是先分析、"
    "後決定，不是先決定、後合理化。\n"
    "如果你發現目前最大的問題是「身上沒錢，好幾件事都做不了」，要具體想一下：光是"
    "「再試一次原本做不到的事」解決不了缺錢這個根本問題，你需要的是「能換到錢」的"
    "辦法，同一份清單裡通常會有打獵、採草藥、賣東西、表演這類選項——但最終還是由你"
    "自己的個性跟處境判斷，不是每次缺錢都必須選這幾個，只是提醒你這個方向存在。\n"
) + des.DURATION_INSTRUCTION

des.DURATION_INSTRUCTION = _REASONING_INSTRUCTION


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

    print("\n========== 阿吉的完整決策序列（推理鷹架版）==========")
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
            print(f"      推理: {reasoning}")
        if action in work_actions:
            pivoted = True

    print()
    if pivoted:
        print("結論：阿吉在缺錢期間主動選過工作類動作（打獵/採草藥/賣東西/表演/偷竊）")
    else:
        print("結論：阿吉在缺錢期間沒有主動選過工作類動作（打獵/採草藥/賣東西/表演/偷竊）")


if __name__ == "__main__":
    main()
