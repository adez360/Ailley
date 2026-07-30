"""Ailley POC — poc_village_sim 離散事件模擬（DES）引擎，含「中斷正在進行中的長動作」機制。

跟 run_tick_sim.py（固定 15 分鐘 tick、五人平行決策）不同：這裡每個角色的行動有自己的
duration_minutes，用 heapq 依時間排程，不同角色的下一次決定時間點各自不同。兩套引擎
先並存觀察，還沒決定要不要用這套取代 run_tick_sim.py（見 note）。

中斷機制設計與驗證過程見
note/40-規劃與路線圖/POC 紀錄 - poc_village_sim 五人整合試跑（新版 AI 架構首測）.md
「同 tick 互動設計：A 攻擊/搭話 B，B 該如何反應？」一節：
- 攻擊/搶劫等 WITNESS_WORTHY_ACTIONS 命中「同地點」的目標時，若目標正在進行中的長動作
  尚未到期，強制作廢該動作、位置退回中斷前的地點、提前排一次重新決定。
- heap 用 (time, priority, seq, cid) 四元組：priority 0＝中斷觸發，1＝正常排定的下一次
  決定（同一時間點時中斷優先處理）；seq 是每個角色目前有效事件的版本號，用來對舊事件
  做 lazy deletion（heapq 不支援真刪除）。
- 中斷只在攻擊者與受害者同地點時觸發——強制注入測試發現，若跨地點觸發，grammar 的
  target 候選清單只從「同地點可見角色」組出來，會生出「情緒上想反擊、但 target 是 null」
  這種不合理情境，所以同地點是必要前提。

生理數值/無聊度/攻擊/睡眠反思等規則全部重用 run_tick_sim.py 已驗證過的公式與函式，
不重新發明——差異只在排程邏輯（固定 tick → 事件佇列）。

用法：
  python run_des_sim.py [遊戲分鐘數上限，預設 300] [重複次數，預設 1]
"""

import copy
import heapq
import json
import sys
import time
from datetime import datetime
from pathlib import Path

POC_DIR = Path(__file__).parent
sys.path.insert(0, str(POC_DIR))
import characters as c
import run_tick_sim as rts  # 重用已驗證的常數與函式，不重新發明

TRANSCRIPT_DIR = POC_DIR / "transcripts"
START_DAY, START_HOUR, START_MINUTE = 3, 19, 40

DURATION_INSTRUCTION = (
    "\n\n【新增欄位：intent.duration_minutes】\n"
    "這次多一個欄位：`intent.duration_minutes`，代表你決定要花多少分鐘做這件事——"
    "喝口水可能 1-2 分鐘、跟人聊幾句可能 5-15 分鐘、採草藥或打獵可能 60-180 分鐘、"
    "睡一覺可能 300-540 分鐘、打一場架可能 1-5 分鐘。請依照這個動作在現實中大概需要"
    "多久，給一個合理的分鐘數，不用刻意湊整數，也不用被上面這些例子的數字限制死。\n"
    "\n【提醒】如果你發現自己已經連續選擇同一種動作很多次（可以從無聊度、飢餓/口渴這些"
    "數值感覺出來），想想看真實生活中的人會不會這樣一直重複下去——通常會膩、會想換點"
    "別的事做。這只是提醒，不是規定，最終還是由你自己判斷這個角色在當下真正會怎麼做。\n"
)

# 攻擊/搶劫等命中同地點目標時，若目標正在進行中的動作還沒到期，強制中斷——沿用既有的
# WITNESS_WORTHY_ACTIONS，不另外發明一套判準（2026-07-29 跟使用者討論定案）
INTERRUPTIBLE_TRIGGER_ACTIONS = rts.WITNESS_WORTHY_ACTIONS
# 被中斷時，若目標原本的動作是移動類，位置退回中斷前的位置（「先求正確不求擬真」）
LOCATION_CHANGING_ACTIONS = {"移動", "奔跑"}
# 安全上限，避免卡迴圈情境下無限跑下去（DES 沒有固定 tick 數可以當終止條件）
MAX_EVENTS_SAFETY_CAP = 400


def total_minutes_to_time(total_minutes: int) -> tuple[str, int]:
    day, hour, minute = rts.advance_time(START_DAY, START_HOUR, START_MINUTE, total_minutes)
    return rts.format_time(day, hour, minute), day


