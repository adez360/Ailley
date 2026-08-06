"""巢狀動作分類實驗（2026-08-06）。

假設：grammar 先讓模型 commit「生理/社交/工作/動作」這個大類別，逐 token 生成時等於
先做了一次隱性 chain-of-thought，再從類別底下的清單選具體動作，應該比一次從 38 個扁平
選項裡選一個更穩——同一個機制之前用在「intent 欄位順序調整解決敘事脫節」上驗證有效。

對照組（baseline，同樣用 turn_duration_experiment.gbnf.template + villager_system_prompt.txt）：
跑法跟 test_livelihood_v2.py 一樣，用同一套 same_rate / cycle2_rate 指標比較。

用法：
  python test_nested_action.py [模式: baseline|nested，預設兩個都跑] [遊戲分鐘數上限，預設 300] [重複次數，預設 4]
"""

import json
import sys
from collections import defaultdict
from datetime import datetime
from pathlib import Path

POC_DIR = Path(__file__).parent
sys.path.insert(0, str(POC_DIR))

import run_des_sim as des

TRANSCRIPT_DIR = POC_DIR / "transcripts"


def analyze_run(events: list) -> dict:
    """回傳 {角色名: {"n", "same_rate", "cycle2_rate", "null_target_rate"}}。
    null_target_rate 額外統計「偷竊/搶劫/攻擊/抓捕/舉報」這類理當要有對象的動作裡
    target 填 null 的比例，沿用房屋偷竊實驗發現的診斷方式（見 note）。"""
    NEEDS_TARGET_ACTIONS = {"偷竊", "搶劫", "破壞樂器", "攻擊", "抓捕", "舉報"}
    by_char = defaultdict(list)
    target_stats = defaultdict(lambda: [0, 0])  # name -> [null次數, 該類動作總數]
    for ev in events:
        if ev.get("system_forced"):
            continue
        intent = ev.get("output", {}).get("intent", {})
        action = intent.get("action")
        if action is None:
            continue
        by_char[ev["name"]].append(action)
        if action in NEEDS_TARGET_ACTIONS:
            stat = target_stats[ev["name"]]
            stat[1] += 1
            if intent.get("target") in (None, "null"):
                stat[0] += 1

    result = {}
    for name, actions in by_char.items():
        n = len(actions)
        if n < 2:
            result[name] = {"n": n, "same_rate": None, "cycle2_rate": None}
        else:
            same = sum(1 for i in range(n - 1) if actions[i] == actions[i + 1])
            same_rate = same / (n - 1)
            if n >= 3:
                cyc = sum(1 for i in range(n - 2) if actions[i] == actions[i + 2])
                cycle2_rate = cyc / (n - 2)
            else:
                cycle2_rate = None
            result[name] = {"n": n, "same_rate": same_rate, "cycle2_rate": cycle2_rate}
        null_n, total_n = target_stats[name]
        result[name]["null_target_rate"] = (null_n / total_n) if total_n else None
        result[name]["needs_target_n"] = total_n
    return result


def aggregate(all_analyses: list) -> dict:
    agg = defaultdict(lambda: {"n": 0, "same": 0, "cyc": 0, "cyc_n": 0, "null_n": 0, "needs_target_n": 0})
    for analysis in all_analyses:
        for name, stats in analysis.items():
            a = agg[name]
            if stats["n"] is not None and stats["n"] >= 2:
                a["n"] += stats["n"] - 1
                a["same"] += round(stats["same_rate"] * (stats["n"] - 1))
                if stats["cycle2_rate"] is not None:
                    a["cyc_n"] += stats["n"] - 2
                    a["cyc"] += round(stats["cycle2_rate"] * (stats["n"] - 2))
            if stats.get("needs_target_n"):
                a["needs_target_n"] += stats["needs_target_n"]
                a["null_n"] += round((stats["null_target_rate"] or 0) * stats["needs_target_n"])
    return agg


