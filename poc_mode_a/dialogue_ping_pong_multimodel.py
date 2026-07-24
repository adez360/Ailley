"""Ailley POC 實驗版 — multimodel：一個村民一個語言模型，取代「同一顆模型跑兩個 session」

跟 dialogue_ping_pong_memory.py 的唯一架構差異：原本紅村/藍村兩側都是同一顆 llama-server
（同一個模型檔案）用不同 prompt 各自呼叫一次，資訊隔離靠「各自只看自己視角的 prompt」達成，
底層模型是同一顆。這版改成紅村跟藍村各自指定一個不同的 GGUF 模型檔案，回合輪到誰發言，
就把 llama-server 背後實際載入的模型換成那位村民指定的那顆——紅村用 Qwen2.5-7B，藍村用
Mistral-7B-v0.3（這兩顆是這次 session 配對切換測試驗證過、切換耗時能穩定收斂到 1-2 秒的組合，
見 note：POC 紀錄 - 多模型輪替啟動測試）。

其他邏輯（記憶流檢索、停滯偵測、洩漏偵測、prompt 組裝、輸出格式）完全沿用
dialogue_ping_pong_memory.py，不重新設計。

前置需求：跟 dialogue_ping_pong_memory.py 相同，但**不需要**自己先手動啟動 llama-server——
這支腳本自己管理 llama-server 的啟動/關閉/切換（要在跟 llama.cpp 執行檔、GGUF 模型檔同一台
機器上跑，預期路徑結構跟 poc/ 那支的部署方式一致：LLAMA_SERVER_BIN／MODELS_DIR 預設值假設
llama.cpp 建置產物跟 *.gguf 檔案都在 poc_mode_a/ 的上一層目錄）。

環境變數：
  AILLEY_MODEL_RED／AILLEY_MODEL_BLUE：紅村／藍村各自使用的 GGUF 檔名（預設見 MODEL_BY_SIDE）
  AILLEY_LLAMA_SERVER_BIN：llama-server 執行檔路徑（預設 ../llama.cpp/build/bin/llama-server）
  AILLEY_MODELS_DIR：GGUF 模型檔所在目錄（預設 ..，也就是跟 poc_mode_a/ 同一層的上層目錄）
  其餘跟 dialogue_ping_pong_memory.py 完全一致（AILLEY_MODE_A_MAX_TURNS／AILLEY_MODE_A_STAGNATION／
  AILLEY_SEED／AILLEY_TEMPERATURE／AILLEY_SAMPLING_EXTRA）。
"""

import atexit
import difflib
import json
import os
import random
import re
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

import requests
from opencc import OpenCC

from characters import generate_fixed_roster, pick_encounter

_OPENCC = OpenCC("s2t")

POC_DIR = Path(__file__).parent
SERVER_HOST = "127.0.0.1"
SERVER_PORT = 8080
SERVER_URL = f"http://{SERVER_HOST}:{SERVER_PORT}/completion"
HEALTH_URL = f"http://{SERVER_HOST}:{SERVER_PORT}/health"
TRANSCRIPT_DIR = POC_DIR / "transcripts"

TEMPERATURE = float(os.environ.get("AILLEY_TEMPERATURE", "0.7"))
TOP_P = 0.9
TOP_K = 40
REPEAT_PENALTY = 1.0
REPEAT_LAST_N = 256
REQUEST_TIMEOUT_SEC = 600
MAX_TURNS = int(os.environ.get("AILLEY_MODE_A_MAX_TURNS", "10"))
STAGNATION_ENABLED = os.environ.get("AILLEY_MODE_A_STAGNATION", "1") != "0"

SEED = int(os.environ["AILLEY_SEED"]) if os.environ.get("AILLEY_SEED") else None
EXTRA_SAMPLING = json.loads(os.environ.get("AILLEY_SAMPLING_EXTRA", "{}"))

TACTIC_LABEL = {
    "bluff": "虛張聲勢",
    "pressure": "步步進逼",
    "empathy_bait": "示弱誘敵",
    "misdirect": "轉移話題",
    "retreat": "戰略撤退",
    "none": "日常閒聊",
}

