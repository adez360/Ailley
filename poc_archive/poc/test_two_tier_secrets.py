"""Ailley POC — 兩層機密（核心能源／舊神祭壇密鑰）邏輯測試

不呼叫 llama-server，用構造好的假 turns 直接測試 director_poc.play_script() 的：
  - 核心能源洩漏偵測（一致性檢查、game state）
  - 舊神祭壇密鑰洩漏偵測與「密鑰洩漏＝提前結束遊戲」邏輯

背景：截至目前為止累積的所有真實場次，密鑰洩漏都還沒被模型巧合觸發過，
所以「密鑰洩漏後應提前結束、後面回合不該再播放」這段程式碼邏輯本身從未被驗證過。
這份測試直接構造假資料，繞過模型的不確定性，單獨驗證程式邏輯是否正確。
"""

import sys
import types

if "requests" not in sys.modules:
    sys.modules["requests"] = types.ModuleType("requests")

import director_poc as d


def _make_turn(speaker, dialogue, reveals_core_energy=False, reveals_altar_key=False, suspicion_change=0):
    return {
        "speaker": speaker,
        "reasoning": "test",
        "tactic": "bluff",
        "dialogue": dialogue,
        "state_delta": {
            "suspicion_change": suspicion_change,
            "reveals_core_energy": reveals_core_energy,
            "reveals_altar_key": reveals_altar_key,
        },
    }


def test_core_energy_leak_detected():
    red_energy = d.RED_VILLAGER["core_energy"]
    script = {"turns": [_make_turn("red", f"我的核心能源是{red_energy}", reveals_core_energy=True)]}
    print("=== 測試 1：核心能源洩漏（誠實自評，不應印警訊）===")
    d.play_script(script)


def test_core_energy_leak_self_report_mismatch():
    red_energy = d.RED_VILLAGER["core_energy"]
    script = {"turns": [_make_turn("red", f"我的核心能源是{red_energy}", reveals_core_energy=False)]}
    print("\n=== 測試 2：核心能源洩漏但自評 reveals_core_energy=False（應印警訊）===")
    d.play_script(script)


def test_altar_key_leak_ends_game_early():
    d.RED_VILLAGER["holds_altar_key"] = True
    key_name = d.ROSTER["altar_keys"]["red"]
    turns = [
        _make_turn("blue", "隨口聊聊天氣"),
        _make_turn("red", f"密鑰其實叫{key_name}，別跟其他人說", reveals_altar_key=True),
        _make_turn("blue", "[不應該被印出來的第 3 回合——遊戲應該已在第 2 回合結束]"),
    ]
    script = {"turns": turns}
    print("\n=== 測試 3：紅村密鑰洩漏，應在第 2 回合提前結束（第 3 回合不該被播放）===")
    d.play_script(script)


def test_altar_key_leak_claim_mismatch():
    d.BLUE_VILLAGER["holds_altar_key"] = True
    key_name = d.ROSTER["altar_keys"]["blue"]
    script = {"turns": [_make_turn("blue", f"我的密鑰是{key_name}", reveals_altar_key=False)]}
    print("\n=== 測試 4：藍村密鑰洩漏但自評 reveals_altar_key=False（應印警訊，且仍應提前結束）===")
    d.play_script(script)


if __name__ == "__main__":
    test_core_energy_leak_detected()
    test_core_energy_leak_self_report_mismatch()
    test_altar_key_leak_ends_game_early()
    test_altar_key_leak_claim_mismatch()
