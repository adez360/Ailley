"""維生方式提示句 v2 驗證（2026-08-05）。

跟 v1 不同：這次**不**疊加精簡版身體狀態格式（terse 已判定「效果小且不一致，不值得
投入」，見 note），只用現行完整格式（baseline）＋條件式措辭的維生提示句，乾淨比較
「改措辭本身有沒有用」，不跟 terse 的雜訊混在一起。

對照基準（同樣 300 分鐘、五人自然開局、baseline 完整格式，見 note）：
- 不加提示句（baseline）：老周 84%／鐵牛 88%／小梅 81%／阿蘭 87%／阿吉 73%（相鄰同動作率）
- v1（祈使句「應該」）：老周 100%／鐵牛 84%／小梅 90%／阿蘭 86%／阿吉 76%

用法：
  python test_livelihood_v2.py [遊戲分鐘數上限，預設 300] [重複次數，預設 4]
"""

import json
import sys
from collections import defaultdict
from datetime import datetime
from pathlib import Path

POC_DIR = Path(__file__).parent
sys.path.insert(0, str(POC_DIR))

import livelihood_hint_v2_patch as hint_patch
hint_patch.apply()

import run_des_sim as des  # 在 patch 套用之後才 import，確保 des 內部用到的是 patch 過的 c.render_personality_block

TRANSCRIPT_DIR = POC_DIR / "transcripts"


def analyze_run(events: list) -> dict:
    """回傳 {角色名: {"n": 決策數, "same_rate": 相鄰同動作率, "cycle2_rate": 2循環率}}。
    2循環率定義：對每個 i（0..n-3），若 a[i]==a[i+2] 視為一次「隔一格重複」（抓 ABAB
    振盪型態），不要求 a[i+1]==a[i+3] 同時成立——比嚴格版寬鬆，但足以抓出比原本
    「相鄰同動作率」更細的偽多樣性，沿用 note 裡 8/5 大規模驗證用的同一套判斷方式。"""
    by_char = defaultdict(list)
    for ev in events:
        if ev.get("system_forced"):
            continue
        action = ev.get("output", {}).get("intent", {}).get("action")
        if action is None:
            continue
        by_char[ev["name"]].append(action)

    result = {}
    for name, actions in by_char.items():
        n = len(actions)
        if n < 2:
            result[name] = {"n": n, "same_rate": None, "cycle2_rate": None}
            continue
        same = sum(1 for i in range(n - 1) if actions[i] == actions[i + 1])
        same_rate = same / (n - 1)
        if n >= 3:
            cyc = sum(1 for i in range(n - 2) if actions[i] == actions[i + 2])
            cycle2_rate = cyc / (n - 2)
        else:
            cycle2_rate = None
        result[name] = {"n": n, "same_rate": same_rate, "cycle2_rate": cycle2_rate}
    return result


def main() -> None:
    target_game_minutes = int(sys.argv[1]) if len(sys.argv) > 1 else 300
    num_runs = int(sys.argv[2]) if len(sys.argv) > 2 else 4

    template = (POC_DIR / "prompts" / "villager_system_prompt.txt").read_text(encoding="utf-8")
    grammar = (POC_DIR / "grammar" / "turn_duration_experiment.gbnf.template").read_text(encoding="utf-8")
    reflection_template = (POC_DIR / "prompts" / "sleep_reflection_system_prompt.txt").read_text(encoding="utf-8")
    reflection_grammar = (POC_DIR / "grammar" / "reflection.gbnf.template").read_text(encoding="utf-8")
    importance_grammar = (POC_DIR / "grammar" / "importance.gbnf.template").read_text(encoding="utf-8")
    TRANSCRIPT_DIR.mkdir(exist_ok=True)

    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    all_analyses = []
    for run_index in range(1, num_runs + 1):
        print(f"\n========== livelihood_v2 第 {run_index}/{num_runs} 次（{target_game_minutes} 分鐘）==========")
        result = des.run_one_simulation(
            run_index, target_game_minutes, template, grammar,
            reflection_template, reflection_grammar, importance_grammar,
        )
        out_path = TRANSCRIPT_DIR / f"livelihood_v2_run{run_index}_{timestamp}.json"
        out_path.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
        analysis = analyze_run(result["events"])
        all_analyses.append(analysis)
        print(f"第 {run_index} 次完成，{result['num_events']} 個事件，已存到 {out_path}")
        for name, stats in analysis.items():
            print(f"  {name}: n={stats['n']} same_rate={stats['same_rate']} cycle2_rate={stats['cycle2_rate']}")

    # 彙整：每個角色跨所有輪次合併計算（用總次數加權，不是輪次平均）
    print("\n========== 彙整（跨輪次，依決策次數加權）==========")
    agg = defaultdict(lambda: {"n": 0, "same": 0, "cyc": 0, "cyc_n": 0})
    for analysis in all_analyses:
        for name, stats in analysis.items():
            if stats["n"] is None or stats["n"] < 2:
                continue
            a = agg[name]
            a["n"] += stats["n"] - 1
            a["same"] += round(stats["same_rate"] * (stats["n"] - 1))
            if stats["cycle2_rate"] is not None:
                a["cyc_n"] += stats["n"] - 2
                a["cyc"] += round(stats["cycle2_rate"] * (stats["n"] - 2))

    for name, a in agg.items():
        same_rate = a["same"] / a["n"] if a["n"] else None
        cyc_rate = a["cyc"] / a["cyc_n"] if a["cyc_n"] else None
        print(f"  {name}: 決策數(n-1)={a['n']} same_rate={same_rate:.2%} cycle2_rate={(cyc_rate or 0):.2%}")


if __name__ == "__main__":
    main()
