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
import re
import sys
import time
from datetime import datetime
from pathlib import Path

POC_DIR = Path(__file__).parent
sys.path.insert(0, str(POC_DIR))
import characters as c
import enums
import run_tick_sim as rts  # 重用已驗證的常數與函式，不重新發明
import requests

TRANSCRIPT_DIR = POC_DIR / "transcripts"
START_DAY, START_HOUR, START_MINUTE = 3, 19, 40

# 2026-08-10：推理鷹架正式併入主線。原本是test_money_hint_reasoning_100.py裡的
# monkeypatch，經過對照實驗（base模型不訓練、強制貧窮情境0/43→4/4輪都轉向）跟7小時
# 長時間驗證（跨36遊戲日、7391筆決策、parse_ok全程100%、動作分布健康分散）驗證有效
# 才併進來，不是隨手加的——見note 2026-08-09/10。
REASONING_INSTRUCTION = (
    "\n\n【新增欄位：reasoning，必須寫在最前面，上限100字】\n"
    "在你決定 intent 之前，先用 `reasoning` 欄位寫一段分析：現在最大的問題是什麼、"
    "有哪些辦法可以解決、你打算選哪一個、為什麼。**不超過100字**，把因果關係講完整"
    "（例如「A做不到 → 所以需要B」），但不用鉅細靡遺列出每一個考慮過的選項。\n"
    "這段要先想清楚再寫 intent，不能寫完 intent 之後才回頭補理由。\n"
    "如果最大的問題是「身上沒錢，好幾件事都做不了」，記得：再試一次原本做不到的事"
    "解決不了缺錢問題，需要的是「能換到錢」的辦法（打獵/採草藥/賣東西/表演這類），"
    "但最終還是由你自己的個性跟處境判斷。\n"
)

DURATION_INSTRUCTION = REASONING_INSTRUCTION + (
    "\n\n【新增欄位：intent.duration_minutes】\n"
    "這次多一個欄位：`intent.duration_minutes`，代表你決定要花多少分鐘做這件事——"
    "喝口水可能 1-2 分鐘、跟人聊幾句可能 5-15 分鐘、採草藥或打獵可能 60-180 分鐘、"
    "睡一覺可能 300-540 分鐘、打一場架可能 1-5 分鐘。請依照這個動作在現實中大概需要"
    "多久，給一個合理的分鐘數，不用刻意湊整數，也不用被上面這些例子的數字限制死。\n"
    "\n【提醒】如果你發現自己已經連續選擇同一種動作很多次（可以從無聊度、飢餓/口渴這些"
    "數值感覺出來），想想看真實生活中的人會不會這樣一直重複下去——通常會膩、會想換點"
    "別的事做。這只是提醒，不是規定，最終還是由你自己判斷這個角色在當下真正會怎麼做。\n"
)

# 攻擊/搶劫等命中同地點目標時，若目標正在進行中的動作還沒到期，強制中斷——原本沿用
# WITNESS_WORTHY_ACTIONS、刻意不含說話（2026-07-29 跟使用者討論定案：說話是非強制性的，
# B 晚一點知道也沒差，等現有動作結束再回應即可）。2026-08-03 team 決定改成優先觀察角色
# 互相交流，把說話／喊話／悄悄話也納入中斷觸發，讓 B 被搭話當下就能立刻重新決策、
# 生成回應，不用乾等現有動作跑完。故意不直接改 rts.WITNESS_WORTHY_ACTIONS 本體，
# 而是另外併一個新集合——那個集合同時也是無聊度公式的「目擊」判定用途（見
# state[o]["last_declaration"]["action"] in rts.WITNESS_WORTHY_ACTIONS 那段），
# 說話不該連帶影響旁觀者的無聊度衰減，兩個判準要分開，不能共用同一份清單。
_DIALOGUE_ACTIONS = {"說話", "喊話", "悄悄話"}
INTERRUPTIBLE_TRIGGER_ACTIONS = rts.WITNESS_WORTHY_ACTIONS | _DIALOGUE_ACTIONS
# 被中斷時，若目標原本的動作是移動類，位置退回中斷前的位置（「先求正確不求擬真」）
LOCATION_CHANGING_ACTIONS = {"移動", "奔跑"}
# 安全上限，避免卡迴圈情境下無限跑下去（DES 沒有固定 tick 數可以當終止條件）
MAX_EVENTS_SAFETY_CAP = 400

# --- 執行前可行性檢查＋立即重試（2026-08-04）---
# 原本「錢不夠」這類失敗是宣告了就照跑完整個 duration，時間白白浪費掉，下一輪決策才
# 會看到失敗原因——跟使用者確認過，這不是想要的行為：希望的是「做不到的決策當下就被
# 打回來，同一個時刻立刻換一個做得到的動作」，不浪費宣告的時長。這裡對四個金錢/資源
# 閘門動作（吃飯/喝酒/治療/採草藥）在真正執行（推進時間、扣血/扣錢）之前先檢查可不
# 可行，不可行就不消耗任何時間，同一時刻（priority 0，比正常排定的下一次決定更優先）
# 立刻讓同一個角色重新決策，最多重試 FEASIBILITY_MAX_RETRIES 次；超過上限代表模型
# 持續選同一個做不到的動作，強制改成安全預設動作（發呆）接手，避免模擬卡死在無限
# 重試迴圈——這個上限本身也順便產生了 DPO 最乾淨的 rejected 樣本：同一個 context
# 被連續問好幾次還選一樣答案，排除掉跨輪次時間流逝/生理數值變化的干擾因素。
FEASIBILITY_GATED_ACTIONS = {"吃飯", "喝酒", "治療", "採草藥", "舉報"}
FEASIBILITY_MAX_RETRIES = 3
FEASIBILITY_FALLBACK_ACTION = "發呆"
FEASIBILITY_FALLBACK_DURATION = 5
# 軟性提示實驗（2026-08-04）：只加在「重試時看到的失敗訊息」，第一次宣告失敗維持原樣
# 不提前暗示——這樣才能對照「第一次失敗 vs 有提示的重試」選擇會不會不一樣。之前測過
# 7-8 種軟性提示版本（血量警示升級等）全部沒真的改變行為，這次情境不同（同一時刻立刻
# 被打回來重問，不是跨輪次的提醒），值得用現成的重試機制便宜測一次，不預設一定沒用。
FEASIBILITY_RETRY_SUGGESTION_TEXT = "請選其他動作。"
# 2026-08-07：缺錢是最常見的可行性失敗原因，但「請選其他動作」太籠統，觀察到模型會
# 反覆重選同一個做不到的動作直到被強制發呆，從沒主動切去打獵/賣東西這類工作動作賺錢
# （見 note）。這裡只在失敗原因明確是「錢不夠」時換成列出多個工作選項的提示，不用
# 祈使句、不指定單一動作——之前「維生方式提示句 v1」用祈使句「應該去表演」讓老周
# 100%鎖死在表演，這次刻意用列舉措辭避免重蹈覆轍。非缺錢原因（地點不對／庫存耗盡／
# 投訴額滿）維持原本的通用提示，這些情境通常只有一種解法，不需要额外提示。
FEASIBILITY_MONEY_SHORTAGE_SUGGESTION_TEXT = (
    "村子裡有幾種方式能賺到錢：打獵、採草藥、賣東西、表演，看你想怎麼處理。"
)