def run_one_simulation(run_index: int, target_game_minutes: int, template: str, grammar: str,
                        reflection_template: str, reflection_grammar: str, importance_grammar: str) -> dict:
    cast = c.load_all_characters()
    relationships = c.load_relationships()
    name_to_id = {v["name"]: cid for cid, v in cast.items()}

    home_names = [c.home_name(v["name"]) for v in cast.values()]
    location_names = rts.SHARED_LOCATIONS + home_names
    location_list_str = "、".join(location_names)

    state = {}
    for cid in rts.ORDER:
        state[cid] = {
            "location": cast[cid]["location"],
            "last_emotion": cast[cid]["last_emotion"],
            "last_action_result": cast[cid]["last_action_result"],
            "physiology": copy.deepcopy(cast[cid]["physiology"]),
            "last_action": None,
            "last_declaration": None,  # {"time","action","target_id","speech"}，給「上一刻對你做了什麼」用
            "today_day": START_DAY,
            "today_actions": set(),
            "today_locations": {cast[cid]["location"]},
            "today_people": set(),
            "personality": copy.deepcopy(cast[cid]["personality"]),
            "personality_drifted": False,
            "memories": [],
            "current_plan": "",
            "last_sleep_event": 0,
            "is_sleeping": False,
            "alive": True,
            "death_time": None,
            "seq": 0,
            "in_progress": None,  # {"action","target","start_time","end_time","start_location"}
            "interrupt_note": None,
        }

    heap = [(0, 1, 0, cid) for cid in rts.ORDER]
    heapq.heapify(heap)
    events_log = []
    interrupt_count = 0
    run_start = time.time()

    while heap and len(events_log) < MAX_EVENTS_SAFETY_CAP:
        now, priority, seq, cid = heapq.heappop(heap)
        if now > target_game_minutes:
            break
        me = state[cid]
        if seq != me["seq"]:
            continue  # 舊事件已被中斷機制作廢，跳過（lazy deletion）
        villager = cast[cid]

        current_time, day = total_minutes_to_time(now)
        if day != me["today_day"]:
            me["today_actions"], me["today_locations"], me["today_people"] = set(), {me["location"]}, set()
            me["today_day"] = day

        visible = [
            {"id": o, "activity": f"在「{state[o]['location']}」"}
            for o in rts.ORDER if o != cid and state[o]["alive"] and state[o]["location"] == me["location"]
        ]

        was_interrupted = me["interrupt_note"] is not None
        if was_interrupted:
            recent_event = me["interrupt_note"]
            me["interrupt_note"] = None
        else:
            recent_event = "上一刻村子裡各自在忙自己的事，沒有人特別找你"
            for o in rts.ORDER:
                if o == cid:
                    continue
                od = state[o]["last_declaration"]
                if od and od["target_id"] == cid:
                    speaker_name = cast[o]["name"]
                    if od["speech"]:
                        recent_event = f"上一刻，{speaker_name}對你「{od['action']}」，說：「{od['speech']}」"
                    else:
                        recent_event = f"上一刻，{speaker_name}對你做了「{od['action']}」的動作"
                    break

        live_villager = {**villager, "physiology": me["physiology"], "personality": me["personality"]}
        if me["personality_drifted"]:
            live_villager["personality_text"] = None
        recent_memory = "（尚無長期記憶）" if not me["memories"] else "；".join(
            m["content"] for m in sorted(me["memories"], key=lambda m: -m["importance"])[:3]
        )

        prompt = c.build_villager_prompt(
            template, world_lore=rts.WORLD_LORE_PLACEHOLDER, villager=live_villager, relationships=relationships,
            current_time=current_time, location=me["location"], visible=visible, recent_event=recent_event,
            last_emotion=me["last_emotion"], last_action_result=me["last_action_result"],
            recent_memory=recent_memory, location_list=location_list_str, today_plan=me["current_plan"],
        ) + DURATION_INSTRUCTION

        grammar_for_call = rts.build_grammar_for_call(
            grammar, [cast[v["id"]]["name"] for v in visible], location_names
        )
        payload = {"prompt": prompt, "grammar": grammar_for_call, "temperature": 0.7, "top_p": 0.9,
                   "top_k": 40, "repeat_penalty": 1.0, "repeat_last_n": 256, "n_predict": 300, "cache_prompt": True}
        tag = "⚡中斷重決" if was_interrupted else ""
        label = f"run{run_index} [{current_time}] {villager['name']}{tag}"
        out, parse_ok, elapsed, meta = rts.call_llm_with_retry(payload, label)

        events_log.append({
            "event_index": len(events_log), "time": now, "id": cid, "name": villager["name"],
            "current_time": current_time, "location_before": me["location"], "was_interrupted": was_interrupted,
            "elapsed_sec": round(elapsed, 2), "parse_ok": parse_ok, "output": out,
            "truncated": meta.get("truncated"), "tokens_evaluated": meta.get("tokens_evaluated"),
            # 決策當下（做這個決定之前）的生理快照——2026-07-30 補上，讓「流血/扭到腳還
            # 選奔跑」這種硬規則違規可以事後從 transcript 直接稽核，不用重跑一次模擬。
            "physiology_before": {
                "health": me["physiology"]["health"], "bleeding": me["physiology"].get("bleeding", False),
                "sprained_ankle": me["physiology"].get("sprained_ankle", False), "money": me["physiology"]["money"],
            },
        })

        if not parse_ok:
            me["seq"] += 1
            heapq.heappush(heap, (now + 10, 1, me["seq"], cid))
            continue

        action = out["intent"]["action"]
        duration = out["intent"]["duration_minutes"]
        new_location = out["intent"]["location"]
        target_name = out["intent"]["target"]
        target_id = rts.normalize_target(target_name, name_to_id)
        emotion = out["emotion"]
        phys = me["physiology"]
        old_location = me["location"]

        print(f"[{label}] {action}（{duration}分）{f'-> {target_name}' if target_name else ''} "
              f"@{new_location} [{emotion}] 血{phys['health']:.0f} 飢{phys['hunger']:.0f} "
              f"力{phys['stamina']:.0f} 悶{phys['boredom']:.0f} {elapsed:.2f}s")

        # --- 生理數值：重用 rts 的每-tick 公式，依 duration 換算成幾個 15 分鐘份反覆套用 ---
        sub_ticks = max(1, round(duration / rts.TICK_MINUTES))
        self_home = c.home_name(villager["name"])
        valid_sleep = action == "睡覺" and new_location == self_home
        attack_hit = None
        for _ in range(sub_ticks):
            phys["hunger"] = rts.clamp(phys["hunger"] + rts.HUNGER_PER_TICK)
            phys["thirst"] = rts.clamp(phys["thirst"] + rts.THIRST_PER_TICK)
            if action == "睡覺":
                phys["stamina"] = rts.clamp(phys["stamina"] + (rts.STAMINA_SLEEP_DELTA if valid_sleep else rts.STAMINA_NAP_DELTA))
            elif action == "攻擊" and target_id:
                phys["health"] = rts.clamp(phys["health"] + rts.ATTACK_SELF_HEALTH_DELTA)
                phys["stamina"] = rts.clamp(phys["stamina"] + rts.random.randint(*rts.ATTACK_SELF_STAMINA_DELTA_RANGE))
            else:
                phys["stamina"] = rts.clamp(phys["stamina"] + rts.stamina_delta(action))
        if action == "吃飯":
            phys["hunger"] = rts.clamp(phys["hunger"] - rts.EAT_HUNGER_RELIEF)
        if action == "喝酒":
            phys["thirst"] = rts.clamp(phys["thirst"] - rts.DRINK_THIRST_RELIEF)
        if action == "治療" and new_location == "藥草鋪" and phys["money"] >= rts.HEAL_COST:
            phys["money"] -= rts.HEAL_COST
            phys["health"] = rts.clamp(phys["health"] + rts.HEAL_IMMEDIATE_BONUS)
            phys["bleeding"] = False
            phys["severe_injury"] = False
            phys["recovering"] = phys["health"] < 100

        # --- 攻擊命中判定：只有目標在同地點才會真的打中（跟中斷機制共用同地點前提）---
        target_same_location = target_id and state[target_id]["alive"] and state[target_id]["location"] == old_location
        if action == "攻擊" and target_same_location:
            attack_hit = rts.random.random() < rts.ATTACK_HIT_CHANCE
            if attack_hit:
                target_phys = state[target_id]["physiology"]
                target_phys["health"] = rts.clamp(target_phys["health"] + rts.random.randint(*rts.ATTACK_TARGET_HEALTH_DELTA_RANGE))
                if rts.random.random() < rts.ATTACK_BLEED_CHANCE:
                    target_phys["bleeding"] = True
                if target_phys["health"] <= 0 and state[target_id]["alive"]:
                    state[target_id]["alive"] = False
                    state[target_id]["death_time"] = now
                    print(f"    {cast[target_id]['name']} 生命值歸零，死亡（{current_time}）")

        if phys["bleeding"]:
            phys["health"] = rts.clamp(phys["health"] + rts.BLEEDING_HEALTH_DELTA)
        if phys.get("severe_injury"):
            phys["health"] = rts.clamp(phys["health"] + rts.SEVERE_INJURY_HEALTH_DELTA)
        if phys.get("recovering"):
            phys["health"] = rts.clamp(phys["health"] + rts.RECOVERING_HEALTH_DELTA)
            if phys["health"] >= 100:
                phys["recovering"] = False
        if phys["health"] <= 0 and me["alive"]:
            me["alive"] = False
            me["death_time"] = now
            print(f"    {villager['name']} 生命值歸零，死亡（{current_time}）")

        # --- 血量持續偏低的次數：補 health_tier_text 只在 ≤20 才開始講的空窗期（2026-07-30）---
        if phys["health"] < 50:
            phys["health_decline_streak"] = phys.get("health_decline_streak", 0) + 1
        else:
            phys["health_decline_streak"] = 0

        # --- 無聊度：base 依 duration 縮放，五個「新鮮感」項目各只算一次 ---
        boredom_delta = 2 * sub_ticks
        if action == me["last_action"]:
            boredom_delta += 3
        if target_id and target_id not in me["today_people"]:
            boredom_delta -= 25
        if new_location not in me["today_locations"]:
            boredom_delta -= 15
        if action not in me["today_actions"]:
            boredom_delta -= 10
        if any(
            state[o]["last_declaration"] and state[o]["last_declaration"]["action"] in rts.WITNESS_WORTHY_ACTIONS
            and state[o]["location"] == old_location
            for o in rts.ORDER if o != cid and state[o]["alive"]
        ):
            boredom_delta -= 10
        phys["boredom"] = rts.clamp(phys["boredom"] + boredom_delta)

        target_note = f"（對 {cast[target_id]['name']}）" if target_id else ""
        if attack_hit is True:
            me["last_action_result"] = f"{action}{target_note} → 打中了"
        elif attack_hit is False:
            me["last_action_result"] = f"{action}{target_note} → 揮空了"
        else:
            me["last_action_result"] = f"{action}{target_note} → 已宣告（DES 引擎，未經完整 guardrail 判定）"

        me["today_actions"].add(action)
        me["today_locations"].add(new_location)
        if target_id:
            me["today_people"].add(target_id)
        me["last_action"] = action
        me["location"] = new_location
        me["last_emotion"] = emotion
        me["last_declaration"] = {"time": now, "action": action, "target_id": target_id, "speech": out["speech"]}

        # --- 睡眠反思：只在「一段連續睡眠的第一個事件」觸發一次（跟 run_tick_sim.py 同邏輯）；
        # 體力耗盡（<=0）時視為強制昏睡，一樣觸發反思——2026-07-30 發現部分角色幾乎永遠不會
        # 主動選擇睡覺，靠「選擇睡覺」觸發反思的機制對他們形同虛設，補這條路保底一定會有
        # 觸發到的機會，同時給一次比自願睡覺少的體力恢復（帶懲罰性質）。---
        collapsed = phys["stamina"] <= 0 and not valid_sleep and not me["is_sleeping"]
        if collapsed:
            phys["stamina"] = rts.clamp(phys["stamina"] + rts.STAMINA_COLLAPSE_RECOVERY)
        if (valid_sleep and not me["is_sleeping"]) or collapsed:
            today_events_text = rts.build_today_events_text(
                cid,
                [{"tick": e["event_index"], "id": e["id"], "current_time": e["current_time"],
                  "parse_ok": e["parse_ok"], "output": e["output"]} for e in events_log],
                me["last_sleep_event"], len(events_log) - 1,
            )
            reflection = rts.run_sleep_reflection(
                cid, live_villager, today_events_text,
                reflection_template, reflection_grammar, importance_grammar, label,
            )
            if reflection:
                for dim, delta_value in reflection["personality_delta"].items():
                    me["personality"][dim] = rts.clamp(me["personality"][dim] + delta_value)
                if any(reflection["personality_delta"].values()):
                    me["personality_drifted"] = True
                me["memories"].append({
                    "event_index": len(events_log) - 1, "importance": reflection["importance"],
                    "content": reflection["long_term_memory"],
                })
                me["current_plan"] = reflection["today_plan"]
                me["last_sleep_event"] = len(events_log) - 1
                tag = "（體力耗盡昏睡）" if collapsed else ""
                print(f"[{label}] 睡眠反思{tag}：{reflection['reflection']}｜人格變動 {reflection['personality_delta']}｜"
                      f"今天想做：{reflection['today_plan']}")
        me["is_sleeping"] = valid_sleep

        # --- 中斷機制：命中同地點目標、且動作屬於 WITNESS_WORTHY_ACTIONS，
        # 若目標正在進行中的動作尚未到期，強制作廢並提前重新決定 ---
        if target_id and action in INTERRUPTIBLE_TRIGGER_ACTIONS and target_same_location:
            victim = state[target_id]
            vip = victim["in_progress"]
            if victim["alive"] and vip and vip["end_time"] > now:
                if vip["action"] in LOCATION_CHANGING_ACTIONS:
                    victim["location"] = vip["start_location"]
                victim["interrupt_note"] = (
                    f"上一刻，你正在「{vip['action']}」，但被{villager['name']}的「{action}」打斷"
                    + (f"，說：「{out['speech']}」" if out["speech"] else "")
                )
                victim["in_progress"] = None
                victim["seq"] += 1
                heapq.heappush(heap, (now, 0, victim["seq"], target_id))
                interrupt_count += 1
                print(f"    ⚡ 中斷觸發：{cast[target_id]['name']} 原本的「{vip['action']}」"
                      f"（預計 {total_minutes_to_time(vip['end_time'])[0]} 才結束）被作廢，提前重新決定")

        if me["alive"]:
            me["in_progress"] = {"action": action, "target": target_id, "start_time": now,
                                  "end_time": now + duration, "start_location": old_location}
            me["seq"] += 1
            heapq.heappush(heap, (now + duration, 1, me["seq"], cid))

    run_elapsed = time.time() - run_start
    return {
        "run_index": run_index, "target_game_minutes": target_game_minutes,
        "run_elapsed_sec": round(run_elapsed, 2), "num_events": len(events_log),
        "interrupt_count": interrupt_count, "events": events_log,
        "final_memories": {cid: state[cid]["memories"] for cid in rts.ORDER},
        "final_personality": {cid: state[cid]["personality"] for cid in rts.ORDER},
        "death_times": {cid: state[cid]["death_time"] for cid in rts.ORDER if not state[cid]["alive"]},
    }


