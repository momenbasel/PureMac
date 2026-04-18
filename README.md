<p align="center">
  <img src="screenshot.png" alt="PureMac" width="700">
</p>

<p align="center">
  <b>English</b> |
  <a href="docs/README.es.md">Español</a> |
  <a href="docs/README.ja.md">日本語</a> |
  <a href="docs/README.zh-Hans.md">简体中文</a> |
  <a href="docs/README.zh-Hant.md">繁體中文</a>
</p>

<h1 align="center">PureMac</h1>

<p align="center">
  <b>Free, open-source macOS app manager and system cleaner.</b><br>
  Uninstall apps completely. Find orphaned files. Clean system junk.<br>
  No subscriptions. No telemetry. No data collection.
</p>

<p align="center">
  <a href="https://github.com/momenbasel/PureMac/releases/latest"><img src="https://img.shields.io/github/v/release/momenbasel/PureMac?style=flat-square&label=Download" alt="Latest Release"></a>
  <a href="https://github.com/momenbasel/PureMac/actions/workflows/build.yml"><img src="https://img.shields.io/github/actions/workflow/status/momenbasel/PureMac/build.yml?style=flat-square&label=Build" alt="Build Status"></a>
  <img src="https://img.shields.io/badge/macOS-13.0+-blue?style=flat-square" alt="macOS 13.0+">
  <img src="https://img.shields.io/badge/Swift-5.9-orange?style=flat-square" alt="Swift 5.9">
  <a href="LICENSE"><img src="https://img.shields.io/github/license/momenbasel/PureMac?style=flat-square" alt="MIT License"></a>
  <a href="https://github.com/momenbasel/PureMac/stargazers"><img src="https://img.shields.io/github/stars/momenbasel/PureMac?style=flat-square" alt="Stars"></a>
  <a href="https://github.com/momenbasel/PureMac/releases"><img src="https://img.shields.io/github/downloads/momenbasel/PureMac/total?style=flat-square&label=Downloads" alt="Downloads"></a>
</p>

<p align="center">
  <a href="#install">Install</a> -
  <a href="#features">Features</a> -
  <a href="#screenshots">Screenshots</a> -
  <a href="#contributing">Contributing</a>
</p>

---

## Install

### Homebrew (recommended)

```bash
brew update
brew install --cask puremac
```

### Direct Download

