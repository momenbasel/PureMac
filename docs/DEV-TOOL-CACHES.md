# Dev Tool Caches

> GUI category "Dev Tool Caches" (`CleaningCategory.devToolCaches`): download, package and build caches of developer tools, one row per cache root. Code: `PureMac/Logic/Utilities/DevToolCaches.swift` (`DevToolCaches`, `DevToolCacheEnvironment`), `PureMac/Services/ScanEngine.swift` (`scanDevToolCaches`), `PureMac/Services/CleaningEngine.swift` (`cleanDevToolCache`). Tests: `PureMacTests/DevToolCachesTests.swift`.

## Contents
- [What it finds](#what-it-finds)
- [How it decides](#how-it-decides)
- [How it removes](#how-it-removes)
- [Safety invariants](#safety-invariants)
- [Failure modes and logs](#failure-modes-and-logs)
- [Testing](#testing)
- [Related](#related)

## What it finds

`DevToolCaches.roots` is the only list. It mirrors the "Dev Tools" targets of `cli/Sources/puremac/Core/Catalog.swift` (`Catalog.dev`): same paths, same `selectedByDefault`. A row appears only when the directory exists, is not behind a symlink, and holds data (size > 0). Paths are relative to `$HOME`. No environment variable (`CARGO_HOME`, `GOCACHE`, `UV_CACHE_DIR`, `GRADLE_USER_HOME`, ...) is read to find roots; only the default locations are listed.

| Tool | Paths | Removal method | Default | Notes |
|---|---|---|---|---|
| Bun | `.bun/install/cache` | unlink | selected | `~/.bun/bin` is not touched. |
| uv | `.cache/uv`, `Library/Caches/uv` | `uv cache clean --cache-dir <root>`; unlink if `uv` is not installed | selected | Never `--force`. uv waits for a lock held by another uv process; a run that exceeds the timeout is reported as busy and skipped. |
| pip | `Library/Caches/pip`, `.cache/pip` | unlink | selected | Moved here from "User Cache" so it is not listed twice. |
| Poetry | `Library/Caches/pypoetry`, `.cache/pypoetry` | unlink | selected | |
| CocoaPods | `Library/Caches/CocoaPods` | unlink | selected | `~/.cocoapods` (spec repos) is not touched. |
| Swift Package Manager | `Library/Caches/org.swift.swiftpm` | unlink | selected | |
| Gradle | `.gradle/caches`, `.gradle/wrapper/dists` | unlink, refused while Gradle runs | selected (unselected while Gradle runs) | CLI also lists `.gradle/daemon` (logs and daemon registry); the GUI does not. `gradle.properties` is never touched. |
| Cargo | `.cargo/registry/cache`, `.cargo/registry/index`, `.cargo/git/db`, `.cargo/git/checkouts` | unlink | selected | Exactly these four. `~/.cargo/bin`, `config.toml`, `credentials.toml` and `registry/src` are not touched. |
| Go build cache | `Library/Caches/go-build` | `go clean -cache`; unlink if `go` is not installed | selected | |
| Go module cache | `go/pkg/mod` | `go clean -modcache` only | selected | Listed only when `go` is found. **Deliberate deviation from the CLI**, which lists the subset `go/pkg/mod/cache`: `go clean -modcache` removes all of `go/pkg/mod`, so the GUI row and its size cover exactly what is removed. Module files are read-only, so plain removal is never attempted. |
| Deno | `Library/Caches/deno`, `.cache/deno` | unlink | selected | |
| Dart pub | `.pub-cache/hosted`, `.pub-cache/git` | unlink | selected | The CLI lists all of `.pub-cache`; `bin/` and `global_packages/` hold `dart pub global activate` tools and are excluded. |
| Playwright | `Library/Caches/ms-playwright`, `.cache/ms-playwright` | unlink | selected | Browser downloads, re-fetched by `playwright install`. |
| Puppeteer | `.cache/puppeteer` | unlink | selected | |
| node-gyp | `Library/Caches/node-gyp`, `.cache/node-gyp` | unlink | selected | |
| Electron | `Library/Caches/electron`, `Library/Caches/electron-builder` | unlink | selected | |
| Maven | `.m2/repository` | unlink | **not selected** | Can hold artifacts installed locally with `mvn install` that cannot be downloaded again. |
| NuGet | `.nuget/packages`, `.local/share/NuGet/http-cache` | unlink | **not selected** | Can hold locally built packages. |

Not in this category: `node_modules` and Rust `target/` (project artifacts), Homebrew ("Brew Cache"), npm, Yarn and pnpm ("Node Cache"), Docker, Xcode, Hugging Face (`.cache/huggingface`), Ollama, `~/.claude`.

Row names are localization keys (`DevToolCaches.Root.nameKey`). Several rows can share a name when a tool has two locations (uv, pip, Poetry, Deno, Playwright, node-gyp, NuGet).

## How it decides

| Row state | Condition | Selectable / preselected |
|---|---|---|
| Normal row | Root exists, is a directory, no symlink between `$HOME` and the root, size > 0 | Selectable. Preselected unless the root is opt-in (Maven, NuGet). |
| Gradle row while Gradle runs | `ps -axo command=` shows `GradleDaemon`, `GradleWrapperMain`, `GradleWorkerMain` or `org.gradle.launcher.GradleMain`, or `ps` could not be read | Selectable, not preselected, name gets the suffix "(Gradle is running)". |
| Go module cache without `go` | `go` not found in `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/local/go/bin`, `~/.local/bin`, `~/.cargo/bin` | Row is not listed. |
| Symlinked root | `$HOME/<root>` or any directory between is a symlink (`lstat`) | Row is not listed; logged as a warning. |

Smart Scan and scheduled cleaning include the category: every row except Maven/NuGet is regenerable by the tool, as for "Node Cache". Opt-in rows are never preselected, so unattended cleaning leaves them alone.

Opt-in rows (`Root.selectedByDefault == false`) carry `CleanableItem.selectOnlyByHand = true`. Only a per-row toggle (`AppState.toggleItem`, the row checkbox) selects them. "Select all" (`AppState.selectAllInCategory`), the Overview category checkbox (`AppState.categoryBinding`) and "Select visible" (`AppState.setSelection`, `CategoryDetailView`) skip them; "Clear selection" and "Deselect visible" still deselect them.

The roots are excluded from the "User Cache" scan (`ScanEngine.scanUserCache`), so no path is counted in two categories.

## How it removes

`CleaningEngine.cleanItems` sends every `.devToolCaches` item to `cleanDevToolCache`. It does not use the generic unlink path and never uses the administrator pass.

1. The item path must equal a `DevToolCaches.roots` path exactly (`DevToolCaches.root(forPath:home:)`); otherwise the item is refused.
2. No symlink between `$HOME` and the root, the resolved path equals the path, and the path passes the delete allowlist (`CleaningEngine.allowedDeletionRoots`).
3. Missing root: counted as handled, nothing removed.
4. By `Removal`:
   - `unlink`: `FileManager.removeItem` on the root directory after a second symlink check.
   - `unlinkUnlessGradleRunning`: `DevToolCacheEnvironment.isGradleRunning()` is checked at clean time; if true the item is skipped with the message "a Gradle daemon or build is running. Run `gradle --stop`, then clean again."
   - `uvCacheClean`: `uv cache clean --cache-dir <root>`, started only after the root passes `isUnchangedDevToolRoot` again. Exit 0 counts as cleaned. No exit within `commandTimeout` (300 s; uv waits for a lock held by another uv process) is reported as busy and skipped. Any non-zero exit is an error. The local dialog shows up to 300 characters of stderr. `--force` is never passed. Without `uv`, the root is unlinked.
   - `goCleanCache`: `go env GOCACHE`, then `go clean -cache`. Without `go`, the root is unlinked.
   - `goCleanModcache`: `go env GOMODCACHE`, then `go clean -modcache`. Without `go`, the item is skipped and nothing is touched.
   - For both Go rows the value printed by `go env` must be absolute and, after `resolvingSymlinksInPath`, equal the row path; otherwise the item is skipped and the path is reported (exported variable, `go env -w`). The root is checked again with `isUnchangedDevToolRoot` after `go env` returns and immediately before `go clean`.
5. A skipped item stays in the list, its reason is shown in the "Couldn't clean everything" alert, and it does not trigger the Full Disk Access prompt (`CleaningResult.skippedPaths`, `AppState.survivingItems`).

Freed space is the scan-time size of each cleaned row.

Never touched: anything outside the listed roots, including siblings and parents (`~/.cargo`, `~/.gradle`, `~/.m2`, `~/go`, `~/.bun`, `~/.pub-cache`, `~/.nuget`, `~/.local`).

## Safety invariants

1. Only exact roots are removable. `DevToolCaches.root(forPath:home:)` rejects parents, descendants, relative paths, `..` and control characters. Test: `testRootLookupIsExactMatchOnly`, `testCleanRefusesPathsThatAreNotExactRoots`.
2. The delete allowlist gains exact roots only, derived from the same list: `CleaningEngine.allowedDeletionRoots` → `DevToolCaches.absolutePaths`. Broad parents are not allow-listed. Test: `testEveryRootIsInsideAnAllowlistedRoot`, `testAllowlistGainsExactRootsNotBroadParents`.
3. No root equals, contains, or sits inside `~/.claude`, `~/.ollama`, `~/.cache/huggingface`, `~/.ssh`, `~/.cargo/bin`, `~/.cargo/config.toml`, `~/.gradle/gradle.properties` and similar. `~/.m2/repository` is a root only as an unselected row. Test: `testNoRootEqualsContainsOrSitsInsideProtectedLocations`, `testMavenRepositoryAppearsOnlyAsAnUnselectedRow`.
4. Symlinked roots and symlinked ancestors are refused at scan and at clean: `DevToolCaches.hasSymlinkBelowHome` (`lstat`, never follows). `CleaningEngine.isUnchangedDevToolRoot` (no symlink on the way and `resolvingSymlinksInPath` equals the path) runs at the start of the clean, right before `uv cache clean`, right before `go clean`, and right before the unlink (`unlinkDevToolCache`). Test: `testScanRefusesSymlinkedRoots`, `testCleanRefusesSymlinkedRootAndKeepsTarget`, `testUVCleanIsNotStartedOnASymlinkedRoot`, `testGoCleanAbortsWhenTheRootBecomesASymlinkDuringGoEnv`, `testPlainUnlinkIsRefusedWhenTheRootBecomesASymlinkAfterTheFirstChecks` (uses the `DevToolCacheEnvironment.beforeUnlinkRecheck` test seam).
   Residual race: plain removal uses `FileManager.removeItem` after the check above. `renameatx_np` with `RENAME_NOFOLLOW_ANY` would close the window, but the macOS SDK header (`sys/stdio.h`) declares the flag with no availability annotation (only `renameatx_np` itself is marked 10.12), so it cannot be shown to exist on the macOS 13 deployment target and is not used. A process running as the same user can still replace a root with a symlink between the last check and the unlink. The tools (`uv`, `go`) have the same window between the check and their own start. Nothing outside the user's own files is exposed by this, since a same-user process can already delete them.
5. Opt-in roots (Maven, NuGet) are never preselected and cannot be selected in bulk: `CleanableItem.selectOnlyByHand`, honored by `AppState.selectAllInCategory`, `AppState.setSelection` and `CategoryDetailView`'s "Select visible". Test: `testMavenAndNuGetAreOptInAndEverythingElseIsPreselected`, `testScanFindsEveryPresentRootWithCatalogSelection`, `DevToolCacheSelectionTests` (`testSelectAllInCategorySkipsOptInRows`, `testCategoryCheckboxBindingSkipsOptInRows`, `testSelectVisibleSkipsOptInRows`, `testOnlyAPerRowToggleSelectsAnOptInRow`).
6. uv is cleaned through uv, pinned to the row with `--cache-dir`, never forced. Only a timeout counts as busy; stderr is never pattern-matched, so a real failure is never hidden as "locked". Test: `testUVCleanUsesUVWithExplicitCacheDirAndNeverForce`, `testUVStderrMentioningLockIsARealErrorNotABusySkip`, `testUVCleanThatWaitsForTheLockPastTheTimeoutIsReportedAsBusy`, `testUVCleanFailureOtherThanLockIsAnErrorNotASkip`.
7. `go clean` runs only when `go` reports, in canonical form, the row's directory as its cache. Module cache is never unlinked. Test: `testGoCleanUsesGoCleanForBuildAndModuleCaches`, `testGoCleanRefusesWhenGoUsesADifferentCacheDirectory`, `testGoEnvValueIsComparedInCanonicalForm`, `testGoEnvValueThatIsASymlinkToAnotherDirectoryIsRefused`, `testGoModuleCacheIsLeftAloneWithoutGo`.
8. Gradle caches are not removed while a Gradle process runs; an unreadable process list counts as running. Test: `testGradleCleanSkippedWhileDaemonRuns`, `testUnreadableProcessListCountsAsGradleRunning`, `testScanFlagsGradleRowsWhileGradleRuns`.
9. Cargo: only the four registry/git roots. Test: `testPlainCleanRemovesOnlyTheRootAndKeepsSiblings`, `testScanDoesNotListCargoBinOrConfig`.
10. The generic and administrator routes reject developer cache paths, even if a caller labels them as a different category. Test: `testAdminPassRefusesDevToolCaches`.
11. No path is listed twice across categories: `ScanEngine.scanUserCache` excludes `DevToolCaches.absolutePaths`. Test: `testUserCacheNoLongerDoublesUpOnDevToolRoots`.

## Failure modes and logs

PureMac writes diagnostics to the macOS unified log (subsystem `com.puremac.app`, category `general`). For unsuccessful uv or Go runs, the log records the exit status.

| Symptom | Cause | Where to look |
|---|---|---|
| Row missing | Directory absent, empty, symlinked, or `go` not found (Go module cache) | Log: `Dev tool caches: refusing symlinked cache root <path>`, `Dev tool caches: go not found; not listing the Go module cache` |
| Alert: "uv did not finish in time; the cache may be locked by another uv process" | `uv cache clean` was still waiting (usually for the lock of another uv process) after 300 s | Log: `uv cache clean timed out; treating the cache as busy` |
| Alert: "a Gradle daemon or build is running" | `ps` shows a Gradle process | Run `gradle --stop` (or quit the IDE build), clean again. Log: `Skipped <name>: a Gradle daemon or build is running` |
| Alert: "go uses <dir>, not <path>" | `GOCACHE`/`GOMODCACHE` points elsewhere | Log: `Skipped <name>: go uses ...` |
| Alert: "`go` was not found, so the module cache was left untouched" | Go module cache row selected without `go` installed | Install Go or remove the directory yourself |
| Alert: "Skipped symlink or unsafe path" | Path is not an exact root, or a symlink appeared after the scan | Log: `Skipped symlink or unsafe path`, `Unsupported developer tool cache path` |
| Alert: "<name> at <path>: ..." | `removeItem` failed (permissions, file in use) | Log: `Clean failed:` |
| Alert: "uv cache clean failed (exit N): <stderr>" | uv exited non-zero (permissions, I/O error, ...). The row stays in the list and can raise the Full Disk Access prompt | Log: `uv cache clean exited N` |
| Alert: "Aborting uv cache clean" / "Aborting go clean: path resolution changed" | The root, or a directory above it, became a symlink after the scan | Log with the same text; inspect the path with `ls -ld` |

## Testing

```
xcodegen generate
xcodebuild test -project PureMac.xcodeproj -scheme PureMac -destination 'platform=macOS' \
  -derivedDataPath "$TMPDIR/dev-tool-caches-dd" CODE_SIGNING_ALLOWED=NO \
  -only-testing:PureMacTests/DevToolCachesTests
```

Tests build a temporary home under `FileManager.default.temporaryDirectory`, create each cache with a payload file, and inject `DevToolCacheEnvironment(searchDirectories:processCommandLines:commandTimeout:)`. `uv` and `go` are fake shell scripts in a temp `bin` directory that log their arguments; the process list is a closure. No real tool, process list or user directory is read. `LocalizationFilesTests` checks the strings in all 13 `Localizable.strings` files.

Manual run against a fake home (create the cache directories first, for example `mkdir -p <home>/.bun/install/cache && head -c 1000000 /dev/zero > <home>/.bun/install/cache/x`):

```
CFFIXED_USER_HOME=<fixture-home> <DerivedData>/Build/Products/Debug/PureMac.app/Contents/MacOS/PureMac
```

## Related

- [Node Cache and Brew Cache scanners](../PureMac/Services/ScanEngine.swift) (`scanNodeCache`, `scanBrewCache`)
- CLI catalog this list mirrors: [`cli/Sources/puremac/Core/Catalog.swift`](../cli/Sources/puremac/Core/Catalog.swift), CLI guard rules: [`cli/Sources/puremac/Core/Safety.swift`](../cli/Sources/puremac/Core/Safety.swift)
- [Delete allowlist and clean flow](../PureMac/Services/CleaningEngine.swift) (`allowedDeletionRoots`, `cleanItems`)
- [Apple features research](APPLE-FEATURES.md)
