# AGENTS.md

Contract for any coding agent working in this repository. PureMac is a native SwiftUI
macOS cleaner app, MIT licensed. It removes files from a real person's Mac. Work
accordingly.

## Before you touch anything

- [ ] Read this file to the end. Then read `CONTRIBUTING.md`.
- [ ] Know that `PureMac.xcodeproj` is **generated**. `project.yml` is the source of truth.
- [ ] Have XcodeGen installed: `brew install xcodegen`.
- [ ] Run `xcodegen generate` once, and again after every `git pull` or `project.yml` edit.
- [ ] If `xcode-select` points at CommandLineTools, export the full Xcode path before any
      `xcodebuild` call:
      `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`
- [ ] Know the localization rule: 11 `Localizable.strings` files must hold exactly the
      same keys. One new English string means 11 file edits.
- [ ] Know that CI runs the build only. It does **not** run the tests. Green CI does not
      mean the change is correct.
- [ ] Scope your change to one thing. This project takes one focused change per PR.

## Build and verify loop

Setup:

```bash
brew install xcodegen
xcodegen generate
```

Build exactly as CI does. This build is the only required check for merge:

```bash
xcodebuild -project PureMac.xcodeproj -scheme PureMac -configuration Release -derivedDataPath build build ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

Test, because CI will not:

```bash
xcodebuild test -project PureMac.xcodeproj -scheme PureMac
```

Tests are XCTest, not Swift Testing. 4 files, 19 test functions, in `PureMacTests/`:
`AppLanguagePreferencesTests.swift`, `AppStateTests.swift`, `LocalizationFilesTests.swift`,
`SimulatorRuntimeSupportTests.swift`.

There is no linter and no formatter in this repo. No SwiftLint, no SwiftFormat. Match the
surrounding code by reading it.

Facts you may need:

| Item | Value |
| --- | --- |
| Deployment target | macOS 13.0 |
| Swift | 5.9 |
| xcodeVersion | 16.4 |
| Architectures | arm64 + x86_64 |
| Bundle id | `com.puremac.app` |
| Targets | `PureMac`, `PureMacTests` |
| Scheme | `PureMac` |
| Dependency | Sparkle (SPM, from 2.0.0). First build needs network. |
| CI | `.github/workflows/build.yml`, macos-15, push to main and PRs to main |

`DEVELOPMENT_TEAM` is hardcoded to `H3WXHVTP97` in `project.yml`. Do not commit a change
to it. Local builds should rely on the Debug config, which sets `CODE_SIGNING_ALLOWED`
to `NO`.

## Hard rules

### 1. Never edit `PureMac.xcodeproj`

It is generated from `project.yml` by XcodeGen. Any hand edit is lost on the next
`xcodegen generate` and will confuse everyone. Change `project.yml`, then regenerate.
New source files need no project edit at all. XcodeGen picks them up.

### 2. Never break localization parity

11 languages, classic `Localizable.strings` (not `.xcstrings`):
`ar`, `en`, `es`, `fr`, `ja`, `pl`, `pt-BR`, `ru`, `uk`, `zh-Hans`, `zh-Hant`.

`PureMacTests/LocalizationFilesTests.swift` fails on:

- a key missing from any of the 11 files
- an **extra** key present in one file and not the others
- a format-specifier mismatch between languages
- a duplicate key inside one file

Add a string, add it to all 11. Remove a string, remove it from all 11. Use `%lld` with
an explicit `Int64` cast, never `%d`.

Three lookup patterns are in use:

- bare string literal passed to `Text` / `Button` / `Label` / `.help` / `.searchable`
- `Text(LocalizedStringKey(runtimeString))` for enum `rawValue` and other runtime strings
- `String(format: String(localized: "...%lld..."), Int64(n))` for interpolation

CI does not run tests, so broken localization can pass CI. Run the test target yourself.

### 3. Never bypass `CleaningEngine`

All destructive work goes through `Services/CleaningEngine.swift`. It is
symlink-resistant, does TOCTOU-safe re-resolution, and is gated by an allow-list.
Orphan removal is additionally gated by `OrphanSafetyPolicy.allowedRoots` in
`Logic/Utilities/OrphanSafetyPolicy.swift`. Do not create a second delete path anywhere.

### 4. Never add `rm`, and never add ad hoc removal

Files move to the Trash with `FileManager.trashItem`. No `rm`. No shell-out deletes.
No new `FileManager.removeItem` calls.

### 5. Other safety constraints

- The app is **not sandboxed**. `PureMac.entitlements` sets
  `com.apple.security.app-sandbox` to `false`. It needs this to work. Do not enable the
  sandbox.
- Full Disk Access is load-bearing. Without it the app misses most of what it should
  find. `FullDiskAccessManager` probes with real reads (`FileHandle` / `Data`), not
  `FileManager.isReadableFile` or `fileExists`. Metadata-only calls do not trigger TCC,
  and macOS then never lists the app in the Full Disk Access pane. Do not convert that
  probe to a metadata check.
- Every destructive UI action sits behind `.confirmationDialog` or `.alert`. Keep it that
  way.
- `Info.plist` declares an `NSServices` entry (`NSMessage` `uninstallApp`) that powers the
  Finder right-click "Uninstall with PureMac". Do not drop it.

## Where code goes

| Directory | Role |
| --- | --- |
| `Core/` | App-wide constants. `AppConstants.swift`. |
| `Models/` | Pure value types, no logic. `Models.swift`, `ScanError.swift`, `AppLanguage.swift`. |
| `Logic/Scanning/` | Stateless discovery. `AppPathFinder.swift` (10-level leftover matching), `Locations.swift` (120+ search paths), `Conditions.swift` (25 per-app rules), `AppInfoFetcher.swift`, `UniversalBinaryScanner.swift`, `LanguageFilesScanner.swift`. |
| `Logic/Utilities/` | `Logger.swift`, `FileSize.swift`, `OrphanSafetyPolicy.swift`, `FileProtection.swift`, `CLI.swift`, `SimulatorRuntimeSupport.swift`. |
| `Services/` | Engines. `ScanEngine`, `CleaningEngine`, `BinaryThinner` are actors. `PermissionCoordinator`, `SchedulerService`, `SystemMonitor`, `MenuBarController`, `UpdateService`, `FullDiskAccessManager` are `@MainActor` ObservableObjects. |
| `ViewModels/` | `AppState.swift` only. `@MainActor final class AppState: ObservableObject`, about 1128 lines, 15 MARK sections. The single store for the app. |
| `Views/` | SwiftUI screens, with `Apps/`, `Components/`, `Orphans/`, `Settings/`. `Views/Components/AppTheme.swift` is the design system. |
| `Extensions/` | `Theme.swift`, one View modifier. |

## Style to match

- 4 spaces, no tabs.
- Types default to `internal` with no explicit modifier. Everything else is `private`
  (573 `private` against 5 explicit `internal`).
- `// MARK: - Title` with the dash, in files over roughly 60 lines.
- **No header comment block on new files.** Start with `import SwiftUI` or
  `import Foundation`. Some older files carry an Xcode template header. Do not copy it.
