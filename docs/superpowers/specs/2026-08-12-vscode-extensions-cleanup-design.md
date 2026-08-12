# VS Code–Family Extensions Cleanup — Design

**Date:** 2026-08-12  
**Status:** Approved for implementation planning  
**Approach:** New `CleaningCategory` (Developer section), list installed extensions for user review

## Goal

Add a PureMac Smart Scan / Developer cleanup category that lists installed VS Code–family editor extensions so the user can selectively move chosen extension folders to Trash.

## Non-goals (v1)

- JetBrains / Sublime / other non–VS Code–family plugins
- Auto-discovery of unknown VS Code forks under Application Support
- Legacy `~/Library/Application Support/<Editor>/extensions` paths
- Detecting disabled extensions or calling `code --uninstall-extension`
- Collapsing multiple versions of the same extension into one row
- Blocking delete while the editor is running

## Product decisions

| Decision | Choice |
|---|---|
| Scope | VS Code, VS Code Insiders, Cursor, VSCodium, Windsurf only |
| Behavior | List installed extensions; user selects; default **unselected** |
| Placement | New category in Developer cleanup + Smart Scan |
| Delete | `FileManager.trashItem` via existing `CleaningEngine` |
| Paths | Home-dir `~/.{vscode,vscode-insiders,vscode-oss,cursor,windsurf}/extensions` |

## Architecture

Follow the existing cleaning-category pattern (same shape as Xcode / Docker):

1. `CleaningCategory.vsCodeExtensions` in `Models.swift`
2. `ScanEngine.scanVSCodeExtensions()` (optionally extract helpers into `Logic/Scanning/VSCodeExtensionScanner.swift`)
3. Extend `CleaningEngine.isSafeToDelete` allow-list with the five `…/extensions` roots
4. Wire UI lists: `DashboardView.developerCleanupCategories`, `MainWindow.advancedCategories`
5. Localize display name / description (at least `en` + `zh-Hans`)
6. Document in README / Chinese README sibling if present

```text
Smart Scan / category tap
        │
        ▼
ScanEngine.scanVSCodeExtensions()
        │  enumerate roots → child dirs → package.json + size
        ▼
CategoryResult / CleanableItem[]  (isSelected = false)
        │
        ▼
CategoryDetailView (reuse) → user selects
        │
        ▼
CleaningEngine.cleanItems → trashItem (allow-listed paths only)
```

## Scan roots

**No hardcoded editor list.** At scan time, PureMac enumerates `~/.*` directories and looks for an `extensions/` child. An extension folder is included only when its `package.json` declares `engines.vscode`.

Delete safety uses the same rule: path must be `~/.{editor}/extensions/{ext}/…` and that `{ext}/package.json` must declare `engines.vscode`. The entire `extensions/` directory itself is not deletable.

Editor label is derived from the dot-directory name (e.g. `.trae-cn` → `Trae Cn`).

## Item rules

For each **immediate child directory** under a root:

1. Skip any immediate child whose name starts with `.` (e.g. `.obsolete`)
2. Require a readable `package.json`; if missing or unreadable, **skip** the directory (no Unknown rows in v1)
3. Parse `displayName` (fallback: folder name), optional `publisher` / `version`
4. `CleanableItem.name`: `"{Editor} · {displayName}"` (e.g. `Cursor · Better Comments`)
5. `path`: absolute path to that extension directory
6. `size`: recursive directory size (same helper style as other scanners)
7. `isSelected`: `false`
8. Sort items by size descending within the category result

Do not emit the extensions root itself as a single wipe item.

## Safety

`CleaningEngine.isSafeToDelete` must allow only paths that are **equal to or strictly inside** one of:

- `~/…/.vscode/extensions`
- `~/…/.vscode-insiders/extensions`
- `~/…/.vscode-oss/extensions`
- `~/…/.cursor/extensions`
- `~/…/.windsurf/extensions`

Must **refuse**:

- `~/.vscode`, `~/.cursor`, etc. (editor home roots)
- Settings, argv, CLI shims, anything outside the five extensions roots
- Existing provider-owned / cloud paths (reuse current checks)

Trailing-`/` prefix matching must follow the same sibling-safe pattern already used for `/tmp` vs `/tmpfoo`.

Copy in category description / README: suggest quitting the matching editor before cleaning.

## UI / copy

- English raw value / title: `VS Code Extensions`
- Description: installed VS Code–family extensions; review before removing
- Icon: `puzzlepiece.extension` (macOS 13+)
- Color: `.brown` (unused by active Developer categories)
- Sidebar: include in `MainWindow.advancedCategories`
- Dashboard: include in `developerCleanupCategories`
- Localizations: `en.lproj` + `zh-Hans.lproj` minimum; other locales can fall back or get a short string in the same PR if cheap

## Testing

TDD with temp-directory fixtures (no user home absolute paths in tests):

1. Scanner finds extensions under a fake root with `package.json` → correct name/path/size; `isSelected == false`
2. Skips directories without `package.json` and hidden dirs
3. Missing root → empty contribution (no crash)
4. `isSafeToDelete`: child under allow-listed extensions root → true; editor home root / settings path → false

## README

Add one bullet under System Cleaner / Smart Scan developer categories documenting VS Code–family extension review cleanup.

## Implementation notes

- Prefer a small `VSCodeExtensionScanner` type for path table + `package.json` parsing so unit tests do not need the full `ScanEngine` graph.
- CLI (`CleaningCategory.scannable`) picks up the new case automatically once it is not in `appModifying`.
- No change to orphan finder or uninstall `AppCondition` paths in v1.

## Approval record

- Scope: VS Code family only (option 1)
- Behavior: list + user select (option 2)
- Editors: fixed set of five (option 1)
- Approach: new cleaning category A
- Design sections 1–3: approved 2026-08-12
