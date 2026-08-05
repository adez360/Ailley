"""Ailley POC — poc_village_sim 多 tick 行為觀察腳本（簡化版引擎，純 prompt-only 取樣）

用途：連續跑 N 個 tick、重複 M 次獨立模擬，觀察角色行動趨勢、互動性，以及多次生成之間的
差異性。**還不是正式引擎**——沒有 guardrail 判定動作成功/失敗、沒有隨機受傷、沒有物品
分級定價，只做了讓生理數值/情緒/無聊度會隨 tick 變化的最小必要邏輯（見下方各常數區塊的
依據），目的是先確認「六維人格＋好感矩陣＋生理狀態」這套設計在多輪之後行為會不會自然
波動、會不會卡死，還不是要驗證完整世界模擬的正確性。

數值依據見 note/40-規劃與路線圖/POC 紀錄 - poc_village_sim 五人整合試跑（新版 AI 架構首測）.md
2026-07-26 補充的那節（跟使用者討論後定案）。

用法：
  python run_tick_sim.py [ticks 數，預設 20] [重複次數，預設 5]
"""

import copy
import json
import random
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from pathlib import Path

import requests

POC_DIR = Path(__file__).parent
sys.path.insert(0, str(POC_DIR))
import characters as c
import memory_store as ms

SERVER_URL = "http://127.0.0.1:8080/completion"
TRANSCRIPT_DIR = POC_DIR / "transcripts"
TICK_MINUTES = 15  # 每個 tick 代表遊戲內過了 15 分鐘

WORLD_LORE_PLACEHOLDER = (
    "（測試用臨時世界觀，非正式素材）這是一座普通的小村莊，村民依自己的日常需求與人際"
    "關係過生活，沒有特殊神明或機密設定。"
)

ORDER = ["alan", "zhou", "mei", "tie", "aji"]

# 公用地點（不含「家」——每個角色改成有自己專屬的家，見 build_grammar_for_call()／
# c.home_name()，2026-07-27 跟使用者討論定案）
SHARED_LOCATIONS = [
    "餐酒館", "涼亭", "湖泊", "長椅", "森林", "藥草叢", "服裝鋪",
    "藥草鋪", "洗心革面所", "結婚禮堂", "甘道夫石", "村莊廣場",
]

# ---------------------------------------------------------------------------
# 生理數值變化速率——先全部用固定值，不分物品/獵物等級（那些屬於正式經濟系統的內容
# 設計，現在的 Action Schema 也還沒有「吃哪一樣食物」這個欄位，之後真的要做食物分級
# 要先加 grammar 的 item 欄位，這次先不做）。
# ---------------------------------------------------------------------------

HUNGER_PER_TICK = 2   # Specify2 §7.1：滿值→危險值約 40 tick，危險值門檻設在 70，70/40≈1.75，取整數 2
THIRST_PER_TICK = 2

EAT_HUNGER_RELIEF = 40
DRINK_THIRST_RELIEF = 35
HEAL_COST = 40  # 治療固定花費，Specify1 §9 範例文字本來就用這個數字

# 貨幣制度：吃飯/喝酒要花錢，表演/採草藥/打獵能賺錢或換成可販售的物品（2026-07-31，
# 目的是測「有真實經濟代價/誘因之後，動作多樣性會不會改變」——之前吃飯喝酒完全免費、
# 賣藝/採藥/打獵完全不會真的進帳，角色沒有任何理由要在「維生」跟「賺錢」之間切換）。
EAT_COST = 6         # 吃飯要花的錢，錢不夠就吃不到（跟治療同邏輯：宣告了但沒效果）
DRINK_COST = 8       # 喝酒要花的錢
PERFORM_INCOME = 10  # 表演的賞錢，每次事件固定入帳一次，不隨時長縮放
GATHER_ITEM = ("藥草", 1)                # 採草藥每次固定拿到的物品
HUNT_ITEMS = [("獸皮", 1), ("獸肉", 1)]  # 打獵每次固定拿到的物品
SELL_PRICES = {"獸皮": 15, "獸肉": 8, "藥草": 8}  # 賣東西的收購價；背包裡沒有可賣的東西就白忙一場

# 生命值：流血/重傷持續扣血，藥草鋪治療是「一次性急救 + 之後被動慢慢恢復」，不是瞬間全滿
# （2026-07-27 跟使用者討論定案）
BLEEDING_HEALTH_DELTA = -1
SEVERE_INJURY_HEALTH_DELTA = -3
RECOVERING_HEALTH_DELTA = 1
HEAL_IMMEDIATE_BONUS = 50

