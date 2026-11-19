import Foundation

/// The "Dev Tool Caches" category: one row per cache root of a developer tool.
///
/// `roots` is the single GUI list. It mirrors the "Dev Tools" targets in
/// `cli/Sources/puremac/Core/Catalog.swift` (paths and `selectedByDefault`);
/// the deviations are listed in `docs/DEV-TOOL-CACHES.md`. Project-level
/// artifacts (`node_modules`, Rust `target`) are deliberately not here.
///
/// Every root is an exact directory. `CleaningEngine` removes only a path that
/// equals one of these roots, never a descendant and never a parent.
enum DevToolCaches {
    /// How a root is emptied. The tool's own CLI is preferred whenever the tool
    /// manages its cache (lock handling, read-only files).
    enum Removal: Equatable {
        /// Plain `FileManager.removeItem` on the root.
        case unlink
        /// Plain removal, refused while a Gradle daemon or build is running.
        case unlinkUnlessGradleRunning
        /// `uv cache clean --cache-dir <root>` when `uv` exists, else plain removal.
        case uvCacheClean
        /// `go clean -cache` when `go` exists, else plain removal.
        case goCleanCache
        /// `go clean -modcache` when `go` exists. Never removed without `go`:
        /// module files are read-only, so plain removal fails midway.
        case goCleanModcache
    }

    struct Root: Equatable {
        /// Stable identifier, also used by tests and docs.
        let id: String
        /// Localization key shown as the row name.
        let nameKey: String
        /// Path relative to the home directory.
        let relativePath: String
        var selectedByDefault = true
        var removal: Removal = .unlink

        func path(home: String) -> String {
            (home as NSString).appendingPathComponent(relativePath)
        }
    }

    // Order matches the scan order shown in the UI.
    static let roots: [Root] = [
        Root(id: "bun", nameKey: "Bun cache", relativePath: ".bun/install/cache"),
        Root(id: "uv-xdg", nameKey: "uv cache", relativePath: ".cache/uv", removal: .uvCacheClean),
        Root(id: "uv-library", nameKey: "uv cache", relativePath: "Library/Caches/uv", removal: .uvCacheClean),
        Root(id: "pip-library", nameKey: "pip cache", relativePath: "Library/Caches/pip"),
        Root(id: "pip-xdg", nameKey: "pip cache", relativePath: ".cache/pip"),
        Root(id: "poetry-library", nameKey: "Poetry cache", relativePath: "Library/Caches/pypoetry"),
        Root(id: "poetry-xdg", nameKey: "Poetry cache", relativePath: ".cache/pypoetry"),
        Root(id: "cocoapods", nameKey: "CocoaPods cache", relativePath: "Library/Caches/CocoaPods"),
        Root(id: "swiftpm", nameKey: "Swift Package Manager cache", relativePath: "Library/Caches/org.swift.swiftpm"),
        Root(id: "gradle-caches", nameKey: "Gradle caches", relativePath: ".gradle/caches", removal: .unlinkUnlessGradleRunning),
        Root(id: "gradle-wrapper", nameKey: "Gradle wrapper distributions", relativePath: ".gradle/wrapper/dists", removal: .unlinkUnlessGradleRunning),
        // Cargo: only these four. ~/.cargo/bin and ~/.cargo/config.toml are never touched.
        Root(id: "cargo-registry-cache", nameKey: "Cargo registry cache", relativePath: ".cargo/registry/cache"),
        Root(id: "cargo-registry-index", nameKey: "Cargo registry index", relativePath: ".cargo/registry/index"),
        Root(id: "cargo-git-db", nameKey: "Cargo git database", relativePath: ".cargo/git/db"),
        Root(id: "cargo-git-checkouts", nameKey: "Cargo git checkouts", relativePath: ".cargo/git/checkouts"),
        Root(id: "go-build", nameKey: "Go build cache", relativePath: "Library/Caches/go-build", removal: .goCleanCache),
        // The CLI lists go/pkg/mod/cache (the download subset). `go clean -modcache`
        // removes all of GOMODCACHE, so the GUI row and its size cover go/pkg/mod.
        Root(id: "go-modcache", nameKey: "Go module cache", relativePath: "go/pkg/mod", removal: .goCleanModcache),
        Root(id: "deno-library", nameKey: "Deno cache", relativePath: "Library/Caches/deno"),
        Root(id: "deno-xdg", nameKey: "Deno cache", relativePath: ".cache/deno"),
        // The CLI lists all of ~/.pub-cache. bin/ and global_packages/ hold
        // `dart pub global activate` tools, so only downloaded packages are listed.
        Root(id: "pub-hosted", nameKey: "Dart pub packages", relativePath: ".pub-cache/hosted"),
        Root(id: "pub-git", nameKey: "Dart pub git packages", relativePath: ".pub-cache/git"),
        Root(id: "playwright-library", nameKey: "Playwright browsers", relativePath: "Library/Caches/ms-playwright"),
        Root(id: "playwright-xdg", nameKey: "Playwright browsers", relativePath: ".cache/ms-playwright"),
        Root(id: "puppeteer", nameKey: "Puppeteer browsers", relativePath: ".cache/puppeteer"),
        Root(id: "node-gyp-library", nameKey: "node-gyp headers", relativePath: "Library/Caches/node-gyp"),
        Root(id: "node-gyp-xdg", nameKey: "node-gyp headers", relativePath: ".cache/node-gyp"),
        Root(id: "electron", nameKey: "Electron download cache", relativePath: "Library/Caches/electron"),
        Root(id: "electron-builder", nameKey: "Electron Builder cache", relativePath: "Library/Caches/electron-builder"),
        // Opt-in: these can hold things that are not re-downloadable.
        Root(id: "maven", nameKey: "Maven repository (may hold local installs)", relativePath: ".m2/repository", selectedByDefault: false),
        Root(id: "nuget-packages", nameKey: "NuGet packages (may hold local packages)", relativePath: ".nuget/packages", selectedByDefault: false),
        Root(id: "nuget-http", nameKey: "NuGet HTTP cache", relativePath: ".local/share/NuGet/http-cache", selectedByDefault: false),
    ]