# 藥草叢庫存/刷新——之前查證表演/採草藥/打獵在規則上結構性不會失敗，藥草叢加庫存上限
# 之後「採草藥」才會有失敗的可能，是這批動作裡唯一真的需要世界層級狀態（不是角色個人
# 生理值）的資源池。打獵維持原樣不動（這次只先做採草藥，見 note 的範圍討論）。
HERB_PATCH_CAPACITY = 10
HERB_PATCH_REFRESH_MINUTES = 1440  # 24 小時遊戲時間刷新一次，回滿到上限

# 舉報制度（2026-08-05 跟使用者討論定案，改成「多人投訴累積制」，不是組員原本想像的
# 「當場叫人抓現行犯」——這裡先照這個方向做 POC 驗證，之後可能要跟組員的版本收斂）：
# - 一定要人在洗心革面所才算數（跟治療一樣的地點閘門）
# - 對象不需要跟舉報者同地點（去投訴，不是當場對峙）——但這點目前只在無grammar模式下
#   靠 Python 事後驗證放寬，grammar 硬約束模式下 target 還是被限制在「當下視野內」，
#   這是選了「不重寫grammar」這個簡化方案後必然的技術限制，先接受這個落差。
# - 同一人一天最多舉報 REPORT_DAILY_LIMIT 次，超過直接不受理駁回（擋濫用洗票）
# - 累積到 REPORT_ARREST_THRESHOLD 位「不同」角色都投訴過同一人，才觸發逮捕
#   （同一人狂舉報同一個目標不會疊加，一定要不同人）
# - 逮捕後強制拘留 REPORT_DETENTION_MINUTES 分鐘（對齊老周背景故事「三天前...剛從
#   洗心革面所出來」的時長設定），拘留期滿投訴記錄歸零重新算
REPORT_DAILY_LIMIT = 3
REPORT_ARREST_THRESHOLD = 2
REPORT_DETENTION_MINUTES = 3 * 24 * 60  # 三天

# 偷竊（2026-08-05 新增）：之前動作清單裡就有「偷竊」，但引擎端完全沒有執行邏輯，宣告了
# 沒有任何效果——這次是為了讓低道德角色（例如阿吉）在生存危機時「考慮非法手段，但不是
# 每次都選」這個訓練訊號有意義，才補上真正的機制。設計成有風險（不是穩賺）、且不論成功
# 失敗都會被對象發現（POC 簡化，不做「神不知鬼不覺」的隱蔽判定）：
# - 一定要有明確 target，且 target 執行當下人還在同一地點（跟攻擊判定同一套 target_same_
#   location 邏輯），否則算失敗（目標不在附近，不消耗對方金錢）
# - STEAL_SUCCESS_CHANCE 機率成功，偷到 STEAL_AMOUNT_RANGE 區間內的錢（不會超過對象身上
#   實際有的錢）
# - 不論成功失敗，對象都會發現，好感度重挫 STEAL_RELATIONSHIP_PENALTY——這同時也是要讓
#   「舉報」有更明確的觸發動機（之前補強批次測到舉報完全沒被自然選到，缺的可能就是這種
#   明確的被冒犯事件），順便把受害者這輪的 last_action_result 也記一筆，讓對象下一次
#   決策時看得到「被偷了」這件事，不是只有內部關係分數變動、當事人毫無感知
STEAL_SUCCESS_CHANCE = 0.5
STEAL_AMOUNT_RANGE = (5, 20)
STEAL_RELATIONSHIP_PENALTY = 40


def _refill_herb_patch_if_due(world_state: dict, now: int) -> None:
    if now - world_state["herb_patch_last_refill"] >= HERB_PATCH_REFRESH_MINUTES:
        world_state["herb_patch_stock"] = HERB_PATCH_CAPACITY
        world_state["herb_patch_last_refill"] = now


def check_feasibility(action: str, phys: dict, location: str, world_state: dict, now: int,
                       reports_filed_today: int = 0) -> tuple[bool, str | None]:
    """執行前可行性檢查，只檢查（不扣款/不消耗庫存——真正執行時原有的 action_result_note
    區塊會再做一次同樣的判斷並實際扣款/扣庫存，這裡只是提前擋下做不到的宣告，避免浪費
    duration）。回傳 (是否可行, 不可行時的失敗原因文字或 None)。"""
    if action == "吃飯" and phys["money"] < rts.EAT_COST:
        return False, f"吃飯 → 失敗：錢不夠（需要 {rts.EAT_COST} 元，只有 {phys['money']:.0f} 元）"
    if action == "喝酒" and phys["money"] < rts.DRINK_COST:
        return False, f"喝酒 → 失敗：錢不夠（需要 {rts.DRINK_COST} 元，只有 {phys['money']:.0f} 元）"
    if action == "治療":
        if location != "藥草鋪":
            return False, "治療 → 失敗：不在藥草鋪"
        if phys["money"] < rts.HEAL_COST:
            return False, f"治療 → 失敗：錢不夠（需要 {rts.HEAL_COST} 元，只有 {phys['money']:.0f} 元）"
    if action == "採草藥" and location == "藥草叢":
        _refill_herb_patch_if_due(world_state, now)
        if world_state["herb_patch_stock"] <= 0:
            wait = world_state["herb_patch_last_refill"] + HERB_PATCH_REFRESH_MINUTES - now
            return False, f"採草藥 → 失敗：藥草叢已經採完了，還要等 {wait:.0f} 分鐘才會刷新"
    if action == "舉報":
        if location != "洗心革面所":
            return False, "舉報 → 失敗：不在洗心革面所"
        if reports_filed_today >= REPORT_DAILY_LIMIT:
            return False, f"舉報 → 失敗：今天已經投訴滿 {REPORT_DAILY_LIMIT} 次，不受理"
    return True, None

