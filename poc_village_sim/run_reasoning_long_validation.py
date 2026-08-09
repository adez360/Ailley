"""推理鷹架長時間驗證（100字版，2026-08-10）：不是強制貧窮的對照情境，是五人
正常起始狀態，跑長時間，確認「先推理再決定」這個改動撐不撐得住正常作息
（睡覺、吃飯、工作、社交），不會退化成只會寫推理文字但決策本身變奇怪，
也不會讓 parse 失敗率/中斷風暴之類的既有指標變差。

用法：python3 run_reasoning_long_validation.py
"""
import sys
from pathlib import Path

POC_DIR = Path(__file__).parent
sys.path.insert(0, str(POC_DIR))

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
# 長時間驗證，不要被安全上限提早卡住——真正的終止條件交給外面的7小時監控
des.MAX_EVENTS_SAFETY_CAP = 100000
TARGET_GAME_MINUTES = 200000  # 夠長，實際會被7小時的wall-clock監控切斷，不是被這個數字卡住


def main() -> None:
    template = (POC_DIR / "prompts" / "villager_system_prompt.txt").read_text(encoding="utf-8")
    grammar = (POC_DIR / "grammar" / "turn_reasoning_experiment.gbnf.template").read_text(encoding="utf-8")
    reflection_template = (POC_DIR / "prompts" / "sleep_reflection_system_prompt.txt").read_text(encoding="utf-8")
    reflection_grammar = (POC_DIR / "grammar" / "reflection.gbnf.template").read_text(encoding="utf-8")
    importance_grammar = (POC_DIR / "grammar" / "importance.gbnf.template").read_text(encoding="utf-8")

    out_path = des.TRANSCRIPT_DIR / "reasoning_long_validation.json"
    result = des.run_one_simulation(
        1, TARGET_GAME_MINUTES, template, grammar,
        reflection_template, reflection_grammar, importance_grammar,
        incremental_out_path=out_path,
    )

    events = result["events"]
    print(f"總事件數: {len(events)}，中斷次數: {result['interrupt_count']}")
    parse_ok_rate = sum(1 for e in events if e["parse_ok"]) / len(events) if events else 0
    print(f"parse_ok率: {parse_ok_rate:.4f}")
    print("LONG_VALIDATION_DONE")


if __name__ == "__main__":
    main()
