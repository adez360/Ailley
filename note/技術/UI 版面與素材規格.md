---
tags:
  - 技術
  - ui
status: 已實作
scene: scenes/bubble.tscn, scenes/chat_input.tscn, scenes/debug_console.tscn
script: scripts/ui/bubble.gd
updated: 2026-08-10
---

# UI 版面與素材規格

畫任何一張 UI 素材之前要知道的尺寸約束。

## 解析度

`project.godot` 的 `[display]`：

| 設定 | 值 |
| --- | --- |
| `viewport_width` / `viewport_height` | 640 × 360 |
| `stretch/mode` | `canvas_items` |
| `stretch/scale_mode` | `integer` |
| `stretch/aspect` | `keep` |
| `default_texture_filter` | 0（nearest） |

> [!note] `stretch/aspect` 查不到是正常的
> `keep` 是引擎預設值，Godot 只把非預設值寫進 `project.godot`，所以那一行不存在。
> 行為仍然是 `keep`，用 `project_manage(op="settings_get")` 查得到。

選 640×360 的理由是**高度要能整除 360**，常見螢幕才都落在整數倍、不留黑邊：

| 螢幕 | 倍率 |
| --- | --- |
| 1280×720 | 2x |
| 1920×1080 | 3x |
| 2560×1440 | 4x |
| 3840×2160 | 6x |

高度 270 那一系列（480×270）在 720p 與 1440p 都不整除，所以不用。

素材一律 **1:1 畫**，不要在 Godot 裡縮放。要讓世界看起來更厚重就調 `Camera2D.zoom`（只用整數），不要縮 viewport —— zoom 只放大世界，CanvasLayer 上的 UI 不受影響，這才是「厚重世界 + 精細 UI」的做法。

## 字型

**全 UI 字級統一 11。** 點陣中文字型只在原生尺寸或其整數倍才銳利，混用字級會有一部分糊掉。

選定 Cubic 11（俐方體 11 號，11px，OFL，含繁中）。

字型檔在 `assets/fonts/Cubic_11.ttf`，透過專案設定 `gui/theme/custom_font` 掛上 ——
Godot 會把它套成 project theme 的 `default_font`，效果等同寫進 `.tres`。
執行期實測 `get_theme_font("font").get_font_name()` 回 `"Cubic 11"`。

`Cubic_11.ttf.import` 的四個關鍵值**必須是這樣**，改動任何一個字就會糊掉：

| 參數 | 值 | 為什麼 |
| --- | --- | --- |
| `antialiasing` | `0`（None） | 開著的話 11px 中文的 1px 筆畫會被攤成兩個半透明像素 |
| `hinting` | `0`（None） | 會擅自挪動字幹 |
| `subpixel_positioning` | `0`（Disabled） | 官方文件明講像素字必關，否則像素大小不均 |
| `oversampling` | `1.0` | 預設 `0.0` 會跟著 viewport 倍率，把 11px 字直接點陣化成 33px，而不是畫成 11px 再讓 viewport 用最鄰近放大 |

沒有 MCP op 能改 `.import`，只能在編輯器的 Import 分頁改完按 Reimport。

> [!tip] 怎麼客觀驗證「有沒有糊」
> 不要靠眼睛。把字型的點陣圖集撈出來數 alpha：
>
> ```gdscript
> var img = font.get_texture_image(0, Vector2i(11, 0), 0)
> # 逐像素統計 get_pixel(x, y).a
> ```
>
> 設定正確時**中間值必須是 0 個**（只有 alpha 0 與 1）。
> 實測：設定錯誤時是 partial 2604 / full 8，正確時是 partial 0 / full 1295。

## Theme

`assets/ui/ailley_theme.tres`，掛在專案設定 `gui/theme/custom`，所以**新增的 Control 自動繼承**，
不必逐一指定。樣式寫在這裡，不要再寫回場景的 `theme_override_*`。

