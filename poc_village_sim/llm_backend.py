"""統一的 LLM 呼叫介面——讓呼叫端（目前先接 server.py，`run_tick_sim.py`／
`run_des_sim.py` 之後要接也可以直接重用）不用關心底層打的是本地 llama-server 還是
雲端 API，組員套入 API key 後改個環境變數就能切換，不用改程式碼。

切換方式：環境變數 `LLM_BACKEND`，預設／沒設定／設錯值都當 `"local"` 處理，不會
意外燒到雲端額度。設成 `"cloud"` 才會改打雲端，另外要設定 `LLM_CLOUD_API_KEY`
（必要）、`LLM_CLOUD_MODEL`／`LLM_CLOUD_URL`（有預設值，預設指到 OpenRouter 的
`openai/gpt-oss-20b:free`）。

本地路徑直接重用 `run_tick_sim.py` 已經驗證過的 `build_llm_payload()`／
`call_llm_with_retry()`，不重新實作，零行為改變、零回歸風險——這條路徑本來就是
production 在跑的，不能因為加這層抽象就有機會壞掉。

雲端沒有 grammar 硬約束支援，統一走「prompt 尾端加 JSON 格式要求 + 事後驗證」，
驗證邏輯（emotion／action／location／target 合法性）跟 `run_des_sim.py` 的
`call_llm_no_grammar_with_retry()` 同一套精神，`_extract_first_json()` 直接重用
`run_des_sim.py` 那份（無grammar時模型可能連續吐好幾個 JSON 黏在一起，貪婪正則
會解析失敗，不能用貪婪正則抓大括號）。

連線重試原則兩邊一致（這幾天修過的教訓，`run_tick_sim.py`／`run_des_sim.py` 的
`call_llm_with_retry` 開頭註解都寫過同一件事）：4xx／雲端免費額度用盡（429 訊息含
`free-models-per-day`）是請求內容本身的問題，同一份payload重打還是會錯，不重試；
5xx／連線例外才是暫時性問題，無限重試＋指數退避封頂。
"""
import json
import os
import sys
import time
from pathlib import Path

import requests

sys.path.insert(0, str(Path(__file__).parent))
import run_tick_sim as rts
import run_des_sim as rds

LLM_BACKEND = os.environ.get("LLM_BACKEND", "local").strip().lower()
CLOUD_API_KEY = os.environ.get("LLM_CLOUD_API_KEY", "")
CLOUD_MODEL = os.environ.get("LLM_CLOUD_MODEL", "openai/gpt-oss-20b:free")
CLOUD_URL = os.environ.get("LLM_CLOUD_URL", "https://openrouter.ai/api/v1/chat/completions")

_VALID_EMOTIONS = rds._VALID_EMOTIONS


def _cloud_json_instruction(duration_field: str) -> str:
    intent_fields = (
        f'"action": "從允許清單選一個中文字串", "{duration_field}": 整數, '
        '"target": "字串或null", "location": "從允許清單選一個中文字串"'
    )
    schema = (
        '{"emotion": "8選1英文字串", "intent": {' + intent_fields + '}, '
        '"inner_monologue": "字串", "speech": "字串或null", "speech_volume": "normal/shout/whisper"}'
    )
    return (
        "\n\n【格式要求（雲端模型專用，本地版用 grammar 硬約束，這裡靠你自己遵守）】\n"
        "只能輸出一個 JSON 物件，不要有任何 JSON 以外的文字、不要用 markdown code fence。"
        f"欄位跟型別：\n{schema}"
    )