Download the latest `.dmg` from [Releases](https://github.com/momenbasel/PureMac/releases/latest), open it, and drag PureMac to `/Applications`.

> Signed and notarized with Apple Developer ID - installs without Gatekeeper warnings.

### Build from source

```bash
brew install xcodegen
git clone https://github.com/momenbasel/PureMac.git
cd PureMac
xcodegen generate
xcodebuild -project PureMac.xcodeproj -scheme PureMac -configuration Release -derivedDataPath build build
open build/Build/Products/Release/PureMac.app
```

## Features

### App Uninstaller
- Discovers all installed apps from `/Applications` and `~/Applications`
- Heuristic file discovery engine with **10-level matching** (bundle ID, company name, entitlements, team identifier, Spotlight metadata, container discovery)
- **3 sensitivity levels**: Strict (safe), Enhanced (balanced), Deep (thorough)
- Shows all related files: caches, preferences, containers, logs, support files, launch agents
- System app protection - 27 Apple apps are excluded from the uninstall list
- Master-detail view: app table on left, discovered files on right

### Orphaned File Finder
- Detects leftover files in `~/Library` from apps that have been uninstalled
- Compares Library contents against all installed app identifiers
- One-click cleanup of orphaned files

### System Cleaner
- **Smart Scan** - one-click scan across all categories
- **System Junk** - system caches, logs, and temporary files
- **User Cache** - dynamically discovers all app caches (no hardcoded app list)
- **Mail Attachments** - downloaded mail attachments
- **Trash Bins** - empty all Trash
- **Large & Old Files** - files over 100 MB or older than 1 year
- **Purgeable Space** - APFS purgeable disk space detection
- **Xcode Junk** - DerivedData, Archives, simulator caches
- **Brew Cache** - Homebrew download cache (detects custom HOMEBREW_CACHE)
- **Scheduled Cleaning** - automatic scans on configurable intervals

### Native macOS Experience
- Built with SwiftUI using native macOS components
- `NavigationSplitView`, `Toggle`, `ProgressView`, `Form`, `GroupBox`, `Table`
- Respects system light/dark mode automatically
- No custom gradients, glows, or web-app styling
- First-launch onboarding with Full Disk Access setup

### Safety
- Confirmation dialogs before all destructive operations
- Symlink attack prevention - resolves and validates paths before deletion
- System app protection - Apple apps cannot be uninstalled
- Large & Old Files are never auto-selected
- Structured logging via `os.log` (visible in Console.app)

## Screenshots

| Onboarding | App Uninstaller |
|---|---|
| ![Onboarding](screenshots/onboarding.png) | ![App Uninstaller](screenshots/app-uninstaller.png) |

| System Junk | Xcode Junk |
|---|---|
| ![System Junk](screenshots/system-junk.png) | ![Xcode Junk](screenshots/xcode-junk.png) |

| User Cache |
|---|
| ![User Cache](screenshots/user-cache.png) |

## Architecture

```
PureMac/
  Logic/Scanning/     - Heuristic scan engine, locations database, conditions
  Logic/Utilities/    - Structured logging
  Models/             - Data models, typed errors
  Services/           - Scan engine, cleaning engine, scheduler
  ViewModels/         - Centralized app state
  Views/              - Native SwiftUI views
    Apps/             - App uninstaller views
    Cleaning/         - Smart scan and category views
    Orphans/          - Orphan finder
    Settings/         - Native Form-based settings
    Components/       - Shared components
```

Key components:
- **AppPathFinder** - 10-level heuristic matching engine for discovering app-related files
- **Locations** - 120+ macOS filesystem search paths
- **Conditions** - 25 per-app matching rules for edge cases (Xcode, Chrome, VS Code, etc.)
- **AppInfoFetcher** - Spotlight metadata + Info.plist fallback for app discovery
- **Logger** - Apple `os.log` unified logging

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

Areas where help is especially welcome:
- Size/date filter presets in category views
- XCTest coverage for AppState and scan engine
- Localization (zh-Hans, zh-Hant, and other languages)
- App icon design

## Acknowledgments

v2.0 was shaped by community feedback and contributions:

- **[@nguyenhuy158](https://github.com/nguyenhuy158)** - Search and filter feature request ([#18](https://github.com/momenbasel/PureMac/issues/18)) and implementation ([#29](https://github.com/momenbasel/PureMac/pull/29))
- **[@edufalcao](https://github.com/edufalcao)** - Cleaning safety guards and confirmation dialogs ([#30](https://github.com/momenbasel/PureMac/pull/30))
- **[@zeck00](https://github.com/zeck00)** - UI overhaul ([#31](https://github.com/momenbasel/PureMac/pull/31)), app uninstaller with system app protection ([#32](https://github.com/momenbasel/PureMac/pull/32)), and onboarding experience ([#33](https://github.com/momenbasel/PureMac/pull/33))
- **[@0x-man](https://github.com/0x-man)** - Symlink security vulnerability report ([#25](https://github.com/momenbasel/PureMac/issues/25))
- **[@ansidev](https://github.com/ansidev)** - Checkbox interaction bug report ([#34](https://github.com/momenbasel/PureMac/issues/34))
- **[@fengcheng01](https://github.com/fengcheng01)** - App uninstaller feature request ([#28](https://github.com/momenbasel/PureMac/issues/28))
- **[@scholzfuni](https://github.com/scholzfuni)** - Modularization proposal ([#23](https://github.com/momenbasel/PureMac/issues/23))

## License

MIT License. See [LICENSE](LICENSE) for details.
