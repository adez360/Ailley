---
tags: [ailley, tech, decision]
status: decided
created: 2026-07-10
---

# 引擎選型：Godot vs Phaser.js

> [!success] 決策
> **採用 Godot。** 以 [[System-Analyst]]（系統分析文件）為準繩，該文件的非功能性需求與發行需求指向「原生應用程式」路線（**A 案：離線原生**），Godot 的結構比 Phaser.js 更順。

## 決策前提

本案以 [[System-Analyst]] 為主文件。其骨幹為：**內嵌完全離線的地端 LLM，同時發行 Steam 買斷版與手機 App（含廣告 SDK／內購）**。此前提排除了純 Web／雲端優先路線。

## 決定性需求 × 引擎適配度

| 需求（出處） | Godot | Phaser.js |
| --- | --- | --- |
| 地端 LLM・完全離線（四・隱私與安全性） | 原生打包＋GDExtension／sidecar 較易內嵌並執行 llama.cpp；已有社群外掛（如 nobodywho） | 純瀏覽器靠 WebLLM/WebGPU 太重、實用性低；Electron＋node-llama-cpp 桌面可行，但**手機的離線本地推論非常棘手** |
| Steam 買斷＋官方 API 介接（三・電腦版） | GodotSteam 成熟、案例多 | Electron＋greenworks 可行但維護麻煩 |
| 行動版＋廣告 SDK＋內購（三・行動版） | 原生 Android/iOS 匯出，有 AdMob／IAP 外掛 | Capacitor 包裝＋webview，原生整合弱一截 |
| 地端推論效能（四・效能） | 原生較有利，手機尤其明顯 | 走 webview 較吃虧 |
| 行為樹・模組化・工作坊（四・擴充性） | LimboAI／Beehave＋Resource 易做 mod | 需自行實作 |

一句話：A 案需「內嵌離線本地 LLM，且同時上 Steam 與手機」。Phaser 得同時扛兩套包裝（桌面＝Electron／手機＝Capacitor），而 Godot 用單一原生引擎即可涵蓋雙平台。

## 已知取捨與待補（選 Godot 需正視）

> [!warning] Godot 的弱項
> - **資料密集的觀察 UI**（[[內心想法視窗]]／[[AI 日誌系統]]／回放）在 HTML/React 較好做；Godot 需用 Control／RichTextLabel 自建，工較粗。
> - 若日後未來展望轉向 **SaaS／觀戰直播／CTF 聯賽**（見 [[補充]]），Web 前端仍有其價值，屆時可能需要另做一個 Web 觀戰／回放層。

## 對既有文件的影響

- [[技術架構總覽]] 原本斷言「採用 Phaser.js＋Web＋雲端 API」，與本決策衝突，**已依 A 案改寫為 Godot＋地端 LLM＋離線**（2026-07-10）。
- [[潛在挑戰與解法]] 的風險已由「API 成本／JSON 格式」重評為「**地端推論延遲／量化、grammar 結構化輸出、離線模型打包**」。

## 相關

- 主文件 → [[System-Analyst]]
- 待改寫 → [[技術架構總覽]]
- 產品定位（離線 vs 雲端的取捨） → [[MVP 範圍]]、[[補充]]
