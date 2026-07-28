"""Ailley POC — poc_village_sim 記憶檢索層（睡眠反思產物用）

只做記憶的評分與檢索邏輯，不含任何 LLM 呼叫（呼叫邏輯留在 run_tick_sim.py，跟
poc_agent_loop/memory_store.py 刻意分開呼叫端與儲存端是同一個原則）。

評分公式沿用 poc_agent_loop/memory_store.py 已經驗證過的版本：新近度（指數衰減）+
重要性，刻意不含相關性（embedding）項——poc_mode_a/dialogue_ping_pong_memory_embed.py
已經驗證過相關性檢索會強化對話卡住/重複的傾向，這裡不重蹈覆轍。

跟 poc_agent_loop 的差異：這裡直接用「tick 編號」當新近度衰減的時間軸（不需要另外維護
一個跨角色共用的 global_index，tick 本身在整個模擬裡就是單調遞增、跨角色共用的）。

這支模組目前只在單次模擬執行的記憶體內使用（配合 run_tick_sim.py 每次獨立模擬都重置
狀態），還沒做跨執行的硬碟持久化——poc_agent_loop/run_multiday.py 那種「讀取既有存檔接續」
的模式，等 poc_village_sim 有自己的多日批次執行入口時再補。
"""

MEMORY_RECENCY_DECAY = 0.95
MEMORY_TOP_K = 6


def retrieve_memories(memories: list, current_tick: int, top_k: int = MEMORY_TOP_K) -> list:
    """新近度（指數衰減）+ 重要性（正規化到 0-1）加權排序，取分數最高的 top_k 筆，
    依原始 tick 順序排列後回傳。"""
    scored = []
    for m in memories:
        recency = MEMORY_RECENCY_DECAY ** (current_tick - m["tick"])
        importance = m["importance"] / 10
        scored.append((recency + importance, m))
    scored.sort(key=lambda pair: pair[0], reverse=True)
    top = [m for _, m in scored[:top_k]]
    top.sort(key=lambda m: m["tick"])
    return top


def render_memory_block(memories: list) -> str:
    if not memories:
        return "（尚無長期記憶）"
    return "\n".join(f"- {m['content']}" for m in memories)