# 體力消耗分級（Specify1 §3 風險表的精神：高風險高消耗，社交/文書類最低）
# 「睡覺」不在這張表裡——它的體力效果跟地點綁在一起（見主迴圈），不是單純查表。
# 「發呆」也不特別列——讓它跟其他沒特別分類的動作一樣走低消耗（STAMINA_LOW_DELTA），
# 正常流逝，不特別給恢復效果（2026-07-27 跟使用者討論定案）。
# 「攻擊」也移出這張表——它現在有自己專屬的命中判定與生命/體力公式（見下方 ATTACK_*）。
STAMINA_HIGH = {"打獵", "搶劫", "抓捕", "破壞樂器", "奔跑"}
STAMINA_MID = {"表演", "移動", "跟隨", "巡邏", "偷竊"}
# 其餘動作（說話類、需同意互動類、消費類、發呆、靜態動作）都算低消耗
STAMINA_HIGH_DELTA = -8
STAMINA_MID_DELTA = -4
STAMINA_LOW_DELTA = -1
# 8 小時睡眠要能把體力從 0 補到 100：TICK_MINUTES=15 → 8 小時＝32 tick，100/32=3.125，
# 取 4（25 tick／6.25 小時回滿，8 小時綽綽有餘，比無條件捨去到 3／32 tick 才回 96 更符合
# 「睡滿 8 小時要能回滿」的要求）
STAMINA_SLEEP_DELTA = 4   # 在自己家睡覺才拿得到這個值
STAMINA_NAP_DELTA = 1     # 選了「睡覺」但不在自己家——只能打盹
# 體力耗盡時強制昏睡的恢復量：比自願睡覺少，帶懲罰性質，用意只是保證「睡眠反思」（連帶
# 「今天想做的事」計畫）一定會有觸發到的機會——2026-07-30 發現部分角色會長期卡在同一個
# 非睡覺動作、幾乎永遠不會主動選擇睡覺，導致靠「選擇睡覺」觸發的反思機制形同虛設。
STAMINA_COLLAPSE_RECOVERY = 20

# 攻擊：命中判定 + 雙方各自的代價（2026-07-27 跟使用者討論定案）。命中率是固定值，
# 不看人格數值——Specify2 §3.1「人格參數不參與任何引擎機率運算，不影響命中率」，
# 之後真的要做角色能力差異（職業/武器）再另外設計，這次先不摻進人格。
ATTACK_HIT_CHANCE = 0.6
ATTACK_SELF_HEALTH_DELTA = -1               # 攻擊方固定扣，不管有沒有打中
ATTACK_SELF_STAMINA_DELTA_RANGE = (-4, -2)  # 攻擊方體力消耗，不管有沒有打中
ATTACK_TARGET_HEALTH_DELTA_RANGE = (-3, -1) # 只有打中才套用
ATTACK_BLEED_CHANCE = 0.15                  # 只有打中才有機會觸發，跟命中判定各自獨立擲一次

# 目擊到會被記進無聊度減免的「事件類」動作（Specify2 §7.3：目擊衝突/犯罪/表演 −10）
WITNESS_WORTHY_ACTIONS = {"表演", "攻擊", "搶劫", "偷竊", "破壞樂器", "抓捕", "大叫"}
# 舉報（2026-08-05）：改成「去洗心革面所投訴」的設計後，不再是當場衝突類事件，故意不放進
# 這個集合——一來不該讓旁觀者的無聊度也跟著減免（沒有真的「目擊」到什麼戲劇性場面），
# 二來（更重要）這個集合同時也是 run_des_sim.py 中斷觸發的基礎清單，之前拿掉之前就是
# 因為「舉報零成本＋會觸發中斷」疊加角色背景故事的世仇設定，跑出雪崩式互相中斷迴圈
# （見 note）。現在補了地點閘門/每日上限/累積門檻等真正的機制後果，但拿掉中斷觸發資格
# 這個決定維持不變——投訴不是當場對峙，沒有「對方要立刻知道並反應」的急迫性。

EMOTION_DECAY_TICKS = 5  # Specify2 §3.4：預設持續 5 tick 後自動衰減回 neutral

# ---------------------------------------------------------------------------
# 睡眠反思（Reflection）——Specify2 §8：角色睡覺時觸發一次額外呼叫，輸出反思／人格微調／
# 濃縮後的長期記憶。方案 C（跟使用者討論定案，見 note）：反思產物進 memory_store 的檢索
# 排序，但當天的原始事件（ticks_log 本來就有）另外留底，不進檢索排序。
# ---------------------------------------------------------------------------

PERSONALITY_DELTA_TOTAL_CAP = 6  # Specify2 §8：單晚總變動上限 ±6（單項 ±3 已經被 grammar 鎖死）

# 跟 poc_agent_loop/agent_loop.py 的 _IMPORTANCE_PROMPT_TEMPLATE 同一個精神，內容改成
# 村莊生活場景（原本是紅藍村獻祭博弈專用文字，已封存，不能直接沿用）
_IMPORTANCE_PROMPT_TEMPLATE = (
    "這是一位村莊居民一天生活片段的反思。\n"
    "內容：「{content}」\n"
    "請幫這段反思的重要程度打分（1 到 10 分，1 分是日常瑣事，10 分是會長期影響人際關係或"
    "人生態度的重大轉折），只需要輸出分數，不要解釋原因。"
)


def stamina_delta(action: str) -> int:
    """「睡覺」不查這張表——它的體力效果要看在不在自己家，由主迴圈另外處理。
    「發呆」也沒有特別分類，跟其他沒列進 HIGH/MID 的動作一樣走 STAMINA_LOW_DELTA。"""
    if action in STAMINA_HIGH:
        return STAMINA_HIGH_DELTA
    if action in STAMINA_MID:
        return STAMINA_MID_DELTA
    return STAMINA_LOW_DELTA


def add_inventory_item(phys: dict, item_name: str, qty: int = 1, note: str | None = None) -> None:
    """背包裡已經有同名物品就疊加數量，沒有就新增一筆——採草藥／打獵拿到東西時用。"""
    for entry in phys["inventory"]:
        if entry["item"] == item_name:
            entry["qty"] += qty
            return
    phys["inventory"].append({"item": item_name, "qty": qty, "note": note})


