"""DPO資料重新蒐集（money_fail情境，v3）：2026-08-09。

修正v1/v2的問題——追查發現dpo_chosen_money_fail_v1.json當初是用run_des_sim.py的
「無grammar對照模式」收集的，跟正式決策的grammar硬約束路徑prompt格式不一致
（已用test_money_hint_nogrammar.py直接因果驗證過：格式對上，訓練學到的偏好才會
表現出來）。這支腳本明確強制USE_GRAMMAR=True，不依賴預設值，避免同樣的事再發生。

情境設計沿用v1/v2驗證過的做法：五人金錢分散到有高有低，涵蓋吃不起/喝不起/治不起
的不同區間，讓money_fail_switch（付得起其中一項就切過去）跟money_fail_perform
（兩項都付不起，該轉去工作類動作）兩種情況都有機會被真實模型跑出來。

用法：python3 dpo_collection_money_fail_v3.py <trial_num>
"""
import sys
import json
import time
import re
from collections import Counter
from pathlib import Path

POC_DIR = Path(__file__).parent
sys.path.insert(0, str(POC_DIR))
import run_des_sim as rds  # noqa: E402
import characters as c  # noqa: E402

assert rds.USE_GRAMMAR, "USE_GRAMMAR 應該預設就是 True，這裡只是雙重確認"
rds.USE_GRAMMAR = True  # 2026-08-09：明確寫死，不依賴預設值——這正是v1出問題的根源

if len(sys.argv) != 2:
    print("用法: python3 dpo_collection_money_fail_v3.py <trial_num>")
    sys.exit(1)
trial_num = sys.argv[1]

template = (POC_DIR / "prompts" / "villager_system_prompt.txt").read_text(encoding="utf-8")
grammar = (POC_DIR / "grammar" / "turn_duration_experiment.gbnf.template").read_text(encoding="utf-8")
reflection_template = (POC_DIR / "prompts" / "sleep_reflection_system_prompt.txt").read_text(encoding="utf-8")
reflection_grammar = (POC_DIR / "grammar" / "reflection.gbnf.template").read_text(encoding="utf-8")
importance_grammar = (POC_DIR / "grammar" / "importance.gbnf.template").read_text(encoding="utf-8")

# 五人金錢分散，涵蓋不同的「付不起什麼」區間：
# 阿吉/小梅偏低（吃不起也喝不起，money_fail_perform情境）；
# 鐵牛中低（可能吃得起但喝不起，money_fail_switch情境）；
# 老周/阿蘭中等（有錢但不夠治療）。
_OVERRIDE_PLAN = {
    "aji":  {"physiology": {"bleeding": False, "sprained_ankle": False, "money": 3}},
    "mei":  {"physiology": {"bleeding": False, "sprained_ankle": False, "money": 4}},
    "tie":  {"physiology": {"bleeding": True,  "sprained_ankle": False, "money": 9}},
    "zhou": {"physiology": {"bleeding": False, "sprained_ankle": True,  "money": 20}},
    "alan": {"physiology": {"bleeding": False, "sprained_ankle": False, "money": 25}},
}

_orig_load = c.load_all_characters


def _load_with_overrides():
    cast = _orig_load()
    for cid, ov in _OVERRIDE_PLAN.items():
        cast[cid]["physiology"].update(ov["physiology"])
    return cast


c.load_all_characters = _load_with_overrides
rds.c.load_all_characters = _load_with_overrides

rds.START_DAY, rds.START_HOUR, rds.START_MINUTE = 3, 9, 0
rds.MAX_EVENTS_SAFETY_CAP = 800
TARGET_GAME_MINUTES = 1440  # 1天，先求量夠、時間可控，不求跨天機制驗證（那不是這次目的）

label_tag = f"dpo_money_fail_v3_trial{trial_num}"
print(f"========== {label_tag}（{TARGET_GAME_MINUTES}遊戲分鐘，grammar模式，五人金錢分散）"
      f" ==========", flush=True)
print(f"USE_GRAMMAR = {rds.USE_GRAMMAR}", flush=True)
t0 = time.time()
out_path = rds.TRANSCRIPT_DIR / f"{label_tag}.json"
result = rds.run_one_simulation(
    1, TARGET_GAME_MINUTES, template, grammar,
    reflection_template, reflection_grammar, importance_grammar,
    incremental_out_path=out_path,
)
elapsed = time.time() - t0
result["trial_num"] = trial_num
result["use_grammar"] = True  # 2026-08-09：明確記錄在資料檔裡，避免以後又要回頭猜
out_path.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
print(f"完成：{result['num_events']} 個事件，耗時 {elapsed:.1f}s，中斷次數={result['interrupt_count']}")

events = result["events"]
parse_ok_rate = sum(1 for e in events if e["parse_ok"]) / len(events) if events else 0
print(f"parse_ok率: {parse_ok_rate:.3f}")

action_counter = Counter(
    e["output"]["intent"]["action"] for e in events if e.get("output") and e.get("parse_ok")
)
print("動作分布：")
for a, n in action_counter.most_common(15):
    print(f"  {a}: {n} ({n / len(events) * 100:.1f}%)")


def failed_reason(p):
    if not p:
        return ""
    m = re.search(r"上一個動作結果】\n(.*?)\n\n【", p, re.S)
    return m.group(1).strip() if m else ""


clean = [e for e in events if "失敗" in failed_reason(e.get("prompt"))]
per_char = Counter(e["name"] for e in clean)
reason_action = Counter(failed_reason(e["prompt"]).split(" →")[0] for e in clean)
print(f"\n乾淨rejected候選：{len(clean)}/{len(events)}")
print("按角色分布：", dict(per_char))
print("按失敗動作分布：", dict(reason_action))
print(f"輸出檔：{out_path}")
