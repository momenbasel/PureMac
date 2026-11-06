import XCTest
@testable import PureMac

/// Fixtures live under a temporary home. `uv` and `go` are fake shell scripts
/// in a temp bin directory; no real tool, process list or user directory is
/// consulted.
final class DevToolCachesTests: XCTestCase {
    private var base: URL!
    private var home: String!
    private var bin: URL!
    private var log: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("puremac-devtools-\(UUID().uuidString)", isDirectory: true)
        let homeURL = base.appendingPathComponent("home", isDirectory: true)
        bin = base.appendingPathComponent("bin", isDirectory: true)
        log = base.appendingPathComponent("tool.log")
        try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        home = XcodeBuildMCPDerivedDataSupport.canonicalHomeDirectory(homeURL).path
        FileManager.default.createFile(atPath: log.path, contents: Data())
    }

    override func tearDownWithError() throws {
        // Go-style read-only trees must be writable again before removal.
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["-R", "u+w", base.path]
        try? chmod.run()
        chmod.waitUntilExit()
        try? FileManager.default.removeItem(at: base)
    }

    // MARK: - Fixtures

    private func environment(
        gradleRunning: Bool = false,
        timeout: TimeInterval = 10
    ) -> DevToolCacheEnvironment {
        let lines = gradleRunning
            ? ["/usr/bin/java -cp gradle-launcher.jar org.gradle.launcher.daemon.bootstrap.GradleDaemon 8.5"]
            : ["/sbin/launchd", "/usr/bin/java -jar other.jar"]
        return DevToolCacheEnvironment(
            searchDirectories: [bin.path],
            processCommandLines: { lines },
            commandTimeout: timeout
        )
    }

    @discardableResult
    private func makeCache(_ relativePath: String, bytes: Int = 8192) throws -> String {
        let dir = (home as NSString).appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let file = (dir as NSString).appendingPathComponent("payload.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: file, contents: Data(repeating: 7, count: bytes)))
        return dir
    }

    private func makeAllCaches() throws {
        for root in DevToolCaches.roots { try makeCache(root.relativePath) }
    }

    private func installTool(_ name: String, script: String) throws {
        let url = bin.appendingPathComponent(name)
        try ("#!/bin/sh\n" + script).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func toolLog() -> [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    private func item(_ relativePath: String, size: Int64 = 8192) -> CleanableItem {
        CleanableItem(
            name: relativePath,
            path: (home as NSString).appendingPathComponent(relativePath),
            size: size,
            category: .devToolCaches,
            isSelected: true,
            lastModified: nil
        )
    }

    private func exists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: (home as NSString).appendingPathComponent(relativePath))
    }

    private func clean(
        _ items: [CleanableItem],
        environment env: DevToolCacheEnvironment? = nil
    ) async -> CleaningEngine.CleaningResult {
        let engine = CleaningEngine(
            homeDirectory: URL(fileURLWithPath: home, isDirectory: true),
            devToolEnvironment: env ?? environment()
        )
        return await engine.cleanItems(items) { _ in }
    }

    // MARK: - Catalog and allowlist

    func testEveryRootIsInsideAnAllowlistedRoot() {
        let allowed = CleaningEngine.allowedDeletionRoots(home: "/Users/example")
        for root in DevToolCaches.roots {
            let path = root.path(home: "/Users/example")
            XCTAssertTrue(
                allowed.contains { path == $0 || path.hasPrefix($0 + "/") },
                "\(root.id) is not covered by the delete allowlist"
            )
        }
    }

    func testAllowlistGainsExactRootsNotBroadParents() {
        let before = Set(CleaningEngine.allowedDeletionRoots(home: "/Users/example"))
        for broad in ["/.cargo", "/.cargo/registry", "/.cargo/git", "/.gradle", "/.gradle/wrapper",
                      "/.m2", "/go", "/go/pkg", "/.bun", "/.bun/install", "/.pub-cache", "/.nuget",
                      "/.local", "/.local/share", "/.local/share/NuGet"] {
            XCTAssertFalse(before.contains("/Users/example" + broad), "\(broad) must not be allow-listed")
        }
        XCTAssertTrue(before.contains("/Users/example/.bun/install/cache"))
        XCTAssertTrue(before.contains("/Users/example/.cargo/registry/cache"))
        XCTAssertTrue(before.contains("/Users/example/.gradle/caches"))
    }

    func testNoRootEqualsContainsOrSitsInsideProtectedLocations() {
        let home = "/Users/example"
        // No root may be one of these, sit inside one, or be a parent of one.
        let protected = [
            ".claude", ".claude.json", ".ollama", ".cache/huggingface", ".ssh", ".aws", ".gnupg",
            ".kube", ".docker", ".config", ".rustup", ".cargo/bin", ".cargo/config.toml",
            ".cargo/credentials.toml", ".gradle/gradle.properties", ".pub-cache/bin",
            ".pub-cache/global_packages", "go/src", "go/bin",
        ].map { "\(home)/\($0)" }
        // No root may be one of these broad parents (roots may sit inside them).
        let broadParents = [
            "", ".cargo", ".cargo/registry", ".cargo/git", ".gradle", ".gradle/wrapper", ".m2", "go", "go/pkg",
            ".bun", ".bun/install", ".pub-cache", ".nuget", ".local", ".local/share", ".cache", "Library",
            "Library/Caches", "Documents", "Desktop", "Downloads",
        ].map { $0.isEmpty ? home : "\(home)/\($0)" }

        for root in DevToolCaches.roots {
            let path = root.path(home: home)
            for forbidden in protected {
                XCTAssertFalse(path == forbidden || path.hasPrefix(forbidden + "/"), "\(root.id) is inside \(forbidden)")
                XCTAssertFalse(forbidden.hasPrefix(path + "/"), "\(root.id) contains \(forbidden)")
            }
            XCTAssertFalse(broadParents.contains(path), "\(root.id) is a broad parent")
        }
    }

    func testMavenRepositoryAppearsOnlyAsAnUnselectedRow() {
        let maven = DevToolCaches.roots.filter {
            $0.relativePath == ".m2/repository" || $0.relativePath.hasPrefix(".m2/")
        }
        XCTAssertEqual(maven.map(\.relativePath), [".m2/repository"])
        XCTAssertFalse(maven[0].selectedByDefault)
    }

    func testMavenAndNuGetAreOptInAndEverythingElseIsPreselected() {
        let optIn = DevToolCaches.roots.filter { !$0.selectedByDefault }.map(\.relativePath)
        XCTAssertEqual(
            Set(optIn),
            [".m2/repository", ".nuget/packages", ".local/share/NuGet/http-cache"]
        )
        XCTAssertEqual(DevToolCaches.roots.filter(\.selectedByDefault).count, DevToolCaches.roots.count - 3)
    }

    func testRootsAreUniqueRelativeAndNeverContainProjectArtifacts() {
        let paths = DevToolCaches.roots.map(\.relativePath)
        XCTAssertEqual(Set(paths).count, paths.count)
        for path in paths {
            XCTAssertFalse(path.hasPrefix("/"))
            XCTAssertFalse(path.contains(".."))
            XCTAssertFalse(path.contains("node_modules"))
            XCTAssertFalse(path.hasSuffix("target"))
        }
        let ids = DevToolCaches.roots.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testRootLookupIsExactMatchOnly() {
        let home = "/Users/example"
        XCTAssertEqual(DevToolCaches.root(forPath: "\(home)/.bun/install/cache", home: home)?.id, "bun")
        XCTAssertNil(DevToolCaches.root(forPath: "\(home)/.bun/install/cache/x", home: home))
        XCTAssertNil(DevToolCaches.root(forPath: "\(home)/.bun/install", home: home))
        XCTAssertNil(DevToolCaches.root(forPath: "\(home)/.bun", home: home))
        XCTAssertNil(DevToolCaches.root(forPath: "\(home)/.cargo", home: home))
        XCTAssertNil(DevToolCaches.root(forPath: "\(home)/.cargo/bin", home: home))
        XCTAssertNil(DevToolCaches.root(forPath: "\(home)/.cargo/registry", home: home))
        XCTAssertNil(DevToolCaches.root(forPath: ".bun/install/cache", home: home))
        XCTAssertNil(DevToolCaches.root(forPath: "\(home)/.bun/install/cache/../../../.ssh", home: home))
        XCTAssertNil(DevToolCaches.root(forPath: "\(home)/.bun/install/cache\n/x", home: home))
        XCTAssertNil(DevToolCaches.root(forPath: "", home: home))
    }

    func testGradleProcessDetection() {
        XCTAssertTrue(DevToolCaches.containsGradleProcess([
            "/usr/bin/java -Xmx64m org.gradle.launcher.daemon.bootstrap.GradleDaemon 8.5",
        ]))
        XCTAssertTrue(DevToolCaches.containsGradleProcess([
            "java -classpath gradle-wrapper.jar org.gradle.wrapper.GradleWrapperMain build",
        ]))
        XCTAssertFalse(DevToolCaches.containsGradleProcess(["/usr/bin/java -jar app.jar", "vim build.gradle"]))
    }

    // MARK: - Scan

    func testScanFindsEveryPresentRootWithCatalogSelection() async throws {
        try installTool("go", script: "exit 0\n")
        try makeAllCaches()

        let result = await ScanEngine(
            homeDirectory: URL(fileURLWithPath: home, isDirectory: true),
            devToolEnvironment: environment()
        ).scanCategory(.devToolCaches)

        XCTAssertEqual(result.category, .devToolCaches)
        XCTAssertEqual(
            Set(result.items.map(\.path)),
            Set(DevToolCaches.absolutePaths(home: home))
        )
        let optIn = Set(DevToolCaches.roots.filter { !$0.selectedByDefault }.map { $0.path(home: home) })
        for item in result.items {
            XCTAssertEqual(item.isSelected, !optIn.contains(item.path), item.path)
            XCTAssertEqual(item.selectOnlyByHand, optIn.contains(item.path), item.path)
            XCTAssertEqual(item.category, .devToolCaches)
            XCTAssertGreaterThan(item.size, 0)
        }
        XCTAssertEqual(result.totalSize, result.items.reduce(0) { $0 + $1.size })
    }

    func testScanOmitsMissingRootsAndGoModuleCacheWithoutGo() async throws {
        try makeCache(".bun/install/cache")
        try makeCache("go/pkg/mod")

        let result = await ScanEngine(
            homeDirectory: URL(fileURLWithPath: home, isDirectory: true),
            devToolEnvironment: environment()
        ).scanCategory(.devToolCaches)

        XCTAssertEqual(result.items.map(\.path), [(home as NSString).appendingPathComponent(".bun/install/cache")])
    }

    func testScanDoesNotListCargoBinOrConfig() async throws {
        try makeCache(".cargo/registry/cache")
        try makeCache(".cargo/bin")
        try "x".write(toFile: home + "/.cargo/config.toml", atomically: true, encoding: .utf8)

        let result = await ScanEngine(
            homeDirectory: URL(fileURLWithPath: home, isDirectory: true),
            devToolEnvironment: environment()
        ).scanCategory(.devToolCaches)

        XCTAssertEqual(result.items.map(\.path), [home + "/.cargo/registry/cache"])
    }

    func testScanRefusesSymlinkedRoots() async throws {
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 8192).write(to: outside.appendingPathComponent("keep.bin"))
        // Symlinked ancestor (~/.bun) and symlinked root itself (~/.cache/deno).
        try FileManager.default.createSymbolicLink(
            atPath: home + "/.bun", withDestinationPath: outside.path
        )
        try FileManager.default.createDirectory(atPath: home + "/.cache", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: home + "/.cache/deno", withDestinationPath: outside.path
        )

        let result = await ScanEngine(
            homeDirectory: URL(fileURLWithPath: home, isDirectory: true),
            devToolEnvironment: environment()
        ).scanCategory(.devToolCaches)

        XCTAssertTrue(result.items.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appendingPathComponent("keep.bin").path))
    }

    func testScanFlagsGradleRowsWhileGradleRuns() async throws {
        try makeCache(".gradle/caches")
        try makeCache(".gradle/wrapper/dists")
        try makeCache(".bun/install/cache")

        let running = await ScanEngine(
            homeDirectory: URL(fileURLWithPath: home, isDirectory: true),
            devToolEnvironment: environment(gradleRunning: true)
        ).scanCategory(.devToolCaches)
        let gradleRows = running.items.filter { $0.path.contains("/.gradle/") }
        XCTAssertEqual(gradleRows.count, 2)
        XCTAssertTrue(gradleRows.allSatisfy { !$0.isSelected })
        XCTAssertTrue(gradleRows.allSatisfy { $0.name.contains("Gradle") })
        XCTAssertTrue(running.items.first { $0.path.contains("/.bun/") }?.isSelected == true)

        let idle = await ScanEngine(
            homeDirectory: URL(fileURLWithPath: home, isDirectory: true),
            devToolEnvironment: environment(gradleRunning: false)
        ).scanCategory(.devToolCaches)
        XCTAssertTrue(idle.items.filter { $0.path.contains("/.gradle/") }.allSatisfy(\.isSelected))
    }

    func testUnreadableProcessListCountsAsGradleRunning() async throws {
        try makeCache(".gradle/caches")
        let unreadable = DevToolCacheEnvironment(
            searchDirectories: [bin.path], processCommandLines: { nil }, commandTimeout: 5
        )
        let result = await ScanEngine(
            homeDirectory: URL(fileURLWithPath: home, isDirectory: true),
            devToolEnvironment: unreadable
        ).scanCategory(.devToolCaches)
        XCTAssertEqual(result.items.count, 1)
        XCTAssertFalse(result.items[0].isSelected)

        let cleaned = await clean([item(".gradle/caches")], environment: unreadable)
        XCTAssertTrue(exists(".gradle/caches"))
        XCTAssertTrue(cleaned.skippedPaths.contains(home + "/.gradle/caches"))
    }

    func testUserCacheNoLongerDoublesUpOnDevToolRoots() async throws {
        try makeCache("Library/Caches/CocoaPods")
        try makeCache("Library/Caches/pip")
        try makeCache(".cache/pip")
        try makeCache("Library/Caches/SomeOtherApp")

        let result = await ScanEngine(
            homeDirectory: URL(fileURLWithPath: home, isDirectory: true),
            devToolEnvironment: environment()
        ).scanCategory(.userCache)

        let paths = result.items.map(\.path)
        XCTAssertTrue(paths.contains(home + "/Library/Caches/SomeOtherApp"))
        XCTAssertFalse(paths.contains(home + "/Library/Caches/CocoaPods"))
        XCTAssertFalse(paths.contains(home + "/Library/Caches/pip"))
        XCTAssertFalse(paths.contains(home + "/.cache/pip"))
    }

    func testCategoryIsRegenerableSoSmartScanIncludesIt() {
        XCTAssertTrue(CleaningCategory.scannable.contains(.devToolCaches))
        XCTAssertFalse(CleaningCategory.appModifying.contains(.devToolCaches))
    }

    // MARK: - Clean: plain removal

    func testPlainCleanRemovesOnlyTheRootAndKeepsSiblings() async throws {
        try makeCache(".bun/install/cache")
        try makeCache(".bun/bin")
        try makeCache(".cargo/registry/cache")
        try makeCache(".cargo/registry/index")
        try makeCache(".cargo/git/db")
        try makeCache(".cargo/git/checkouts")
        try makeCache(".cargo/bin")
        try "[build]".write(toFile: home + "/.cargo/config.toml", atomically: true, encoding: .utf8)

        let items = [
            item(".bun/install/cache"), item(".cargo/registry/cache"), item(".cargo/registry/index"),
            item(".cargo/git/db"), item(".cargo/git/checkouts"),
        ]
        let result = await clean(items)

        XCTAssertEqual(result.itemsCleaned, 5)
        XCTAssertEqual(result.freedSpace, 5 * 8192)
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        for relative in [".bun/install/cache", ".cargo/registry/cache", ".cargo/registry/index",
                         ".cargo/git/db", ".cargo/git/checkouts"] {
            XCTAssertFalse(exists(relative), relative)
        }
        XCTAssertTrue(exists(".bun/bin/payload.bin"))
        XCTAssertTrue(exists(".cargo/bin/payload.bin"))
        XCTAssertTrue(exists(".cargo/config.toml"))
    }

    func testCleanRefusesPathsThatAreNotExactRoots() async throws {
        try makeCache(".cargo/bin")
        try makeCache(".cargo/registry/cache")
        try makeCache(".ssh")
        try makeCache(".claude")

        let victims = [
            item(".cargo/bin"), item(".cargo/registry"), item(".cargo"), item(".ssh"), item(".claude"),
            item(".cargo/registry/cache/payload.bin"), item("Library/Caches"),
        ]
        let result = await clean(victims)

        XCTAssertEqual(result.itemsCleaned, 0)
        XCTAssertEqual(result.errors.count, victims.count)
        XCTAssertTrue(result.cleanedPaths.isEmpty)
        XCTAssertTrue(exists(".cargo/bin/payload.bin"))
        XCTAssertTrue(exists(".cargo/registry/cache/payload.bin"))
        XCTAssertTrue(exists(".ssh/payload.bin"))
        XCTAssertTrue(exists(".claude/payload.bin"))
    }

    func testCleanRefusesSymlinkedRootAndKeepsTarget() async throws {
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 8192).write(to: outside.appendingPathComponent("keep.bin"))
        try FileManager.default.createDirectory(atPath: home + "/.cache", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: home + "/.cache/puppeteer", withDestinationPath: outside.path
        )
        try FileManager.default.createDirectory(
            at: outside.appendingPathComponent("install/cache"), withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(atPath: home + "/.bun", withDestinationPath: outside.path)

        let result = await clean([item(".cache/puppeteer"), item(".bun/install/cache")])

        XCTAssertEqual(result.itemsCleaned, 0)
        XCTAssertEqual(result.errors.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appendingPathComponent("keep.bin").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home + "/.cache/puppeteer"))
    }

    func testAlreadyRemovedRootCountsAsHandled() async {
        let result = await clean([item(".bun/install/cache")])
        XCTAssertTrue(result.cleanedPaths.contains(home + "/.bun/install/cache"))
        XCTAssertEqual(result.itemsCleaned, 0)
        XCTAssertTrue(result.errors.isEmpty)
    }

    func testAdminPassRefusesDevToolCaches() async throws {
        try makeCache(".bun/install/cache")
        let engine = CleaningEngine(
            homeDirectory: URL(fileURLWithPath: home, isDirectory: true),
            devToolEnvironment: environment()
        )
        let result = await engine.cleanWithAdminPrivileges(items: [item(".bun/install/cache")])
        XCTAssertEqual(result.itemsCleaned, 0)
        XCTAssertEqual(result.errors.count, 1)
        XCTAssertTrue(exists(".bun/install/cache/payload.bin"))
    }

    func testGenericCleanupCannotBypassDevToolCacheChecks() async throws {
        let root = try makeCache("Library/Caches/uv")
        let payload = root + "/payload.bin"
        let engine = CleaningEngine(
            homeDirectory: URL(fileURLWithPath: home, isDirectory: true),
            devToolEnvironment: environment()
        )
        let rows = [root, payload].map {
            CleanableItem(name: "Cache", path: $0, size: 8192,
                          category: .userCache, isSelected: true, lastModified: nil)
        }

        let regular = await engine.cleanItems(rows) { _ in }
        XCTAssertTrue(regular.cleanedPaths.isEmpty)
        XCTAssertEqual(regular.errors.count, rows.count)
        XCTAssertTrue(exists("Library/Caches/uv/payload.bin"))
    }

    // MARK: - Clean: Gradle

    func testGradleCleanSkippedWhileDaemonRuns() async throws {
        try makeCache(".gradle/caches")
        try makeCache(".gradle/wrapper/dists")

        let result = await clean(
            [item(".gradle/caches"), item(".gradle/wrapper/dists")],
            environment: environment(gradleRunning: true)
        )

        XCTAssertEqual(result.itemsCleaned, 0)
        XCTAssertEqual(result.skippedPaths.count, 2)
        XCTAssertTrue(result.cleanedPaths.isEmpty)
        XCTAssertEqual(result.errors.count, 2)
        XCTAssertTrue(result.errors.allSatisfy { $0.contains("Gradle") })
        XCTAssertTrue(exists(".gradle/caches/payload.bin"))
        XCTAssertTrue(exists(".gradle/wrapper/dists/payload.bin"))
    }

    func testGradleCleanRunsWhenNoDaemonAndKeepsOtherGradleFiles() async throws {
        try makeCache(".gradle/caches")
        try makeCache(".gradle/daemon")
        try "org.gradle.jvmargs=-Xmx2g".write(
            toFile: home + "/.gradle/gradle.properties", atomically: true, encoding: .utf8
        )

        let result = await clean([item(".gradle/caches")], environment: environment(gradleRunning: false))

        XCTAssertEqual(result.itemsCleaned, 1)
        XCTAssertFalse(exists(".gradle/caches"))
        XCTAssertTrue(exists(".gradle/gradle.properties"))
        XCTAssertTrue(exists(".gradle/daemon/payload.bin"))
    }

    // MARK: - Clean: uv

    func testUVCleanUsesUVWithExplicitCacheDirAndNeverForce() async throws {
        let cache = try makeCache(".cache/uv")
        try installTool("uv", script: """
        echo "$@" >> "\(log.path)"
        rm -rf "$4"
        exit 0

        """)

        let result = await clean([item(".cache/uv")])

        XCTAssertEqual(toolLog(), ["cache clean --cache-dir \(cache)"])
        XCTAssertFalse(toolLog().joined().contains("--force"))
        XCTAssertEqual(result.itemsCleaned, 1)
        XCTAssertTrue(result.cleanedPaths.contains(cache))
        XCTAssertTrue(result.skippedPaths.isEmpty)
        XCTAssertTrue(result.errors.isEmpty)
    }

    func testUVStderrMentioningLockIsARealErrorNotABusySkip() async throws {
        let cache = try makeCache(".cache/uv")
        try installTool("uv", script: """
        echo "$@" >> "\(log.path)"
        echo "error: failed to remove \(cache)/.lock: Operation not permitted" >&2
        exit 2

        """)

        let result = await clean([item(".cache/uv")])

        XCTAssertEqual(toolLog(), ["cache clean --cache-dir \(cache)"])
        XCTAssertEqual(result.itemsCleaned, 0)
        XCTAssertTrue(result.cleanedPaths.isEmpty)
        XCTAssertTrue(result.skippedPaths.isEmpty, "a real failure must stay a survivor")
        XCTAssertEqual(result.errors.count, 1)
        XCTAssertTrue(result.errors[0].contains("Operation not permitted"))
        XCTAssertTrue(exists(".cache/uv/payload.bin"))
    }

    func testUVCleanThatWaitsForTheLockPastTheTimeoutIsReportedAsBusy() async throws {
        let cache = try makeCache("Library/Caches/uv")
        try installTool("uv", script: """
        echo "$@" >> "\(log.path)"
        exec /bin/sleep 30

        """)

        let result = await clean(
            [item("Library/Caches/uv")],
            environment: environment(timeout: 1)
        )

        XCTAssertEqual(toolLog(), ["cache clean --cache-dir \(cache)"])
        XCTAssertEqual(result.skippedPaths, [cache])
        XCTAssertTrue(result.cleanedPaths.isEmpty)
        XCTAssertEqual(result.errors.count, 1)
        XCTAssertTrue(result.errors[0].contains("locked by another uv process"))
        XCTAssertTrue(exists("Library/Caches/uv/payload.bin"))
    }

    func testUVCleanFailureOtherThanLockIsAnErrorNotASkip() async throws {
        try makeCache(".cache/uv")
        try installTool("uv", script: """
        echo "error: something else" >&2
        exit 1

        """)

        let result = await clean([item(".cache/uv")])

        XCTAssertTrue(result.skippedPaths.isEmpty)
        XCTAssertEqual(result.errors.count, 1)
        XCTAssertTrue(exists(".cache/uv/payload.bin"))
    }

    func testUVCacheIsRemovedDirectlyWhenUVIsNotInstalled() async throws {
        try makeCache(".cache/uv")
        let result = await clean([item(".cache/uv")])
        XCTAssertEqual(result.itemsCleaned, 1)
        XCTAssertFalse(exists(".cache/uv"))
        XCTAssertTrue(toolLog().isEmpty)
    }

    // MARK: - Clean: Go

    private func goScript(cacheReports: String, modcacheReports: String) -> String {
        """
        echo "$@" >> "\(log.path)"
        if [ "$1" = "env" ] && [ "$2" = "GOCACHE" ]; then echo "\(cacheReports)"; exit 0; fi
        if [ "$1" = "env" ] && [ "$2" = "GOMODCACHE" ]; then echo "\(modcacheReports)"; exit 0; fi
        if [ "$1" = "clean" ] && [ "$2" = "-cache" ]; then rm -rf "\(cacheReports)"; exit 0; fi
        if [ "$1" = "clean" ] && [ "$2" = "-modcache" ]; then chmod -R u+w "\(modcacheReports)"; rm -rf "\(modcacheReports)"; exit 0; fi
        exit 1

        """
    }

    func testGoCleanUsesGoCleanForBuildAndModuleCaches() async throws {
        let build = try makeCache("Library/Caches/go-build")
        let mod = try makeCache("go/pkg/mod/example.com/m@v1.0.0")
        let modRoot = home + "/go/pkg/mod"
        // Module files and directories are read-only, as Go creates them.
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["-R", "a-w", modRoot]
        try chmod.run()
        chmod.waitUntilExit()
        XCTAssertTrue(mod.hasPrefix(modRoot))
        try installTool("go", script: goScript(cacheReports: build, modcacheReports: modRoot))

        let result = await clean([item("Library/Caches/go-build"), item("go/pkg/mod")])

        XCTAssertEqual(
            toolLog(),
            ["env GOCACHE", "clean -cache", "env GOMODCACHE", "clean -modcache"]
        )
        XCTAssertEqual(result.itemsCleaned, 2)
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        XCTAssertFalse(exists("Library/Caches/go-build"))
        XCTAssertFalse(exists("go/pkg/mod"))
    }

    func testGoModuleCacheIsLeftAloneWithoutGo() async throws {
        try makeCache("go/pkg/mod/example.com/m@v1.0.0")

        let result = await clean([item("go/pkg/mod")])

        XCTAssertEqual(result.itemsCleaned, 0)
        XCTAssertEqual(result.skippedPaths, [home + "/go/pkg/mod"])
        XCTAssertTrue(result.cleanedPaths.isEmpty)
        XCTAssertTrue(exists("go/pkg/mod/example.com/m@v1.0.0/payload.bin"))
    }

    func testGoBuildCacheFallsBackToPlainRemovalWithoutGo() async throws {
        try makeCache("Library/Caches/go-build")
        let result = await clean([item("Library/Caches/go-build")])
        XCTAssertEqual(result.itemsCleaned, 1)
        XCTAssertFalse(exists("Library/Caches/go-build"))
    }

    func testGoCleanRefusesWhenGoUsesADifferentCacheDirectory() async throws {
        let build = try makeCache("Library/Caches/go-build")
        let elsewhere = base.appendingPathComponent("custom-gocache").path
        try installTool("go", script: goScript(cacheReports: elsewhere, modcacheReports: elsewhere))

        let result = await clean([item("Library/Caches/go-build")])

        XCTAssertEqual(toolLog(), ["env GOCACHE"])
        XCTAssertEqual(result.itemsCleaned, 0)
        XCTAssertEqual(result.skippedPaths, [build])
        XCTAssertTrue(exists("Library/Caches/go-build/payload.bin"))
    }

    func testGoCleanAbortsWhenTheRootBecomesASymlinkDuringGoEnv() async throws {
        let build = try makeCache("Library/Caches/go-build")
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 8192).write(to: outside.appendingPathComponent("keep.bin"))
        // `go env` swaps the root for a link to another directory, then reports the root.
        try installTool("go", script: """
        echo "$@" >> "\(log.path)"
        if [ "$1" = "env" ]; then
          rm -rf "\(build)"
          ln -s "\(outside.path)" "\(build)"
          echo "\(build)"
          exit 0
        fi
        rm -rf "\(build)/"
        exit 0

        """)

        let result = await clean([item("Library/Caches/go-build")])

        XCTAssertEqual(toolLog(), ["env GOCACHE"], "go clean must not run after the swap")
        XCTAssertEqual(result.itemsCleaned, 0)
        XCTAssertTrue(result.cleanedPaths.isEmpty)
        XCTAssertEqual(result.errors.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appendingPathComponent("keep.bin").path))
    }

    func testGoEnvValueIsComparedInCanonicalForm() async throws {
        let build = try makeCache("Library/Caches/go-build")
        let alias = base.appendingPathComponent("alias-to-gocache").path
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: build)
        try installTool("go", script: goScript(cacheReports: alias, modcacheReports: alias)
            .replacingOccurrences(of: "rm -rf \"\(alias)\"", with: "rm -rf \"\(build)\""))

        let result = await clean([item("Library/Caches/go-build")])

        // A link that resolves to the row's directory is the same directory.
        XCTAssertEqual(toolLog(), ["env GOCACHE", "clean -cache"])
        XCTAssertEqual(result.itemsCleaned, 1)
        XCTAssertFalse(exists("Library/Caches/go-build"))
    }

    func testGoEnvValueThatIsASymlinkToAnotherDirectoryIsRefused() async throws {
        try makeCache("Library/Caches/go-build")
        let elsewhere = base.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let alias = base.appendingPathComponent("alias-to-elsewhere").path
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: elsewhere.path)
        try installTool("go", script: goScript(cacheReports: alias, modcacheReports: alias))

        let result = await clean([item("Library/Caches/go-build")])

        XCTAssertEqual(toolLog(), ["env GOCACHE"])
        XCTAssertEqual(result.skippedPaths, [home + "/Library/Caches/go-build"])
        XCTAssertTrue(exists("Library/Caches/go-build/payload.bin"))
    }

    func testPlainUnlinkIsRefusedWhenTheRootBecomesASymlinkAfterTheFirstChecks() async throws {
        let root = try makeCache(".bun/install/cache")
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 8192).write(to: outside.appendingPathComponent("keep.bin"))
        // The swap happens after the engine's first checks, right before the unlink.
        var env = environment()
        env.beforeUnlinkRecheck = { path in
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: outside.path)
        }

        let result = await clean([item(".bun/install/cache")], environment: env)

        XCTAssertEqual(result.itemsCleaned, 0)
        XCTAssertTrue(result.cleanedPaths.isEmpty)
        XCTAssertEqual(result.errors.count, 1)
        XCTAssertTrue(result.errors[0].contains("path resolution changed"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appendingPathComponent("keep.bin").path))
        // The link itself is left in place; nothing was unlinked.
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: root),
            outside.path
        )
    }

    func testUVCleanIsNotStartedOnASymlinkedRoot() async throws {
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 8192).write(to: outside.appendingPathComponent("keep.bin"))
        try FileManager.default.createDirectory(atPath: home + "/.cache", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: home + "/.cache/uv", withDestinationPath: outside.path)
        try installTool("uv", script: "echo \"$@\" >> \"\(log.path)\"\nexit 0\n")

        let result = await clean([item(".cache/uv")])

        XCTAssertTrue(toolLog().isEmpty)
        XCTAssertEqual(result.errors.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appendingPathComponent("keep.bin").path))
    }

    // MARK: - Localization

    func testEveryRootNameHasAnEnglishLocalization() throws {
        let stringsURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PureMac/en.lproj/Localizable.strings")
        let strings = try XCTUnwrap(
            NSDictionary(contentsOf: stringsURL) as? [String: String]
        )
        for root in DevToolCaches.roots {
            XCTAssertNotNil(strings[root.nameKey], "Missing key: \(root.nameKey)")
        }
        XCTAssertNotNil(strings["%@ (Gradle is running)"])
        XCTAssertNotNil(strings[CleaningCategory.devToolCaches.rawValue])
        XCTAssertNotNil(strings[CleaningCategory.devToolCaches.description])
    }
}