def sell_one_item(phys: dict, sell_prices: dict) -> tuple[str | None, int]:
    """賣掉背包裡第一個「有收購價」的物品（qty -1，見底就整筆移除），回傳
    (賣了什麼, 賣了多少錢)；背包裡沒有可賣的東西就回傳 (None, 0)，白忙一場——
    grammar 沒有「要賣哪一項」這個欄位，`intent.action="賣東西"` 沒有指定物品，
    引擎自己挑第一個可賣的，符合「LLM 有意圖權、引擎有結果權」的原則。"""
    for entry in phys["inventory"]:
        if entry["item"] in sell_prices:
            entry["qty"] -= 1
            price = sell_prices[entry["item"]]
            item_name = entry["item"]
            if entry["qty"] <= 0:
                phys["inventory"].remove(entry)
            return item_name, price
    return None, 0


def clamp(value: int, lo: int = 0, hi: int = 100) -> int:
    return max(lo, min(hi, value))


def build_grammar_for_call(base_grammar: str, visible_names: list[str], location_names: list[str]) -> str:
    """動態把 target-value／location-value 兩條規則附加在靜態 grammar 後面：
    - target-value 鎖定成「當下視野內的人名 + null」，模型結構上不可能幻覺人名、選到視野外
      的人，或把「沒有對象」寫成字面字串 "null"（跟真正的 JSON null 搞混）。
    - location-value 鎖定成「公用地點 + 每人各自的家」（SHARED_LOCATIONS + 角色名單現場
      算出來的家），不是靜態清單——換角色名單時（例如未來擴充陣容）家的清單會跟著變。
    這比事後用程式碼過濾更根本，直接讓 grammar 不允許產生非法值。"""
    target_alternatives = ['"null"'] + [f'"\\"{name}\\""' for name in visible_names]
    location_alternatives = [f'"\\"{name}\\""' for name in location_names]
    return (
        base_grammar
        + "\ntarget-value ::= " + " | ".join(target_alternatives)
        + "\nlocation-value ::= " + " | ".join(location_alternatives)
        + "\n"
    )


def normalize_target(target: str | None, name_to_id: dict) -> str | None:
    """target 現在是 grammar 鎖死過的視野內人名（或 null），這裡只需要轉換成內部用的 id，
    不需要再防幻覺/防字面字串 "null"——但還是保留 .get() 的預設 None，多一層保險。"""
    if not target or target == "null":
        return None
    return name_to_id.get(target)


def advance_time(day: int, hour: int, minute: int, minutes: int) -> tuple[int, int, int]:
    total = hour * 60 + minute + minutes
    day += total // (24 * 60)
    total %= 24 * 60
    return day, total // 60, total % 60


def format_time(day: int, hour: int, minute: int) -> str:
    period = "夜晚" if hour >= 19 or hour < 5 else "白天"
    return f"第 {day} 天 {hour:02d}:{minute:02d}（{period}）"


EXTRA_SAMPLING_PARAMS: dict = {}
# 給實驗用的採樣參數覆蓋層，預設空字典＝完全不影響現有行為。測試腳本可以在呼叫
# run_one_simulation() 之前設定 rts.EXTRA_SAMPLING_PARAMS = {"dry_multiplier": 0.8}
# 這種東西，call_llm_with_retry() 會在送出前 merge 進 payload。


def build_llm_payload(prompt: str, grammar: str, **overrides) -> dict:
    """所有跟 llama-server /completion 溝通的呼叫都用這支組 payload——之前
    run_tick_sim.py／run_des_sim.py／server.py／睡眠反思／重要性評分五個地方各自
    複製貼上同一組採樣參數，改一個參數（例如這次測 DRY sampler）要改五個地方，
    這裡收成一個函式，只有一個地方要改（2026-07-31）。`overrides` 蓋掉預設值，
    例如重要性評分要用 `n_predict=20`：`build_llm_payload(p, g, n_predict=20)`。"""
    payload = {
        "prompt": prompt, "grammar": grammar, "temperature": 0.7,
        "top_p": 0.9, "top_k": 40, "repeat_penalty": 1.0,
        "repeat_last_n": 256, "n_predict": 300, "cache_prompt": True,
    }
    payload.update(overrides)
    return payload


CONNECTION_RETRY_MAX_BACKOFF = 30  # 秒，連線層級重試的等待上限（指數成長但封頂）


