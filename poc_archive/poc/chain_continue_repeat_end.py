"""Ailley POC 實驗版 — repeat_end：串接多輪續寫，改呼叫 continue_director_poc_repeat_end.py

跟正式版 chain_continue.py 的唯一差異是 subprocess 呼叫的目標腳本，用來驗證
「偵測到重複也當成收尾訊號」這個機制對長鏈重複率跟自然收尾比例的影響。

用法：
  python chain_continue_repeat_end.py <初始 transcript.json> [續寫輪數，預設 5] [每輪回合數，預設 6]
"""

import json
import re
import subprocess
import sys
import time
from pathlib import Path

POC_DIR = Path(__file__).parent


def run_chain(initial_path: Path, max_rounds: int, turns_per_round: int) -> dict:
    current_path = initial_path
    log = {"initial": str(initial_path.name), "rounds": [], "stopped_reason": None}

    for round_i in range(1, max_rounds + 1):
        proc = subprocess.run(
            [sys.executable, str(POC_DIR / "continue_director_poc_repeat_end.py"), str(current_path), str(turns_per_round)],
            capture_output=True, text=True, cwd=POC_DIR,
        )
        stdout = proc.stdout

        if proc.returncode != 0:
            log["stopped_reason"] = f"round {round_i}: 續寫腳本中止（{stdout.strip().splitlines()[-1] if stdout.strip() else proc.stderr.strip()}）"
            break

        m_path = re.search(r"已存至 (transcripts/\S+\.json)", stdout)
        m_elapsed = re.search(r"耗時 ([\d.]+) 秒", stdout)
        if not m_path:
            log["stopped_reason"] = f"round {round_i}: 找不到輸出檔案路徑，原始輸出：{stdout[-500:]}"
            break

        new_path = POC_DIR / m_path.group(1)
        elapsed = float(m_elapsed.group(1)) if m_elapsed else None

        record = json.loads(new_path.read_text(encoding="utf-8"))
        total_turns = len(record["script"]["turns"])

        tactics = [t.get("tactic") for t in record["script"]["turns"][-turns_per_round:]]
        leaked = "遊戲結束" in stdout
        leak_line = None
        if leaked:
            m_leak = re.search(r"=== 第 \d+ 回合：.*遊戲結束 ===", stdout)
            leak_line = m_leak.group(0) if m_leak else "（偵測到遊戲結束訊息，但抓不到細節）"

        natural_ended = "對話自然收尾" in stdout
        natural_end_line = None
        if natural_ended:
            m_end = re.search(r"=== 第 \d+ 回合：對話自然收尾[^\n]*===", stdout)
            natural_end_line = m_end.group(0) if m_end else None

        warnings = re.findall(r"\[警訊\][^\n]*", stdout)
        # 轉發 repeat_end 的判斷行，這是這個實驗版本真正想觀察的東西（懷疑度卡住/重複
        # 觸發哪一種），不能再讓它消失在子行程 stdout 裡（見 batch_regen 那次踩過的坑）。
        repeat_end_log = re.findall(r"\[(?:repeat_end|判斷)\][^\n]*", stdout)
        for line in repeat_end_log:
            print(f"  {line}")

        log["rounds"].append({
            "round": round_i,
            "file": str(new_path.name),
            "elapsed_sec": elapsed,
            "total_turns": total_turns,
            "new_tactics": tactics,
            "warnings": warnings,
            "repeat_end_log": repeat_end_log,
            "leaked": leaked,
            "leak_line": leak_line,
            "natural_ended": natural_ended,
            "natural_end_line": natural_end_line,
        })

        status = "leaked" if leaked else ("natural_end" if natural_ended else "continuing")
        print(f"  round {round_i}: {new_path.name} | {elapsed}s | 累計 {total_turns} 回合 | 新戰術 {tactics} | {status}")

        if leaked:
            log["stopped_reason"] = f"round {round_i}: {leak_line}"
            break
        if natural_ended:
            log["stopped_reason"] = f"round {round_i}: 自然收尾（累計 {total_turns} 回合）"
            break

        current_path = new_path
    else:
        log["stopped_reason"] = f"跑滿 {max_rounds} 輪，未洩漏也未自然收尾"

    return log


def main():
    initial_path = Path(sys.argv[1])
    max_rounds = int(sys.argv[2]) if len(sys.argv) > 2 else 5
    turns_per_round = int(sys.argv[3]) if len(sys.argv) > 3 else 6

    print(f"[串接開始] 起點：{initial_path.name}，最多續寫 {max_rounds} 輪，每輪 {turns_per_round} 回合")
    start = time.perf_counter()
    log = run_chain(initial_path, max_rounds, turns_per_round)
    elapsed_total = time.perf_counter() - start
    log["total_wall_sec"] = round(elapsed_total, 2)

    print(f"[串接結束] 總耗時 {elapsed_total:.2f} 秒，結束原因：{log['stopped_reason']}")

    out_path = POC_DIR / "transcripts" / f"chain_log_{initial_path.stem}.json"
    out_path.write_text(json.dumps(log, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"[記錄] 串接日誌已存至 {out_path.relative_to(POC_DIR)}")


if __name__ == "__main__":
    main()