# 兩村各自指定的模型檔案。預設用這次 session 配對切換測試驗證過的組合（合計 8.5GB，
# 在這台機器 14GB 可用 RAM 下能整組留在 page cache 熱區，來回切換穩定在 1-2 秒級，
# 見 note：POC 紀錄 - 多模型輪替啟動測試「分組配對切換測試」章節）。
MODEL_BY_SIDE = {
    "red": os.environ.get("AILLEY_MODEL_RED", "Qwen2.5-7B-Instruct-Q4_K_M.gguf"),
    "blue": os.environ.get("AILLEY_MODEL_BLUE", "Mistral-7B-Instruct-v0.3-Q4_K_M.gguf"),
}

LLAMA_SERVER_BIN = Path(os.environ.get(
    "AILLEY_LLAMA_SERVER_BIN", str(POC_DIR.parent / "llama.cpp" / "build" / "bin" / "llama-server")
))
MODELS_DIR = Path(os.environ.get("AILLEY_MODELS_DIR", str(POC_DIR.parent)))


# ---------------------------------------------------------------------------
# 模型切換：管理背後 llama-server 的啟動/關閉，回合輪到哪一村發言就確保載入
# 那一村指定的模型。VRAM 一次只夠塞一顆 7-9B 級模型，所以是真的關掉舊的、
# 重新啟動新的，不是同時常駐兩顆（見 note：VRAM 8GB 上限的實測數字）。
# ---------------------------------------------------------------------------

_current_process: subprocess.Popen | None = None
_current_model: str | None = None
_swap_count = 0
_swap_total_sec = 0.0


def _wait_for_health(timeout_sec: float = 120.0) -> bool:
    deadline = time.time() + timeout_sec
    while time.time() < deadline:
        try:
            if requests.get(HEALTH_URL, timeout=2).status_code == 200:
                return True
        except requests.exceptions.RequestException:
            pass
        time.sleep(0.5)
    return False


def _stop_current_server() -> None:
    global _current_process, _current_model
    if _current_process is None:
        return
    _current_process.terminate()
    try:
        _current_process.wait(timeout=15)
    except subprocess.TimeoutExpired:
        _current_process.kill()
        _current_process.wait(timeout=15)
    _current_process = None
    _current_model = None