def call_llm_with_retry(payload: dict, label: str) -> tuple[dict | None, bool, float, dict]:
    """沿用 poc_agent_loop/agent_loop.py 的 call_director() 精神：JSON 解析失敗重打一次；
    另外加上連線層級的重試（逾時／SSH tunnel 瞬斷）——跑 30+ tick 的長批次比短批次更容易
    撞到這種問題，2026-07-28 實測撞過一次沒接住直接讓整支腳本崩潰，這裡補上。

    2026-07-31 修正：**連線層級的問題（連不上／HTTP 非 200）改成無限重試**，不是原本
    的「試 3 次就放棄」——筆電會睡眠、SSH 隧道會斷線是這幾天實測撞過好幾次的真實情況，
    隧道斷線可能要等使用者醒來手動重連，3 次重試（10 幾秒）根本撐不過這種空窗期，撞到
    就會把整批測試燒成一堆失敗記錄。改成連線問題無限等待、指數退避封頂在
    `CONNECTION_RETRY_MAX_BACKOFF` 秒，隧道接回來就會自動繼續跑，不用重跑整批。
    **JSON 解析失敗維持原本「試 3 次」的有限重試**——這是模型輸出品質的問題，不是連線
    問題，無限重試沒有意義。

    第四個回傳值 meta 帶 llama-server 回報的 {"truncated", "tokens_evaluated"}——
    2026-07-30 發現這兩個欄位原本直接被丟棄，代表完全沒有機制能發現 prompt 有沒有因為
    超過 context 上限被截斷。truncated=True 時立刻印警告，不等呼叫端自己去查。"""
    if EXTRA_SAMPLING_PARAMS:
        payload = {**payload, **EXTRA_SAMPLING_PARAMS}

    def _post_until_connected() -> tuple[dict, float]:
        """連線層級：無限重試、指數退避封頂，直到真的連上、拿到 HTTP 200 為止。"""
        backoff = 3
        connection_attempt = 0
        while True:
            connection_attempt += 1
            t0 = time.time()
            try:
                resp = requests.post(SERVER_URL, json=payload, timeout=120)
            except requests.exceptions.RequestException as e:
                print(f"[{label}] 連線錯誤（第 {connection_attempt} 次，{e}），{backoff} 秒後重試")
                time.sleep(backoff)
                backoff = min(backoff * 2, CONNECTION_RETRY_MAX_BACKOFF)
                continue
            elapsed = time.time() - t0
            # 4xx 是請求內容本身的問題（例如 prompt 超過 n_ctx 導致 400
            # exceed_context_size_error）——同一份 payload 重打還是會一樣的錯，2026-07-31
            # 實測撞到「同一個必定失敗的請求被無限重試」的迴圈，這種要立刻放棄，不能
            # 當連線問題無限等。只有 5xx（伺服器端暫時性問題）才跟連線錯誤一樣繼續重試。
            if 400 <= resp.status_code < 500:
                print(f"[{label}] HTTP {resp.status_code}（請求內容問題，不重試）：{resp.text[:300]}")
                return None, elapsed
            if not resp.ok:
                print(f"[{label}] HTTP 錯誤 {resp.status_code}（第 {connection_attempt} 次）："
                      f"{resp.text[:200]}，{backoff} 秒後重試")
                time.sleep(backoff)
                backoff = min(backoff * 2, CONNECTION_RETRY_MAX_BACKOFF)
                continue
            return resp.json(), elapsed

    last_elapsed, meta, raw = 0.0, {}, ""
    for attempt in range(3):
        body, elapsed = _post_until_connected()
        last_elapsed = elapsed
        if body is None:
            return {"parse_error": True, "raw": "", "http_error": True}, False, elapsed, {}
        meta = {"truncated": body.get("truncated"), "tokens_evaluated": body.get("tokens_evaluated")}
        if meta["truncated"]:
            print(f"[{label}] ⚠️ 警告：prompt 被 llama-server 截斷了（tokens_evaluated="
                  f"{meta['tokens_evaluated']}），模型沒有讀到完整內容")
        raw = body.get("content", "")
        # DPO 訓練要用模型實際生成的逐字文字去算 log-prob，重新 json.dumps(out) 序列化
        # 出來的字串（縮排/空白）不等於模型真正吐出來的 token 序列——這裡把逐字原文另外
        # 存住，不能只留解析後的 dict（2026-08-03 盤點 DPO 欄位缺口時發現這個洞）。
        meta["raw_completion"] = raw
        try:
            return json.loads(raw), True, elapsed, meta
        except json.JSONDecodeError:
            if attempt < 2:
                print(f"[{label}] JSON 解析失敗，重打一次")
                continue
            print(f"[{label}] 重打後仍無法解析")
    return {"parse_error": True, "raw": raw}, False, last_elapsed, meta


def clamp_personality_delta(delta: dict) -> dict:
    """每項已經被 grammar 限制在 -3~3；這裡只處理「單晚總變動上限 ±6」（Specify2 §8）。"""
    total = sum(abs(v) for v in delta.values())
    if total <= PERSONALITY_DELTA_TOTAL_CAP or total == 0:
        return delta
    scale = PERSONALITY_DELTA_TOTAL_CAP / total
    return {k: int(v * scale) for k, v in delta.items()}


def build_today_events_text(cid: str, ticks_log: list, since_tick: int, until_tick: int) -> str:
    """把某個角色從上次睡覺（或模擬開始）到現在的原始 tick 記錄，組成給反思 LLM 看的
    時間序列文字——這是方案 C 的「當日 log」，只在這裡當場用完，不會另外存進記憶檢索。"""
    lines = []
    for rec in ticks_log:
        if rec["id"] != cid or rec["tick"] <= since_tick or rec["tick"] > until_tick or not rec["parse_ok"]:
            continue
        out = rec["output"]
        target_note = f"（對象：{out['intent']['target']}）" if out["intent"]["target"] else ""
        speech_note = f"，說了：「{out['speech']}」" if out["speech"] else ""
        lines.append(
            f"{rec['current_time']}：{out['intent']['action']}{target_note}，"
            f"心情{out['emotion']}，心裡想：「{out['inner_monologue']}」{speech_note}"
        )
    return "\n".join(lines) if lines else "（今天還沒發生什麼特別的事）"


