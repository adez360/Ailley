class_name DecisionContext
extends RefCounted

## 決策請求的中繼資訊，跟 envelope/requester_id/policy 一起沿著 DecisionProvider
## 鏈路傳遞，但不是「決策內容」本身（#217）。之後要加新的請求層級中繼資訊，
## 改這裡加欄位，不用逐層在 DecisionProvider 的每個實作裡加參數、逐層轉發。

## 同一次決策內的內容驗證失敗重試要跳過冷卻檢查，不然重試永遠會被自己剛送出
## 的上一次呼叫的冷卻擋下（見 agent.gd._decide_with_retry()、AIService.request()）
var is_retry := false