def ensure_model_loaded(side: str) -> None:
    """確保 llama-server 目前載入的是 side 這一村指定的模型，不是就切換。"""
    global _current_process, _current_model, _swap_count, _swap_total_sec
    target_model = MODEL_BY_SIDE[side]
    if _current_model == target_model:
        return

    start = time.perf_counter()
    _stop_current_server()

    model_path = MODELS_DIR / target_model
    if not model_path.exists():
        print(f"[錯誤] 找不到模型檔案：{model_path}")
        sys.exit(1)

    _current_process = subprocess.Popen(
        [str(LLAMA_SERVER_BIN), "-m", str(model_path), "-ngl", "99", "-c", "8192", "-fa", "on",
         "--host", SERVER_HOST, "--port", str(SERVER_PORT)],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    if not _wait_for_health():
        print(f"[錯誤] 模型 {target_model} 載入逾時（120 秒），llama-server 沒有回應 /health。")
        sys.exit(1)
    _current_model = target_model
    elapsed = time.perf_counter() - start
    _swap_count += 1
    _swap_total_sec += elapsed
    village_label = "紅村" if side == "red" else "藍村"
    print(f"[model-swap] 切到{village_label}的模型「{target_model}」，耗時 {elapsed:.2f} 秒")


atexit.register(_stop_current_server)


# ---------------------------------------------------------------------------
# 洩漏偵測（完全沿用 dialogue_ping_pong_memory.py）
# ---------------------------------------------------------------------------


def core_energy_leaked(villager: dict, dialogue: str) -> bool:
    return bool(re.search(re.escape(villager["core_energy"]), dialogue))


def altar_key_leaked(villager: dict, altar_key_name: str, dialogue: str) -> bool:
    if not villager["holds_altar_key"]:
        return False
    return bool(re.search(re.escape(altar_key_name), dialogue))


def opponent_side(speaker: str) -> str:
    return "blue" if speaker == "red" else "red"


# ---------------------------------------------------------------------------
# 停滯偵測 + 強制新話題注入（完全沿用 dialogue_ping_pong_memory.py）
# ---------------------------------------------------------------------------

STAGNATION_REPEAT_THRESHOLD = 0.8
STAGNATION_SELF_WINDOW = 4
STAGNATION_SUSPICION_WINDOW = 4
STAGNATION_SUSPICION_THRESHOLD = 5

STUCK_TOPIC_HOOKS = [
    "老周最近在渡口說，他新釀的一批米酒特別香，已經有不少人向他打聽訣竅。",
    "後山老井最近排隊取水的人變多了，聽說是因為豐收季快到了。",
    "芷姨在市集又聽到什麼消息，逢人就想聊上兩句。",
    "阿柏這幾天在碼頭修一艘新來的漁船，船身的記號跟平常見過的不太一樣。",
    "哨站的守衛換班時，提到昨晚巡邏時聽到田埂那邊有點動靜。",
    "老馮的鐵匠鋪這幾天在趕製一批農具，說是豐收季前大家都來得急。",
    "集市日前一天，村口大榕樹下已經有人搶著佔位子擺攤了。",
    "芷姨新織的頭巾用了少見的藍紫色染料，市集裡好幾個人在問哪裡買得到。",
    "渡口的茶棚今天特別多人，聽說是在等一艘晚到的漁船。",
]


def detect_self_repetition(own_turns: list, window: int = STAGNATION_SELF_WINDOW,
                            threshold: float = STAGNATION_REPEAT_THRESHOLD) -> bool:
    recent = own_turns[-window:]
    for i in range(len(recent)):
        for j in range(i + 1, len(recent)):
            for field in ("dialogue", "reasoning"):
                a, b = recent[i].get(field, ""), recent[j].get(field, "")
                if not a or not b:
                    continue
                if difflib.SequenceMatcher(None, a, b).ratio() >= threshold:
                    return True
    return False


def detect_suspicion_stagnation(own_turns: list, window: int = STAGNATION_SUSPICION_WINDOW,
                                 threshold: int = STAGNATION_SUSPICION_THRESHOLD) -> bool:
    recent = own_turns[-window:]
    if len(recent) < window:
        return False
    movement = sum(t.get("state_delta", {}).get("suspicion_change", 0) for t in recent)
    return abs(movement) <= threshold


_DEGENERATE_STRIP_PATTERN = re.compile(r"[^\w一-龥]")


def is_degenerate_output(text: str) -> bool:
    return len(_DEGENERATE_STRIP_PATTERN.sub("", text)) < 2


def build_stuck_topic_instruction(hook: str) -> str:
    return (
        "【強制規定：這一回合必須帶入一個新話題切入點，這不是可以自行選擇的事】\n"
        "外部系統判斷：最近的對話已經在原地打轉，光靠換句話說沒有用，需要真正新的素材才能讓"
        "對話繼續往前推進。具體規定：這一回合請自然帶出以下這件近況、當作新話題的切入點"
        "（可以搭配你的個性自由發揮怎麼講、用什麼態度講，但這件事本身一定要出現，這不是機密，"
        "只是尋常的日常近況）：\n"
        f"「{hook}」"
    )


# ---------------------------------------------------------------------------
# 記憶流：新近度 + 重要性檢索（完全沿用 dialogue_ping_pong_memory.py）
# ---------------------------------------------------------------------------

MEMORY_RECENCY_DECAY = 0.95
MEMORY_TOP_K = 6
MEMORY_IMPORTANCE_ENABLED = os.environ.get("AILLEY_MODE_A_MEMORY_IMPORTANCE", "1") != "0"

_IMPORTANCE_PROMPT_TEMPLATE = (
    "這是一場心理博弈裡兩位村民之間的一段對話內容。\n"
    "內容：「{content}」\n"
    "請幫這段內容的重要程度打分（1 到 10 分，1 分是日常閒聊等瑣事，10 分是攸關核心能源／"
    "舊神祭壇密鑰這類機密的關鍵轉折），只需要輸出分數，不要解釋原因。"
)


def score_importance(content: str, grammar: str) -> int:
    prompt = _IMPORTANCE_PROMPT_TEMPLATE.format(content=content)
    try:
        result = call_director(prompt, grammar, n_predict=20)
    except SystemExit:
        print("[importance] 評分呼叫失敗，回退成預設值 5")
        return 5
    try:
        return int(result.get("importance", 5))
    except (TypeError, ValueError):
        return 5


def retrieve_memories(memories: list, current_turn: int, top_k: int = MEMORY_TOP_K) -> list:
    scored = []
    for m in memories:
        recency = MEMORY_RECENCY_DECAY ** (current_turn - m["turn"])
        importance = m["importance"] / 10
        scored.append((recency + importance, m))
    scored.sort(key=lambda pair: pair[0], reverse=True)
    top = [m for _, m in scored[:top_k]]
    top.sort(key=lambda m: m["turn"])
    return top


# ---------------------------------------------------------------------------
# prompt 組裝（完全沿用 dialogue_ping_pong_memory.py）
# ---------------------------------------------------------------------------


def _two_tier_block(self_villager: dict) -> str:
    if self_villager["holds_altar_key"]:
        return (
            "【機密的兩個層級】\n"
            "你有自己的核心能源（個人層級機密）；此外你村莊還有一份舊神祭壇密鑰（村莊層級機密），"
            "只有特定村民持有，握有密鑰等於能操作全村所有村民的核心能源，價值遠高於單一一份核心能源。"
            "你剛好就是密鑰持有者，這是比核心能源更重要的秘密。"
        )
    return "【機密】\n你有自己的核心能源，這是你最深層的秘密。"


def _altar_key_block(self_villager: dict, altar_key_name: str) -> str:
    if not self_villager["holds_altar_key"]:
        return ""
    return f"你同時也是舊神祭壇密鑰持有者，密鑰名稱是：「{altar_key_name}」，這是比核心能源更重要的秘密，絕不能主動洩漏。\n"


def _motivation_block(villager: dict) -> str:
    if not villager.get("motivation"):
        return ""
    return f"你的驅動力：{villager['motivation']}\n"


def _relationship_block(villager: dict, opponent: dict) -> str:
    if not villager.get("relationship"):
        return ""
    target = villager.get("relationship_target")
    opponent_key = opponent.get("id", "").split("-", 1)[-1]
    if target and target == opponent_key:
        return f"你跟現在對話的這個人（{opponent['name']}）之間的關係背景：{villager['relationship']}\n"
    if target:
        return f"你的背景故事（不是跟現在對話的這個人有關，是別的事，可以自然提起或不提）：{villager['relationship']}\n"
    return f"你的處世態度：{villager['relationship']}\n"


def _own_history_block(retrieved_memories: list) -> str:
    self_entries = [m for m in retrieved_memories if m["kind"] == "self"]
    if not self_entries:
        return "（這是你的第一次發言，還沒有過去的內心想法或發言）"
    lines = []
    for m in self_entries:
        lines.append(f"第 {m['turn']} 回合：\n  內心想法：{m['reasoning']}\n  說的話：「{m['dialogue']}」")
    return "\n".join(lines)


def _shared_dialogue_block(retrieved_memories: list) -> str:
    if not retrieved_memories:
        return "（對話尚未開始，你是第一個發言的人）"
    lines = []
    for m in retrieved_memories:
        village = "紅村" if m["speaker"] == "red" else "藍村"
        lines.append(f"第 {m['turn']} 回合｜{village}：「{m['dialogue']}」")
    return "\n".join(lines)


def build_prompt(template: str, world_lore: str, speaker: str, self_villager: dict, opponent_villager: dict,
                  altar_key_name: str, retrieved_memories: list, _unused: list, stuck_instruction: str = "") -> str:
    return (
        template.replace("{{WORLD_LORE}}", world_lore)
        .replace("{{STUCK_INSTRUCTION_BLOCK}}", stuck_instruction)
        .replace("{{TWO_TIER_BLOCK}}", _two_tier_block(self_villager))
        .replace("{{SELF_NAME}}", self_villager["name"])
        .replace("{{SELF_OCCUPATION}}", self_villager["occupation"])
        .replace("{{SELF_PERSONALITY}}", self_villager["personality"])
        .replace("{{SELF_CORE_ENERGY}}", self_villager["core_energy"])
        .replace("{{SELF_ALTAR_KEY_BLOCK}}", _altar_key_block(self_villager, altar_key_name))
        .replace("{{SELF_MOTIVATION_BLOCK}}", _motivation_block(self_villager))
        .replace("{{SELF_RELATIONSHIP_BLOCK}}", _relationship_block(self_villager, opponent_villager))
        .replace("{{OPPONENT_NAME}}", opponent_villager["name"])
        .replace("{{OPPONENT_OCCUPATION}}", opponent_villager["occupation"])
        .replace("{{OPPONENT_PERSONALITY}}", opponent_villager["personality"])
        .replace("{{OWN_HISTORY_BLOCK}}", _own_history_block(retrieved_memories))
        .replace("{{SHARED_DIALOGUE_BLOCK}}", _shared_dialogue_block(retrieved_memories))
    )


# ---------------------------------------------------------------------------
# 呼叫 llama-server（完全沿用 dialogue_ping_pong_memory.py，含 n_predict 上限
# 跟解析失敗重試，SERVER_URL 換成本檔案自己管理的常數）
# ---------------------------------------------------------------------------

TOKENS_PER_TURN_BUDGET = 300


def call_director(prompt: str, grammar: str, seed_override: int | None = None, n_predict: int = TOKENS_PER_TURN_BUDGET) -> dict:
    payload = {
        "prompt": prompt,
        "grammar": grammar,
        "temperature": TEMPERATURE,
        "top_p": TOP_P,
        "top_k": TOP_K,
        "repeat_penalty": REPEAT_PENALTY,
        "repeat_last_n": REPEAT_LAST_N,
        "n_predict": n_predict,
        "cache_prompt": True,
    }
    if seed_override is not None:
        payload["seed"] = seed_override
    elif SEED is not None:
        payload["seed"] = SEED
    payload.update(EXTRA_SAMPLING)
    for attempt in range(2):
        try:
            resp = requests.post(SERVER_URL, json=payload, timeout=REQUEST_TIMEOUT_SEC)
            resp.raise_for_status()
        except requests.exceptions.ConnectionError:
            print(f"[錯誤] 連不到 llama-server（{SERVER_URL}）。請確認 server 已啟動。")
            sys.exit(1)
        except requests.exceptions.Timeout:
            print(f"[錯誤] 呼叫逾時（超過 {REQUEST_TIMEOUT_SEC} 秒）。")
            sys.exit(1)
        except requests.exceptions.HTTPError as e:
            print(f"[錯誤] llama-server 回傳錯誤：{e}")
            sys.exit(1)

        raw = resp.json().get("content", "")
        try:
            return json.loads(raw)
        except json.JSONDecodeError as e:
            if attempt == 0:
                print(f"[警告] JSON 解析失敗，重打一次：{e}")
                continue
            print(f"[錯誤] 重打後仍無法解析為 JSON：{e}")
            print("--- 原始輸出 ---")
            print(raw)
            sys.exit(1)


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------


def main() -> None:
    if SEED is not None:
        random.seed(SEED)
    roster = generate_fixed_roster()
    red_villager, blue_villager = pick_encounter(roster)
    altar_keys = roster["altar_keys"]
    villager_by_side = {"red": red_villager, "blue": blue_villager}

    print(f"[本場主角] 紅村：{red_villager['name']}（{red_villager['occupation']}，{red_villager['personality']}，"
          f"模型={MODEL_BY_SIDE['red']}）"
          f" vs 藍村：{blue_villager['name']}（{blue_villager['occupation']}，{blue_villager['personality']}，"
          f"模型={MODEL_BY_SIDE['blue']}）")
    if red_villager["holds_altar_key"]:
        print(f"  紅村持有密鑰：{altar_keys['red']}")
    if blue_villager["holds_altar_key"]:
        print(f"  藍村持有密鑰：{altar_keys['blue']}")

    world_lore = (POC_DIR / "prompts" / "world_lore.txt").read_text(encoding="utf-8")
    prompt_template = (POC_DIR / "prompts" / "villager_system_prompt.txt").read_text(encoding="utf-8")
    grammar = (POC_DIR / "grammar" / "turn.gbnf.template").read_text(encoding="utf-8")
    importance_grammar = (POC_DIR / "grammar" / "importance.gbnf.template").read_text(encoding="utf-8")

    own_history = {"red": [], "blue": []}
    shared_log: list = []
    merged_turns: list = []
    memory_stream = {"red": [], "blue": []}
    suspicion = {"red": 0, "blue": 0}
    revealed = {"red": False, "blue": False}
    altar_key_revealed = {"red": False, "blue": False}
    cross_faction_leak_count = 0
    used_hooks = {"red": set(), "blue": set()}

    start_total = time.perf_counter()

    for i in range(1, MAX_TURNS + 1):
        speaker = "red" if i % 2 == 1 else "blue"
        opp = opponent_side(speaker)
        self_villager = villager_by_side[speaker]
        opponent_villager = villager_by_side[opp]

        ensure_model_loaded(speaker)

        village_label = "紅村" if speaker == "red" else "藍村"
        self_repeat = STAGNATION_ENABLED and detect_self_repetition(own_history[speaker])
        suspicion_stuck = STAGNATION_ENABLED and detect_suspicion_stagnation(own_history[speaker])
        stuck_instruction = ""
        if self_repeat or suspicion_stuck:
            reason = "自我重複+懷疑度停滯" if (self_repeat and suspicion_stuck) else (
                "自我重複" if self_repeat else "懷疑度停滯")
            available_hooks = [h for h in STUCK_TOPIC_HOOKS if h not in used_hooks[speaker]] or STUCK_TOPIC_HOOKS
            hook = random.choice(available_hooks)
            used_hooks[speaker].add(hook)
            stuck_instruction = build_stuck_topic_instruction(hook)
            print(f"[stagnation] 判定{village_label}第{i}回合卡住（{reason}），加入強制新話題指令：「{hook}」")

        retrieved = retrieve_memories(memory_stream[speaker], current_turn=i)
        print(f"[memory] 第{i}回合{village_label}檢索到記憶：回合 {[m['turn'] for m in retrieved]}")

        prompt = build_prompt(prompt_template, world_lore, speaker, self_villager, opponent_villager,
                               altar_keys[speaker], retrieved, retrieved, stuck_instruction)

        for attempt in range(1, 4):
            seed_override = (SEED + attempt - 1) if SEED is not None and attempt > 1 else None
            start = time.perf_counter()
            result = call_director(prompt, grammar, seed_override=seed_override)
            elapsed = time.perf_counter() - start
            reasoning = _OPENCC.convert(result.get("reasoning", ""))
            dialogue = _OPENCC.convert(result.get("dialogue", ""))
            if not is_degenerate_output(reasoning) and not is_degenerate_output(dialogue):
                break
            print(f"[degenerate] 第 {attempt} 次嘗試輸出退化（reasoning={reasoning!r}, dialogue={dialogue!r}），重新生成...")
        else:
            print("[degenerate] 已達最大重試次數，仍是退化輸出，採用最後一次結果")

        tactic = result.get("tactic", "?")
        delta = result.get("state_delta", {})

        village = "紅村" if speaker == "red" else "藍村"
        print(f"\n--- 第 {i} 回合｜{village}（{TACTIC_LABEL.get(tactic, tactic)}）| {elapsed:.2f}秒 | 模型={MODEL_BY_SIDE[speaker]} ---")
        print(f"  [內心] {reasoning}")
        print(f"  「{dialogue}」")

        suspicion[speaker] += delta.get("suspicion_change", 0)

        claims_core_leak = bool(delta.get("reveals_core_energy", False))
        actually_core_leaked = core_energy_leaked(self_villager, dialogue)
        if claims_core_leak != actually_core_leaked:
            print(f"  [警訊] state_delta 宣稱核心能源洩漏={claims_core_leak}，但文字比對結果={actually_core_leaked}")
        if actually_core_leaked:
            revealed[speaker] = True

        claims_key_leak = bool(delta.get("reveals_altar_key", False))
        actually_key_leaked = altar_key_leaked(self_villager, altar_keys[speaker], dialogue)
        if claims_key_leak != actually_key_leaked:
            print(f"  [警訊] state_delta 宣稱密鑰洩漏={claims_key_leak}，但文字比對結果={actually_key_leaked}")
        if actually_key_leaked:
            altar_key_revealed[speaker] = True

        opponent_villager_secret = villager_by_side[opp]
        if core_energy_leaked(opponent_villager_secret, dialogue):
            print(f"  [警訊] {village}的角色講出了對方的核心能源！理論上不該發生（資訊隔離失效）")
            cross_faction_leak_count += 1
            revealed[opp] = True
        if altar_key_leaked(opponent_villager_secret, altar_keys[opp], dialogue):
            print(f"  [警訊] {village}的角色講出了對方的舊神祭壇密鑰！理論上不該發生（資訊隔離失效）")
            cross_faction_leak_count += 1
            altar_key_revealed[opp] = True

        print(f"  [state] suspicion(紅)={suspicion['red']} suspicion(藍)={suspicion['blue']}")

        turn_record = {
            "speaker": speaker,
            "model": MODEL_BY_SIDE[speaker],
            "reasoning": reasoning,
            "tactic": tactic,
            "dialogue": dialogue,
            "state_delta": delta,
            "elapsed_sec": round(elapsed, 2),
        }
        own_history[speaker].append(turn_record)
        shared_log.append({"speaker": speaker, "dialogue": dialogue})
        merged_turns.append(turn_record)

        importance = score_importance(f"{reasoning} {dialogue}", importance_grammar) if MEMORY_IMPORTANCE_ENABLED else 5
        memory_stream[speaker].append({
            "turn": i, "speaker": speaker, "kind": "self",
            "dialogue": dialogue, "reasoning": reasoning, "importance": importance,
        })
        memory_stream[opp].append({
            "turn": i, "speaker": speaker, "kind": "heard",
            "dialogue": dialogue, "reasoning": None, "importance": importance,
        })

        if altar_key_revealed["red"] or altar_key_revealed["blue"]:
            loser = "紅村" if altar_key_revealed["red"] else "藍村"
            print(f"\n=== 第 {i} 回合：{loser}的舊神祭壇密鑰洩漏，全村核心能源淪陷，遊戲結束 ===")
            break
        if revealed["red"] and revealed["blue"]:
            print(f"\n=== 第 {i} 回合：雙方核心能源均已洩漏，遊戲結束 ===")
            break
    else:
        print(f"\n=== 跑滿 {MAX_TURNS} 回合，未分出勝負 ===")

    elapsed_total = time.perf_counter() - start_total

    print(f"\n--- 最終戰報 ---")
    print(f"  總耗時：{elapsed_total:.2f} 秒（{len(shared_log)} 回合，平均每回合 {elapsed_total/max(len(shared_log),1):.2f} 秒）")
    print(f"  模型切換次數：{_swap_count}，切換總耗時：{_swap_total_sec:.2f} 秒（平均每次 {_swap_total_sec/max(_swap_count,1):.2f} 秒）")
    print(f"  紅村（{red_villager['name']}）核心能源洩漏：{revealed['red']}")
    print(f"  藍村（{blue_villager['name']}）核心能源洩漏：{revealed['blue']}")
    print(f"  跨陣營洩題次數（預期應為 0）：{cross_faction_leak_count}")
    print(f"  最終懷疑度：紅={suspicion['red']} 藍={suspicion['blue']}")

    TRANSCRIPT_DIR.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    out_path = TRANSCRIPT_DIR / f"{timestamp}_multimodel.json"
    out_record = {
        "timestamp": timestamp,
        "mode": "A_ping_pong_multimodel",
        "model_by_side": MODEL_BY_SIDE,
        "swap_count": _swap_count,
        "swap_total_sec": round(_swap_total_sec, 2),
        "elapsed_sec": round(elapsed_total, 2),
        "temperature": TEMPERATURE,
        "top_p": TOP_P,
        "top_k": TOP_K,
        "repeat_penalty": REPEAT_PENALTY,
        "max_turns": MAX_TURNS,
        "seed": SEED,
        "extra_sampling": EXTRA_SAMPLING,
        "red_villager": red_villager,
        "blue_villager": blue_villager,
        "cross_faction_leak_count": cross_faction_leak_count,
        "own_history": own_history,
        "script": {"turns": merged_turns},
    }
    out_path.write_text(json.dumps(out_record, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"[記錄] 完整劇本已存至 {out_path.relative_to(POC_DIR)}")


if __name__ == "__main__":
    main()
