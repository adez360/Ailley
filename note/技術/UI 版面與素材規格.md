---
tags:
  - 技術
  - ui
status: 已實作
scene: scenes/bubble.tscn, scenes/chat_input.tscn, scenes/debug_console.tscn, scenes/main.tscn
script: scripts/ui/bubble.gd, scripts/ui/status_panel.gd, scripts/ui/inventory_panel.gd
updated: 2026-08-11
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

## 調色盤

暖土色系。`assets/ui/ailley.gpl`，Aseprite 直接載入，畫圖時鎖住不要取盤外的色。

| 名稱 | Hex | 角色 |
| --- | --- | --- |
| Ink | `#1A1512` | 最暗；主控台底（配 85% alpha）、Amber 上的字 |
| **Bark** | `#2F2522` | 面板外框、主文字 —— **沿用角色 sprite 的描邊色** |
| Loam | `#5D4A38` | 次要文字、面板暗面 |
| Clay | `#75593C` | 停用文字、分隔線 |
| Wheat | `#D9C49A` | 面板底 |
| **Cream** | `#FAF3E8` | 面板亮面、氣泡底 —— **沿用角色 sprite 的本體色** |
| Amber | `#C96C23` | 強調底（選中分頁、focus 框、滑桿已填滿段） |
| Honey | `#F0A94E` | 強調亮 |
| Moss | `#5D6145` | 正面／成功 |
| Ember | `#8B1F14` | 警示／危險 |
| Ash | `#7E8A93` | *選用*。中性 chrome，對比只有 4.2:1，不要拿來墊正文 |
| Sage | `#ACCAB2` | *選用*。柔和提示 |

Ink→Cream 是一條**明度單調遞增**的斜坡（10→18→36→46→85→98%），色相同時從 14° 位移到 40° ——
暗處偏紅、亮處偏黃。這個色相位移是像素調色盤看起來有沒有設計過的分水嶺，
不要用只調明暗的斜坡。

文字搭配全部驗過 WCAG：主文字/面板底 8.74:1、次要/面板底 4.92:1、
Ink/Amber 4.87:1、Cream/Moss 5.84:1、Cream/Ember 8.27:1。停用文字 3.79:1 是刻意壓低的。

> [!warning] `chatbox-1.png` 目前用純白
> 它只有兩個顏色：`#FFFFFF` 與 `#595652`，都在盤外。
> 純白跟角色的暖奶油 `#FAF3E8` 擺在一起會顯得死白，重畫氣泡時一起換掉。

世界側的既有用色（畫 UI 時的參照）：草地 `#A1C688` / `#B3D79A`、泥土 `#C6A47F`、
交界 `#808B77`；角色 `#FAF3E8` 本體、`#2F2522` 描邊、`#B9B3A1` 陰影。

## 目前的版面座標

| 節點 | 位置 |
| --- | --- |
| `chat_input.tscn` 的 `Input` | 底部置中，240×20，離底 12 |
| `debug_console.tscn` 的 `Root` | 頂部橫向貼邊，左右各留 4，高 128 |
| `main.tscn` 的 `HUD/TimeLabel` | 左上 (4, 2) |
| `main.tscn` 的 `StatusPanel/Panel` | 螢幕置中，150×175 |
| `main.tscn` 的 `InventoryPanel/Panel` | 螢幕置中，280×160 |
| `main.tscn` 的 `Hotbar/Backdrop` | 底部置中，270×40，離底 8 |
| 氣泡折行寬度 | `bubble.gd` 的 `MAX_LINE_WIDTH = 132`，11px 下一行約 12 個中文字 |

氣泡的 `BORDER_X` / `BORDER_TOP` / `BORDER_BOTTOM` / `TAIL_INSET_FROM_RIGHT` 對應素材本身的 patch margin，只有換素材時才動，跟解析度無關。

### StatusPanel 重用 Setting menu.png 的做法

