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
## 刻意只收 String / Stats / float，不收 Character：
## 一來避免 character.gd -> conversation.gd -> dialogue_lines.gd -> character.gd 的循環相依，
## 二來逼自己把「產生台詞需要哪些資訊」講清楚，之後那就是要送給 LLM 的 context。

const AFFINITY_FRIEND := 30.0
const AFFINITY_DISLIKE := -20.0


static func opening(listener_name: String, stats: Stats, affinity: float) -> String:
	if affinity <= AFFINITY_DISLIKE:
		return L10n.t("DLG_OPENING_DISLIKE")
	if affinity >= AFFINITY_FRIEND:
		return L10n.tf("DLG_OPENING_FRIEND", {"name": listener_name})
	return L10n.tf("DLG_OPENING_NEUTRAL", {"name": listener_name})

# turn 從 0 開始算，目前沒用到，之後要做「話題會推進」時會需要
static func reply(stats: Stats, affinity: float, _turn: int) -> String:
	var lowest := stats.get_lowest_need()

	if stats.get_value(lowest) < Stats.CRITICAL:
		match lowest:
			"hunger":
				return L10n.t("DLG_NEED_HUNGER")
			"energy":
				return L10n.t("DLG_NEED_ENERGY")
			"social":
				return L10n.t("DLG_NEED_SOCIAL")
			"fun":
				return L10n.t("DLG_NEED_FUN")

	var mood := stats.get_value("mood")
	if mood >= 70.0:
		return L10n.t("DLG_MOOD_HIGH")
	if mood <= 30.0:
		return L10n.t("DLG_MOOD_LOW")

	if affinity >= AFFINITY_FRIEND:
		return L10n.t("DLG_REPLY_FRIEND")

	return L10n.t("DLG_REPLY_NEUTRAL")

static func closing(listener_name: String, affinity: float) -> String:
	if affinity <= AFFINITY_DISLIKE:
		return L10n.t("DLG_CLOSING_DISLIKE")
	if affinity >= AFFINITY_FRIEND:
		return L10n.tf("DLG_CLOSING_FRIEND", {"name": listener_name})
	return L10n.t("DLG_CLOSING_NEUTRAL")
