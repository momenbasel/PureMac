# CLAUDE.md

Guidance for Claude Code working in this repository.

## 1. What this app is, and why care is needed

PureMac is a native SwiftUI macOS cleaner app (MIT licensed). It finds junk files,
app leftovers, orphaned data, unused languages and fat universal binaries, then
removes them.

**This app deletes user data.** A wrong path, a bad allow-list edit or a skipped
confirmation can destroy files a person cannot get back. Treat every change under
`Logic/`, `Services/CleaningEngine.swift` and `Logic/Utilities/OrphanSafetyPolicy.swift`
as high risk. Read section 6 before you touch any of them.

## 2. Build and test

The project uses **XcodeGen**. `project.yml` is the source of truth.
`PureMac.xcodeproj` is generated output. **Never hand-edit `PureMac.xcodeproj`.**

First-time setup:

```bash
brew install xcodegen
xcodegen generate
open PureMac.xcodeproj
```

Re-run `xcodegen generate` after any change to `project.yml`, and after every `git pull`.

If `xcode-select` points at CommandLineTools, `xcodebuild` will fail. Export the full
Xcode path first:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

Build the way CI builds (this is the only required check for merge):

```bash
xcodegen generate
xcodebuild -project PureMac.xcodeproj -scheme PureMac -configuration Release -derivedDataPath build build ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

Run the tests:

```bash
xcodebuild test -project PureMac.xcodeproj -scheme PureMac
```

In Xcode, tests run with Cmd+U.

| Item | Value |
| --- | --- |
| Deployment target | macOS 13.0 |
| Swift | 5.9 |
| xcodeVersion | 16.4 |
| Architectures | arm64 + x86_64 |
| Bundle id | `com.puremac.app` |
| Targets | `PureMac` (app), `PureMacTests` (unit tests) |
| Scheme | `PureMac` |
| Dependency | Sparkle (SPM, from 2.0.0) for auto-update |
| Test framework | XCTest (not Swift Testing) |
| Lint / format | None. No SwiftLint, no SwiftFormat. |
| CI | `.github/workflows/build.yml`, macos-15, on push to main and PRs to main |

The first build needs network access to resolve Sparkle.

`DEVELOPMENT_TEAM` is hardcoded to `H3WXHVTP97` in `project.yml`. Do not commit a
change to it. For local builds rely on the Debug config, which sets
`CODE_SIGNING_ALLOWED` to `NO`.

**CI does not run tests.** Only the build runs. See section 3 for why that matters.

## 3. The localization parity trap (read this first)

This is the most common way to break the repo.

The app ships 11 languages using classic `Localizable.strings` files (not `.xcstrings`):

`ar`, `en`, `es`, `fr`, `ja`, `pl`, `pt-BR`, `ru`, `uk`, `zh-Hans`, `zh-Hant`

`PureMacTests/LocalizationFilesTests.swift` enforces:

- key parity across all 11 files, failing on **missing keys and on extra keys**
- format-specifier parity between languages
- no duplicate keys inside a file

So:

- Adding one English string means adding that key to **all 11** `Localizable.strings` files.
- Removing one string means deleting that key from **all 11**.

**CI does not run tests, so you can get a green CI with broken localization.**
Run `xcodebuild test -project PureMac.xcodeproj -scheme PureMac` yourself before you
call any string change done.

Three lookup patterns are in use:

| Pattern | Use it for |
| --- | --- |
| Bare string literal passed to `Text` / `Button` / `Label` / `.help` / `.searchable` | Static UI text. SwiftUI resolves the key. |
| `Text(LocalizedStringKey(runtimeString))` | Runtime strings, such as enum `rawValue`. |
| `String(format: String(localized: "...%lld..."), Int64(n))` | Interpolated numbers. |

Always use `%lld` with an explicit `Int64` cast. Never `%d`.

## 4. Architecture map

| Directory | Role |
| --- | --- |
| `Core/` | App-wide constants. `AppConstants.swift`. |
| `Models/` | Pure value types, no logic. `Models.swift` (CleaningCategory, CleanableItem, CategoryResult, ScanState, DiskInfo, ScheduleConfig), `ScanError.swift` (LocalizedError enum), `AppLanguage.swift`. |
| `Logic/Scanning/` | Stateless discovery helpers. `AppPathFinder.swift` (10-level app-leftover matching engine), `Locations.swift` (120+ macOS search paths), `Conditions.swift` (25 per-app edge-case rules), `AppInfoFetcher.swift`, `UniversalBinaryScanner.swift`, `LanguageFilesScanner.swift`. |
| `Logic/Utilities/` | `Logger.swift`, `FileSize.swift` (allocated-size math), `OrphanSafetyPolicy.swift` (allowedRoots allow-list), `FileProtection.swift`, `CLI.swift`, `SimulatorRuntimeSupport.swift`. |
| `Services/` | The engines. `ScanEngine`, `CleaningEngine`, `BinaryThinner` are `actor` types. `PermissionCoordinator`, `SchedulerService`, `SystemMonitor`, `MenuBarController`, `UpdateService`, `FullDiskAccessManager` are `@MainActor` ObservableObjects. |
| `ViewModels/` | One file: `AppState.swift`, about 1128 lines, `@MainActor final class AppState: ObservableObject`. The single store for the whole app, split into 15 MARK sections. |
| `Views/` | SwiftUI screens. Subfolders `Apps/`, `Components/`, `Orphans/`, `Settings/`. `Views/Components/AppTheme.swift` holds the design system: CardSurface, IconTile, Tint, MotionTokens, AnimatedCheckboxStyle, EmptyStateView. |
| `Extensions/` | `Theme.swift`, one View modifier. |

## 5. Code style (observed, not aspirational)

- 4 spaces. No tabs.
- Types default to `internal` with no explicit modifier. Everything else is `private`.
  The tree has 573 uses of `private` against 5 explicit `internal`.
- `// MARK: - Title`, with the dash, in files over roughly 60 lines.
- Most files have **no header comment block**. They start with `import SwiftUI` or
  `import Foundation`. A few older files still carry an Xcode template header.
  New files get no header block.
