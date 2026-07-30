"""給組員（Godot 端）串接用的最小 API 伺服器。

只做一件事：收一個角色的「當下情境」，組出跟 run_tick_sim.py 完全一樣的 prompt／grammar，
呼叫 llama-server 拿決策結果，回傳 JSON。不做世界狀態管理（不記錄村民生理數值變化、
不維護時間軸）——那些是正式引擎（run_tick_sim.py／run_des_sim.py）的責任，這支只是讓
組員在串接階段先看得到「丟資料進去、拿得到什麼格式的回覆」。

啟動方式：
    uvicorn server:app --host 0.0.0.0 --port 8100 --reload

組員從 Tailscale 網段呼叫：
    POST http://<這台筆電的 tailscale ip>:8100/decide
"""
import threading
from pathlib import Path

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

import characters as c
import run_tick_sim as rts

POC_DIR = Path(__file__).parent
app = FastAPI(title="poc_village_sim 決策 API")

# 用專屬的 prompt 變體（多一句 duration_ticks 單位說明），不動共用的
# villager_system_prompt.txt——run_des_sim.py 那邊刻意不加語意提示、純看 AI 自然填什麼
# 的實驗設計不能被這裡影響到。
TEMPLATE = (POC_DIR / "prompts" / "villager_system_prompt_server.txt").read_text(encoding="utf-8")
# 用「幾個 10 秒 tick」為時長單位的 grammar（duration_ticks），跟 run_des_sim.py 那邊
# 分鐘制的 turn_duration_experiment.gbnf.template 是分開的兩條線，見該 grammar 檔開頭註解。
GRAMMAR = (POC_DIR / "grammar" / "turn_duration_ticks.gbnf.template").read_text(encoding="utf-8")
TICK_SECONDS = 10  # 遊戲內時間顆粒度：每個 duration_ticks 單位＝這麼多秒

CAST = c.load_all_characters()
RELATIONSHIPS = c.load_relationships()
HOME_NAMES = [c.home_name(v["name"]) for v in CAST.values()]
LOCATION_NAMES = rts.SHARED_LOCATIONS + HOME_NAMES
LOCATION_LIST_STR = "、".join(LOCATION_NAMES)

# 每個角色「第一次呼叫」各自當自己的相對時間原點（0 秒）——鐵牛跟阿蘭的時間軸互不相干，
# 不是共用同一條全域時間軸。之後每次呼叫回傳的動作開始戳記＝這個角色前面所有動作時長
# （秒）的累加值。伺服器重啟就會歸零；同一個角色也可以在 request 裡帶 reset_clock=true
# 手動重新歸零（例如組員重新開一輪測試）。
# 用 lock 保護是因為 uvicorn 對同步 def 的 endpoint 會丟進 threadpool 平行執行，
# 同一個角色如果被連續呼叫兩次可能會撞在一起改到同一份計數。
_clock_lock = threading.Lock()
_character_clocks: dict[str, int] = {}  # character_id -> 累積秒數


class VisibleCharacter(BaseModel):
    id: str = Field(..., description="看得到的其他角色 id，例如 zhou")
    activity: str = Field(..., description="這個人目前在做什麼的描述文字，例如「在「餐酒館」」")


class DecideRequest(BaseModel):
    character_id: str = Field(..., description="要做決策的角色 id：alan/zhou/mei/tie/aji")
    current_time: str = Field(..., description="遊戲內目前時間文字，例如「第3天 19:40」")
    location: str = Field(..., description="這個角色目前所在地點，需在地點清單內（見 /locations）")
    visible: list[VisibleCharacter] = Field(
        default_factory=list, description="同地點看得到的其他角色清單，可為空陣列"
    )
    recent_event: str = Field(
        default="上一刻村子裡各自在忙自己的事，沒有人特別找你",
        description="上一刻發生的事（有人找他互動就填互動描述，沒有就用預設句子）",
    )
    last_emotion: str = Field(default="neutral", description="上一刻的情緒標籤")
    last_action_result: str = Field(default="", description="上一個動作的結果描述，沒有就空字串")
    recent_memory: str = Field(default="", description="要餵給模型的近期記憶摘要文字，沒有就空字串")
    physiology_override: dict | None = Field(
        default=None,
        description="要覆蓋這個角色目前生理數值/金錢/物品欄時填（不填就用 characters/<id>.json 的當前存檔值）",
    )
    reset_clock: bool = Field(
        default=False,
        description="true 的話把這個角色的相對時間原點重設成這一次呼叫（offset 從 0 重新算），"
                    "平常呼叫不用填",
    )


@app.get("/health")
def health():
    return {"ok": True}


@app.get("/locations")
def locations():
    """回傳目前合法的地點清單，組 location／visible 欄位時要對照這份。"""
    return {"locations": LOCATION_NAMES}


@app.get("/characters")
def list_characters():
    """回傳目前可用的角色 id 清單。"""
    return {"characters": list(CAST.keys())}


@app.post("/decide")
def decide(req: DecideRequest):
    if req.character_id not in CAST:
        raise HTTPException(400, f"未知的 character_id：{req.character_id}，合法值見 /characters")
    if req.location not in LOCATION_NAMES:
        raise HTTPException(400, f"未知的 location：{req.location}，合法值見 /locations")
    for v in req.visible:
        if v.id not in CAST:
            raise HTTPException(400, f"visible 裡有未知的角色 id：{v.id}")

    villager = CAST[req.character_id]
    if req.physiology_override:
        villager = {**villager, "physiology": {**villager["physiology"], **req.physiology_override}}

    visible_list = [v.model_dump() for v in req.visible]

    prompt = c.build_villager_prompt(
        TEMPLATE, world_lore=rts.WORLD_LORE_PLACEHOLDER, villager=villager, relationships=RELATIONSHIPS,
        current_time=req.current_time,
        location=req.location,
        visible=visible_list,
        recent_event=req.recent_event,
        last_emotion=req.last_emotion,
        last_action_result=req.last_action_result,
        recent_memory=req.recent_memory,
        location_list=LOCATION_LIST_STR,
    )
    grammar_for_call = rts.build_grammar_for_call(
        GRAMMAR, [CAST[v.id]["name"] for v in req.visible], LOCATION_NAMES
    )
    payload = {
        "prompt": prompt, "grammar": grammar_for_call, "temperature": 0.7,
        "top_p": 0.9, "top_k": 40, "repeat_penalty": 1.0,
        "repeat_last_n": 256, "n_predict": 300, "cache_prompt": True,
    }

    with _clock_lock:
        if req.reset_clock:
            _character_clocks[req.character_id] = 0
        action_start_offset_seconds = _character_clocks.get(req.character_id, 0)

    out, parse_ok, elapsed = rts.call_llm_with_retry(payload, label=f"api {req.character_id}")
    if not parse_ok or out is None:
        raise HTTPException(502, "llama-server 呼叫失敗或回傳內容無法解析成 JSON，請重試")

    duration_seconds = out["intent"]["duration_ticks"] * TICK_SECONDS
    with _clock_lock:
        _character_clocks[req.character_id] = action_start_offset_seconds + duration_seconds

    return {
        "character_id": req.character_id,
        "elapsed_seconds": round(elapsed, 2),
        "action_start_offset_seconds": action_start_offset_seconds,
        "action_duration_seconds": duration_seconds,
        "output": out,
    }