def run_sleep_reflection(cid: str, villager: dict, today_events_text: str,
                          reflection_template: str, reflection_grammar: str,
                          importance_grammar: str, label: str) -> dict | None:
    """觸發一次睡眠反思呼叫（Specify2 §8），失敗就跳過（不影響主迴圈），回傳
    {reflection, personality_delta, long_term_memory, importance} 或 None。"""
    prompt = (
        reflection_template
        .replace("{{WORLD_LORE}}", WORLD_LORE_PLACEHOLDER)
        .replace("{{SELF_NAME}}", villager["name"])
        .replace("{{SELF_PERSONALITY_BLOCK}}", c.render_personality_block(villager))
        .replace("{{TODAY_EVENTS_BLOCK}}", today_events_text)
    )
    payload = build_llm_payload(prompt, reflection_grammar)
    out, parse_ok, elapsed, _meta = call_llm_with_retry(payload, f"{label} 睡眠反思")
    if not parse_ok:
        print(f"[{label}] 睡眠反思解析失敗，跳過這次反思")
        return None

    importance_prompt = _IMPORTANCE_PROMPT_TEMPLATE.format(content=out["long_term_memory"])
    importance_payload = build_llm_payload(importance_prompt, importance_grammar, n_predict=20)
    imp_out, imp_ok, _, _meta2 = call_llm_with_retry(importance_payload, f"{label} 重要性評分")
    importance = imp_out.get("importance", 5) if imp_ok else 5

    return {
        "reflection": out["reflection"],
        "personality_delta": clamp_personality_delta(out["personality_delta"]),
        "long_term_memory": out["long_term_memory"],
        "importance": importance,
        "today_plan": out["today_plan"],
    }


def decide_for_character(cid: str, tick: int, run_index: int, current_time: str,
                          state_at_tick_start: dict, last_declarations: dict, cast: dict,
                          relationships: dict, template: str, grammar: str,
                          location_list_str: str, location_names: list[str]) -> dict:
    """一個角色這個 tick 的決策部分（組 prompt／grammar + 呼叫 LLM），只讀
    state_at_tick_start（這個 tick 開始前的快照），不寫入任何共用狀態——這樣 5 人的呼叫
    才能安全地丟進 ThreadPoolExecutor 平行執行，不會互相搶著寫同一份資料。
    寫入 state 的部分（生理數值/情緒/死亡判定等）留在 run_one_simulation() 裡序列處理。"""
    villager = cast[cid]
    self_state = state_at_tick_start[cid]

    if not self_state["alive"]:
        return {"cid": cid, "alive": False}

    display_emotion = self_state["last_emotion"]
    if self_state["emotion_streak"] >= EMOTION_DECAY_TICKS:
        display_emotion = "neutral"

    visible = [
        {"id": other_id, "activity": f"在「{state_at_tick_start[other_id]['location']}」"}
        for other_id in ORDER
        if other_id != cid and state_at_tick_start[other_id]["location"] == self_state["location"]
        and state_at_tick_start[other_id]["alive"]
    ]

    targeted_by = [
        (speaker, decl) for speaker, decl in last_declarations.items()
        if decl.get("target") == cid and speaker != cid
    ]
    if targeted_by:
        speaker, decl = targeted_by[0]
        speaker_name = cast[speaker]["name"]
        if decl.get("speech"):
            recent_event = f"上一刻，{speaker_name}對你「{decl['intent']['action']}」，說：「{decl['speech']}」"
        else:
            recent_event = f"上一刻，{speaker_name}對你做了「{decl['intent']['action']}」的動作"
    else:
        recent_event = "上一刻村子裡各自在忙自己的事，沒有人特別找你"

    live_villager = {**villager, "physiology": self_state["physiology"], "personality": self_state["personality"]}
    if self_state["personality_drifted"]:
        live_villager["personality_text"] = None

    recent_memory = ms.render_memory_block(ms.retrieve_memories(self_state["memories"], tick))

    prompt = c.build_villager_prompt(
        template, world_lore=WORLD_LORE_PLACEHOLDER, villager=live_villager, relationships=relationships,
        current_time=current_time,
        location=self_state["location"],
        visible=visible,
        recent_event=recent_event,
        last_emotion=display_emotion,
        last_action_result=self_state["last_action_result"],
        recent_memory=recent_memory,
        location_list=location_list_str,
        today_plan=self_state["current_plan"],
    )
    grammar_for_call = build_grammar_for_call(
        grammar, [cast[v["id"]]["name"] for v in visible], location_names
    )
    payload = build_llm_payload(prompt, grammar_for_call)

    label = f"run{run_index} tick{tick:02d} {cid}"
    out, parse_ok, elapsed, meta = call_llm_with_retry(payload, label)

    return {
        "cid": cid, "alive": True, "self_state": self_state, "live_villager": live_villager,
        "out": out, "parse_ok": parse_ok, "elapsed": elapsed, "label": label, "meta": meta,
        "prompt": prompt,
    }


