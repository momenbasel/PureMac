import XCTest
@testable import puremac

final class PureMacTests: XCTestCase {
    let home = FileManager.default.homeDirectoryForCurrentUser.path

    func testMemoryFormattingUsesBinaryUnits() {
        XCTAssertEqual(ByteCount.memory(51_539_607_552), "48 GB")
        XCTAssertEqual(ByteCount.memory(17_179_869_184), "16 GB")
        XCTAssertEqual(ByteCount.memory(536_870_912), "512 MB")
        XCTAssertEqual(ByteCount.memory(1_610_612_736), "1.5 GB")
        XCTAssertEqual(ByteCount.memory(1_000_000), "976.6 KB")
        XCTAssertEqual(ByteCount.memory(1_024), "1 KB")
        XCTAssertEqual(ByteCount.memory(1_023), "1023 bytes")
        XCTAssertEqual(ByteCount.memory(0), "Zero KB")
        XCTAssertEqual(ByteCount.human(51_539_607_552), "51.5 GB")
    }

    func testByteCountFormatting() {
        XCTAssertEqual(ByteCount.human(0), "Zero KB")
        XCTAssertEqual(ByteCount.human(1_000), "1 KB")
        XCTAssertEqual(ByteCount.human(631_000), "631 KB")
        XCTAssertEqual(ByteCount.human(23_790_000_000), "23.8 GB")
        XCTAssertEqual(ByteCount.human(358_700_000), "358.7 MB")
    }

    func testArtifactMatching() {
        XCTAssertTrue(Purger.isArtifact("node_modules"))
        XCTAssertTrue(Purger.isArtifact(".venv"))
        XCTAssertTrue(Purger.isArtifact("cmake-build-debug"))
        XCTAssertFalse(Purger.isArtifact("src"))
        XCTAssertFalse(Purger.isArtifact("vendor"))
    }

    func testSafetyBlocksCriticalRoots() {
        let ig = IgnoreStore()
        XCTAssertFalse(Safety.canRemove("/", ignore: ig).ok)
        XCTAssertFalse(Safety.canRemove(home, ignore: ig).ok)
        XCTAssertFalse(Safety.canRemove("\(home)/Library/Caches", ignore: ig).ok)
        XCTAssertFalse(Safety.canRemove("\(home)/Library", ignore: ig).ok)
    }

    func testSafetyBlocksProviderState() {
        let ig = IgnoreStore()
        XCTAssertFalse(Safety.canRemove("\(home)/Library/Mobile Documents/x", ignore: ig).ok)
        XCTAssertTrue(Safety.isProviderOwned("\(home)/Library/CloudStorage/Dropbox/f"))
        XCTAssertTrue(Safety.isProviderOwned("\(home)/anything/com~apple~CloudDocs/x"))
    }

    func testSafetyBlocksCredentialDirs() {
        let ig = IgnoreStore()
        for dir in [".ssh", ".aws", ".gnupg", ".kube", ".docker", ".claude", ".config", ".cargo"] {
            XCTAssertFalse(Safety.canRemove("\(home)/\(dir)", ignore: ig).ok, "\(dir) must be protected")
        }
        XCTAssertFalse(Safety.isCredentialRoot("\(home)/.docker/buildx/cache"))
    }

    func testValidScanRootRejectsSystemPaths() {
        XCTAssertFalse(Safety.isValidScanRoot("/").ok)
        XCTAssertFalse(Safety.isValidScanRoot("/Library").ok)
        XCTAssertFalse(Safety.isValidScanRoot(home).ok)
        XCTAssertFalse(Safety.isValidScanRoot("\(home)/Library").ok)
    }

    func testCleanerRefusesSymlinkedParent() throws {
        let fm = FileManager.default
        let base = NSTemporaryDirectory() + "pm-symtest-\(getpid())"
        let victim = base + "/victim"
        let victimChild = victim + "/child"
        let link = base + "/link"
        try fm.createDirectory(atPath: victimChild, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: link, withDestinationPath: victim)
        defer { try? fm.removeItem(atPath: base) }

        XCTAssertTrue(Cleaner.parentHasSymlink(link + "/child"))

        let item = ScanItem(path: link + "/child", sizeBytes: 4096, modified: nil)
        let out = Cleaner.remove([item], ignore: IgnoreStore(), dryRun: false)
        XCTAssertEqual(out.removed, 0)
        XCTAssertEqual(out.skipped.count, 1)
        XCTAssertTrue(fm.fileExists(atPath: victimChild), "victim must survive a symlinked-parent delete")
    }

    func testSafetyHonorsIgnoreList() throws {

        let tmp = NSTemporaryDirectory() + "puremac-test-\(getpid())"
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let ignoreFile = URL(fileURLWithPath: tmp).appendingPathComponent("ignore")
        var ig = try IgnoreStore(fileURL: ignoreFile)

        XCTAssertTrue(Safety.canRemove(tmp, ignore: ig).ok)
        _ = try ig.add(tmp)
        XCTAssertFalse(Safety.canRemove(tmp, ignore: ig).ok)
        _ = try ig.remove(tmp)
    }

    func testCountedUsesTheSingularOnlyForOne() {
        XCTAssertEqual(Render.counted(0, "item"), "0 items")
        XCTAssertEqual(Render.counted(1, "folder"), "1 folder")
        XCTAssertEqual(Render.counted(2, "core"), "2 cores")
    }
}
