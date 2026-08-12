# VS Code Extension Related-Files Cleanup — Design

**Date:** 2026-08-12  
**Status:** Approved  
**Parent:** `2026-08-12-vscode-extensions-cleanup-design.md`  
**Approach:** A — Apps-like list → related-files detail

## Goal

Change VS Code Extensions from a flat cleanable-item list into an Apps-style flow: pick an extension, review related leftovers (install dir + storage/cache), then delete selected paths.

## UX

1. **Extension list** (like `AppListView`): editor label, display name, install size; search; select row.
2. **Related files detail** (like `AppFilesView`): grouped paths, per-item selection, delete selected.
3. Smart Scan / category tile remains an **entry** showing install-dir total size only; related-file deletion requires the detail flow (no one-click wipe of storage).

### Groups

- Extension (install directory)
- Global Storage
- Workspace Storage
- VSIX Cache
- Home Personalization (`~/.{name|publisher|…}`, `~/.config/…`) — listed, **default unchecked**
- Other (only whitelist hits)

### Defaults

- Install / globalStorage / workspaceStorage id folder / CachedExtensionVSIXs: default selected when shown.
- Home personalization leftovers: **default not selected** (opt-in only).
- Do not list `extensions.json` / `.obsolete` as rows; after successful install-dir delete, best-effort rewrite those indexes.

## Discovery rules

### Installed extensions

Unchanged: `~/.*/extensions/{folder}` whose `package.json` has `engines.vscode`.

Identity: `publisher.name` → `extensionId`. Keep `editorDotDir` (e.g. `.cursor`) and install path.

### App Support mapping (`AppSupportResolver`)

From `~/.{dot}` under home, resolve zero or more directories under `~/Library/Application Support/`:

1. Case-insensitive exact match on `{dot}` without leading `.`
2. Hyphen/space insensitive match (`trae-cn` ↔ `Trae CN`)
3. Fixed aliases only: `vscode`→`Code`, `vscode-insiders`→`Code - Insiders`, `vscode-oss`→`VSCodium`
4. Multiple matches allowed (e.g. `.trae` → `Trae` + `Trae CN`); union and dedupe paths

### Leftovers (`VSCodeExtensionLeftoverFinder`)

For each resolved App Support root + extensionId:

| Group | Path rule |
|---|---|
| Extension | install directory itself |
| Global Storage | `{AS}/User/globalStorage/{extensionId}` (case-insensitive dir name) |
| Workspace Storage | `{AS}/User/workspaceStorage/*/{extensionId}` (child only) |
| VSIX Cache | `{AS}/CachedExtensionVSIXs/{extensionId}-*` |
| Home Personalization | Deterministic home hits only (see below) |

No fuzzy whole-disk search. No deleting entire `workspaceStorage/<hash>`.

### Home personalization (`VSCodeExtensionHomePathRules`)

For `publisher.name`, check existence of (case-insensitive on APFS):

- `~/.{name}`, `~/.config/{name}` — if `name` length ≥ 5 and not denylisted (python, docker, git, …)
- `~/.{publisher}`, `~/.config/{publisher}` — if `publisher` length ≥ 5 and not denylisted (microsoft, github, docker, …)
- `~/.{publisher}-{name}`, `~/.{publisher}_{name}`, `~/.{extensionId}`
- `~/.config/{publisher}-{name}`, `~/.config/{publisher}_{name}`, `~/.config/{extensionId with . → -}` (e.g. `github.copilot` → `github-copilot`)

Never list exact high-risk roots (`.ssh`, `.config`, `.docker`, `.vscode`, …).

## Safety

`CleaningEngine` accepts a path if:

- existing VS Code install-dir rule (`engines.vscode`), OR
- under `~/Library/Application Support/<Editor>/User/globalStorage/<extensionId>` (exact folder), OR
- under `.../workspaceStorage/<hash>/<extensionId>` (exact folder or inside it), OR
- under `.../CachedExtensionVSIXs/<extensionId>-*`, OR
- home personalization path associated via `VSCodeExtensionHomePathRules` for that `extensionId` (typed check; path-only CleaningEngine inference does not allow bare `~/.foo`)

Prefer validating via `VSCodeExtensionLeftoverFinder.isSafeRelatedPath` shared helper.

## Implementation touchpoints

- `Logic/Scanning/AppSupportResolver.swift`
- `Logic/Scanning/VSCodeExtensionLeftoverFinder.swift`
- Enrich `VSCodeExtensionItem` with `extensionId`, `editorDotDirectory`, optional version
- `Views/Extensions/ExtensionListView.swift` (+ files detail, can mirror AppFiles grouping)
- `AppState`: load extensions, select, scan leftovers, remove selected
- `MainWindow`: `.cleaning(.vsCodeExtensions)` → `ExtensionListView`
- `ScanEngine.scanVSCodeExtensions`: keep install-only totals for Smart Scan card
- Localizations + README note

## Tests

- Resolver aliases and hyphen matching
- LeftoverFinder fixture finds all four kinds; ignores other extensionIds
- Safety rejects workspace hash root; accepts id child
- Scanner still skips non-`engines.vscode` folders

## Non-goals (v1)

- Extension-specific external caches (cpptools ipch, etc.)
- Editing `settings.json` / sync state
- Calling `code --uninstall-extension`
EOF
