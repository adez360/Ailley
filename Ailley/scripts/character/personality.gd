class_name Personality
extends RefCounted

## HEXACO 六維 → 兩份產出：引擎用的 10 項數值，跟 LLM 用的 `system_prompt` 文字。
## 規格見《01-1 人格生成規格書》§3（轉換式）、§4（極端值映射表）、§5（組裝規則）。
##
## **兩份產出的讀者不同，刻意不共用同一種表達**（《01》§2-1）：
##
## | 誰 | 讀什麼 | 為什麼 |
## | --- | --- | --- |
## | 引擎 | 10 項數字 | 算成功率、算記憶衰減 |
## | LLM | 行為準則文字 | 本地模型看到 `curiosity: 60` 沒有基準，不知 60 是高是低 |
##
## 所以 `personality` 的 10 項**不注入 prompt**，注入的是這裡組出來的
## `system_prompt`。兩者由同一份 HEXACO 輸入產出，不會互相矛盾。

const TRAITS_PATH := "res://data/hexaco_traits.json"

## 六個滑桿的欄位名，順序就是《01-1》§2-1 表格的順序，也就是行為準則列出來的順序。
## 一律帶 `hex_` 前綴：HEXACO 的「誠實謙遜」跟引擎參數 `honesty`（誠實度）不是
## 同一個東西，不加前綴一定會有人接錯
const HEX_FIELDS := [
	"hex_honesty", "hex_emotionality", "hex_extraversion",
	"hex_agreeableness", "hex_conscientiousness", "hex_openness",
]

## hexaco_to_personality() 輸出的 10 項引擎參數欄位名（《01-1》§3）。#349 的
## personality_delta 驗證要用同一份名單判斷「這是不是合法的維度」，不在
## ai_schema.gd 那邊另外抄一份——欄位改了這裡忘記跟著改，驗證層跟實際算出來
## 的維度就會對不上
const PERSONALITY_KEYS := [
	"diligence", "courage", "sociability", "morality", "stability",
	"romanticism", "curiosity", "grudge", "greed", "honesty",
]

## PERSONALITY_KEYS -> L10n key，給玩家看的人格面板用（issue #385 改範圍後的
## 墓碑查看面板）。跟 Stats.SPEC 的 "label" 同一種做法——顯示用的翻譯鍵跟
## 引擎欄位名分開存一份對照表，不是欄位名本身拿去查 L10n
const PERSONALITY_LABELS := {
	"diligence": "TRAIT_DILIGENCE",
	"courage": "TRAIT_COURAGE",
	"sociability": "TRAIT_SOCIABILITY",
	"morality": "TRAIT_MORALITY",
	"stability": "TRAIT_STABILITY",
	"romanticism": "TRAIT_ROMANTICISM",
	"curiosity": "TRAIT_CURIOSITY",
	"grudge": "TRAIT_GRUDGE",
	"greed": "TRAIT_GREED",
	"honesty": "TRAIT_HONESTY",
}

## 極端項的門檻（《01-1》§2-3）。26~74 一律不輸出任何字——不是輸出「普通」，
## 是整條略過，中間值就是留給 AI 的自主空間
const EXTREME_LOW := 25
const EXTREME_HIGH := 75

## 滑桿沒給值時當中間值，那一維不會產生任何行為準則
const NEUTRAL := 50

## 開場白與結尾句（《01-1》§5）。任何角色都有這兩句，就算完全沒有人格資料——
## 空字串會讓 AIService 整個略過 system 訊息，模型連「你在扮演一個角色」都不知道
const PROMPT_HEAD := "你正在扮演一個遊戲角色。\n\n"
const PROMPT_TAIL := "請嚴格遵循上述設定，依當前局勢做出決策與回應。"

static var _traits: Dictionary = {}
static var _loaded := false


## 一次拿到兩份產出：`{"personality": {10 項}, "system_prompt": String}`。
## 呼叫端（character.gd::_ready()）只要記得存這兩個欄位，不用自己串三個函式。
##
## `identity` 是 npc_schedule.json 的 identities 那一筆，可以只有 character_id／
## character_name 沒有人格資料——那種角色拿到的是空的 personality 跟只有開場白
## 加結尾句的 system_prompt，不是 null（AC 要求：無 persona 資料時要有合理預設值）。
##
## `seed_text` 決定每個極端維度從 3 種語氣變體裡抽哪一條。傳 character_id 進來，
## 不要靠真的隨機：`system_prompt` 的設計前提是「建角後逐字元不變」（《01-1》§5
## 規則 4，那是 llama-server 每個 slot 命中 KV cache 的條件），真隨機的話同一隻
## 角色每次開遊戲的人格文案都不一樣。存檔接上之後（#21）改成存下來的那份，
## 這裡不用改
static func from_identity(identity: Dictionary, seed_text: String) -> Dictionary:
	var hexaco: Dictionary = identity.get("hexaco", {}) if identity.get("hexaco") is Dictionary else {}
	var description := str(identity.get("character", ""))

	return {
		"personality": hexaco_to_personality(hexaco) if not hexaco.is_empty() else {},
		# 外觀文字先傳空字串：appearance 的 slot 清單在《01》§1-2 還是【待規劃】，
		# 沒有資料來源。build_system_prompt() 對空區塊本來就整段不輸出
		"system_prompt": build_system_prompt(traits_from_hexaco(hexaco, seed_text), description, ""),
	}