- Comments explain **why**, and often cite an issue number such as `(#114)`.
- State is classic Combine: `ObservableObject` + `@Published` + `@EnvironmentObject` +
  `@ObservedObject`. The `@Observable` macro is **not used anywhere**
  (47 `@Published`, 0 `@Observable`). Do not introduce it.
- Concurrency: `ScanEngine`, `CleaningEngine` and `BinaryThinner` are actors with plain
  synchronous methods. Actor isolation is the safety, so there are no `async func`
  declarations on them. Call sites use `Task { }` and `await`. Heavy work uses
  `Task.detached(priority:)` and returns through
  `await MainActor.run { [weak self] in }`. Two legacy completion-handler APIs remain,
  in `AppPathFinder.swift` and `AppState.swift`.
- Errors: typed `enum: LocalizedError` with `errorDescription`. Most failure paths
  return an optional or collect messages into an `errors: [String]` array instead of
  throwing. Only 3 `throws` sites exist in the tree.
- Logging: `Logger.shared.log(_:level:)`, which wraps `os.Logger`. 16 stray `print()`
  calls exist. Do not add more.
- Motion: every animation is gated on `@Environment(\.accessibilityReduceMotion)` and
  written as `.animation(reduceMotion ? nil : MotionTokens.snappy, value: x)`.
  New animations must follow this.

## 6. Safety rules

These are not style preferences. Breaking one can destroy user data.

1. **Trash, never delete.** Removal goes through `FileManager.trashItem`. Never `rm`.
   Do not add ad hoc `FileManager.removeItem` calls.
2. **Route destructive work through `CleaningEngine`.** It is symlink-resistant, does
   TOCTOU-safe re-resolution, and is allow-list gated. Do not build a second delete path.
3. **Respect `OrphanSafetyPolicy.allowedRoots`.** Every orphan removal is gated by this
   allow-list. Widening it needs a strong, stated reason.
