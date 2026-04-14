<p align="center">
  <img src="screenshot.png" alt="PureMac" width="700">
</p>

<h1 align="center">PureMac</h1>

<p align="center">
  <b>Free, open-source macOS cleaner.</b> The CleanMyMac alternative that respects your privacy.<br>
  No subscriptions. No telemetry. No data collection. Just a clean Mac.
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
  <a href="#comparison">Comparison</a> -
  <a href="#contributing">Contributing</a>
</p>

---

## Why PureMac?

Most Mac cleaning apps cost $30-50/year, collect usage data, and show upsell popups. PureMac does the same job for free, runs entirely offline, and the source code is right here for you to audit.

- **100% free** - no trial, no premium tier, no subscriptions
- **100% private** - no analytics, no telemetry, no network calls
- **100% native** - built with SwiftUI, no Electron, no web views
- **100% open source** - MIT licensed, audit the code yourself
- **Signed & notarized** - Apple Developer ID, no Gatekeeper warnings

## Install

### Homebrew (recommended)

```bash
brew tap momenbasel/tap
brew install --cask puremac
```

### Direct Download

Download the latest `.app` from [Releases](https://github.com/momenbasel/PureMac/releases/latest), unzip, and drag to `/Applications`.

> Signed and notarized with Apple Developer ID - installs without security warnings.



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

- **Smart Scan** - One-click scan across all categories
- **System Junk** - System caches, logs, and temporary files
- **User Cache** - Application caches and browser data
- **AI Apps** - Ollama and LM Studio logs, caches, and temporary app data
- **Mail Attachments** - Downloaded mail attachments
- **Trash Bins** - Empty all Trash bins
- **Large & Old Files** - Files over 100 MB or older than 1 year
- **Purgeable Space** - APFS purgeable disk space (Time Machine snapshots)
- **Xcode Junk** - Derived data, archives, and simulator caches
- **Homebrew Cache** - Homebrew download cache
- **Scheduled Cleaning** - Automatic scans on configurable intervals
- **Auto-Purge** - Automatically purge purgeable files on schedule
- **Click-to-inspect** - See exactly what will be removed before cleaning

## Screenshots

| Smart Scan | Category Detail | File Inspector |
|---|---|---|
| ![Smart Scan](screenshots/smart-scan.png) | ![System Junk](screenshots/system-junk-detail.png) | ![Category View](screenshots/category-view.png) |

## Comparison

How does PureMac stack up against other Mac cleaning tools?

| Feature | PureMac | CleanMyMac X | OnyX | AppCleaner |
|---|---|---|---|---|
| Price | **Free** | $39.95/yr | Free | Free |
| Open source | **Yes** | No | No | No |
| Privacy (no telemetry) | **Yes** | No | Yes | Yes |
| System cache cleaning | **Yes** | Yes | Yes | No |
| Xcode junk cleaning | **Yes** | Yes | No | No |
| Scheduled auto-cleaning | **Yes** | Yes | No | No |
| Purgeable space purging | **Yes** | No | No | No |
| App uninstaller | No | Yes | No | Yes |
| Malware scanner | No | Yes | No | No |
| Native SwiftUI | **Yes** | No (AppKit) | No (AppKit) | No (AppKit) |
| macOS Ventura+ | **Yes** | Yes | Yes | Yes |

## Scheduling

1. Open **Settings** (gear icon or Cmd+,)
2. Go to the **Schedule** tab
3. Enable **Automatic Cleaning**
4. Choose your interval: hourly / 3h / 6h / 12h / daily / weekly / biweekly / monthly
5. Optionally enable **Auto-clean after scan** and **Auto-purge purgeable space**

## What Gets Cleaned

| Category | Paths |
|---|---|
| System Junk | `/Library/Caches`, `/Library/Logs`, `/tmp`, `~/Library/Logs` |
| User Cache | `~/Library/Caches`, npm/pip/yarn/pnpm caches |
| AI Apps | `~/.ollama/logs`, Ollama caches/WebKit/saved state, `~/.lmstudio/server-logs` |
| Mail Attachments | `~/Library/Mail Downloads` |
| Trash | `~/.Trash` |
| Large Files | `~/Downloads`, `~/Documents`, `~/Desktop` (>100MB or >1yr old) |
| Purgeable | Time Machine local snapshots via `tmutil` |
| Xcode | `DerivedData`, `Archives`, `CoreSimulator/Caches` |
| Homebrew | `~/Library/Caches/Homebrew` |

## Safety

- Never deletes system-critical files
- Only removes caches, logs, temporary files, and user-selected items
- AI Apps excludes Ollama models, LM Studio models, and LM Studio conversations
- Large & Old Files are **not auto-selected** - you choose what to remove
- All operations are non-destructive to the operating system
- Purgeable space uses only Time Machine snapshots, not actual free space

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

MIT License. See [LICENSE](LICENSE) for details.

---

<p align="center">
  If PureMac saved you time or money, consider giving it a star on GitHub.
</p>