/// Bulk selection must never select rows that only a per-row toggle may select.
@MainActor
final class DevToolCacheSelectionTests: XCTestCase {
    private func row(_ name: String, selected: Bool, handOnly: Bool) -> CleanableItem {
        CleanableItem(
            name: name,
            path: "/Users/example/\(name)",
            size: 4_096,
            category: .devToolCaches,
            isSelected: selected,
            lastModified: nil,
            selectOnlyByHand: handOnly
        )
    }

    private func makeState() -> (AppState, normal: CleanableItem, optIn: CleanableItem, other: CleanableItem) {
        let state = AppState(performStartupTasks: false)
        let normal = row(".bun/install/cache", selected: true, handOnly: false)
        let optIn = row(".m2/repository", selected: false, handOnly: true)
        let other = row("plain-unselected", selected: false, handOnly: false)
        state.categoryResults[.devToolCaches] = CategoryResult(
            category: .devToolCaches, items: [normal, optIn, other], totalSize: 3 * 4_096
        )
        state.scanState = .completed
        return (state, normal, optIn, other)
    }

    func testOptInRowStartsUnselected() {
        let (state, normal, optIn, _) = makeState()
        XCTAssertTrue(state.isItemSelected(normal))
        XCTAssertFalse(state.isItemSelected(optIn))
    }