def run_one_simulation(run_index: int, num_ticks: int, template: str, grammar: str,
                        reflection_template: str, reflection_grammar: str, importance_grammar: str) -> dict:
    cast = c.load_all_characters()
    relationships = c.load_relationships()
    name_to_id = {v["name"]: cid for cid, v in cast.items()}

    # 地點清單依「今天選了哪些村民」現場算出來：公用地點 + 每個人的家（2026-07-27 定案）
    home_names = [c.home_name(v["name"]) for v in cast.values()]
    location_names = SHARED_LOCATIONS + home_names
    location_list_str = "、".join(location_names)

    day, hour, minute = 3, 19, 40

    state = {}
    for cid in ORDER:
        state[cid] = {
            "location": cast[cid]["location"],
            "last_emotion": cast[cid]["last_emotion"],
            "last_action_result": cast[cid]["last_action_result"],
            "physiology": copy.deepcopy(cast[cid]["physiology"]),
            "emotion_streak": 0,
            "last_action": None,
            "today_day": day,
            "today_actions": set(),
            "today_locations": {cast[cid]["location"]},
            "today_people": set(),
            "personality": copy.deepcopy(cast[cid]["personality"]),
            "personality_drifted": False,
            "memories": [],
            "current_plan": "",
            "last_sleep_tick": 0,
            "is_sleeping": False,
            "alive": True,
            "death_tick": None,
        }

    last_declarations: dict = {}
    ticks_log = []
    run_start = time.time()

    for tick in range(1, num_ticks + 1):
        current_time = format_time(day, hour, minute)
        state_at_tick_start = copy.deepcopy(state)
        this_tick_declarations = {}

        # --- 決策階段：5 人平行呼叫（2026-07-28 跟使用者討論定案）---
        # 只讀 state_at_tick_start，不寫共用狀態，所以可以安全平行——這是遠端 llama-server
        # 開 --parallel 5（搭配夠大的 -c，見連線手冊）之後才有意義，序列伺服器平行發請求
        # 一樣會在伺服器端排隊，速度不會變。
        with ThreadPoolExecutor(max_workers=len(ORDER)) as executor:
            futures = {
                cid: executor.submit(
                    decide_for_character, cid, tick, run_index, current_time,
                    state_at_tick_start, last_declarations, cast, relationships,
                    template, grammar, location_list_str, location_names,
                )
                for cid in ORDER
            }
            decisions = {cid: f.result() for cid, f in futures.items()}

        # --- 套用階段：序列處理，避免多執行緒同時寫同一份 state 造成 race condition ---
        for cid in ORDER:
            decision = decisions[cid]
            if not decision["alive"]:
                continue  # 生命值歸零已死亡，不再參與模擬

            villager = cast[cid]
            self_state = decision["self_state"]
            live_villager = decision["live_villager"]
            out, parse_ok, elapsed, label = decision["out"], decision["parse_ok"], decision["elapsed"], decision["label"]

            record = {
                "tick": tick, "id": cid, "name": villager["name"],
                "current_time": current_time, "location_before": self_state["location"],
                "elapsed_sec": round(elapsed, 2), "parse_ok": parse_ok,
                "prompt": decision["prompt"], "output": out,
                "raw_completion": decision["meta"].get("raw_completion"),
                "truncated": decision["meta"].get("truncated"),
                "tokens_evaluated": decision["meta"].get("tokens_evaluated"),
                "physiology_before": {
                    "health": self_state["physiology"]["health"],
                    "bleeding": self_state["physiology"].get("bleeding", False),
                    "sprained_ankle": self_state["physiology"].get("sprained_ankle", False),
                    "money": self_state["physiology"]["money"],
                },
            }
            ticks_log.append(record)

            target = normalize_target(out.get("intent", {}).get("target"), name_to_id) if parse_ok else None
            this_tick_declarations[cid] = {
                "target": target,
                "speech": out.get("speech") if parse_ok else None,
                "intent": out.get("intent", {}) if parse_ok else {},
            }

            print(f"[{label}] {elapsed:.2f}s parse_ok={parse_ok}")

            if not parse_ok:
                continue

            new_location = out["intent"]["location"]
            action = out["intent"]["action"]
            emotion = out["emotion"]
            phys = state[cid]["physiology"]

            # --- 情緒衰減計數 ---
            if emotion == self_state["last_emotion"]:
                state[cid]["emotion_streak"] = self_state["emotion_streak"] + 1
            else:
                state[cid]["emotion_streak"] = 0
            state[cid]["last_emotion"] = emotion

            # --- 生理數值：飢餓/口渴基礎漂移 + 體力依動作分級 ---
            phys["hunger"] = clamp(phys["hunger"] + HUNGER_PER_TICK)
            phys["thirst"] = clamp(phys["thirst"] + THIRST_PER_TICK)

            self_home = c.home_name(villager["name"])
            valid_sleep = action == "睡覺" and new_location == self_home
            attack_hit = None  # None＝這回合不是攻擊；True／False＝有揮出去、有沒有打中
            if action == "睡覺":
                phys["stamina"] = clamp(phys["stamina"] + (STAMINA_SLEEP_DELTA if valid_sleep else STAMINA_NAP_DELTA))
            elif action == "攻擊" and target:
                # 攻擊方不管有沒有打中都付代價；只有打中才會傷到對方，帶機率觸發流血
                phys["health"] = clamp(phys["health"] + ATTACK_SELF_HEALTH_DELTA)
                phys["stamina"] = clamp(phys["stamina"] + random.randint(*ATTACK_SELF_STAMINA_DELTA_RANGE))
                attack_hit = random.random() < ATTACK_HIT_CHANCE
                if attack_hit:
                    target_phys = state[target]["physiology"]
                    target_phys["health"] = clamp(target_phys["health"] + random.randint(*ATTACK_TARGET_HEALTH_DELTA_RANGE))
                    if random.random() < ATTACK_BLEED_CHANCE:
                        target_phys["bleeding"] = True
            else:
                phys["stamina"] = clamp(phys["stamina"] + stamina_delta(action))

            # 2026-08-03：機制性後果（沒錢/沒東西可賣）過去只讓效果靜默失效，last_action_result
            # 卻永遠只填「已宣告，未經 guardrail 判定」這句萬用空話——模型從來沒被明確告知
            # 「上次那個動作到底為什麼沒用」。村民AI規格書／技術架構規格書都把「回報失敗原因」
            # 列為硬性規定（少了這個 LLM 會一直重試同一個無效動作），這裡補上具體原因，
            # action_result_note 有值就取代下面組 last_action_result 時的萬用句。
            action_result_note = None
            if action == "吃飯":
                if phys["money"] >= EAT_COST:
                    phys["money"] -= EAT_COST
                    phys["hunger"] = clamp(phys["hunger"] - EAT_HUNGER_RELIEF)
                    action_result_note = "吃飯 → 成功，花了{}元".format(EAT_COST)
                else:
                    action_result_note = f"吃飯 → 失敗：錢不夠（需要 {EAT_COST} 元，只有 {phys['money']:.0f} 元）"
            if action == "喝酒":
                if phys["money"] >= DRINK_COST:
                    phys["money"] -= DRINK_COST
                    phys["thirst"] = clamp(phys["thirst"] - DRINK_THIRST_RELIEF)
                    action_result_note = "喝酒 → 成功，花了{}元".format(DRINK_COST)
                else:
                    action_result_note = f"喝酒 → 失敗：錢不夠（需要 {DRINK_COST} 元，只有 {phys['money']:.0f} 元）"
            if action == "表演":
                phys["money"] += PERFORM_INCOME
                action_result_note = f"表演 → 成功，賺了 {PERFORM_INCOME} 元"
            if action == "採草藥":
                add_inventory_item(phys, *GATHER_ITEM)
                action_result_note = f"採草藥 → 成功，拿到 {GATHER_ITEM[0]}"
            if action == "打獵":
                for item_name, qty in HUNT_ITEMS:
                    add_inventory_item(phys, item_name, qty)
                action_result_note = "打獵 → 成功，帶回獵物"
            if action == "賣東西":
                sold_item, price = sell_one_item(phys, SELL_PRICES)
                if sold_item:
                    phys["money"] += price
                    action_result_note = f"賣東西 → 成功，賣了 {sold_item} 得 {price} 元"
                else:
                    action_result_note = "賣東西 → 失敗：背包裡沒有可以賣的東西"
            if action == "治療":
                if new_location != "藥草鋪":
                    action_result_note = "治療 → 失敗：不在藥草鋪"
                elif phys["money"] < HEAL_COST:
                    action_result_note = f"治療 → 失敗：錢不夠（需要 {HEAL_COST} 元，只有 {phys['money']:.0f} 元）"
                else:
                    phys["money"] -= HEAL_COST
                    phys["health"] = clamp(phys["health"] + HEAL_IMMEDIATE_BONUS)
                    phys["bleeding"] = False
                    phys["severe_injury"] = False
                    phys["sprained_ankle"] = False
                    phys["hand_cut"] = False
                    phys["recovering"] = phys["health"] < 100
                    action_result_note = f"治療 → 成功，花了{HEAL_COST}元"

            # --- 生命值：流血/重傷持續扣，治療中的人被動慢慢回血，滿血自動解除治療中狀態 ---
            if phys["bleeding"]:
                phys["health"] = clamp(phys["health"] + BLEEDING_HEALTH_DELTA)
            if phys["severe_injury"]:
                phys["health"] = clamp(phys["health"] + SEVERE_INJURY_HEALTH_DELTA)
            if phys["recovering"]:
                phys["health"] = clamp(phys["health"] + RECOVERING_HEALTH_DELTA)
                if phys["health"] >= 100:
                    phys["recovering"] = False

            # --- 死亡：生命值歸零是引擎判定的「結果」，不是覆蓋角色的選擇——他的意圖照樣
            # 自由宣告，只是流血/重傷不治療的後果是真的（2026-07-27 跟使用者討論定案）。
            # 死亡後不再參與模擬：不會再被呼叫、也不會出現在其他人的視野裡。
            if phys["health"] <= 0:
                state[cid]["alive"] = False
                state[cid]["death_tick"] = tick
                print(f"[{label}] {villager['name']} 生命值歸零，死亡（第 {tick} tick）")

            # --- 無聊度（Specify2 §7.3，原樣照抄）---
            boredom_delta = 2
            if action == self_state["last_action"]:
                boredom_delta += 3
            if target and target not in self_state["today_people"]:
                boredom_delta -= 25
            if new_location not in self_state["today_locations"]:
                boredom_delta -= 15
            if action not in self_state["today_actions"]:
                boredom_delta -= 10
            if any(
                last_declarations.get(other_id, {}).get("intent", {}).get("action") in WITNESS_WORTHY_ACTIONS
                for other_id in ORDER
                if other_id != cid and state_at_tick_start[other_id]["location"] == self_state["location"]
            ):
                boredom_delta -= 10
            phys["boredom"] = clamp(phys["boredom"] + boredom_delta)

            # --- 位置/上一動作結果 + 「今天」集合更新 ---
            state[cid]["location"] = new_location
            state[cid]["last_action"] = action
            state[cid]["today_actions"] = self_state["today_actions"] | {action}
            state[cid]["today_locations"] = self_state["today_locations"] | {new_location}
            if target:
                state[cid]["today_people"] = self_state["today_people"] | {target}
            else:
                state[cid]["today_people"] = self_state["today_people"]

            target_note = f"（對 {cast[target]['name']}）" if target else ""
            if attack_hit is True:
                state[cid]["last_action_result"] = f"{action}{target_note} → 打中了"
            elif attack_hit is False:
                state[cid]["last_action_result"] = f"{action}{target_note} → 揮空了"
            elif action_result_note:
                state[cid]["last_action_result"] = action_result_note
            else:
                state[cid]["last_action_result"] = f"{action}{target_note} → 已宣告（此為簡化版模擬，未經完整 guardrail 判定成功與否）"

            # --- 睡眠反思（Specify2 §8）：只在「一段連續睡眠的第一個 tick」觸發一次，
            # 不是只要這個 tick 選了睡覺就觸發——2026-07-27 跟使用者討論定案：如果每 tick
            # 都重新觸發，連續睡好幾個 tick 會重複打好幾次反思，而且中間幾乎沒新事件可反思。
            # 也只有在自己家睡才算數（在外面選睡覺只是打盹，不會真的觸發反思）。
            # 體力耗盡（<=0）時視為強制昏睡，一樣觸發反思——見 STAMINA_COLLAPSE_RECOVERY
            # 定義處的說明（2026-07-30）。
            collapsed = phys["stamina"] <= 0 and not valid_sleep and not self_state["is_sleeping"]
            if collapsed:
                phys["stamina"] = clamp(phys["stamina"] + STAMINA_COLLAPSE_RECOVERY)
            if (valid_sleep and not self_state["is_sleeping"]) or collapsed:
                today_events_text = build_today_events_text(cid, ticks_log, self_state["last_sleep_tick"], tick)
                reflection = run_sleep_reflection(
                    cid, live_villager, today_events_text,
                    reflection_template, reflection_grammar, importance_grammar, label,
                )
                if reflection:
                    for dim, delta_value in reflection["personality_delta"].items():
                        state[cid]["personality"][dim] = clamp(state[cid]["personality"][dim] + delta_value)
                    if any(reflection["personality_delta"].values()):
                        state[cid]["personality_drifted"] = True
                    state[cid]["memories"] = self_state["memories"] + [{
                        "tick": tick, "importance": reflection["importance"],
                        "content": reflection["long_term_memory"],
                    }]
                    state[cid]["current_plan"] = reflection["today_plan"]
                    state[cid]["last_sleep_tick"] = tick
                    tag = "（體力耗盡昏睡）" if collapsed else ""
                    print(f"[{label}] 睡眠反思{tag}：{reflection['reflection']}｜人格變動 {reflection['personality_delta']}｜"
                          f"今天想做：{reflection['today_plan']}")
            state[cid]["is_sleeping"] = valid_sleep

        # --- 換日：重置「今天」集合（Specify2 §7.3 的無聊度減免都是以「今天」為單位）---
        new_day, hour, minute = advance_time(day, hour, minute, TICK_MINUTES)
        if new_day != day:
            for cid in ORDER:
                state[cid]["today_actions"] = set()
                state[cid]["today_locations"] = {state[cid]["location"]}
                state[cid]["today_people"] = set()
        day = new_day

        last_declarations = this_tick_declarations

    run_elapsed = time.time() - run_start
    return {
        "run_index": run_index, "num_ticks": num_ticks, "tick_minutes": TICK_MINUTES,
        "run_elapsed_sec": round(run_elapsed, 2), "records": ticks_log,
        "final_memories": {cid: state[cid]["memories"] for cid in ORDER},
        "final_personality": {cid: state[cid]["personality"] for cid in ORDER},
        "death_ticks": {cid: state[cid]["death_tick"] for cid in ORDER if not state[cid]["alive"]},
    }