4. **The app is not sandboxed.** `PureMac.entitlements` sets
   `com.apple.security.app-sandbox` to `false`. It needs this to work. Do not enable
   the sandbox.
5. **Full Disk Access is load-bearing.** Without it the app misses most of what it
   should find. `FullDiskAccessManager` probes with real reads (`FileHandle` / `Data`),
   not `FileManager.isReadableFile` or `fileExists`. Metadata-only calls do not trigger
   TCC, and macOS then never lists the app in the Full Disk Access pane. Do not
   "optimise" that probe into a metadata check.
6. **Destructive UI actions always sit behind `.confirmationDialog` or `.alert`.**
   No exceptions.
7. `Info.plist` declares an `NSServices` entry (`NSMessage` `uninstallApp`). It powers
   the Finder right-click "Uninstall with PureMac". Do not remove it by accident.

## 7. Common tasks

### Add a cleaning category

1. Add the case to `CleaningCategory` in `Models/Models.swift`.
2. Add its search paths to `Logic/Scanning/Locations.swift`. Add per-app exceptions to
   `Logic/Scanning/Conditions.swift` if the category needs them.
3. Wire discovery into `Services/ScanEngine.swift`.
4. Confirm removal goes through `Services/CleaningEngine.swift` and, for orphan-style
   paths, that the roots are inside `OrphanSafetyPolicy.allowedRoots`.
5. Surface it in `ViewModels/AppState.swift` and the relevant view.
6. Add the display name and any count strings to **all 11** `Localizable.strings` files.
7. Run the tests. Run the app and confirm the destructive action shows a confirmation.

### Add a user-facing string

1. Add the key and English value to `PureMac/en.lproj/Localizable.strings`.
2. Add the same key to the other 10 `.lproj/Localizable.strings` files. Translate, or
   fall back to the English value. The key must exist in all 11.
3. Keep format specifiers identical across all 11. Use `%lld` with `Int64(n)`.
4. Use it with the right pattern from section 3.
5. Run `xcodebuild test -project PureMac.xcodeproj -scheme PureMac`.

### Add a view

1. Put the file in `Views/`, or in `Apps/`, `Components/`, `Orphans/` or `Settings/`
   if it belongs to one of those areas.
2. No header comment block. Start with `import SwiftUI`.
3. Read shared state with `@EnvironmentObject var appState: AppState`. Do not create a
   second store.
4. Use `AppTheme` pieces (CardSurface, IconTile, Tint, EmptyStateView) instead of new
   one-off styling.
5. Gate every animation on `@Environment(\.accessibilityReduceMotion)`.
6. Add all its strings to the 11 `Localizable.strings` files.
7. `xcodegen generate` picks the new file up automatically. There is no project file
   to edit.

## 8. Contributing and release

- Fork, clone, `brew install xcodegen`, `xcodegen generate`, `open PureMac.xcodeproj`.
- One focused change per PR. Test on macOS 13.0 at minimum. Update `README.md` if
  user-facing behaviour changes.
- Issue titles are prefixed `[Bug]` (label `bug`) or `[Feature]` (label `enhancement`).
- The PR template asks for: what the PR does, type of change, tested-on checkboxes for
  Ventura 13.x / Sonoma 14.x / Sequoia 15.x, and screenshots.
- There is no documented commit message convention. Observed style in automation is a
  lowercase scope prefix and a colon, for example `homebrew: bump to 2.9.7`.

Release: bump `MARKETING_VERSION` in `project.yml`, then push a matching tag
`v*.*.*`. `.github/workflows/release.yml` archives, signs with Developer ID, builds a
DMG, notarizes, staples, writes checksums, publishes the GitHub release, and bumps both
`homebrew/puremac.rb` and the external `momenbasel/homebrew-tap`. It needs 6 secrets,
documented in `scripts/SECRETS.md`. A fork cannot run this without its own Apple
Developer ID. Local fallback:

```bash
scripts/release-local.sh <version> [notary_profile]
```
