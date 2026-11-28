import XCTest
@testable import PureMac

final class NodeCachePathTests: XCTestCase {
    func testApprovedManagerRootsRemainNarrow() {
        let home = "/Users/example"

        XCTAssertEqual(
            ScanEngine.approvedNodeCacheRoots(for: .npm, home: home),
            ["/Users/example/.npm", "/Users/example/Library/Caches/npm"]
        )
        XCTAssertEqual(
            ScanEngine.approvedNodeCacheRoots(for: .yarn, home: home),
            ["/Users/example/Library/Caches/Yarn", "/Users/example/.cache/yarn"]
        )
        XCTAssertEqual(
            ScanEngine.approvedNodeCacheRoots(for: .pnpm, home: home),
            [
                "/Users/example/Library/pnpm/store",
                "/Users/example/.local/share/pnpm/store",
                "/Users/example/.pnpm-store",
                "/Users/example/.cache/pnpm",
            ]
        )
    }

    func testValidationAcceptsOnlyManagerRootOrDescendant() {
        let home = "/Users/example"

        XCTAssertEqual(
            ScanEngine.validatedNodeCachePath(
                "/Users/example/.npm/_cacache",
                manager: .npm,
                home: home
            ),
            "/Users/example/.npm/_cacache"
        )
        XCTAssertEqual(
            ScanEngine.validatedNodeCachePath(
                "/Users/example/Library/pnpm/store/v10",
                manager: .pnpm,
                home: home
            ),
            "/Users/example/Library/pnpm/store/v10"
        )
        XCTAssertNil(
            ScanEngine.validatedNodeCachePath(
                "/Users/example/.npm",
                manager: .pnpm,
                home: home
            )
        )
    }

    func testValidationRejectsBroadParentsRelativePathsAndTraversal() {
        let home = "/Users/example"
        let rejected = [
            "/",
            home,
            "~/.npm",
            "/Users/example/Library/Application Support",
            "/Users/example/Library/Application Support/.cache",
            "/Users/example/.cache",
            "/Users/example/.npm/../../Library/Application Support",
            "/Users/example/.npm\n/Library",
        ]

        for candidate in rejected {
            XCTAssertNil(
                ScanEngine.validatedNodeCachePath(candidate, manager: .npm, home: home),
                candidate
            )
        }
    }

    func testValidationRejectsSymlinkEscapingApprovedRoot() throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let homeURL = base.appendingPathComponent("home", isDirectory: true)
        let cacheURL = homeURL.appendingPathComponent(".npm", isDirectory: true)
        let outsideURL = base.appendingPathComponent("outside", isDirectory: true)
        let aliasURL = cacheURL.appendingPathComponent("redirect", isDirectory: true)
        try fileManager.createDirectory(at: cacheURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outsideURL, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: aliasURL, withDestinationURL: outsideURL)
        defer { try? fileManager.removeItem(at: base) }