def main() -> None:
    num_ticks = int(sys.argv[1]) if len(sys.argv) > 1 else 20
    num_runs = int(sys.argv[2]) if len(sys.argv) > 2 else 5

    template = (POC_DIR / "prompts" / "villager_system_prompt.txt").read_text(encoding="utf-8")
    grammar = (POC_DIR / "grammar" / "turn.gbnf.template").read_text(encoding="utf-8")
    reflection_template = (POC_DIR / "prompts" / "sleep_reflection_system_prompt.txt").read_text(encoding="utf-8")
    reflection_grammar = (POC_DIR / "grammar" / "reflection.gbnf.template").read_text(encoding="utf-8")
    importance_grammar = (POC_DIR / "grammar" / "importance.gbnf.template").read_text(encoding="utf-8")
    TRANSCRIPT_DIR.mkdir(exist_ok=True)

    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    all_runs = []
    for run_index in range(1, num_runs + 1):
        print(f"\n========== 第 {run_index}/{num_runs} 次模擬開始（{num_ticks} tick）==========")
        result = run_one_simulation(
            run_index, num_ticks, template, grammar,
            reflection_template, reflection_grammar, importance_grammar,
        )
        all_runs.append(result)
        out_path = TRANSCRIPT_DIR / f"tick_sim_run{run_index}_{timestamp}.json"
        out_path.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"第 {run_index} 次模擬完成，耗時 {result['run_elapsed_sec']}s，已存到 {out_path}")

    summary_path = TRANSCRIPT_DIR / f"tick_sim_summary_{timestamp}.json"
    summary_path.write_text(json.dumps(
        {"num_ticks": num_ticks, "num_runs": num_runs, "tick_minutes": TICK_MINUTES,
         "run_elapsed_sec": [r["run_elapsed_sec"] for r in all_runs]},
        ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\n全部完成，共 {num_runs} 次 x {num_ticks} tick，逐輪耗時：{[r['run_elapsed_sec'] for r in all_runs]}")


if __name__ == "__main__":
    main()
