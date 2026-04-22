<p align="center">
  <img src="../screenshot.png" alt="PureMac" width="700">
</p>

<p align="center">
  <a href="../README.md">English</a> |
  <a href="README.ar.md">العربية</a> |
  <a href="README.es.md">Español</a> |
  <a href="README.ja.md">日本語</a> |
  <a href="README.zh-Hans.md">简体中文</a> |
  <b>繁體中文</b>
</p>

<h1 align="center">PureMac</h1>

<p align="center">
  <b>免費、開源的 macOS 應用程式管理與系統清理工具。</b><br>
  徹底解除安裝應用程式。尋找孤立檔案。清理系統垃圾。<br>
  無訂閱。無遙測。無資料收集。
</p>

<p align="center">
  <a href="https://github.com/momenbasel/PureMac/releases/latest"><img src="https://img.shields.io/github/v/release/momenbasel/PureMac?style=flat-square&label=%E4%B8%8B%E8%BC%89" alt="最新版本"></a>
  <a href="https://github.com/momenbasel/PureMac/actions/workflows/build.yml"><img src="https://img.shields.io/github/actions/workflow/status/momenbasel/PureMac/build.yml?style=flat-square&label=Build" alt="建置狀態"></a>
  <img src="https://img.shields.io/badge/macOS-13.0+-blue?style=flat-square" alt="macOS 13.0+">
  <img src="https://img.shields.io/badge/Swift-5.9-orange?style=flat-square" alt="Swift 5.9">
  <a href="../LICENSE"><img src="https://img.shields.io/github/license/momenbasel/PureMac?style=flat-square" alt="MIT 授權"></a>
  <a href="https://github.com/momenbasel/PureMac/stargazers"><img src="https://img.shields.io/github/stars/momenbasel/PureMac?style=flat-square" alt="Stars"></a>
  <a href="https://github.com/momenbasel/PureMac/releases"><img src="https://img.shields.io/github/downloads/momenbasel/PureMac/total?style=flat-square&label=%E4%B8%8B%E8%BC%89%E6%95%B8" alt="下載數"></a>
</p>

<p align="center">
  <a href="#安裝">安裝</a> -
  <a href="#功能">功能</a> -
  <a href="#螢幕截圖">螢幕截圖</a> -
  <a href="#貢獻">貢獻</a>
</p>

---

## 安裝

### Homebrew（建議）

```bash
brew update
brew install --cask puremac
```

### 直接下載

從 [Releases](https://github.com/momenbasel/PureMac/releases/latest) 下載最新的 `.dmg`,開啟後將 PureMac 拖曳到 `/Applications`。

> 已使用 Apple Developer ID 簽署並公證 — 安裝時不會出現 Gatekeeper 警告。

### 由原始碼建置

```bash
brew install xcodegen
git clone https://github.com/momenbasel/PureMac.git
cd PureMac
xcodegen generate
xcodebuild -project PureMac.xcodeproj -scheme PureMac -configuration Release -derivedDataPath build build
open build/Build/Products/Release/PureMac.app
```

## 功能

### 應用程式解除安裝
- 從 `/Applications` 及 `~/Applications` 探索所有已安裝的應用程式
- 具備**10 層比對機制**的啟發式檔案發現引擎(Bundle ID、公司名稱、entitlements、Team Identifier、Spotlight 中繼資料、容器探索)
- **3 種靈敏度**:Strict(安全)、Enhanced(平衡)、Deep(徹底)
- 顯示所有相關檔案:快取、偏好設定、容器、記錄、支援檔案、啟動代理
- 系統應用程式保護 — 排除 27 個 Apple 應用程式,避免誤刪
- 主從檢視:左側為應用程式列表,右側為發現的檔案

### 孤立檔案搜尋
- 偵測 `~/Library` 中已解除安裝應用程式留下的殘餘檔案
- 將 Library 內容與所有已安裝應用程式的識別碼比對
- 一鍵清除孤立檔案

### 系統清理
- **智慧掃描** — 一鍵掃描所有分類
- **系統垃圾** — 系統快取、記錄與暫存檔案
- **使用者快取** — 動態發現所有應用程式快取(不需寫死清單)
- **郵件附件** — 已下載的郵件附件
- **垃圾桶** — 清空所有垃圾桶
- **大型與舊檔案** — 超過 100 MB 或超過 1 年的檔案
- **可清除空間** — 偵測 APFS 可清除磁碟空間
- **Xcode 垃圾** — DerivedData、Archives、模擬器快取
- **Brew 快取** — Homebrew 下載快取(可辨識自訂的 HOMEBREW_CACHE)
- **排程清理** — 以可設定的間隔自動掃描

### 原生 macOS 體驗
- 使用 SwiftUI 與原生 macOS 元件打造
- `NavigationSplitView`、`Toggle`、`ProgressView`、`Form`、`GroupBox`、`Table`
- 自動沿用系統淺色/深色模式
- 不使用自訂漸層、光暈或網頁風格樣式
- 首次啟動時提供完整磁碟存取權的設定流程

### 安全性
- 所有破壞性操作前皆會顯示確認對話框
- 符號連結攻擊防護 — 刪除前先解析並驗證路徑
- 系統應用程式保護 — Apple 應用程式無法被解除安裝
- 大型與舊檔案永遠不會被自動勾選
- 透過 `os.log` 進行結構化記錄(可在「主控台」App 中檢視)

## 螢幕截圖

| 引導 | 應用程式解除安裝 |
|---|---|
| ![引導](../screenshots/onboarding.png) | ![應用程式解除安裝](../screenshots/app-uninstaller.png) |

| 系統垃圾 | Xcode 垃圾 |
|---|---|
| ![系統垃圾](../screenshots/system-junk.png) | ![Xcode 垃圾](../screenshots/xcode-junk.png) |

| 使用者快取 |
|---|
| ![使用者快取](../screenshots/user-cache.png) |

## 架構

```
PureMac/
  Logic/Scanning/     - 啟發式掃描引擎、位置資料庫、條件
  Logic/Utilities/    - 結構化記錄
  Models/             - 資料模型、型別化錯誤
  Services/           - 掃描引擎、清理引擎、排程器
  ViewModels/         - 集中式應用程式狀態
  Views/              - 原生 SwiftUI 視圖
    Apps/             - 應用程式解除安裝視圖
    Cleaning/         - 智慧掃描與分類視圖
    Orphans/          - 孤立檔案搜尋
    Settings/         - 以原生 Form 為基礎的設定
    Components/       - 共用元件
```

核心元件:
- **AppPathFinder** — 用於發現應用程式相關檔案的 10 層啟發式比對引擎
- **Locations** — 120 組以上的 macOS 檔案系統搜尋路徑
- **Conditions** — 針對特殊情況(Xcode、Chrome、VS Code 等)的 25 條應用程式比對規則
- **AppInfoFetcher** — 以 Spotlight 中繼資料搭配 Info.plist 作為後備的應用程式發現
- **Logger** — 以 Apple `os.log` 為基礎的整合式記錄

## 貢獻

歡迎參與貢獻。請參閱 [CONTRIBUTING.md](../CONTRIBUTING.md) 了解指引。

特別歡迎協助的方向:
- 分類視圖中的大小/日期篩選預設值
- AppState 與掃描引擎的 XCTest 覆蓋率
- 本地化(其他語言)
- 應用程式圖示設計

## 授權

MIT 授權。詳情請參閱 [LICENSE](../LICENSE)。
