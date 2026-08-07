class_name L10n
extends RefCounted

## 翻譯入口。
##
## Control 節點上的文字（Label.text、LineEdit.placeholder_text）由 Godot 自己
## 翻譯 —— auto_translate_mode 預設 INHERIT，把屬性值填成 key 就會生效，
## **不必**經過這裡。這個類別是給程式碼裡組出來的字串用的。
##
## 為什麼不直接用 tr()：tr() 是 Object 的實例方法，而需要翻譯的三個地方都拿不到 self ——
## DialogueLines 全是 static func、Stats.SPEC 是 const、AIConfig.load_from_user() 也是 static。
## TranslationServer.translate() 沒有這個限制。
##
## 翻譯表在 res://locale/*.csv，由 project.godot 的 internationalization/locale/translations 掛上。
## 找不到 key 時 translate() 原樣回傳 key 本身，所以漏翻譯會在畫面上看到大寫底線字，很好認。

static func t(key: String) -> String:
	return TranslationServer.translate(key)


## 帶參數的句子一律走這裡，用具名參數不要用 %s ——
## 語序在不同語言會變（「{name}，又見面了！」的英文是 Good to see you again, {name}!），
## 位置參數翻不動這種調換。
##
## 數字要指定精度的話，呼叫端先自己 "%.1f" % x 格式化成字串再傳進來：
## format() 沒有格式規格，而把 %.1f 留在翻譯字串裡等於要譯者處理格式碼
static func tf(key: String, args: Dictionary) -> String:
	return TranslationServer.translate(key).format(args)
