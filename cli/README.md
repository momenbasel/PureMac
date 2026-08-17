# PureMac CLI

Clean developer caches, project artifacts, and disk clutter from the terminal. A
command-line companion to the [PureMac](https://github.com/momenbasel/PureMac) app
that reuses the same cleaning logic and safety rules.

PureMac scans first and removes only what you approve. Cache and junk removal is
permanent, but cloud state (iCloud, Dropbox, OneDrive) and your config dotfiles
(`~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.docker`, `~/.claude`, ...) are never touched.

![puremac showing a scan and the confirmation that lists exactly what will be deleted](screenshots/clean.png)

## Install

```bash
brew install momenbasel/tap/puremac-cli
```

Or build from source (requires a Swift 5.9+ toolchain):

```bash
cd cli
swift build -c release
.build/release/puremac --help
```

## Commands

| Command | What it does |
|---|---|
| `puremac clean` | Scan all categories (dev, junk, ai, trash), review, then remove |
| `puremac clean dev` | Package-manager and build-tool caches only |
| `puremac clean junk` | User logs and Xcode-generated junk only |
| `puremac clean ai` | AI-tool caches and logs only |
| `puremac clean trash` | Empty the user Trash and mounted-volume trashes |
| `puremac purge [path]` | Find removable build artifacts inside project folders |
| `puremac analyze [path]` | Show what is taking up disk space, largest first |
| `puremac optimize [ram\|purgeable]` | Free inactive RAM and release purgeable disk space |
| `puremac ignore add\|remove\|list <path>` | Protect paths from every scan |
| `puremac config` | Show or change preferences |

Flags on `clean` and `purge`:

- `--force` removes immediately, skipping the confirmation. Run without it first.
- `--dry-run` scans and reports what it would remove, deleting nothing.
- `--json` prints machine-readable output and never deletes.

## What `clean dev` covers

Homebrew, npm, Yarn, pnpm, pip, Cargo, Go, CocoaPods, VS Code, JetBrains, Maven,
Gradle, Poetry, uv, Bun, Deno, mise, Flutter/Dart, NuGet/.NET, Swift Package
Manager, Docker, and OrbStack. Only precise cache and build directories are
targeted, never a whole config directory such as `~/.cargo` or `~/.docker`.

## What `purge` finds

`node_modules`, `.next`, `.nuxt`, `.turbo`, `.svelte-kit`, `.angular`,
`.parcel-cache`, `target`, `.build`, `DerivedData`, `Pods`, `.venv`, `venv`,
`__pycache__`, `.pytest_cache`, `.mypy_cache`, `.tox`, `.ruff_cache`, `.gradle`,
and `cmake-build-*`, grouped by project. Artifacts older than seven days are
preselected; newer ones are shown but left unchecked.

## Safety

Every deletion passes one gate before it runs:

- Protected roots (`/`, `$HOME`, `~/Library`, and other containers) can be scanned
  into but never removed themselves.
- Config and credential directories are on a hard denylist.
- Cloud File Provider state (iCloud, Dropbox, OneDrive, Google Drive) is refused,
  checked against both the literal and symlink-resolved path.
- Symlinks are skipped, and no deletion follows a symlinked parent.
- Paths on your ignore list are excluded from every command.
- `clean` and `purge` print the full list of what will be removed and ask for
  confirmation before deleting anything.

Protect a path permanently:

```bash
puremac ignore add ~/Projects/important
```

## Notes

- `clean` and `junk` are user-scoped and need no `sudo`.
- `analyze` is read-only; nothing is deleted while browsing.
- An interactive full-screen browser for `analyze` is not built yet; the current
  view ranks folders by size like `du -d1 | sort`.
