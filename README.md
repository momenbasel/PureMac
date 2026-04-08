# PureMac

A free, open-source macOS cleaning utility. Keep your Mac fast, clean, and optimized.

![macOS](https://img.shields.io/badge/macOS-13.0+-blue)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)
![License](https://img.shields.io/badge/License-MIT-green)

## Features

- **Smart Scan** - Scan all categories at once with a single click
- **System Junk** - Clean system caches, logs, and temporary files
- **User Cache** - Remove application caches and browser data
- **Mail Attachments** - Clear downloaded mail attachments
- **Trash Bins** - Empty your Trash
- **Large & Old Files** - Find files over 100 MB or older than 1 year
- **Purgeable Space** - Purge APFS purgeable disk space (Time Machine snapshots)
- **Xcode Junk** - Clean derived data, archives, and simulator caches
- **Homebrew Cache** - Clear Homebrew download cache
- **Scheduled Cleaning** - Automatic scans on configurable intervals (hours/days/weeks)
- **Auto-Purge** - Automatically purge purgeable files on schedule
- **Click-to-inspect** - Click any category to see exactly what will be removed

## Screenshots

| Smart Scan | Category Detail |
|---|---|
| ![Smart Scan](screenshots/smart-scan.png) | ![System Junk Detail](screenshots/system-junk-detail.png) |

## Install

### Download (recommended)

Download the latest `.app` from [Releases](https://github.com/momenbasel/PureMac/releases), unzip, and drag to `/Applications`.

### Build from source

```bash
# Prerequisites
brew install xcodegen

# Clone and build
git clone https://github.com/momenbasel/PureMac.git
cd PureMac
xcodegen generate
xcodebuild -project PureMac.xcodeproj -scheme PureMac -configuration Release -derivedDataPath build build

# Run
open build/Build/Products/Release/PureMac.app

# Or open in Xcode
open PureMac.xcodeproj
```

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
| Mail Attachments | `~/Library/Mail Downloads` |
| Trash | `~/.Trash` |
| Large Files | `~/Downloads`, `~/Documents`, `~/Desktop` (>100MB or >1yr old) |
| Purgeable | Time Machine local snapshots via `tmutil` |
| Xcode | `DerivedData`, `Archives`, `CoreSimulator/Caches` |
| Homebrew | `~/Library/Caches/Homebrew` |

## Safety

- Never deletes system-critical files
- Only removes caches, logs, temporary files, and user-selected items
- Large & Old Files are **not auto-selected** - you choose what to remove
- All operations are non-destructive to the operating system
- Purgeable space calculation uses only Time Machine snapshots, not total free space

## License

MIT License. See [LICENSE](LICENSE) for details.