`Setting menu.png`（256×144）切兩格，各 106×122：左格帶烤進圖裡的 "SETTINGS" 標題列
（含底線），右格素面。`StatusPanel/Panel` 的背景是 `StyleBoxTexture`，`region_rect`
切左格 `Rect2(11, 12, 106, 122)`。

九宮格中間會被拉伸這件事決定了 `texture_margin` 怎麼抓：

> [!warning] `texture_margin_top` 太小的話，標題文字會被跟著拉伸、對不上自己疊上去的 Label
> 9-slice 只有 `texture_margin` 框住的邊角是 1:1 不拉伸；框外（哪怕離邊角很近）
> 一律進中間可伸縮區，面板大小一變就跟著非等比縮放。標題文字＋底線一起烤在素材裡，
> 如果只留 6px 頂邊界，文字會落進可伸縮區，位置跟著面板高度飄，蓋不準。
> 解法是把 `texture_margin_top` 拉到 28（蓋過底線），讓整條標題列變成固定不拉伸的頂邊，
> 場景裡 `TitleBg`／`TitleLabel` 的座標才會跟素材原始像素位置一致。

面板文字疊法：`TitleBg`（ColorRect，色 `#DCB98A`，取樣自素材本體色，不是 theme 的
Wheat `#D9C49A`——兩者肉眼相近但不是同一個值，蓋色要用素材自己的顏色才會無縫）
蓋掉烤進去的 "SETTINGS" 字樣，`TitleLabel` 疊在上面放角色名字，底線裝飾留著不蓋。

StatsBox 底下的 Label 是 `_ready()` 動態長出來的（見 stats.gd 同款設計），
場景編輯器設不到顏色，字色只能在 `status_panel.gd` 裡 `add_theme_color_override`。

### `Sprite sheet for Basic Pack.png` 的格子素材

背包／快捷欄格框用的是這張圖裡素面的暖色格子（跟本專案調色盤的 Wheat 系一致，
同一張圖另外還有一組冷色調的變體，跟本專案色系不搭，沒用）：
`region_rect = Rect2(11, 59, 26, 28)`。整張圖是 48×48 的網格排列
（icon 本體 26×28，其餘是留白），要切別的圖示時先假設同一個網格對。

快捷欄（`hotbar.gd`，螢幕下方常駐 9 格）跟主背包（`inventory_panel.gd`，
按 P 開關的 27 格）是**兩個獨立的 CanvasLayer**，不是同一個節點樹底下的
兩塊——快捷欄要在背包沒開的時候也看得到，硬塞進同一個面板做不到。
兩邊各自 `_ready()` 用 `TextureButton` 動態生出格子（理由跟
`status_panel.gd` 的 `StatsBox` 一樣：資料筆數變動時不用回頭改場景），
選取狀態不換圖，用 `modulate` 疊 Amber `#C96C23` 色調表示，跟
`ailley_theme.tres` 的 `TextEdit` focus 框同一個顏色語意。

快捷欄的選取（`Inventory.set_selected_index()`）是角色自己的狀態，
主背包格點擊只是 `InventoryPanel` 自己的視覺高亮——`Inventory` 沒有
主背包格對應的資料欄位可以存，硬塞的話等於誤把主背包點擊當成換手持物品。

## 還沒做的

- `bubble.tscn` 的 `Box.region_rect` 是非整數（`Rect2(6.065604, 6.3701286, ...)`）。9-slice 用非整數 region 會取樣到相鄰像素，邊框出現雜點
- `assets/unuse/` 裡的 1536×1024 與 1362×1155 對話框圖在這個解析度用不上，縮下來必糊
- `StatusPanel` 的年齡欄目前是 `AGE_PLACEHOLDER` 示意值，Character 還沒有年齡欄位
- `InventoryPanel` 的 36 格目前全部空著，沒有任何道具圖示（`Inventory` 還沒有 item 登錄資料）