    func testSelectAllInCategorySkipsOptInRows() {
        let (state, normal, optIn, other) = makeState()
        state.deselectAllInCategory(.devToolCaches)
        state.selectAllInCategory(.devToolCaches)

        XCTAssertTrue(state.isItemSelected(normal))
        XCTAssertTrue(state.isItemSelected(other), "other unselected rows keep their select-all behaviour")
        XCTAssertFalse(state.isItemSelected(optIn))
        XCTAssertEqual(state.selectedSizeInCategory(.devToolCaches), 2 * 4_096)
    }

    func testCategoryCheckboxBindingSkipsOptInRows() {
        let (state, _, optIn, _) = makeState()
        let binding = state.categoryBinding(for: .devToolCaches)
        binding.wrappedValue = false
        binding.wrappedValue = true
        XCTAssertFalse(state.isItemSelected(optIn))
        XCTAssertEqual(state.selectedCountInCategory(.devToolCaches), 2)
    }

    func testSelectVisibleSkipsOptInRows() {
        let (state, normal, optIn, other) = makeState()
        state.setSelection(false, for: [normal, optIn, other])
        state.setSelection(true, for: [normal, optIn, other])
        XCTAssertTrue(state.isItemSelected(normal))
        XCTAssertTrue(state.isItemSelected(other))
        XCTAssertFalse(state.isItemSelected(optIn))
    }

    func testOnlyAPerRowToggleSelectsAnOptInRow() {
        let (state, _, optIn, _) = makeState()
        state.toggleItem(optIn)
        XCTAssertTrue(state.isItemSelected(optIn))
        // A later bulk select leaves the choice alone, and clearing deselects it.
        state.selectAllInCategory(.devToolCaches)
        XCTAssertTrue(state.isItemSelected(optIn))
        state.deselectAllInCategory(.devToolCaches)
        XCTAssertFalse(state.isItemSelected(optIn))
    }
}
