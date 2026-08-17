class_name DialogueLines
extends RefCounted

## 內容層：決定角色這一輪要講什麼。
##
## Phase 1 是依角色數值組模板句。重點不是台詞好看，而是證明
## 「台詞來自角色狀態」這條管線是通的。
##
## > 這裡曾經寫著「接 LLM 時整個換掉這個檔」。**那是錯的**：這個檔要
## > **留下來當 fallback**。逾時、未設定金鑰、驗證失敗三種情況都需要一條
## > 保證有台詞的路徑，而它正好就是那條路徑 —— 尤其 fallback 一定要能終止對話
## > （LLM 版由回傳的 end 欄位決定，fallback 沒有，所以直接說一句 closing() 就收）。
## > 見 note/技術/LLM 串接與 AI 服務層。
##
## 台詞本身在 res://locale/game.csv 的 DLG_* 那組 key，這裡只決定「哪一句」。
## 因為全是 static func 所以拿不到 tr()，一律走 L10n。
##
## 刻意只收 String / Stats，不收 Character：
## 一來避免 character.gd -> conversation.gd -> dialogue_lines.gd -> character.gd 的循環相依，
## 二來逼自己把「產生台詞需要哪些資訊」講清楚，之後那就是要送給 LLM 的 context。
##
## 台詞不分親疏：好感度欄位已經拿掉（《01》3-1），引擎手上沒有任何
## 「這兩個人熟不熟」的數值可以拿來挑句子。剩下的 trust 是信任不是好感，
## 拿它當親疏門檻等於把兩件事混成一件，那正是規格書要拆開的東西。


static func opening(listener_name: String) -> String:
	return L10n.tf("DLG_OPENING_NEUTRAL", {"name": listener_name})

# turn 從 0 開始算，目前沒用到，之後要做「話題會推進」時會需要
static func reply(stats: Stats, _turn: int) -> String:
	var lowest := stats.get_lowest_need()

	if stats.get_value(lowest) < Stats.CRITICAL:
		match lowest:
			"satiety":
				return L10n.t("DLG_NEED_HUNGER")
			"stamina":
				return L10n.t("DLG_NEED_STAMINA")
			"hydration":
				return L10n.t("DLG_NEED_HYDRATION")
			"wakefulness":
				return L10n.t("DLG_NEED_WAKEFULNESS")
			"social":
				return L10n.t("DLG_NEED_SOCIAL")
			"fun":
				return L10n.t("DLG_NEED_FUN")

	var mood := stats.get_value("mood")
	if mood >= 70.0:
		return L10n.t("DLG_MOOD_HIGH")
	if mood <= 30.0:
		return L10n.t("DLG_MOOD_LOW")

	return L10n.t("DLG_REPLY_NEUTRAL")

static func closing() -> String:
	return L10n.t("DLG_CLOSING_NEUTRAL")
