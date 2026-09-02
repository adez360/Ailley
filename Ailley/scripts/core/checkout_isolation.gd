class_name CheckoutIsolation
extends RefCounted

## `user://` 只依 `project.godot` 的 project name 解析實體路徑，同一台機器上
## 所有 worktree／checkout／匯出版的 project name 都相同，寫死檔名會讓全機
## 所有平行執行的版本共用同一份實體檔案、互相覆寫（issue #334）。用這個
## checkout／匯出版的實際位置算一段完整 sha256 雜湊接在檔名後（不截斷，
## 截斷等於自己削弱防撞名的效果），讓不同 worktree／匯出版本各自落地成
## 不同檔案。`DatabaseManager`／`AIConfig`／`JsonSaveService`／`Player` 四處
## 共用這一份，不要各自再刻一份（issue #987：各自複製的版本在匯出版底下
## 各自壞成同一種形狀，統一成一份之後只要修一次、以後也只有一個地方要記得
## 這個坑）。

static func compute_hash() -> String:
	return _checkout_root().sha256_text()


## 編輯器 Play 模式：`ProjectSettings.globalize_path("res://")` 指向這個
## checkout 在磁碟上的實際路徑，可以用來區分不同 worktree——`OS.has_feature
## ("editor")` 涵蓋這個情況（Play 模式仍是編輯器本體在跑，不是獨立執行檔，
## 見 `llama_sidecar.gd::_sidecar_dir()` 同一種判斷）。
##
## 真正匯出的獨立執行檔（`OS.has_feature("editor")` 為 false）底下，
## `ProjectSettings.globalize_path("res://")` 回傳空字串——issue #987 實測：
## `binary_format/embed_pck=true` 把 `.pck` 內嵌進執行檔本體時 100%重現，
## 空字串的 sha256（`e3b0c442...b855`）讓所有匯出版收斂到同一個雜湊，
## 隔離機制完全失效。改用 `OS.get_executable_path()` 所在目錄——這是磁碟上
## 執行檔實際的位置，不受 `.pck` 是否內嵌影響，同一份執行檔複製到不同機器
## 的不同路徑一樣會分流。
static func _checkout_root() -> String:
	if OS.has_feature("editor"):
		return ProjectSettings.globalize_path("res://")
	return OS.get_executable_path().get_base_dir()