# 實驗開關：拿掉 GBNF grammar 硬約束，改用 prompt-based JSON + 事後驗證重試——
# 2026-07-31，驗證「grammar 本身會不會強化重複鎖定」這個假設用。預設 True＝正式行為
# 完全不受影響，只有測試腳本手動設成 False 才會切換路徑。
USE_GRAMMAR = True

_NO_GRAMMAR_JSON_INSTRUCTION = (
    "\n\n【格式要求（這次測試不掛 grammar，靠你自己遵守，不是引擎硬約束）】\n"
    "只能輸出一個 JSON 物件，不要有任何 JSON 以外的文字、不要用 markdown code fence。"
    "欄位跟型別（reasoning 必須是第一個欄位，先分析再決定 intent，不能先決定再回頭補理由）：\n"
    '{"reasoning": "字串，上限100字", "emotion": "8選1英文字串", "intent": {"action": "從允許清單選一個中文字串",'
    ' "duration_minutes": 整數, "target": "字串或null", "location": "從允許清單選一個中文字串"},'
    ' "inner_monologue": "字串", "speech_target": "字串或null，這句話說給誰聽，跟intent.target互相獨立",'
    ' "speech": "字串或null", "speech_volume": "normal/shout/whisper"}'
)
_VALID_ACTIONS = {a.value for a in enums.Action}
_VALID_EMOTIONS = {"excited","happy","in_love","terrified","burnout","angry","sad","neutral"}


def _extract_first_json(text: str) -> str | None:
    """手動抓「第一個大括號配對平衡」的 JSON 物件字串，不是貪婪正則——沒有 grammar
    約束時模型可能停不下來、連續吐好幾個 JSON，貪婪正則會把好幾個黏在一起解析失敗。"""
    start = text.find("{")
    if start == -1:
        return None
    depth = 0
    in_string = False
    escape = False
    for i in range(start, len(text)):
        ch = text[i]
        if escape:
            escape = False
            continue
        if ch == "\\":
            escape = True
            continue
        if ch == '"':
            in_string = not in_string
            continue
        if in_string:
            continue
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
    return None


def call_llm_no_grammar_with_retry(prompt: str, label: str, location_names: list, visible_names: set,
                                    all_names: set | None = None) -> tuple[dict | None, bool, float, str]:
    """跟 rts.call_llm_with_retry() 平行的版本，差異：不帶 grammar 欄位，額外做
    action/location/target 的語意合法性驗證（grammar 版本靠硬約束保證合法，這裡沒有
    這層保護，要自己檢查，不合法就當作解析失敗重試）。

    2026-07-31：連線層級的問題（連不上／HTTP 非 200）改成無限重試＋指數退避封頂，理由
    跟 rts.call_llm_with_retry() 同一節註解——筆電睡眠、隧道斷線可能要等很久才重連，
    3 次重試撐不住，會把整批測試燒成失敗記錄。內容驗證失敗（JSON/欄位不合法）維持
    有限重試。"""
    payload = {
        "prompt": prompt + _NO_GRAMMAR_JSON_INSTRUCTION, "temperature": 0.7, "top_p": 0.9,
        "top_k": 40, "repeat_penalty": 1.0, "repeat_last_n": 256, "n_predict": 400, "cache_prompt": True,
    }

    def _post_until_connected() -> tuple[dict, float]:
        backoff = 3
        connection_attempt = 0
        while True:
            connection_attempt += 1
            t0 = time.time()
            try:
                resp = requests.post(rts.SERVER_URL, json=payload, timeout=120)
            except requests.exceptions.RequestException as e:
                print(f"[{label}] 連線錯誤（第 {connection_attempt} 次，{e}），{backoff} 秒後重試")
                time.sleep(backoff)
                backoff = min(backoff * 2, rts.CONNECTION_RETRY_MAX_BACKOFF)
                continue
            elapsed = time.time() - t0
            # 4xx 是請求內容本身的問題（prompt 超過 n_ctx 之類），同一份 payload 重打
            # 還是會一樣的錯，不能當連線問題無限等——2026-07-31 實測撞到過。
            if 400 <= resp.status_code < 500:
                print(f"[{label}] HTTP {resp.status_code}（請求內容問題，不重試）：{resp.text[:300]}")
                return None, elapsed
            if not resp.ok:
                print(f"[{label}] HTTP 錯誤 {resp.status_code}（第 {connection_attempt} 次）："
                      f"{resp.text[:200]}，{backoff} 秒後重試")
                time.sleep(backoff)
                backoff = min(backoff * 2, rts.CONNECTION_RETRY_MAX_BACKOFF)
                continue
            return resp.json(), elapsed

    last_elapsed = 0.0
    for attempt in range(5):
        body, elapsed = _post_until_connected()
        last_elapsed = elapsed
        if body is None:
            return None, False, elapsed, ""
        raw = body.get("content", "")
        if not raw:
            print(f"[{label}] content 是空的，重試")
            continue
        json_str = _extract_first_json(raw)
        if not json_str:
            print(f"[{label}] 找不到 JSON，重試")
            continue
        try:
            out = json.loads(json_str)
        except json.JSONDecodeError:
            print(f"[{label}] JSON 解析失敗，重試")
            continue
        if out.get("emotion") not in _VALID_EMOTIONS:
            print(f"[{label}] emotion 不合法：{out.get('emotion')}，重試")
            continue
        intent = out.get("intent", {})
        if intent.get("action") not in _VALID_ACTIONS:
            print(f"[{label}] action 不合法：{intent.get('action')}，重試")
            continue
        if intent.get("location") not in location_names:
            print(f"[{label}] location 不合法：{intent.get('location')}，重試")
            continue
        target = intent.get("target")
        # 舉報（2026-08-05）：對象不需要跟舉報者同地點（去洗心革面所投訴，不是當場對峙），
        # 這裡是唯一放寬成「全村名單都算合法」的例外，其他動作維持原本的視野內限制不變——
        # 這個放寬只在無grammar模式下有效，grammar硬約束模式下 target-value 規則是全域
        # 共用的，沒有重寫grammar結構前，舉報的對象實際上還是被限制在視野內（見 note）。
        allowed_targets = all_names if (intent.get("action") == "舉報" and all_names is not None) else visible_names
        if target is not None and target not in allowed_targets:
            print(f"[{label}] target 不合法（幻覺出視野外的人）：{target}，重試")
            continue
        # DPO 訓練要用逐字生成文字算 log-prob，回傳 raw（模型實際吐出的完整原文，
        # 可能包含 JSON 前後的多餘文字），不能只回傳解析後重新序列化的 out——理由跟
        # rts.call_llm_with_retry() 那邊補 raw_completion 的註解一致。
        return out, True, elapsed, raw
    return None, False, last_elapsed, ""