- Comments explain why, and often cite an issue number such as `(#114)`.
- State is classic Combine: `ObservableObject`, `@Published`, `@EnvironmentObject`,
  `@ObservedObject`. The `@Observable` macro is used nowhere (47 `@Published`,
  0 `@Observable`). Do not introduce it.
- Concurrency: the three engine actors expose plain synchronous methods. Actor isolation
  is the safety, so no `async func` declarations. Call sites use `Task { }` and `await`.
  Heavy work uses `Task.detached(priority:)` and comes back through
  `await MainActor.run { [weak self] in }`. Two legacy completion-handler APIs remain, in
  `AppPathFinder.swift` and `AppState.swift`.
- Errors: typed `enum: LocalizedError` with `errorDescription`. Most failure paths return
  an optional or append to an `errors: [String]` array instead of throwing. Only 3
  `throws` sites exist.
- Logging: `Logger.shared.log(_:level:)` over `os.Logger`. 16 stray `print()` calls exist.
  Add none.
- Motion: gate every animation on `@Environment(\.accessibilityReduceMotion)`, written
  `.animation(reduceMotion ? nil : MotionTokens.snappy, value: x)`.

## Definition of done

Do not report a change as finished until all of these are true.

- [ ] `xcodegen generate` runs clean, and `PureMac.xcodeproj` was not hand-edited.
- [ ] The CI build command above completes with no errors and no new warnings.
- [ ] `xcodebuild test -project PureMac.xcodeproj -scheme PureMac` passes locally.
- [ ] Every added or removed string key is present in, or absent from, **all 11**
      `Localizable.strings` files, with matching format specifiers.
- [ ] No new `print()` calls. Logging goes through `Logger.shared.log(_:level:)`.
- [ ] Every new animation respects `@Environment(\.accessibilityReduceMotion)`.
- [ ] No new delete path. Nothing bypasses `CleaningEngine` or
      `OrphanSafetyPolicy.allowedRoots`. No `rm`, no new `FileManager.removeItem`.
- [ ] Every new destructive action is behind `.confirmationDialog` or `.alert`.
- [ ] **No em-dashes** in code, comments, strings, commit messages or PR text. Use a plain
      hyphen or restructure the sentence.
- [ ] `README.md` is updated if user-facing behaviour changed.
- [ ] The change is one focused thing, and it builds on macOS 13.0 at minimum.

## PRs, issues, releases

- Fork, clone, `brew install xcodegen`, `xcodegen generate`, `open PureMac.xcodeproj`.
- One focused change per PR. Test on macOS 13.0 at minimum.
- Issue titles use the prefix `[Bug]` (label `bug`) or `[Feature]` (label `enhancement`).
- The PR template asks for: what the PR does, type of change, tested-on checkboxes for
  Ventura 13.x / Sonoma 14.x / Sequoia 15.x, and screenshots.
- No documented commit message convention. Observed style in automation is a lowercase
  scope prefix and a colon, for example `homebrew: bump to 2.9.7`.

Release is tag-driven. Bump `MARKETING_VERSION` in `project.yml`, then push a matching
`v*.*.*` tag. `.github/workflows/release.yml` archives, signs with Developer ID, builds
the DMG, notarizes, staples, writes checksums, publishes the GitHub release, and bumps
both `homebrew/puremac.rb` and the external `momenbasel/homebrew-tap`. It needs 6 secrets,
listed in `scripts/SECRETS.md`. A fork cannot run it without its own Apple Developer ID.
Local fallback:

```bash
scripts/release-local.sh <version> [notary_profile]
```