def main() -> None:
    target_game_minutes = int(sys.argv[1]) if len(sys.argv) > 1 else 300
    num_runs = int(sys.argv[2]) if len(sys.argv) > 2 else 1

    template = (POC_DIR / "prompts" / "villager_system_prompt.txt").read_text(encoding="utf-8")
    grammar = (POC_DIR / "grammar" / "turn_duration_experiment.gbnf.template").read_text(encoding="utf-8")
    reflection_template = (POC_DIR / "prompts" / "sleep_reflection_system_prompt.txt").read_text(encoding="utf-8")
    reflection_grammar = (POC_DIR / "grammar" / "reflection.gbnf.template").read_text(encoding="utf-8")
    importance_grammar = (POC_DIR / "grammar" / "importance.gbnf.template").read_text(encoding="utf-8")
    TRANSCRIPT_DIR.mkdir(exist_ok=True)

    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    all_runs = []
    for run_index in range(1, num_runs + 1):
        print(f"\n========== 第 {run_index}/{num_runs} 次 DES 模擬開始（遊戲內 {target_game_minutes} 分鐘）==========")
        result = run_one_simulation(
            run_index, target_game_minutes, template, grammar,
            reflection_template, reflection_grammar, importance_grammar,
        )
        all_runs.append(result)
        out_path = TRANSCRIPT_DIR / f"des_sim_run{run_index}_{timestamp}.json"
        out_path.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"第 {run_index} 次模擬完成，{result['num_events']} 個事件、"
              f"{result['interrupt_count']} 次中斷，耗時 {result['run_elapsed_sec']}s，已存到 {out_path}")

    print(f"\n全部完成，共 {num_runs} 次，逐輪耗時：{[r['run_elapsed_sec'] for r in all_runs]}，"
          f"逐輪中斷次數：{[r['interrupt_count'] for r in all_runs]}")


if __name__ == "__main__":
    main()
