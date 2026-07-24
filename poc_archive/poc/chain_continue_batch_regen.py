"""Ailley POC 實驗版 — batch_regen：串接多輪續寫，改呼叫 continue_director_poc_batch_regen.py

跟正式版 chain_continue.py 的差異：
  1. subprocess 呼叫的目標腳本換成 continue_director_poc_batch_regen.py。
  2. 額外把子行程輸出裡 [batch_regen] 開頭的診斷行轉發出來、存進 log 的 regen_log 欄位——
     修掉這次驗證 repeat_guard 時發現的既有 bug：run_chain() 原本只解析、印自己組的摘要行，
     完全不轉發子行程的原始 stdout，導致重複偵測有沒有觸發、有沒有真的重打，永遠進不了 log，
     只能靠事後手動單獨重跑才能確認。

重複呼叫 continue_director_poc_batch_regen.py，每次都接在上一次輸出的最新 transcript 後面，
直到（a）洩漏發生、遊戲照規則結束，或（b）跑滿指定的續寫輪數，藉此觀察 batch_regen 機制
對長鏈重複退化的實際效果。

用法：
  python chain_continue_batch_regen.py <初始 transcript.json> [續寫輪數，預設 5] [每輪回合數，預設 6]
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
            [sys.executable, str(POC_DIR / "continue_director_poc_batch_regen.py"), str(current_path), str(turns_per_round)],
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
        regen_attempts = record.get("regen_attempts")

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
        # 轉發 batch_regen 的診斷行，這是這個實驗版本真正想觀察的東西，不能再讓它消失在
        # 子行程 stdout 裡（見上面 docstring 記錄的 bug）。
        regen_log = re.findall(r"\[batch_regen\][^\n]*", stdout)
        for line in regen_log:
            print(f"  {line}")

        log["rounds"].append({
            "round": round_i,
            "file": str(new_path.name),
            "elapsed_sec": elapsed,
            "total_turns": total_turns,
            "regen_attempts": regen_attempts,
            "regen_log": regen_log,
            "new_tactics": tactics,
            "warnings": warnings,
            "leaked": leaked,
            "leak_line": leak_line,
            "natural_ended": natural_ended,
            "natural_end_line": natural_end_line,
        })

        status = "leaked" if leaked else ("natural_end" if natural_ended else "continuing")
        print(f"  round {round_i}: {new_path.name} | {elapsed}s | 累計 {total_turns} 回合 | "
              f"regen_attempts={regen_attempts} | 新戰術 {tactics} | {status}")

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