    /// Directories searched for `uv` and `go`. The GUI app does not inherit the
    /// shell `PATH`.
    static func toolSearchDirectories(home: String) -> [String] {
        [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/local/go/bin",
            "\(home)/.local/bin",
            "\(home)/.cargo/bin",
        ]
    }

    /// Process command-line fragments that identify a live Gradle daemon,
    /// wrapper client or test worker.
    static let gradleProcessMarkers = [
        "GradleDaemon",
        "GradleWrapperMain",
        "GradleWorkerMain",
        "org.gradle.launcher.GradleMain",
    ]

    /// Absolute, standardized root paths for `home`.
    static func absolutePaths(home: String) -> [String] {
        roots.map { ($0.path(home: home) as NSString).standardizingPath }
    }

    static func contains(_ path: String, home: String) -> Bool {
        let normalized = (path as NSString).standardizingPath
        return absolutePaths(home: home).contains {
            normalized == $0 || normalized.hasPrefix($0 + "/")
        }
    }

    /// The root whose path equals `path` exactly (after standardizing), or nil.
    /// Descendants, parents and relative paths do not match.
    static func root(forPath path: String, home: String) -> Root? {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { return nil }
        let standardized = (path as NSString).standardizingPath
        guard standardized == path else { return nil }
        let normalizedHome = (home as NSString).standardizingPath
        return roots.first { ($0.path(home: normalizedHome) as NSString).standardizingPath == standardized }
    }

    /// True when `path` or any directory between `home` and `path` is a symbolic
    /// link. `lstat` semantics: the link itself is inspected, never followed.
    static func hasSymlinkBelowHome(_ path: String, home: String) -> Bool {
        let normalizedHome = (home as NSString).standardizingPath
        var current = (path as NSString).standardizingPath
        guard current.hasPrefix(normalizedHome + "/") else { return true }
        while current.count > normalizedHome.count {
            var info = stat()
            if lstat(current, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK { return true }
            current = (current as NSString).deletingLastPathComponent
        }
        return false
    }

    /// True when any entry of `commandLines` names a Gradle process.
    static func containsGradleProcess(_ commandLines: [String]) -> Bool {
        commandLines.contains { line in
            gradleProcessMarkers.contains { line.contains($0) }
        }
    }
}

/// Everything about the host that the dev tool cache scan and clean read:
/// where tools live, whether Gradle runs, how long a tool may take. Injected
/// by tests so no real `uv`, `go` or process list is ever consulted.
struct DevToolCacheEnvironment: Sendable {
    /// Directories searched for `uv` and `go`. Empty means "use the defaults for home".
    var searchDirectories: [String]?
    /// Command line of every running process, read-only. nil when the process
    /// list cannot be read; callers then treat Gradle as running.
    var processCommandLines: @Sendable () -> [String]?
    /// Upper bound for a single `uv` or `go` invocation.
    var commandTimeout: TimeInterval
    /// Test seam: runs with the root path after the clean's first checks and
    /// before the final symlink re-check that precedes a plain unlink. Lets a
    /// test swap the root for a symlink inside the race window.
    var beforeUnlinkRecheck: @Sendable (String) -> Void = { _ in }

    static let live = DevToolCacheEnvironment(
        searchDirectories: nil,
        processCommandLines: { DevToolCacheEnvironment.livePSCommandLines() },
        commandTimeout: 300
    )

    func isGradleRunning() -> Bool {
        guard let lines = processCommandLines() else { return true }
        return DevToolCaches.containsGradleProcess(lines)
    }

    func locate(_ tool: String, home: String, fileManager: FileManager = .default) -> String? {
        let directories = searchDirectories ?? DevToolCaches.toolSearchDirectories(home: home)
        for directory in directories {
            let candidate = (directory as NSString).appendingPathComponent(tool)
            if fileManager.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// `ps -axo command=`: read-only.
    private static func livePSCommandLines() -> [String]? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "command="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
        } catch {
            Logger.shared.log("Dev tool caches: could not list processes: \(error.localizedDescription)", level: .warning)
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }
}