        let home = homeURL.resolvingSymlinksInPath().path
        XCTAssertNil(
            ScanEngine.validatedNodeCachePath(
                aliasURL.path,
                manager: .npm,
                home: home
            )
        )
    }

    func testPruningKeepsCanonicalParentAndRemovesDuplicateDescendants() {
        let paths = [
            "/Users/example/.npm/_cacache",
            "/Users/example/Library/Caches/npm",
            "/Users/example/.npm",
            "/Users/example/.npm",
            "/Users/example/Library/Caches/npm/content-v2",
        ]

        XCTAssertEqual(
            ScanEngine.prunedNodeCachePaths(paths),
            ["/Users/example/.npm", "/Users/example/Library/Caches/npm"]
        )
    }

    // MARK: - Project artifacts (Rust targets, node_modules)

    private func makeHome() throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("puremac-projects-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.resolvingSymlinksInPath().path
    }

    private func makeDir(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    private func touch(_ path: String) throws {
        XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: Data()))
    }

    func testRustTargetRequiresManifestAndCargoMarker() throws {
        let home = try makeHome()
        let project = "\(home)/code/app"
        try makeDir("\(project)/target/debug")
        XCTAssertFalse(ScanEngine.isRustTargetDirectory("\(project)/target", home: home))

        try touch("\(project)/Cargo.toml")
        XCTAssertFalse(
            ScanEngine.isRustTargetDirectory("\(project)/target", home: home),
            "A target folder without cargo's marker files is not trusted"
        )

        try touch("\(project)/target/CACHEDIR.TAG")
        XCTAssertTrue(ScanEngine.isRustTargetDirectory("\(project)/target", home: home))
        XCTAssertFalse(ScanEngine.isRustTargetDirectory("\(project)/target/../target", home: home))
        XCTAssertFalse(ScanEngine.isRustTargetDirectory("\(project)/target", home: "\(home)/other"))
    }

    func testRustTargetRejectsLibraryHiddenAndSymlinkedFolders() throws {
        let home = try makeHome()
        for project in ["\(home)/Library/app", "\(home)/.hidden/app"] {
            try makeDir("\(project)/target")
            try touch("\(project)/Cargo.toml")
            try touch("\(project)/target/CACHEDIR.TAG")
            XCTAssertFalse(ScanEngine.isRustTargetDirectory("\(project)/target", home: home), project)
        }

        let real = "\(home)/code/real"
        try makeDir("\(real)/target")
        try touch("\(real)/target/CACHEDIR.TAG")
        let linked = "\(home)/code/linked"
        try makeDir(linked)
        try touch("\(linked)/Cargo.toml")
        try FileManager.default.createSymbolicLink(atPath: "\(linked)/target", withDestinationPath: "\(real)/target")
        XCTAssertFalse(ScanEngine.isRustTargetDirectory("\(linked)/target", home: home))
    }

    func testNodeModulesRequiresPackageJsonAndTopLevelPlacement() throws {
        let home = try makeHome()
        let project = "\(home)/code/web"
        try makeDir("\(project)/node_modules/dep/node_modules")
        XCTAssertFalse(ScanEngine.isNodeModulesDirectory("\(project)/node_modules", home: home))

        try touch("\(project)/package.json")
        try touch("\(project)/node_modules/dep/package.json")
        XCTAssertTrue(ScanEngine.isNodeModulesDirectory("\(project)/node_modules", home: home))
        XCTAssertFalse(
            ScanEngine.isNodeModulesDirectory("\(project)/node_modules/dep/node_modules", home: home),
            "Nested dependency trees are cleaned through their outermost node_modules"
        )
        XCTAssertFalse(ScanEngine.isNodeModulesDirectory(project, home: home))
        XCTAssertFalse(ScanEngine.isNodeModulesDirectory("\(home)/node_modules", home: home))
    }

    func testProjectDisplayNameIsRelativeToHome() {
        XCTAssertEqual(
            ScanEngine.projectDisplayName(forArtifactAt: "/Users/example/code/app/target", home: "/Users/example"),
            "~/code/app"
        )
    }

    func testNodeModulesScanFindsProjectsAndLeavesThemUnselected() async throws {
        let home = try makeHome()
        let project = "\(home)/code/web"
        try makeDir("\(project)/node_modules/.pnpm/dep")
        try touch("\(project)/package.json")
        XCTAssertTrue(FileManager.default.createFile(
            atPath: "\(project)/node_modules/.pnpm/dep/index.js",
            contents: Data(repeating: 0x61, count: 64 * 1024)
        ))

        let result = await ScanEngine(homeDirectory: URL(fileURLWithPath: home)).scanCategory(.nodeModules)

        XCTAssertEqual(result.items.map(\.path), ["\(project)/node_modules"])
        XCTAssertEqual(result.items.first?.name, "~/code/web")
        XCTAssertEqual(result.items.first?.isSelected, false)
        XCTAssertGreaterThan(result.totalSize, 1024, "Hidden .pnpm payload must count toward the size")
    }

    func testRustTargetsAndNodeModulesShareOneWalkPerScan() async throws {
        let home = try makeHome()
        let crate = "\(home)/code/crate"
        try makeDir("\(crate)/target/debug")
        try touch("\(crate)/Cargo.toml")
        try touch("\(crate)/target/CACHEDIR.TAG")
        XCTAssertTrue(FileManager.default.createFile(
            atPath: "\(crate)/target/debug/lib.rlib",
            contents: Data(repeating: 0x61, count: 64 * 1024)
        ))
        let web = "\(home)/code/web"
        try makeDir("\(web)/node_modules/dep")
        try touch("\(web)/package.json")
        XCTAssertTrue(FileManager.default.createFile(
            atPath: "\(web)/node_modules/dep/index.js",
            contents: Data(repeating: 0x61, count: 64 * 1024)
        ))

        let engine = ScanEngine(homeDirectory: URL(fileURLWithPath: home))
        let rust = await engine.scanCategory(.rustTargets)
        try FileManager.default.removeItem(atPath: "\(web)/package.json")
        let node = await engine.scanCategory(.nodeModules)

        XCTAssertEqual(rust.items.map(\.path), ["\(crate)/target"])
        XCTAssertEqual(node.items.map(\.path), ["\(web)/node_modules"])

        let rescan = await engine.scanCategory(.nodeModules)
        XCTAssertTrue(rescan.items.isEmpty)
    }

    func testCleaningRemovesValidatedNodeModules() async throws {
        let home = try makeHome()
        let project = "\(home)/code/web"
        try makeDir("\(project)/node_modules/dep")
        try touch("\(project)/package.json")
        let item = CleanableItem(
            name: "~/code/web",
            path: "\(project)/node_modules",
            size: 10,
            category: .nodeModules,
            isSelected: true,
            lastModified: nil
        )

        let result = await CleaningEngine(homeDirectory: URL(fileURLWithPath: home))
            .cleanItems([item]) { _ in }

        XCTAssertEqual(result.itemsCleaned, 1, "\(result.errors)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(project)/node_modules"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(project)/package.json"))
    }

    func testCleaningRefusesNodeModulesWithoutPackageJson() async throws {
        let home = try makeHome()
        let folder = "\(home)/Documents/keep/node_modules"
        try makeDir(folder)
        let item = CleanableItem(
            name: "keep",
            path: folder,
            size: 10,
            category: .nodeModules,
            isSelected: true,
            lastModified: nil
        )

        let result = await CleaningEngine(homeDirectory: URL(fileURLWithPath: home))
            .cleanItems([item]) { _ in }

        XCTAssertEqual(result.itemsCleaned, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder))
    }

    func testRustTargetIsCleanedWithCargo() async throws {
        let cargoPaths = [
            FileManager.default.homeDirectoryForCurrentUser.path + "/.cargo/bin/cargo",
            "/opt/homebrew/bin/cargo",
            "/usr/local/bin/cargo"
        ]
        guard let realCargo = cargoPaths.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw XCTSkip("cargo is not installed")
        }
        let home = try makeHome()
        try makeDir("\(home)/.cargo/bin")
        let rustc = URL(fileURLWithPath: realCargo).deletingLastPathComponent().appendingPathComponent("rustc")
        guard FileManager.default.isExecutableFile(atPath: rustc.path) else { throw XCTSkip("rustc is not installed") }
        try FileManager.default.createSymbolicLink(atPath: "\(home)/.cargo/bin/cargo", withDestinationPath: realCargo)
        try FileManager.default.createSymbolicLink(atPath: "\(home)/.cargo/bin/rustc", withDestinationPath: rustc.path)
        // rustup resolves its toolchains through RUSTUP_HOME / CARGO_HOME,
        // which default to the fake home here; point them back at the real ones.
        let realHome = FileManager.default.homeDirectoryForCurrentUser.path
        setenv("RUSTUP_HOME", "\(realHome)/.rustup", 1)
        setenv("CARGO_HOME", "\(realHome)/.cargo", 1)
        addTeardownBlock {
            unsetenv("RUSTUP_HOME")
            unsetenv("CARGO_HOME")
        }

        let project = "\(home)/code/crate"
        try makeDir("\(project)/src")
        try Data("[package]\nname = \"crate\"\nversion = \"0.1.0\"\nedition = \"2021\"\n".utf8)
            .write(to: URL(fileURLWithPath: "\(project)/Cargo.toml"))
        try touch("\(project)/src/lib.rs")
        try makeDir("\(project)/target/debug")
        try Data("Signature: 8a477f597d28d172789f06886806bc55\n".utf8)
            .write(to: URL(fileURLWithPath: "\(project)/target/CACHEDIR.TAG"))
        let otherTarget = "\(home)/code/shared-target"
        try makeDir(otherTarget)
        try touch("\(otherTarget)/keep")
        try makeDir("\(project)/.cargo")
        try Data("[build]\ntarget-dir = \"\(otherTarget)\"\n".utf8)
            .write(to: URL(fileURLWithPath: "\(project)/.cargo/config.toml"))
        let item = CleanableItem(
            name: "~/code/crate",
            path: "\(project)/target",
            size: 42,
            category: .rustTargets,
            isSelected: true,
            lastModified: nil
        )

        let result = await CleaningEngine(homeDirectory: URL(fileURLWithPath: home))
            .cleanItems([item]) { _ in }

        XCTAssertEqual(result.itemsCleaned, 1, "\(result.errors)")
        XCTAssertEqual(result.freedSpace, 42)
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(project)/target"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(project)/Cargo.toml"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(otherTarget)/keep"))
        XCTAssertEqual(result.receiptRows.map(\.disposition), [.completed])
    }
}