| 條目 | 值 | 誰在用 |
| --- | --- | --- |
| `Label/font_sizes/font_size` | 11 | 全部 Label |
| `LineEdit/font_sizes/font_size` | 11 | 聊天輸入、主控台輸入 |
| `RichTextLabel/font_sizes/normal_font_size` | 11 | 主控台輸出 |
| `BubbleLabel/colors/font_color` | 深灰 `#222` | 氣泡文字 |
| `HUDLabel/colors/font_outline_color` + `constants/outline_size` | 黑、4 | 時鐘 |
| `ConsoleOutput/styles/normal` | StyleBoxFlat，半透明深色 | 主控台輸出底板 |

後三個是 **type variation**，節點端要設 `theme_type_variation` 才會套用。
場景裡已經沒有任何 `theme_override_*`，樣式全部由這份 theme 供給。

> [!tip] 清 override 時 Color 是特例
> `node_set_property` 傳 `null` 清得掉 int 與 Resource 型的 override，
> 但 Color 會回 `WRONG_TYPE: Cannot coerce Nil to Color`。
> 只能在 Inspector 的 Theme Overrides 取消勾選，或直接刪掉 `.tscn` 那一行。
> 手改 `.tscn` 之後**一定要 `scene_open(force_reload=true)`**，
> 否則編輯器記憶體裡的舊副本會在下次存檔時把修改覆蓋回去。
> 而且 `force_reload` 只在該場景已經是 current scene 時才生效 —— 第一次呼叫只是切過去，要叫兩次。

> [!warning] variation 一定要註冊 base type
> 沒有 base type 的 variation **完全不進查表** —— `get_theme_color()` 之類會直接跳過它，
> 回傳預設值而不是報錯，所以很難察覺。實測過：三個 variation 在補上 base type 之前，
> 拿到的是 `(1,1,1,1)` / `0` / `StyleBoxEmpty`。
>
> `theme_manage` 沒有對應的 op，只能在編輯器的 Theme 編輯器裡設：
> 雙擊 `.tres` → 底部面板 → 右側 Type 下拉選型別 → 扳手圖示分頁 → Base Type 旁的 ＋。

## 素材尺寸

| 類別 | 畫布 | 備註 |
| --- | --- | --- |
| 9-slice 面板 / 對話框 | 24×24 或 32×32 | 角 4px、邊 1px 可平鋪 |
| 按鈕 | 一張橫排四態 | normal / hover / pressed / disabled |
| icon | 8×8 與 16×16 兩種 | 不要中間值 |
| 滑桿 | 軌 3px 高、鈕 5×5 或 7×7 | 鈕要奇數寬才有中心點 |
| 角色 | 16×16 | 既有 sprite sheet |
| tile | 16×16 | |

調色盤先定 8–12 色（面板底 / 亮邊 / 暗邊 / 主文字 / 次文字 / 強調 / 警示 / 停用），存成 Aseprite palette 鎖住。像素 UI 看起來散掉，多半是因為每張圖各自取色。

## 目前的版面座標

| 節點 | 位置 |
| --- | --- |
| `chat_input.tscn` 的 `Input` | 底部置中，240×20，離底 12 |
| `debug_console.tscn` 的 `Root` | 頂部橫向貼邊，左右各留 4，高 128 |
| `main.tscn` 的 `HUD/TimeLabel` | 左上 (4, 2) |
| 氣泡折行寬度 | `bubble.gd` 的 `MAX_LINE_WIDTH = 132`，11px 下一行約 12 個中文字 |

氣泡的 `BORDER_X` / `BORDER_TOP` / `BORDER_BOTTOM` / `TAIL_INSET_FROM_RIGHT` 對應素材本身的 patch margin，只有換素材時才動，跟解析度無關。

## 還沒做的

- **`ConsoleOutput/base_type` 設成了 `Label`，應該是 `RichTextLabel`。**
  目前不影響 `styles/normal`（那條直接定義在 variation 上），但任何需要從 RichTextLabel
  繼承的項目都會查錯鏈
- `bubble.tscn` 的 `Box.region_rect` 是非整數（`Rect2(6.065604, 6.3701286, ...)`）。9-slice 用非整數 region 會取樣到相鄰像素，邊框出現雜點
- `assets/unuse/` 裡的 1536×1024 與 1362×1155 對話框圖在這個解析度用不上，縮下來必糊