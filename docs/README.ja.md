<p align="center">
  <img src="../screenshot.png" alt="PureMac" width="700">
</p>

<p align="center">
  <a href="../README.md">English</a> |
  <a href="README.es.md">Español</a> |
  <b>日本語</b> |
  <a href="README.zh-Hans.md">简体中文</a> |
  <a href="README.zh-Hant.md">繁體中文</a>
</p>

<h1 align="center">PureMac</h1>

<p align="center">
  <b>無料・オープンソースの macOS アプリマネージャー兼システムクリーナー。</b><br>
  アプリを完全にアンインストール。孤立ファイルを検出。システムのゴミを一掃。<br>
  サブスクリプション、テレメトリ、データ収集は一切なし。
</p>

<p align="center">
  <a href="https://github.com/momenbasel/PureMac/releases/latest"><img src="https://img.shields.io/github/v/release/momenbasel/PureMac?style=flat-square&label=%E3%83%80%E3%82%A6%E3%83%B3%E3%83%AD%E3%83%BC%E3%83%89" alt="最新リリース"></a>
  <a href="https://github.com/momenbasel/PureMac/actions/workflows/build.yml"><img src="https://img.shields.io/github/actions/workflow/status/momenbasel/PureMac/build.yml?style=flat-square&label=Build" alt="ビルド状況"></a>
  <img src="https://img.shields.io/badge/macOS-13.0+-blue?style=flat-square" alt="macOS 13.0+">
  <img src="https://img.shields.io/badge/Swift-5.9-orange?style=flat-square" alt="Swift 5.9">
  <a href="../LICENSE"><img src="https://img.shields.io/github/license/momenbasel/PureMac?style=flat-square" alt="MIT License"></a>
  <a href="https://github.com/momenbasel/PureMac/stargazers"><img src="https://img.shields.io/github/stars/momenbasel/PureMac?style=flat-square" alt="スター数"></a>
  <a href="https://github.com/momenbasel/PureMac/releases"><img src="https://img.shields.io/github/downloads/momenbasel/PureMac/total?style=flat-square&label=%E3%83%80%E3%82%A6%E3%83%B3%E3%83%AD%E3%83%BC%E3%83%89%E6%95%B0" alt="ダウンロード数"></a>
</p>

<p align="center">
  <a href="#インストール">インストール</a> -
  <a href="#機能">機能</a> -
  <a href="#スクリーンショット">スクリーンショット</a> -
  <a href="#コントリビューション">コントリビューション</a>
</p>

---

## インストール

### Homebrew（推奨）

```bash
brew update
brew install --cask puremac
```

### 直接ダウンロード

