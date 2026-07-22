"""Ailley POC — Agent Loop 的跨天持久化層

純粹負責讀寫硬碟：角色名單（跨天固定不變）、狀態（目前第幾天、下一個全域記憶編號）、
每位角色的記憶清單。不含任何呼叫 llama-server 的邏輯（那些留在 agent_loop.py，
因為需要 call_director()／EMBEDDING_SERVER_URL 這些呼叫端的設定）。

global_index 是跨越角色整個生命週期單調遞增的編號（不是每天歸零的回合數），新近度衰減
用這個編號計算，這樣不管模擬到第幾天，「多久以前」的定義都一致，不需要另外處理
「天」跟「回合」兩種時間單位的換算。
"""

import json
from pathlib import Path

POC_DIR = Path(__file__).parent
STORE_DIR = POC_DIR / "memory_store"
ROSTER_PATH = STORE_DIR / "roster.json"
STATE_PATH = STORE_DIR / "state.json"

MEMORY_RECENCY_DECAY = 0.95
MEMORY_TOP_K = 6


def load_roster(generator_fn):
    """讀取既有名單；不存在時（第一次執行）用 generator_fn() 生成一次並存檔，
    之後每次執行都讀這份，角色名單、核心能源、密鑰持有者跨天保持一致。"""
    STORE_DIR.mkdir(parents=True, exist_ok=True)
    if ROSTER_PATH.exists():
        return json.loads(ROSTER_PATH.read_text(encoding="utf-8"))
    roster = generator_fn()
    ROSTER_PATH.write_text(json.dumps(roster, ensure_ascii=False, indent=2), encoding="utf-8")
    return roster


def load_state() -> dict:
    if STATE_PATH.exists():
        return json.loads(STATE_PATH.read_text(encoding="utf-8"))
    return {"current_day": 0, "next_global_index": 0}


def save_state(state: dict) -> None:
    STORE_DIR.mkdir(parents=True, exist_ok=True)
    STATE_PATH.write_text(json.dumps(state, ensure_ascii=False, indent=2), encoding="utf-8")


def _memory_path(char_id: str) -> Path:
    return STORE_DIR / f"memory_{char_id}.json"


def load_memories(char_id: str) -> list:
    path = _memory_path(char_id)
    if path.exists():
        return json.loads(path.read_text(encoding="utf-8"))
    return []


def save_memories(char_id: str, memories: list) -> None:
    STORE_DIR.mkdir(parents=True, exist_ok=True)
    _memory_path(char_id).write_text(json.dumps(memories, ensure_ascii=False, indent=2), encoding="utf-8")


def retrieve_memories(memories: list, current_index: int, top_k: int = MEMORY_TOP_K) -> list:
    """新近度（指數衰減，用 global_index 換算）+ 重要性（正規化到 0-1）加權排序，取分數
    最高的 top_k 筆，依原始時間順序排列後回傳。刻意不含相關性項——已經在
    poc_mode_a/dialogue_ping_pong_memory_embed.py 驗證過相關性檢索對話會反而強化話題
    卡住的傾向，這次不重蹈覆轍。embedding 還是照存（見 agent_loop.py），只是不用在這個
    排序公式裡，留給之後有明確查找情境時再接。"""
    scored = []
    for m in memories:
        recency = MEMORY_RECENCY_DECAY ** (current_index - m["global_index"])
        importance = m["importance"] / 10
        scored.append((recency + importance, m))
    scored.sort(key=lambda pair: pair[0], reverse=True)
    top = [m for _, m in scored[:top_k]]
    top.sort(key=lambda m: m["global_index"])
    return top