## 六維 → 10 項引擎參數（《01-1》§3）。結果 round() 取整、夾制 0~100。
##
## 不要省略這層：`courage` 撐打獵／偷竊／攻擊三種成功率、`romanticism` 撐演奏、
## `grudge` 是記憶衰減率的參數——這三項在 HEXACO 六維裡沒有直接對應欄位
static func hexaco_to_personality(h: Dictionary) -> Dictionary:
	var honesty := _hex(h, "hex_honesty")
	var emotionality := _hex(h, "hex_emotionality")
	var extraversion := _hex(h, "hex_extraversion")
	var agreeableness := _hex(h, "hex_agreeableness")
	var conscientiousness := _hex(h, "hex_conscientiousness")
	var openness := _hex(h, "hex_openness")

	return {
		"diligence": _clamp(conscientiousness),
		"courage": _clamp((100.0 - emotionality) * 0.5 + openness * 0.3 + extraversion * 0.2),
		"sociability": _clamp(extraversion),
		"morality": _clamp(honesty * 0.7 + agreeableness * 0.3),
		"stability": _clamp(100.0 - emotionality),
		"romanticism": _clamp(openness * 0.6 + emotionality * 0.4),
		"curiosity": _clamp(openness),
		"grudge": _clamp((100.0 - agreeableness) * 0.6 + emotionality * 0.4),
		"greed": _clamp((100.0 - honesty) * 0.7 + (100.0 - conscientiousness) * 0.3),
		"honesty": _clamp(honesty),
	}


## 極端維度的行為準則文案（《01-1》§4）。每個極端維度抽一條，中間值的維度
## 整條略過。順序照 HEX_FIELDS，不是照抽中的先後——同一份輸入要產出同一份
## 文字，逐字元一致
static func traits_from_hexaco(h: Dictionary, seed_text: String) -> Array[String]:
	_ensure_loaded()

	var lines: Array[String] = []
	for field in HEX_FIELDS:
		var value := _hex(h, field)
		var side := ""
		if value <= EXTREME_LOW:
			side = "low"
		elif value >= EXTREME_HIGH:
			side = "high"
		else:
			continue

		var variants: Variant = _traits.get(field, {}).get(side, [])
		if not variants is Array or (variants as Array).is_empty():
			push_warning("Personality: %s 缺 %s 端的文案，這一維略過" % [field, side])
			continue

		# 種子帶上欄位名，否則六個維度會一起抽到同一個索引，三種變體等於只有一種
		var rng := RandomNumberGenerator.new()
		rng.seed = hash(seed_text + field)
		lines.append(str((variants as Array)[rng.randi() % (variants as Array).size()]))

	return lines


## 三個區塊：行為準則、`character` 自述、外觀文字（《01-1》§5）。
## **任一區塊為空就整段（含標題）不輸出**——不要留一個「【這個人】」後面接
## 空字串，模型看到空欄位會自行編造
static func build_system_prompt(traits: Array[String], description: String, appearance: String) -> String:
	var p := PROMPT_HEAD

	if not traits.is_empty():
		p += "【行為準則】\n"
		for line in traits:
			p += "- %s\n" % line
		p += "\n"

	if not description.strip_edges().is_empty():
		p += "【這個人】%s\n\n" % description.strip_edges()

	if not appearance.strip_edges().is_empty():
		p += "【你的外表】%s\n\n" % appearance.strip_edges()

	return p + PROMPT_TAIL


# 滑桿值讀成 float。缺欄位或型別不對一律當中間值，那一維不會產生行為準則——
# 資料漏填不該變成一個看不見的極端人格
static func _hex(h: Dictionary, field: String) -> float:
	var value: Variant = h.get(field, NEUTRAL)
	if not (value is int or value is float):
		push_warning("Personality: %s 不是數字（%s），當中間值 %d 用" % [field, value, NEUTRAL])
		return float(NEUTRAL)
	return clampf(float(value), 0.0, 100.0)


static func _clamp(value: float) -> int:
	return clampi(roundi(value), 0, 100)


# 文案表跟 ItemDatabase 同一套 lazy load：第一次要用才讀，讀失敗只 push_error
# 不炸開機——沒有文案表的角色拿到的是沒有行為準則的 system_prompt，遊戲照跑
static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true

	var file := FileAccess.open(TRAITS_PATH, FileAccess.READ)
	if file == null:
		push_error("Personality: 找不到 %s" % TRAITS_PATH)
		return

	var json := JSON.new()
	var text := file.get_as_text()
	file.close()

	if json.parse(text) != OK or not json.data is Dictionary:
		push_error("Personality: %s 不是合法的 JSON 物件" % TRAITS_PATH)
		return

	_traits = json.data as Dictionary
