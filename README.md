<p align="center">
  <img src="screenshots/smart-care.png" alt="Qpure" width="700">
</p>

<p align="center">
  <a href="README.en.md">English (upstream)</a> |
  <a href="docs/README.ar.md">العربية</a> |
  <a href="docs/README.es.md">Español</a> |
  <a href="docs/README.ja.md">日本語</a> |
  <a href="docs/README.pt-BR.md">Português (Brasil)</a> |
  <b>简体中文</b> |
  <a href="docs/README.zh-Hant.md">繁體中文</a>
</p>

<h1 align="center">Qpure</h1>

<p align="center"><img src="assets/qpure-icon-source.png" alt="Qpure logo" width="112"></p>

<p align="center">
  <b>免费、开源的 macOS 应用管理器与系统清理工具。</b><br>
  彻底卸载应用。查找孤立文件。清理系统垃圾。<br>
  无订阅。无遥测。无数据收集。
</p>

<p align="center">
  <a href="https://github.com/qg-hs/Qpure/actions/workflows/build.yml"><img src="https://img.shields.io/github/actions/workflow/status/qg-hs/Qpure/build.yml?style=flat-square&label=Build" alt="构建状态"></a>
  <img src="https://img.shields.io/badge/macOS-13.0+-blue?style=flat-square" alt="macOS 13.0+">
  <img src="https://img.shields.io/badge/Swift-5.9-orange?style=flat-square" alt="Swift 5.9">
  <a href="LICENSE"><img src="https://img.shields.io/github/license/qg-hs/Qpure?style=flat-square" alt="MIT 许可证"></a>
  <a href="https://github.com/qg-hs/Qpure/stargazers"><img src="https://img.shields.io/github/stars/qg-hs/Qpure?style=flat-square" alt="Stars"></a>
</p>

<p align="center">
  <a href="#安装">安装</a> -
  <a href="#功能">功能</a> -
  <a href="#截图">截图</a> -
  <a href="#贡献">贡献</a>
</p>

---

## 安装

### Homebrew

```bash
# Qpure 当前尚未发布独立的 Homebrew 安装包
```

### 直接下载

从 [GitHub Releases](https://github.com/qg-hs/Qpure/releases) 下载最新的 `Qpure-macOS-universal-<版本>.zip`，解压后将 `Qpure.app` 拖到 `/Applications`。

此预览包未使用 Developer ID 签名或 Apple 公证，macOS 首次打开时可能显示安全提示；也可以按下方说明从源码构建。

### 从源码构建

```bash
brew install xcodegen
git clone https://github.com/qg-hs/Qpure.git
cd Qpure
xcodegen generate
xcodebuild -project PureMac.xcodeproj -scheme PureMac -configuration Release -derivedDataPath build build
open build/Build/Products/Release/Qpure.app
```

## 语言与国际化

在「设置 → 通用 → 语言」中选择系统默认或指定语言，切换后重启应用即可生效。界面包含简体中文、繁體中文及其他 9 种语言。添加翻译的方法见[国际化说明](docs/i18n.md)。

## 功能

### 应用卸载器
- 从 `/Applications` 和 `~/Applications` 发现所有已安装应用
- 基于启发式的文件发现引擎,采用**10 级匹配**(Bundle ID、公司名称、entitlements、团队标识符、Spotlight 元数据、容器发现)
- **3 种灵敏度**:严格(安全)、增强(平衡)、深度(彻底)
- 展示所有相关文件:缓存、偏好设置、容器、日志、支持文件、启动代理
- 系统应用保护 — 排除 27 个 Apple 应用,避免误删
- 主从视图:左侧为应用列表,右侧为发现的文件

### 孤立文件查找
- 检测 `~/Library` 中已卸载应用残留的文件
- 将 Library 内容与所有已安装应用的标识符进行比对
- 一键清理孤立文件

### 系统清理
- **智能扫描** — 一键扫描所有类别
- **系统垃圾** — 系统缓存、日志和临时文件
- **用户缓存** — 动态发现所有应用缓存(无需硬编码应用列表)
- **AI 应用** — Ollama 和 LM Studio 日志、缓存，以及可选的本地历史记录清理
- **邮件附件** — 已下载的邮件附件
- **废纸篓** — 清空所有废纸篓
- **大文件与旧文件** — 超过 100 MB 或超过 1 年的文件
- **可清除空间** — 检测 APFS 可清除磁盘空间
- **Xcode 垃圾** — DerivedData、Archives、模拟器缓存与已下载的 simulator runtimes（通过 `simctl runtime delete` 删除，不会自动勾选）
- **Brew 缓存** — Homebrew 下载缓存(可识别自定义 HOMEBREW_CACHE)
- **定时清理** — 按可配置的间隔自动扫描

### 原生 macOS 体验
- 使用 SwiftUI 和原生 macOS 组件构建
- `NavigationSplitView`、`Toggle`、`ProgressView`、`Form`、`GroupBox`、`Table`
- 自动遵循系统浅色/深色模式
- 无自定义渐变、发光或 Web 应用样式
- 首次启动引导,支持完整磁盘访问设置

### 安全性
- 所有破坏性操作前都有确认对话框
- 防御符号链接攻击 — 删除前解析并验证路径
- 系统应用保护 — Apple 应用无法被卸载
- 大文件与旧文件永远不会被自动选中
- AI 提示和对话历史记录会显示供用户检查，但永远不会自动选中
- 通过 `os.log` 进行结构化日志记录(可在“控制台”应用中查看)

## 截图

| 引导 | 应用卸载器 |
|---|---|
| ![引导](../screenshots/onboarding.png) | ![应用卸载器](../screenshots/app-uninstaller.png) |

| 系统垃圾 | Xcode 垃圾 |
|---|---|
| ![系统垃圾](../screenshots/system-junk.png) | ![Xcode 垃圾](../screenshots/xcode-junk.png) |

| 用户缓存 |
|---|
| ![用户缓存](../screenshots/user-cache.png) |

## 架构

```
Qpure/
  Logic/Scanning/     - 启发式扫描引擎、位置数据库、条件
  Logic/Utilities/    - 结构化日志
  Models/             - 数据模型、类型化错误
  Services/           - 扫描引擎、清理引擎、调度器
  ViewModels/         - 集中式应用状态
  Views/              - 原生 SwiftUI 视图
    Apps/             - 应用卸载器视图
    Cleaning/         - 智能扫描与分类视图
    Orphans/          - 孤立文件查找
    Settings/         - 基于原生 Form 的设置
    Components/       - 共享组件
```

核心组件:
- **AppPathFinder** — 用于发现应用相关文件的 10 级启发式匹配引擎
- **Locations** — 120+ 个 macOS 文件系统搜索路径
- **Conditions** — 25 条针对特殊情况的应用级匹配规则(Xcode、Chrome、VS Code 等)
- **AppInfoFetcher** — 使用 Spotlight 元数据,并以 Info.plist 作为回退的应用发现
- **Logger** — 基于 Apple `os.log` 的统一日志

## 贡献

欢迎贡献。请参阅 [CONTRIBUTING.md](CONTRIBUTING.md) 了解指南。

特别欢迎的贡献方向:
- 分类视图中的大小/日期过滤器预设
- AppState 与扫描引擎的 XCTest 覆盖
- 本地化(其他语言)
- 应用图标设计

## 许可证

MIT 许可证。详情请参阅 [LICENSE](../LICENSE)。
