"""Ailley POC — Agent Loop 多天模擬驅動腳本

每次呼叫都讀取（或第一次執行時初始化）persistent 的角色名單／狀態，接續著跑 N 天，
每天結束就存檔一次。刻意設計成「就算分成多次完全獨立的執行」也能正確接續狀態——
這才是「跨回合延續」真正要驗證的能力，不是靠單次執行內的迴圈。

用法：
  python run_multiday.py [要模擬幾天，預設 3]
"""

import sys

import memory_store
from agent_loop import run_one_day
from characters import generate_fixed_roster


def main() -> None:
    num_days = int(sys.argv[1]) if len(sys.argv) > 1 else 3

    roster = memory_store.load_roster(generate_fixed_roster)
    state = memory_store.load_state()

    print(f"[run_multiday] 從第 {state['current_day']} 天接續，本次執行要跑 {num_days} 天")

    summaries = []
    for _ in range(num_days):
        summary = run_one_day(roster, state)
        memory_store.save_state(state)
        summaries.append(summary)

    print(f"\n########## 本次執行總結（第 {summaries[0]['day']}～{summaries[-1]['day']} 天）##########")
    for s in summaries:
        print(f"  第 {s['day']} 天｜相遇 {s['total_encounters']} 組｜洩漏命中 {s['total_leak_hits']} 次｜"
              f"耗時 {s['elapsed_sec']}s")
    print(f"  目前累積到第 {state['current_day']} 天，下一個全域記憶編號：{state['next_global_index']}")


if __name__ == "__main__":
    main()
