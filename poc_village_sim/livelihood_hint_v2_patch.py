"""維生方式提示句 v2（2026-08-05 重新設計）。

v1（8/5 稍早）用祈使句「缺錢的時候應該去表演/賣東西賺錢」，結果模型把它當成唯一指令
執行——老周 4 輪全部 100% 卡死在只做表演，一次都沒吃飯/喝酒/睡覺/社交，比不加提示句
（84%）、比精簡版格式（93%）都更嚴重。見
note/40-規劃與路線圖/POC 紀錄 - poc_village_sim 五人整合試跑（新版 AI 架構首測）.md
「維生方式提示句實驗」一節。

v2 改用條件式措辭：加「如果沒有更急迫的事」「不是唯一選項」「不用每次都這樣」這類
限定句，避免模型把提示句讀成鐵律。阿吉維持 v1 的措辭（v1 結果裡阿吉沒有出現過度錨定，
本來就是條件式寫法，不用改）。

只 monkeypatch `characters.render_personality_block`，不動 production 程式碼；
跟現行完整格式（baseline，非 terse）做對照，因為 terse 格式本身已經被判定「效果小且
不一致，不值得投入」，這次只驗證「換措辭本身有沒有用」，避免跟 terse 的雜訊混在一起。
"""

import characters as c

LIVELIHOOD_HINTS_V2 = {
    "老周": (
        "\n你平常靠在廣場表演（吹笛子）維生。如果身上缺錢、又剛好沒有更急迫的事要處理"
        "（例如不餓、不渴、不累、沒受傷），你可能會想去表演賺點錢；但這不是唯一的選項，"
        "也不用每次缺錢都往表演這條路想，其他更急迫的需求還是優先處理。"
    ),
    "阿蘭": (
        "\n你平常靠打獵維生，身上偶爾會帶著待售的獵物。如果缺錢、身上剛好有獵物、又沒有"
        "更急迫的事要處理，你可能會想找機會賣掉換錢；但這不是唯一的選項，也不用每次缺錢"
        "都想著賣獵物，其他更急迫的需求還是優先處理。"
    ),
    "鐵牛": (
        "\n你平常靠打獵維生，身上偶爾會帶著待售的獵物。如果缺錢、身上剛好有獵物、又沒有"
        "更急迫的事要處理，你可能會想找機會賣掉換錢；但這不是唯一的選項，也不用每次缺錢"
        "都想著賣獵物，其他更急迫的需求還是優先處理。"
    ),
    "小梅": (
        "\n你平常靠採草藥維生，身上偶爾會帶著藥草。如果缺錢、身上剛好有藥草、又沒有更"
        "急迫的事要處理，你可能會想找機會賣掉換錢；但這不是唯一的選項，也不用每次缺錢"
        "都想著賣藥草，其他更急迫的需求還是優先處理。"
    ),
    "阿吉": (
        "\n你沒有正經的維生方式，缺錢的時候可能會想跟老周討點吃的，或是打別人東西的"
        "主意，但你也知道這樣做有風險、不是每次都要這樣做。"
    ),
}

_original_render_personality_block = c.render_personality_block


def render_personality_block_with_livelihood_v2(villager: dict) -> str:
    base = _original_render_personality_block(villager)
    hint = LIVELIHOOD_HINTS_V2.get(villager.get("name"), "")
    return base + hint if hint else base


def apply():
    c.render_personality_block = render_personality_block_with_livelihood_v2