def total_minutes_to_time(total_minutes: int) -> tuple[str, int]:
    day, hour, minute = rts.advance_time(START_DAY, START_HOUR, START_MINUTE, total_minutes)
    return rts.format_time(day, hour, minute), day


def run_one_simulation(run_index: int, target_game_minutes: int, template: str, grammar: str,
                        reflection_template: str, reflection_grammar: str, importance_grammar: str,
                        incremental_out_path=None) -> dict:
    """incremental_out_path 有帶值時，每筆事件寫進 events_log 後就立刻把目前累積的結果整份
    覆寫存檔一次——2026-08-03 雲端多人測試撞到 OpenRouter 每日額度用盡、行程被強制中止，
    原本只在跑完最後一刻才寫檔，中途 kill 掉記憶體裡的 events_log（含 prompt/raw_completion）
    就整個沒了，只能從終端機文字 log 反解析，資料損失很大。雲端呼叫比本地更容易中途失敗
    （額度/網路/供應商限流），這裡補上增量存檔，之後不管什麼原因中斷，最多只損失最後一筆
    還沒寫進去的事件，不會整批作廢。本地跑（不帶這個參數）行為完全不變。"""
    cast = c.load_all_characters()
    relationships = c.load_relationships()
    name_to_id = {v["name"]: cid for cid, v in cast.items()}

    home_names = [c.home_name(v["name"]) for v in cast.values()]
    location_names = rts.SHARED_LOCATIONS + home_names
    location_list_str = "、".join(location_names)
    # 房屋偷竊（2026-08-05）用：地點名稱 -> 屋主 id，判斷「我現在站的地方是不是某人的家」
    home_name_to_owner = {c.home_name(v["name"]): cid_ for cid_, v in cast.items()}

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
            "feasibility_retries": 0,  # 可行性檢查連續失敗次數，見 FEASIBILITY_MAX_RETRIES
            "reports_filed_today": 0,  # 這個角色今天已經舉報過幾次，見 REPORT_DAILY_LIMIT
            "accusers": set(),  # 舉報過「這個角色」的不同角色id集合，見 REPORT_ARREST_THRESHOLD
            "detained_until": 0,  # 被拘留到第幾分鐘（game time），0代表沒被拘留
        }

    # 世界層級資源池（不屬於任何單一角色）——目前只有藥草叢，見 check_feasibility()
    world_state = {"herb_patch_stock": HERB_PATCH_CAPACITY, "herb_patch_last_refill": 0}

    heap = [(0, 1, 0, cid) for cid in rts.ORDER]
    heapq.heapify(heap)
    events_log = []
    # 對話追蹤（2026-08-10）：2026-08-10長時間驗證量到「有明確對象的說話類動作」裡只有
    # 4.6%會被對方接話、而且接話常常答非所問——因為原本只有last_declaration這種一次性
    # 「上一刻對你做了什麼」的敘述，沒有真正的「這是進行中第幾輪對話」的追蹤，模型看不出
    # 自己正處在一場對話裡、該不該接話。key用frozenset({id_a,id_b})，同一對角色不分
    # 誰是發話者，值是這對角色目前這場對話的狀態；沒有進行中的對話就不會有這個key。
    conversation_sessions = {}
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
            me["reports_filed_today"] = 0

        # --- 被舉報累積到門檻、正在洗心革面所拘留中：不呼叫模型，直接強制過完拘留時間
        # （跟體力耗盡強制昏睡同一種「引擎接管、角色沒有自由意志」的處理方式）---
        if me["detained_until"] > now:
            detained_duration = me["detained_until"] - now
            events_log.append({
                "event_index": len(events_log), "time": now, "id": cid, "name": villager["name"],
                "current_time": current_time, "location_before": me["location"], "was_interrupted": False,
                "elapsed_sec": 0.0, "parse_ok": True,
                "prompt": None, "raw_completion": None,
                "output": {
                    "emotion": "sad", "intent": {"action": "睡覺", "duration_minutes": detained_duration,
                                                  "target": None, "location": "洗心革面所"},
                    "inner_monologue": "（正在洗心革面所服刑，沒有自由行動的餘地）", "speech": None,
                    "speech_volume": "normal",
                },
                "truncated": None, "tokens_evaluated": None,
                "physiology_before": {
                    "health": me["physiology"]["health"], "bleeding": me["physiology"].get("bleeding", False),
                    "sprained_ankle": me["physiology"].get("sprained_ankle", False), "money": me["physiology"]["money"],
                },
                "system_forced": "detained",
            })
            me["location"] = "洗心革面所"
            me["last_action_result"] = f"舉報 → 累積投訴人數達標，被拘留 {REPORT_DETENTION_MINUTES} 分鐘，現在已經放出來了"
            me["detained_until"] = 0
            me["seq"] += 1
            heapq.heappush(heap, (now + detained_duration, 1, me["seq"], cid))
            continue

        visible = [
            {"id": o, "activity": f"在「{state[o]['location']}」"}
            for o in rts.ORDER if o != cid and state[o]["alive"] and state[o]["location"] == me["location"]
        ]

        # 房屋偷竊（2026-08-05）：站在某人家、屋主本人不在家時，把屋主名字補進 target
        # 候選名單，並在 prompt 明講「這是誰的家、他現在不在」——不然模型看到 grammar
        # 多出一個沒被提過的名字選項，容易亂猜，重演之前 grammar 欄位重排序修過的
        # 「敘事跟結構脫節」問題（見 note）。
        absent_homeowner_id = home_name_to_owner.get(me["location"])
        if (absent_homeowner_id is None or absent_homeowner_id == cid
                or not state[absent_homeowner_id]["alive"]
                or state[absent_homeowner_id]["location"] == me["location"]):
            absent_homeowner_id = None
        absent_homeowner_name = cast[absent_homeowner_id]["name"] if absent_homeowner_id else None
        home_hint = (
            f"\n【提示】你目前在「{me['location']}」，這是 {absent_homeowner_name} 的家，"
            f"{absent_homeowner_name} 現在不在家。"
        ) if absent_homeowner_name else ""

        was_interrupted = me["interrupt_note"] is not None
        # 對話追蹤：不管有沒有被中斷，都要先查「有沒有人剛剛對我說話、我還沒接話」——
        # 中斷重決跟正常決策都可能是在回應一場進行中的對話，兩種情況都要能看到對話狀態。
        incoming_speaker_id = None
        for o in rts.ORDER:
            if o == cid:
                continue
            od = state[o]["last_declaration"]
            if not od or not od["speech"]:
                continue
            spoke_to_me = (od["action"] in _DIALOGUE_ACTIONS and od["target_id"] == cid) or od.get("speech_target_id") == cid
            if spoke_to_me:
                incoming_speaker_id = o
                break

        if was_interrupted:
            recent_event = me["interrupt_note"]
            me["interrupt_note"] = None
        else:
            recent_event = "上一刻村子裡各自在忙自己的事，沒有人特別找你"
            for o in rts.ORDER:
                if o == cid:
                    continue
                od = state[o]["last_declaration"]
                if od and (od["target_id"] == cid or od.get("speech_target_id") == cid):
                    speaker_name = cast[o]["name"]
                    if od["speech"]:
                        recent_event = f"上一刻，{speaker_name}對你「{od['action']}」，說：「{od['speech']}」"
                    else:
                        recent_event = f"上一刻，{speaker_name}對你做了「{od['action']}」的動作"
                    break

        # 對話追蹤：如果剛剛有人對我說話（incoming_speaker_id），而且這對角色有進行中的
        # session、最後一句是對方講的（還沒輪到我講）——組一段明確的「你正在對話中」提示，
        # 附上輪數跟原句，逼模型意識到這是一場交流而不是孤立事件，由它自己決定接不接話。
        conversation_block = ""
        if incoming_speaker_id is not None:
            key = frozenset((cid, incoming_speaker_id))
            session = conversation_sessions.get(key)
            if session and session["last_speaker_id"] == incoming_speaker_id:
                speaker_name = cast[incoming_speaker_id]["name"]
                conversation_block = (
                    f"\n\n【對話中】你正在跟{speaker_name}對話，這是這場對話的第{session['turns']}輪。"
                    f"對方剛才對你「{session['last_action']}」，說：「{session['last_utterance']}」\n"
                    f"你可以選擇回話延續對話（`intent.action`一樣選說話/喊話/悄悄話，`intent.target`"
                    f"設為{speaker_name}），也可以選擇不回話、去做別的事——如果你選擇不回話，這場"
                    f"對話就算結束了。要不要接話、接了要講什麼，由你自己判斷。"
                )

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
        ) + home_hint + conversation_block + DURATION_INSTRUCTION

        target_candidate_names = [cast[v["id"]]["name"] for v in visible]
        if absent_homeowner_name:
            target_candidate_names.append(absent_homeowner_name)

        tag = "⚡中斷重決" if was_interrupted else ""
        label = f"run{run_index} [{current_time}] {villager['name']}{tag}"
        if USE_GRAMMAR:
            grammar_for_call = rts.build_grammar_for_call(
                grammar, target_candidate_names, location_names
            )
            payload = rts.build_llm_payload(prompt, grammar_for_call)
            out, parse_ok, elapsed, meta = rts.call_llm_with_retry(payload, label)
            full_prompt = prompt
            raw_completion = meta.get("raw_completion")
        else:
            visible_names = set(target_candidate_names)
            all_names = {v["name"] for v in cast.values()}
            out, parse_ok, elapsed, raw_completion = call_llm_no_grammar_with_retry(
                prompt, label, location_names, visible_names, all_names
            )
            meta = {}
            # call_llm_no_grammar_with_retry() 內部會再接上 _NO_GRAMMAR_JSON_INSTRUCTION 才送出，
            # 這裡存的要是模型實際看到的完整文字，不能只存 prompt 半成品——DPO 訓練資料要求
            # prompt 跟 chosen/rejected 輸出必須對應到同一份「模型真正看到的輸入」。
            full_prompt = prompt + _NO_GRAMMAR_JSON_INSTRUCTION

        events_log.append({
            "event_index": len(events_log), "time": now, "id": cid, "name": villager["name"],
            "current_time": current_time, "location_before": me["location"], "was_interrupted": was_interrupted,
            "elapsed_sec": round(elapsed, 2), "parse_ok": parse_ok, "prompt": full_prompt, "output": out,
            "raw_completion": raw_completion,
            "truncated": meta.get("truncated"), "tokens_evaluated": meta.get("tokens_evaluated"),
            # 決策當下（做這個決定之前）的生理快照——2026-07-30 補上，讓「流血/扭到腳還
            # 選奔跑」這種硬規則違規可以事後從 transcript 直接稽核，不用重跑一次模擬。
            "physiology_before": {
                "health": me["physiology"]["health"], "bleeding": me["physiology"].get("bleeding", False),
                "sprained_ankle": me["physiology"].get("sprained_ankle", False), "money": me["physiology"]["money"],
            },
        })

        if incremental_out_path is not None:
            incremental_out_path.write_text(json.dumps({
                "run_index": run_index, "target_game_minutes": target_game_minutes,
                "run_elapsed_sec": round(time.time() - run_start, 2), "num_events": len(events_log),
                "interrupt_count": interrupt_count, "events": events_log, "in_progress": True,
            }, ensure_ascii=False, indent=2), encoding="utf-8")

        if not parse_ok:
            me["seq"] += 1
            heapq.heappush(heap, (now + 10, 1, me["seq"], cid))
            continue

        action = out["intent"]["action"]
        # 正常 grammar 版本靠 duration ::= [1-9][0-9]?[0-9]? 保證一定是合法整數；無grammar
        # 模式沒有這層保護，模型可能填出 0.5 這種小數、字串、甚至漏填，一路傳到
        # advance_time() 的除法運算會讓 format_time() 收到浮點數的 minute，":02d" 格式化
        # 直接炸掉（2026-07-31 實測撞到）——這裡強制轉成至少 1 的整數，轉不了就當 15 分鐘。
        try:
            duration = max(1, round(float(out["intent"]["duration_minutes"])))
        except (TypeError, ValueError, KeyError):
            duration = 15
        new_location = out["intent"]["location"]
        target_name = out["intent"]["target"]
        target_id = rts.normalize_target(target_name, name_to_id)
        speech_target_id = rts.normalize_target(out.get("speech_target"), name_to_id)
        emotion = out["emotion"]
        phys = me["physiology"]
        old_location = me["location"]

        # --- 執行前可行性檢查：吃飯/喝酒/治療/採草藥做不到就不消耗時間，同一時刻立刻
        # 重新決策，見上面 FEASIBILITY_GATED_ACTIONS 定義處的完整說明 ---
        if action in FEASIBILITY_GATED_ACTIONS:
            feasible, infeasible_reason = check_feasibility(
                action, phys, new_location, world_state, now,
                reports_filed_today=me.get("reports_filed_today", 0),
            )
            if not feasible:
                # 2026-08-07：這個事件已經在上面 events_log.append() 記錄過模型的原始宣告，
                # 但這裡不管是「重試」還是最後「強制改成發呆」，模型宣告的動作實際上都沒有
                # 真的執行（不消耗時間、不產生效果）——回頭在已經寫入的事件上補一個標記，
                # 讓分析腳本（例如 test_nested_action.py 的重複鎖定統計）可以排除掉這些
                # 「宣告了但沒真的發生」的事件，不然同一個角色連續打回票好幾次會被誤算成
                # 他自己選了好幾次重複動作，8/7 那次巢狀分類實驗阿吉的樣本就是被這個污染的。
                events_log[-1]["feasibility_rejected"] = True
                me["feasibility_retries"] += 1
                if me["feasibility_retries"] < FEASIBILITY_MAX_RETRIES:
                    # 這句話是給「下一次重試」看的，所以掛建議語——第一次宣告失敗本身
                    # （這一輪的 last_action_result，讀者是這一輪的 prompt，不是下一輪）
                    # 不受影響，維持原樣的中性失敗文字。
                    suggestion = (
                        FEASIBILITY_MONEY_SHORTAGE_SUGGESTION_TEXT if "錢不夠" in infeasible_reason
                        else FEASIBILITY_RETRY_SUGGESTION_TEXT
                    )
                    me["last_action_result"] = f"{infeasible_reason}。{suggestion}"
                    print(f"[{label}] 可行性檢查失敗（第 {me['feasibility_retries']} 次）："
                          f"{infeasible_reason}，同一時刻立刻重新決策")
                    me["seq"] += 1
                    heapq.heappush(heap, (now, 0, me["seq"], cid))
                    continue
                me["last_action_result"] = infeasible_reason
                print(f"[{label}] 可行性檢查連續失敗 {FEASIBILITY_MAX_RETRIES} 次，"
                      f"強制改成「{FEASIBILITY_FALLBACK_ACTION}」接手，避免卡死")
                action = FEASIBILITY_FALLBACK_ACTION
                duration = FEASIBILITY_FALLBACK_DURATION
                new_location = old_location
                target_name = None
                target_id = None
                # 用 forced_fallback_note 而不是直接寫 me["last_action_result"]——下面
                # action_result_note 那個區塊（吃飯/喝酒/…/治療判定）跑完後，最終組裝
                # last_action_result 時的 else 分支會直接覆蓋掉，一定要透過同一套組裝
                # 邏輯才能保留這句話（見下面 target_note/last_action_result 組裝處）。
                forced_fallback_note = f"{infeasible_reason}（已連續失敗 {FEASIBILITY_MAX_RETRIES} 次，強制改成發呆）"
                events_log[-1]["feasibility_forced_fallback"] = True
                events_log[-1]["executed_action"] = FEASIBILITY_FALLBACK_ACTION
                me["feasibility_retries"] = 0
            else:
                me["feasibility_retries"] = 0
                forced_fallback_note = None
        else:
            forced_fallback_note = None

        print(f"[{label}] {action}（{duration}分）{f'-> {target_name}' if target_name else ''} "
              f"@{new_location} [{emotion}] 血{phys['health']:.0f} 飢{phys['hunger']:.0f} "
              f"力{phys['stamina']:.0f} 悶{phys['boredom']:.0f} 錢{phys['money']:.0f} {elapsed:.2f}s")

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

        # --- 體力耗盡：強制送回家昏睡，直到體力回到 30 為止（用「在家睡覺」的正常恢復
        # 速率累加，不是原地打個盹）——2026-07-31 改版，取代原本「原地固定 +20」的簡化
        # 版本。這段會整個覆蓋掉這個角色這次事件原本要做的事：他還沒撐到宣告的動作完成
        # 就先昏過去了，所以連地點、動作、對象都改成「睡覺／在家／沒有對象」。---
        was_collapsed = phys["stamina"] <= 0 and not valid_sleep
        if was_collapsed:
            ticks_needed = max(1, -(-(30 - phys["stamina"]) // rts.STAMINA_SLEEP_DELTA))  # 向上取整
            for _ in range(ticks_needed):
                phys["hunger"] = rts.clamp(phys["hunger"] + rts.HUNGER_PER_TICK)
                phys["thirst"] = rts.clamp(phys["thirst"] + rts.THIRST_PER_TICK)
                phys["stamina"] = rts.clamp(phys["stamina"] + rts.STAMINA_SLEEP_DELTA)
            sub_ticks = ticks_needed
            duration = ticks_needed * rts.TICK_MINUTES
            action = "睡覺"
            new_location = self_home
            target_id = None
            target_name = None
            valid_sleep = True
            print(f"    💤 體力耗盡昏睡：{villager['name']} 被送回{self_home}，"
                  f"強制昏睡 {duration} 分鐘直到體力回到 {phys['stamina']}")

        # 2026-08-03：理由跟 run_tick_sim.py 同一段註解——機制性後果過去只讓效果靜默失效，
        # last_action_result 永遠只填萬用空話，模型從沒被告知具體失敗原因，違反村民AI規格書／
        # 技術架構規格書的硬性規定，這裡補上。
        action_result_note = None
        if action == "吃飯":
            if phys["money"] >= rts.EAT_COST:
                phys["money"] -= rts.EAT_COST
                phys["hunger"] = rts.clamp(phys["hunger"] - rts.EAT_HUNGER_RELIEF)
                action_result_note = f"吃飯 → 成功，花了{rts.EAT_COST}元"
            else:
                action_result_note = f"吃飯 → 失敗：錢不夠（需要 {rts.EAT_COST} 元，只有 {phys['money']:.0f} 元）"
        if action == "喝酒":
            if phys["money"] >= rts.DRINK_COST:
                phys["money"] -= rts.DRINK_COST
                phys["thirst"] = rts.clamp(phys["thirst"] - rts.DRINK_THIRST_RELIEF)
                action_result_note = f"喝酒 → 成功，花了{rts.DRINK_COST}元"
            else:
                action_result_note = f"喝酒 → 失敗：錢不夠（需要 {rts.DRINK_COST} 元，只有 {phys['money']:.0f} 元）"
        if action == "表演":
            phys["money"] += rts.PERFORM_INCOME
            action_result_note = f"表演 → 成功，賺了 {rts.PERFORM_INCOME} 元"
        if action == "採草藥":
            rts.add_inventory_item(phys, *rts.GATHER_ITEM)
            action_result_note = f"採草藥 → 成功，拿到 {rts.GATHER_ITEM[0]}"
            if new_location == "藥草叢":
                # 可行性檢查那邊只查不扣，這裡才是真正執行、真的把庫存扣掉的地方——
                # 兩邊都要判斷同一個 location 條件（不在藥草叢採草藥不受庫存限制，
                # 維持原本「地點寬鬆」的既有行為，這次範圍只加庫存機制，不修這個）。
                world_state["herb_patch_stock"] = max(0, world_state["herb_patch_stock"] - 1)
        if action == "打獵":
            for item_name, qty in rts.HUNT_ITEMS:
                rts.add_inventory_item(phys, item_name, qty)
            action_result_note = "打獵 → 成功，帶回獵物"
        if action == "賣東西":
            sold_item, price = rts.sell_one_item(phys, rts.SELL_PRICES)
            if sold_item:
                phys["money"] += price
                action_result_note = f"賣東西 → 成功，賣了 {sold_item} 得 {price} 元"
            else:
                action_result_note = "賣東西 → 失敗：背包裡沒有可以賣的東西"
        if action == "治療":
            if new_location != "藥草鋪":
                action_result_note = "治療 → 失敗：不在藥草鋪"
            elif phys["money"] < rts.HEAL_COST:
                action_result_note = f"治療 → 失敗：錢不夠（需要 {rts.HEAL_COST} 元，只有 {phys['money']:.0f} 元）"
            else:
                phys["money"] -= rts.HEAL_COST
                phys["health"] = rts.clamp(phys["health"] + rts.HEAL_IMMEDIATE_BONUS)
                phys["bleeding"] = False
                phys["severe_injury"] = False
                phys["recovering"] = phys["health"] < 100
                action_result_note = f"治療 → 成功，花了{rts.HEAL_COST}元"
        if action == "舉報":
            # 可行性檢查已經擋過地點/每日上限，這裡進來的一定是可以真的執行的——這裡只
            # 負責記錄投訴人數、判斷要不要觸發逮捕，不重複判斷地點/上限。
            if not target_id or target_id == cid:
                action_result_note = "舉報 → 失敗：沒有指定明確的投訴對象"
            else:
                me["reports_filed_today"] = me.get("reports_filed_today", 0) + 1
                target_state = state[target_id]
                target_state["accusers"].add(cid)
                num_accusers = len(target_state["accusers"])
                if num_accusers >= REPORT_ARREST_THRESHOLD:
                    target_state["detained_until"] = now + duration + REPORT_DETENTION_MINUTES
                    target_state["accusers"] = set()
                    action_result_note = (
                        f"舉報 → 成功，{cast[target_id]['name']} 累積被 {num_accusers} 人投訴，"
                        f"已經被抓進洗心革面所"
                    )
                else:
                    action_result_note = (
                        f"舉報 → 成功，{cast[target_id]['name']} 目前累積被 {num_accusers} 人投訴"
                        f"（滿 {REPORT_ARREST_THRESHOLD} 人會被抓）"
                    )

        # --- 攻擊命中判定：只有目標在同地點才會真的打中（跟中斷機制共用同地點前提）---
        target_same_location = target_id and state[target_id]["alive"] and state[target_id]["location"] == old_location
        # 房屋偷竊（2026-08-05）：小偷站在目標的家、目標本人不在場，一樣算合法偷竊對象——
        # 跟 target_same_location 分開判斷，不影響攻擊/舉報等其他動作沿用 target_same_location。
        target_is_absent_from_home = (
            target_id and state[target_id]["alive"]
            and old_location == c.home_name(cast[target_id]["name"])
            and state[target_id]["location"] != old_location
        )

        if action == "偷竊":
            is_house_steal = (not target_same_location) and target_is_absent_from_home
            if not target_same_location and not is_house_steal:
                action_result_note = (
                    f"偷竊 → 失敗：{cast[target_id]['name'] if target_id else '目標'}不在附近"
                )
            else:
                target_phys = state[target_id]["physiology"]
                stole_success = target_phys["money"] > 0 and rts.random.random() < STEAL_SUCCESS_CHANCE
                if stole_success:
                    stolen = min(target_phys["money"], rts.random.randint(*STEAL_AMOUNT_RANGE))
                    target_phys["money"] -= stolen
                    phys["money"] += stolen
                    if is_house_steal:
                        action_result_note = f"偷竊 → 成功，闖入{cast[target_id]['name']}家中偷到{stolen:.0f}元"
                        victim_note = f"你發現家裡被翻過，少了{stolen:.0f}元，看起來是{cast[cid]['name']}幹的"
                    else:
                        action_result_note = f"偷竊 → 成功，從{cast[target_id]['name']}身上偷到{stolen:.0f}元"
                        victim_note = f"{cast[cid]['name']}偷了你{stolen:.0f}元，被你發現了"
                else:
                    if is_house_steal:
                        action_result_note = f"偷竊 → 失敗：闖入{cast[target_id]['name']}家中沒找到值錢的東西"
                        victim_note = f"你發現家裡被翻過，但{cast[cid]['name']}好像沒找到什麼值錢的東西"
                    else:
                        action_result_note = f"偷竊 → 失敗：被{cast[target_id]['name']}發現，沒偷到"
                        victim_note = f"{cast[cid]['name']}想偷你的錢，被你發現了，沒得手"
                # 不論成功失敗都被發現（POC 簡化，不做隱蔽判定）——對象好感度重挫，
                # 且讓對象下一輪看得到「被偷了」這件事，不是只有背後的關係分數變動，
                # 這同時也是要給「舉報」更明確的觸發動機（見上面 STEAL_RELATIONSHIP_PENALTY 註解）。
                relationships.setdefault(target_id, {})
                relationships[target_id][cid] = max(
                    -100, relationships[target_id].get(cid, 0) - STEAL_RELATIONSHIP_PENALTY
                )
                state[target_id]["last_action_result"] = victim_note

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
        if forced_fallback_note:
            me["last_action_result"] = forced_fallback_note
        elif attack_hit is True:
            me["last_action_result"] = f"{action}{target_note} → 打中了"
        elif attack_hit is False:
            me["last_action_result"] = f"{action}{target_note} → 揮空了"
        elif action_result_note:
            me["last_action_result"] = action_result_note
        else:
            me["last_action_result"] = f"{action}{target_note} → 已宣告（DES 引擎，未經完整 guardrail 判定）"

        me["today_actions"].add(action)
        me["today_locations"].add(new_location)
        if target_id:
            me["today_people"].add(target_id)
        me["last_action"] = action
        me["location"] = new_location
        me["last_emotion"] = emotion
        me["last_declaration"] = {
            "time": now, "action": action, "target_id": target_id,
            "speech_target_id": speech_target_id, "speech": out["speech"],
        }

        # 對話追蹤：更新/結束session。這一刻cid實際做的事才是真相，跟prompt階段查到的
        # incoming_speaker_id分開處理——incoming_speaker_id只代表「決策前有沒有人在等我
        # 接話」，不代表這一輪cid真的接了。
        # 2026-08-10：「這句話說給誰聽」不再只看 intent.target——喝酒/吃飯這類本身沒有
        # 對象的動作，也可能同時填了 speech_target（見grammar註解），這裡一併當作有效
        # 的對話對象，不然這種「邊喝酒邊聊天」的交流會被漏掉，繼續量不到。
        conversation_target_id = target_id if (action in _DIALOGUE_ACTIONS and target_id) else speech_target_id
        if conversation_target_id and out["speech"]:
            key = frozenset((cid, conversation_target_id))
            existing = conversation_sessions.get(key)
            turns = existing["turns"] + 1 if existing else 1
            conversation_sessions[key] = {
                "turns": turns, "last_speaker_id": cid, "last_utterance": out["speech"],
                "last_action": action, "last_time": now,
            }
            # cid開了一場新對話，但手上還積著另一個人剛剛的話沒回——那場算是被cid晾掉了，
            # 清掉避免之後對方查詢時看到一場其實已經被cid拋下的對話還顯示「輪到我」。
            if incoming_speaker_id is not None and incoming_speaker_id != conversation_target_id:
                conversation_sessions.pop(frozenset((cid, incoming_speaker_id)), None)
        elif incoming_speaker_id is not None:
            # cid這輪決策沒有回話給正在等待的人（選了別的動作，或說話對象換成別人但已經在
            # 上面那個分支處理過）——對話到這裡算結束，不留著讓對方以後誤以為還在進行中。
            conversation_sessions.pop(frozenset((cid, incoming_speaker_id)), None)

        # --- 睡眠反思：只在「一段連續睡眠的第一個事件」觸發一次（跟 run_tick_sim.py 同邏輯）；
        # 體力耗盡強制昏睡（見上面的 was_collapsed 區塊，已經把 action/location 都改成
        # 「睡覺／在家」，這裡的 valid_sleep 自然是 True，不用再另外判斷一次）——2026-07-30
        # 發現部分角色幾乎永遠不會主動選擇睡覺，靠「選擇睡覺」觸發的反思機制對他們形同
        # 虛設，補這條路保底一定會有觸發到的機會。---
        if valid_sleep and not me["is_sleeping"]:
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
                tag = "（體力耗盡昏睡）" if was_collapsed else ""
                print(f"[{label}] 睡眠反思{tag}：{reflection['reflection']}｜人格變動 {reflection['personality_delta']}｜"
                      f"今天想做：{reflection['today_plan']}")
        me["is_sleeping"] = valid_sleep

        # --- 中斷機制：命中同地點目標、且動作屬於 INTERRUPTIBLE_TRIGGER_ACTIONS，
        # 若目標正在進行中的動作尚未到期，強制作廢並提前重新決定 ---
        # 2026-08-04：說話類加進中斷觸發後，腳本化測試發現兩人對話會互相打斷對方還沒講完
        # 的話，變成來回插話的迴圈，不像正常對話。排除「說話類打斷說話類」這一種組合——
        # 攻擊之類還是可以正常打斷正在講話的人（被打斷講話敘事上合理），只有雙方都是
        # 說話類的時候才不觸發，讓一輪對話至少能講完。
        if target_id and action in INTERRUPTIBLE_TRIGGER_ACTIONS and target_same_location:
            victim = state[target_id]
            vip = victim["in_progress"]
            is_dialogue_vs_dialogue = (
                vip and action in _DIALOGUE_ACTIONS and vip["action"] in _DIALOGUE_ACTIONS
            )
            if victim["alive"] and vip and vip["end_time"] > now and not is_dialogue_vs_dialogue:
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
        "final_world_state": world_state,
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