[Releases](https://github.com/momenbasel/PureMac/releases/latest) から最新の `.dmg` をダウンロードし、開いて PureMac を `/Applications` にドラッグします。

> Apple Developer ID で署名・公証済み — Gatekeeper の警告なしでインストールできます。

### ソースからビルド

```bash
brew install xcodegen
git clone https://github.com/momenbasel/PureMac.git
cd PureMac
xcodegen generate
xcodebuild -project PureMac.xcodeproj -scheme PureMac -configuration Release -derivedDataPath build build
open build/Build/Products/Release/PureMac.app
```

## 機能

### アプリアンインストーラー
- `/Applications` と `~/Applications` からすべてのインストール済みアプリを検出
- **10 段階のマッチング**を行うヒューリスティックなファイル検出エンジン（バンドル ID、企業名、エンタイトルメント、チーム識別子、Spotlight メタデータ、コンテナ検出）
- **3 段階の感度**: Strict（安全）、Enhanced（バランス重視）、Deep（徹底）
- 関連するすべてのファイルを表示: キャッシュ、設定、コンテナ、ログ、サポートファイル、ランチエージェント
- システムアプリ保護 — 27 個の Apple 製アプリがアンインストール対象から除外されます
- マスター／ディテールビュー: 左にアプリ一覧、右に検出されたファイル

### 孤立ファイル検出
- アンインストール済みアプリが `~/Library` に残した残骸を検出
- Library の内容を、インストール済みアプリの識別子と照合
- ワンクリックで孤立ファイルをクリーンアップ

### システムクリーナー
- **スマートスキャン** — すべてのカテゴリをワンクリックでスキャン
- **システムジャンク** — システムキャッシュ、ログ、一時ファイル
- **ユーザーキャッシュ** — すべてのアプリキャッシュを動的に検出（ハードコーディングされたリストなし）
- **メール添付ファイル** — ダウンロード済みのメール添付
- **ゴミ箱** — すべてのゴミ箱を空に
- **大容量・古いファイル** — 100 MB を超える、または 1 年以上経過したファイル
- **消去可能領域** — APFS の消去可能ディスク領域を検出
- **Xcode ジャンク** — DerivedData、Archives、シミュレータキャッシュ
- **Brew キャッシュ** — Homebrew ダウンロードキャッシュ（カスタム HOMEBREW_CACHE も検出）
- **スケジュールクリーニング** — 設定可能な間隔での自動スキャン

### ネイティブな macOS 体験
- ネイティブ macOS コンポーネントを使った SwiftUI で実装
- `NavigationSplitView`、`Toggle`、`ProgressView`、`Form`、`GroupBox`、`Table`
- システムのライト／ダークモードを自動で尊重
- カスタムグラデーション、グロー、Web アプリ風のスタイリングなし
- 初回起動時にフルディスクアクセスのオンボーディング

### 安全性
- 破壊的な操作の前に必ず確認ダイアログを表示
- シンボリックリンク攻撃の防止 — 削除前にパスを解決・検証
- システムアプリ保護 — Apple 製アプリはアンインストール不可
- 大容量・古いファイルは自動選択されません
- `os.log` による構造化ログ（Console.app で閲覧可能）

## スクリーンショット

| オンボーディング | アプリアンインストーラー |
|---|---|
| ![オンボーディング](../screenshots/onboarding.png) | ![アプリアンインストーラー](../screenshots/app-uninstaller.png) |

| システムジャンク | Xcode ジャンク |
|---|---|
| ![システムジャンク](../screenshots/system-junk.png) | ![Xcode ジャンク](../screenshots/xcode-junk.png) |

| ユーザーキャッシュ |
|---|
| ![ユーザーキャッシュ](../screenshots/user-cache.png) |

## アーキテクチャ

```
PureMac/
  Logic/Scanning/     - ヒューリスティックなスキャンエンジン、ロケーションデータベース、条件
  Logic/Utilities/    - 構造化ログ
  Models/             - データモデル、型付きエラー
  Services/           - スキャンエンジン、クリーニングエンジン、スケジューラ
  ViewModels/         - アプリ全体の状態管理
  Views/              - ネイティブな SwiftUI ビュー
    Apps/             - アプリアンインストーラーのビュー
    Cleaning/         - スマートスキャンとカテゴリビュー
    Orphans/          - 孤立ファイル検出
    Settings/         - ネイティブ Form ベースの設定画面
    Components/       - 共有コンポーネント
```

主要なコンポーネント:
- **AppPathFinder** — アプリ関連ファイルを検出するための 10 段階ヒューリスティックマッチングエンジン
- **Locations** — macOS の 120 以上のファイルシステム検索パス
- **Conditions** — 特殊ケース用の 25 個のアプリ別マッチングルール（Xcode、Chrome、VS Code など）
- **AppInfoFetcher** — アプリ検出のための Spotlight メタデータ + Info.plist フォールバック
- **Logger** — Apple の `os.log` による統合ロギング

## コントリビューション

コントリビューションを歓迎します。ガイドラインは [CONTRIBUTING.md](../CONTRIBUTING.md) を参照してください。

特に歓迎する分野:
- カテゴリビューでのサイズ／日付フィルターのプリセット
- AppState やスキャンエンジンに対する XCTest のカバレッジ
- ローカライゼーション（その他の言語）
- アプリアイコンのデザイン

## ライセンス

MIT ライセンス。詳細は [LICENSE](../LICENSE) を参照してください。