def _call_cloud(prompt: str, label: str, location_names, visible_names, valid_actions,
                 duration_field: str) -> tuple[dict | None, bool, float, str]:
    if not CLOUD_API_KEY:
        print(f"[{label}] LLM_BACKEND=cloud 但 LLM_CLOUD_API_KEY 沒設定，無法呼叫")
        return {"parse_error": True, "raw": "", "config_error": "missing_api_key"}, False, 0.0, ""

    headers = {"Authorization": f"Bearer {CLOUD_API_KEY}", "Content-Type": "application/json"}
    payload = {
        "model": CLOUD_MODEL,
        "messages": [{"role": "user", "content": prompt + _cloud_json_instruction(duration_field)}],
        "temperature": 0.7,
    }
    last_elapsed = 0.0
    for attempt in range(5):
        t0 = time.time()
        try:
            resp = requests.post(CLOUD_URL, headers=headers, json=payload, timeout=60)
        except requests.exceptions.RequestException as e:
            print(f"[{label}] 連線錯誤（第 {attempt + 1} 次，{e}），3 秒後重試")
            time.sleep(3)
            continue
        elapsed = time.time() - t0
        last_elapsed = elapsed
        if resp.status_code == 429 and "free-models-per-day" in resp.text:
            print(f"[{label}] 雲端免費每日額度用盡，不重試：{resp.text[:200]}")
            return None, False, elapsed, ""
        if not resp.ok:
            print(f"[{label}] HTTP {resp.status_code}（第 {attempt + 1} 次）：{resp.text[:200]}，重試")
            time.sleep(3)
            continue
        # resp.ok（HTTP 200）不保證回應真的有 choices——OpenRouter 內部路由/供應商層級
        # 出錯時，偶爾會回 200 但 body 只有 error 欄位、沒有 choices，直接當成功讀取會
        # KeyError 炸掉（2026-08-04 雲端多人測試實際撞到）。當成跟「content是空的」同一類
        # 暫時性問題重試，不要讓整個模擬直接崩潰。
        body = resp.json()
        choices = body.get("choices")
        if not choices:
            print(f"[{label}] 回應沒有 choices（{str(body)[:200]}），重試")
            time.sleep(2)
            continue
        raw = choices[0].get("message", {}).get("content")
        if not raw:
            print(f"[{label}] content 是空的，重試")
            time.sleep(2)
            continue
        json_str = rds._extract_first_json(raw)
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
        if valid_actions and intent.get("action") not in valid_actions:
            print(f"[{label}] action 不合法：{intent.get('action')}，重試")
            continue
        if location_names is not None and intent.get("location") not in location_names:
            print(f"[{label}] location 不合法：{intent.get('location')}，重試")
            continue
        target = intent.get("target")
        if target is not None and visible_names is not None and target not in visible_names:
            print(f"[{label}] target 不合法（幻覺出視野外的人）：{target}，重試")
            continue
        return out, True, elapsed, raw
    return None, False, last_elapsed, ""


def call_llm(prompt: str, label: str, *, grammar: str = "", location_names=None,
             visible_names=None, valid_actions=None, duration_field: str = "duration_minutes",
             ) -> tuple[dict | None, bool, float, str]:
    """統一入口，回傳 (out, parse_ok, elapsed, raw_completion) 四元組，跟兩支引擎現有
    的呼叫函式回傳格式一致。

    - `LLM_BACKEND=local`（預設）：忽略 location_names/visible_names/valid_actions/
      duration_field，直接重用 `rts.build_llm_payload()`＋`rts.call_llm_with_retry()`，
      grammar 硬約束已經保證合法性，不需要事後驗證。
    - `LLM_BACKEND=cloud`：忽略 grammar（雲端沒有這個能力），改走事後驗證，
      location_names/visible_names/valid_actions 這時候才是必要參數。
    - `duration_field`：兩支引擎跟 server.py 的時長欄位命名不一樣
      （`duration_minutes` vs `duration_ticks`），雲端模式需要知道要教模型填哪個
      欄位名稱，本地模式不受影響（grammar 本身已經鎖好欄位名）。
    """
    if LLM_BACKEND == "cloud":
        out, parse_ok, elapsed, raw = _call_cloud(
            prompt, label, location_names, visible_names, valid_actions, duration_field
        )
        meta = {"truncated": False, "tokens_evaluated": None, "raw_completion": raw}
        return out, parse_ok, elapsed, meta

    payload = rts.build_llm_payload(prompt, grammar)
    out, parse_ok, elapsed, meta = rts.call_llm_with_retry(payload, label)
    return out, parse_ok, elapsed, meta