def run_mode(mode: str, template_path: Path, grammar_path: Path, target_game_minutes: int, num_runs: int) -> dict:
    template = template_path.read_text(encoding="utf-8")
    grammar = grammar_path.read_text(encoding="utf-8")
    reflection_template = (POC_DIR / "prompts" / "sleep_reflection_system_prompt.txt").read_text(encoding="utf-8")
    reflection_grammar = (POC_DIR / "grammar" / "reflection.gbnf.template").read_text(encoding="utf-8")
    importance_grammar = (POC_DIR / "grammar" / "importance.gbnf.template").read_text(encoding="utf-8")
    TRANSCRIPT_DIR.mkdir(exist_ok=True)

    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    all_analyses = []
    for run_index in range(1, num_runs + 1):
        print(f"\n========== [{mode}] 第 {run_index}/{num_runs} 次（{target_game_minutes} 分鐘）==========")
        result = des.run_one_simulation(
            run_index, target_game_minutes, template, grammar,
            reflection_template, reflection_grammar, importance_grammar,
        )
        out_path = TRANSCRIPT_DIR / f"nested_action_{mode}_run{run_index}_{timestamp}.json"
        out_path.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
        analysis = analyze_run(result["events"])
        all_analyses.append(analysis)
        print(f"第 {run_index} 次完成，{result['num_events']} 個事件，已存到 {out_path}")
        for name, stats in analysis.items():
            print(f"  {name}: n={stats['n']} same_rate={stats['same_rate']} cycle2_rate={stats['cycle2_rate']} "
                  f"null_target_rate={stats['null_target_rate']}（需對象動作共 {stats['needs_target_n']} 次）")

    agg = aggregate(all_analyses)
    print(f"\n========== [{mode}] 彙整（跨輪次，依決策次數加權）==========")
    for name, a in agg.items():
        same_rate = a["same"] / a["n"] if a["n"] else None
        cyc_rate = a["cyc"] / a["cyc_n"] if a["cyc_n"] else None
        null_rate = a["null_n"] / a["needs_target_n"] if a["needs_target_n"] else None
        print(f"  {name}: 決策數(n-1)={a['n']} same_rate={(same_rate or 0):.2%} "
              f"cycle2_rate={(cyc_rate or 0):.2%} null_target_rate={(null_rate or 0):.2%}"
              f"（需對象動作共 {a['needs_target_n']} 次）")
    return agg


def main() -> None:
    mode_arg = sys.argv[1] if len(sys.argv) > 1 else "both"
    target_game_minutes = int(sys.argv[2]) if len(sys.argv) > 2 else 300
    num_runs = int(sys.argv[3]) if len(sys.argv) > 3 else 4

    modes = ["baseline", "nested"] if mode_arg == "both" else [mode_arg]
    results = {}
    for mode in modes:
        if mode == "baseline":
            template_path = POC_DIR / "prompts" / "villager_system_prompt.txt"
            grammar_path = POC_DIR / "grammar" / "turn_duration_experiment.gbnf.template"
        elif mode == "nested":
            template_path = POC_DIR / "prompts" / "villager_system_prompt_nested_experiment.txt"
            grammar_path = POC_DIR / "grammar" / "turn_nested_experiment.gbnf.template"
        else:
            raise ValueError(f"未知模式：{mode}")
        results[mode] = run_mode(mode, template_path, grammar_path, target_game_minutes, num_runs)

    if len(results) == 2:
        print("\n========== baseline vs nested 對照 ==========")
        for name in results["baseline"]:
            b, n = results["baseline"][name], results["nested"].get(name)
            if not n:
                continue
            b_same = b["same"] / b["n"] if b["n"] else 0
            n_same = n["same"] / n["n"] if n["n"] else 0
            b_null = b["null_n"] / b["needs_target_n"] if b["needs_target_n"] else 0
            n_null = n["null_n"] / n["needs_target_n"] if n["needs_target_n"] else 0
            print(f"  {name}: same_rate {b_same:.2%} -> {n_same:.2%}　"
                  f"null_target_rate {b_null:.2%} -> {n_null:.2%}")


if __name__ == "__main__":
    main()
