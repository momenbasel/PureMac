import Darwin
import XCTest
@testable import PureMac

private actor MutationLeaseProbe {
    private(set) var acquired = false
    private(set) var failure: String?

    func recordAcquired() {
        acquired = true
    }

    func recordFailure(_ error: Error) {
        failure = error.localizedDescription
    }
}

final class SecureDeletionTests: XCTestCase {
    private var containerURL: URL!
    private var allowedURL: URL!
    private var outsideURL: URL!
    private var stagingURL: URL!
    private var policy: SecureDeletionPolicy!
    private var deleter: SecureFileDeleter!

    override func setUpWithError() throws {
        try super.setUpWithError()
        containerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PureMacSecureDeletionTests-\(UUID().uuidString)", isDirectory: true)
        allowedURL = containerURL.appendingPathComponent("allowed", isDirectory: true)
        outsideURL = containerURL.appendingPathComponent("outside", isDirectory: true)
        stagingURL = containerURL.appendingPathComponent("privileged-staging", isDirectory: true)
        try FileManager.default.createDirectory(at: allowedURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideURL, withIntermediateDirectories: true)

        let basePolicy = SecureDeletionPolicy(
            userID: getuid(),
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path
        )
        let canonicalAllowed = try basePolicy.canonicalPath(allowedURL.path)
        policy = SecureDeletionPolicy(
            userID: getuid(),
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
            cleanerRootsOverride: [
                .init(path: canonicalAllowed, mayDeleteRoot: false),
            ],
            largeFileRootsOverride: []
        )
        deleter = SecureFileDeleter(policy: policy)
    }

    override func tearDownWithError() throws {
        if let containerURL {
            try? FileManager.default.removeItem(at: containerURL)
        }
        try super.tearDownWithError()
    }

    func testRemovesUnchangedFileWithMatchingIdentityAndShellCharacters() throws {
        let victim = allowedURL.appendingPathComponent("cache 'line\n\u{24}(touch nope).bin")
        try Data("payload".utf8).write(to: victim)

        try deleter.remove(try request(for: victim))

        XCTAssertFalse(FileManager.default.fileExists(atPath: victim.path))
    }

    func testRejectsLeafReplacedWithSymlink() throws {
        let victim = allowedURL.appendingPathComponent("victim")
        let movedOriginal = allowedURL.appendingPathComponent("original")
        let canary = outsideURL.appendingPathComponent("canary")
        try Data("original".utf8).write(to: victim)
        try Data("keep".utf8).write(to: canary)
        let request = try request(for: victim)

        try FileManager.default.moveItem(at: victim, to: movedOriginal)
        try FileManager.default.createSymbolicLink(at: victim, withDestinationURL: canary)

        XCTAssertThrowsError(try deleter.remove(request)) { error in
            guard case SecureDeletionError.identityChanged = error else {
                return XCTFail("Expected identityChanged, got \(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: canary), "keep")
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedOriginal.path))
    }

    func testRejectsIntermediateComponentReplacedWithSymlink() throws {
        let parent = allowedURL.appendingPathComponent("parent", isDirectory: true)
        let movedParent = allowedURL.appendingPathComponent("parent-original", isDirectory: true)
        let victim = parent.appendingPathComponent("victim")
        let outsideVictim = outsideURL.appendingPathComponent("victim")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try Data("original".utf8).write(to: victim)
        try Data("keep".utf8).write(to: outsideVictim)
        let request = try request(for: victim)

        try FileManager.default.moveItem(at: parent, to: movedParent)
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: outsideURL)

        XCTAssertThrowsError(try deleter.remove(request))
        XCTAssertEqual(try String(contentsOf: outsideVictim), "keep")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: movedParent.appendingPathComponent("victim").path
        ))
    }

    func testRejectsRecreatedPathWithDifferentInode() throws {
        let victim = allowedURL.appendingPathComponent("victim")
        try Data("same-size".utf8).write(to: victim)
        let request = try request(for: victim)

        try FileManager.default.removeItem(at: victim)
        try Data("same-size".utf8).write(to: victim)

        XCTAssertThrowsError(try deleter.remove(request)) { error in
            guard case SecureDeletionError.identityChanged = error else {
                return XCTFail("Expected identityChanged, got \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: victim.path))
    }

    func testRejectsDirectoryReplacement() throws {
        let victim = allowedURL.appendingPathComponent("victim", isDirectory: true)
        let movedOriginal = allowedURL.appendingPathComponent("original", isDirectory: true)
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: victim.appendingPathComponent("old"))
        let request = try request(for: victim)

        try FileManager.default.moveItem(at: victim, to: movedOriginal)
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: victim.appendingPathComponent("keep"))

        XCTAssertThrowsError(try deleter.remove(request)) { error in
            guard case SecureDeletionError.identityChanged = error else {
                return XCTFail("Expected identityChanged, got \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: victim.appendingPathComponent("keep").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedOriginal.appendingPathComponent("old").path))
    }

    func testRecursiveRemovalUnlinksChildSymlinkWithoutFollowingIt() throws {
        let victim = allowedURL.appendingPathComponent("victim", isDirectory: true)
        let canary = outsideURL.appendingPathComponent("canary")
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: canary)
        try FileManager.default.createSymbolicLink(
            at: victim.appendingPathComponent("outside-link"),
            withDestinationURL: outsideURL
        )

        try deleter.remove(try request(for: victim))

        XCTAssertFalse(FileManager.default.fileExists(atPath: victim.path))
        XCTAssertEqual(try String(contentsOf: canary), "keep")
    }

    func testRecursiveRemovalHandlesFIFOWithoutFollowingOrOpeningIt() throws {
        let victim = allowedURL.appendingPathComponent("victim", isDirectory: true)
        let fifo = victim.appendingPathComponent("worker.sock")
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        XCTAssertEqual(Darwin.mkfifo(fifo.path, mode_t(0o600)), 0)
        try Data("payload".utf8).write(to: victim.appendingPathComponent("regular"))

        try deleter.remove(try request(for: victim))

        XCTAssertFalse(FileManager.default.fileExists(atPath: victim.path))
    }

    func testReenumeratesDirectoryFromStartAfterConcurrentInsertion() throws {
        let victim = allowedURL.appendingPathComponent("victim", isDirectory: true)
        let lateEntry = victim.appendingPathComponent("arrived-after-enumeration")
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        let injection = OneShotGate()
        let racingDeleter = SecureFileDeleter(
            policy: policy,
            beforeDirectoryUnlink: { path in
                guard path == victim.path, injection.claim() else { return }
                try Data("late".utf8).write(to: lateEntry)
            }
        )

        try racingDeleter.remove(try request(for: victim))

        XCTAssertFalse(FileManager.default.fileExists(atPath: victim.path))
    }

    func testInitialTopLevelAbsenceHasDedicatedMissingResult() throws {
        let victim = allowedURL.appendingPathComponent("victim")
        try Data("payload".utf8).write(to: victim)
        let scannedRequest = try request(for: victim)
        try FileManager.default.removeItem(at: victim)

        XCTAssertThrowsError(try deleter.remove(scannedRequest)) { error in
            guard case SecureDeletionError.topLevelMissing = error else {
                return XCTFail("Expected topLevelMissing, got \(error)")
            }
        }
    }

    func testInitialIntermediateAbsenceHasDedicatedMissingResult() throws {
        let parent = allowedURL.appendingPathComponent("parent", isDirectory: true)
        let victim = parent.appendingPathComponent("victim")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: victim)
        let scannedRequest = try request(for: victim)
        try FileManager.default.removeItem(at: parent)

        XCTAssertThrowsError(try deleter.remove(scannedRequest)) { error in
            guard case SecureDeletionError.topLevelMissing = error else {
                return XCTFail("Expected topLevelMissing, got \(error)")
            }
        }
    }

    func testIdentityLookupDistinguishesMissingFromLookupFailure() {
        let absent = allowedURL.appendingPathComponent("definitely-absent")

        guard case .missing = FileIdentity.lookup(path: absent.path) else {
            return XCTFail("Expected an errno-aware missing lookup result")
        }

        let deniedDirectory = allowedURL.appendingPathComponent("denied", isDirectory: true)
        let hiddenFile = deniedDirectory.appendingPathComponent("item")
        do {
            try FileManager.default.createDirectory(
                at: deniedDirectory,
                withIntermediateDirectories: true
            )
            try Data("payload".utf8).write(to: hiddenFile)
            XCTAssertEqual(Darwin.chmod(deniedDirectory.path, mode_t(0)), 0)
            defer { _ = Darwin.chmod(deniedDirectory.path, mode_t(S_IRWXU)) }

            guard case let .failed(code) = FileIdentity.lookup(path: hiddenFile.path) else {
                return XCTFail("Expected an errno-aware lookup failure")
            }
            XCTAssertEqual(code, EACCES)
        } catch {
            XCTFail("Could not prepare denied lookup fixture: \(error)")
        }
    }

    func testPrivilegedQuarantineRemovesIdentityBoundEntryAndCleansStagingDirectory() throws {
        let victim = allowedURL.appendingPathComponent("victim", isDirectory: true)
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: victim.appendingPathComponent("nested"))
        let quarantinedDeleter = SecureFileDeleter(
            policy: policy,
            isolation: .privilegedQuarantine,
            privilegedStagingRootPathOverride: stagingURL.path
        )

        try quarantinedDeleter.remove(try request(for: victim))

        XCTAssertFalse(FileManager.default.fileExists(atPath: victim.path))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: stagingURL.path),
            []
        )
    }

    func testPrivilegedQuarantineValidatesIdentityAfterAtomicRename() throws {
        let victim = allowedURL.appendingPathComponent("victim")
        let original = allowedURL.appendingPathComponent("original")
        let canary = outsideURL.appendingPathComponent("canary")
        try Data("original".utf8).write(to: victim)
        try Data("keep".utf8).write(to: canary)
        let scannedRequest = try request(for: victim)
        let quarantinedDeleter = SecureFileDeleter(
            policy: policy,
            isolation: .privilegedQuarantine,
            beforeQuarantineRename: {
                try FileManager.default.moveItem(at: victim, to: original)
                try FileManager.default.createSymbolicLink(at: victim, withDestinationURL: canary)
            },
            privilegedStagingRootPathOverride: stagingURL.path
        )

        XCTAssertThrowsError(try quarantinedDeleter.remove(scannedRequest)) { error in
            guard case SecureDeletionError.identityChanged = error else {
                return XCTFail("Expected identityChanged, got \(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: canary), "keep")
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertEqual(FileIdentity.capture(path: victim.path)?.isSymbolicLink, true)
    }

    func testPrivilegedQuarantineRestoresAfterPostRenameFailure() throws {
        let victim = allowedURL.appendingPathComponent("victim")
        try Data("original".utf8).write(to: victim)
        let scannedRequest = try request(for: victim)
        let quarantinedDeleter = SecureFileDeleter(
            policy: policy,
            isolation: .privilegedQuarantine,
            afterQuarantineRename: {
                throw InjectedDeletionError.afterRename
            },
            privilegedStagingRootPathOverride: stagingURL.path
        )

        XCTAssertThrowsError(try quarantinedDeleter.remove(scannedRequest))
        XCTAssertEqual(try String(contentsOf: victim), "original")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: stagingURL.path),
            []
        )
    }

    func testPrivilegedQuarantineStripsInheritedACLBeforeStaging() throws {
        let victim = allowedURL.appendingPathComponent("victim")
        try Data("payload".utf8).write(to: victim)
        try runChmod([
            "+a",
            "everyone allow list,search,add_file,add_subdirectory,delete_child,file_inherit,directory_inherit",
            containerURL.path,
        ])
        defer { try? runChmod(["-N", containerURL.path]) }

        let stagingPath = stagingURL.path
        let quarantinedDeleter = SecureFileDeleter(
            policy: policy,
            isolation: .privilegedQuarantine,
            beforeQuarantineRename: {
                let quarantineName = try XCTUnwrap(
                    FileManager.default.contentsOfDirectory(atPath: stagingPath)
                        .first { $0.hasPrefix(".puremac-delete-") }
                )
                let quarantinePath = (stagingPath as NSString)
                    .appendingPathComponent(quarantineName)
                let descriptor = Darwin.open(
                    quarantinePath,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
                XCTAssertGreaterThanOrEqual(descriptor, 0)
                guard descriptor >= 0 else { return }
                defer { Darwin.close(descriptor) }

                errno = 0
                let inheritedACL = Darwin.acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED)
                if let inheritedACL {
                    Darwin.acl_free(UnsafeMutableRawPointer(inheritedACL))
                }
                XCTAssertNil(inheritedACL)
                XCTAssertEqual(errno, ENOENT)
            },
            privilegedStagingRootPathOverride: stagingURL.path
        )

        try quarantinedDeleter.remove(try request(for: victim))

        XCTAssertFalse(FileManager.default.fileExists(atPath: victim.path))
    }

    func testRecoveryRestoresPreparedQuarantineTransaction() throws {
        let victim = allowedURL.appendingPathComponent("prepared-victim")
        try Data("original".utf8).write(to: victim)
        let fixture = try makeRecoveryFixture(state: .prepared, victim: victim)

        XCTAssertFalse(FileManager.default.fileExists(atPath: victim.path))
        try fixture.deleter.recoverPendingQuarantines()

        XCTAssertEqual(try String(contentsOf: victim), "original")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: stagingURL.path),
            []
        )
    }

    func testRecoveryFinishesCommittedQuarantineTransaction() throws {
        let victim = allowedURL.appendingPathComponent("committed-victim", isDirectory: true)
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        try Data("first".utf8).write(to: victim.appendingPathComponent("first"))
        try Data("second".utf8).write(to: victim.appendingPathComponent("second"))
        let fixture = try makeRecoveryFixture(state: .committed, victim: victim)

        // Model a helper crash after recursive deletion already removed one
        // child. COMMITTED recovery must continue; it must never restore a
        // partially deleted tree into the user's namespace.
        try FileManager.default.removeItem(
            at: fixture.quarantineURL
                .appendingPathComponent("item", isDirectory: true)
                .appendingPathComponent("first")
        )
        try fixture.deleter.recoverPendingQuarantines()

        XCTAssertFalse(FileManager.default.fileExists(atPath: victim.path))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: stagingURL.path),
            []
        )
    }

    func testPreparedRecoveryPreservesCollidingSourceEntry() throws {
        let victim = allowedURL.appendingPathComponent("collision-victim")
        try Data("original".utf8).write(to: victim)
        let fixture = try makeRecoveryFixture(state: .prepared, victim: victim)
        try Data("racer".utf8).write(to: victim)

        try fixture.deleter.recoverPendingQuarantines()

        XCTAssertEqual(try String(contentsOf: victim), "original")
        let recoveredName = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(atPath: allowedURL.path)
                .first { $0.hasPrefix(".puremac-recovered-") }
        )
        XCTAssertEqual(
            try String(contentsOf: allowedURL.appendingPathComponent(recoveredName)),
            "racer"
        )
    }

    func testRecoveryNeverDeletesMismatchedCommittedEntry() throws {
        let victim = allowedURL.appendingPathComponent("mismatched-victim")
        try Data("original".utf8).write(to: victim)
        let fixture = try makeRecoveryFixture(state: .committed, victim: victim)
        let staged = fixture.quarantineURL.appendingPathComponent("item")
        try FileManager.default.removeItem(at: staged)
        try Data("replacement".utf8).write(to: staged)

        XCTAssertThrowsError(try fixture.deleter.recoverPendingQuarantines()) { error in
            guard case SecureDeletionError.quarantineRecoveryFailed = error else {
                return XCTFail("Expected quarantineRecoveryFailed, got \(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: staged), "replacement")
        XCTAssertFalse(FileManager.default.fileExists(atPath: victim.path))
    }

    func testDepthLimitFailsSafelyBeforeFileDescriptorExhaustion() throws {
        let victim = allowedURL.appendingPathComponent("victim", isDirectory: true)
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        var deepest = victim
        for index in 0..<66 {
            deepest.appendPathComponent("d\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: deepest, withIntermediateDirectories: false)
        }

        XCTAssertThrowsError(try deleter.remove(try request(for: victim))) { error in
            guard case SecureDeletionError.traversalLimitExceeded = error else {
                return XCTFail("Expected traversalLimitExceeded, got \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: victim.path))
    }

    func testRejectsExpectedDeviceMismatch() throws {
        let victim = allowedURL.appendingPathComponent("victim")
        try Data("payload".utf8).write(to: victim)
        let original = try XCTUnwrap(identity(for: victim))
        let changed = FileIdentity(
            device: original.device &+ 1,
            inode: original.inode,
            fileType: original.fileType,
            owner: original.owner,
            generation: original.generation,
            birthtimeSeconds: original.birthtimeSeconds,
            birthtimeNanoseconds: original.birthtimeNanoseconds
        )

        let request = PrivilegedDeletionRequest(
            path: victim.path,
            identity: changed,
            operation: .cleaner
        )
        XCTAssertThrowsError(try deleter.remove(request))
        XCTAssertTrue(FileManager.default.fileExists(atPath: victim.path))
    }

    func testRejectsChangedOwnerInRequest() throws {
        let victim = allowedURL.appendingPathComponent("victim")
        try Data("payload".utf8).write(to: victim)
        let original = try XCTUnwrap(identity(for: victim))
        let changed = FileIdentity(
            device: original.device,
            inode: original.inode,
            fileType: original.fileType,
            owner: UInt32(getuid()) &+ 1,
            generation: original.generation,
            birthtimeSeconds: original.birthtimeSeconds,
            birthtimeNanoseconds: original.birthtimeNanoseconds
        )

        let request = PrivilegedDeletionRequest(
            path: victim.path,
            identity: changed,
            operation: .cleaner
        )
        XCTAssertThrowsError(try deleter.remove(request))
        XCTAssertTrue(FileManager.default.fileExists(atPath: victim.path))
    }

    func testRejectsAllowlistRootSiblingAndDotComponents() throws {
        let canonicalAllowed = try policy.canonicalPath(allowedURL.path)
        let rootIdentity = try XCTUnwrap(FileIdentity.capture(path: canonicalAllowed))
        let rootRequest = PrivilegedDeletionRequest(
            path: allowedURL.path,
            identity: rootIdentity,
            operation: .cleaner
        )
        XCTAssertThrowsError(try policy.validate(rootRequest))

        let sibling = containerURL.appendingPathComponent("allowed-evil")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let siblingRequest = try request(for: sibling)
        XCTAssertThrowsError(try policy.validate(siblingRequest))

        let dotPath = allowedURL.path + "/../outside/canary"
        let dotRequest = PrivilegedDeletionRequest(
            path: dotPath,
            identity: rootIdentity,
            operation: .cleaner
        )
        XCTAssertThrowsError(try policy.validate(dotRequest))
    }

    func testMostSpecificAllowlistRootControlsWhetherRootItselfMayBeDeleted() throws {
        let specificPolicy = SecureDeletionPolicy(
            userID: getuid(),
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
            cleanerRootsOverride: [
                .init(path: containerURL.path, mayDeleteRoot: true),
                .init(path: allowedURL.path, mayDeleteRoot: false),
            ],
            largeFileRootsOverride: []
        )
        let identity = try XCTUnwrap(FileIdentity.capture(path: allowedURL.path))
        let rootRequest = PrivilegedDeletionRequest(
            path: allowedURL.path,
            identity: identity,
            operation: .cleaner
        )

        XCTAssertThrowsError(try specificPolicy.validate(rootRequest)) { error in
            guard case SecureDeletionError.outsideAllowlist = error else {
                return XCTFail("Expected outsideAllowlist, got \(error)")
            }
        }
    }

    func testDefaultUninstallPolicyAllowsAppsButNotBundlesNestedInsideApps() throws {
        let defaultPolicy = SecureDeletionPolicy(
            userID: getuid(),
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path
        )
        let directoryIdentity = try XCTUnwrap(FileIdentity.capture(path: allowedURL.path))
        let app = PrivilegedDeletionRequest(
            path: "/Applications/Utilities/Example.app",
            identity: directoryIdentity,
            operation: .uninstall
        )
        XCTAssertNoThrow(try defaultPolicy.validate(app))

        let nestedHelper = PrivilegedDeletionRequest(
            path: "/Applications/Example.app/Contents/Library/LoginItems/Helper.app",
            identity: directoryIdentity,
            operation: .uninstall
        )
        XCTAssertThrowsError(try defaultPolicy.validate(nestedHelper))
    }

    func testDefaultLargeFilePolicyRequiresARegularFileInUserDocumentRoots() throws {
        let defaultPolicy = SecureDeletionPolicy(
            userID: getuid(),
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path
        )
        let file = allowedURL.appendingPathComponent("large")
        try Data("payload".utf8).write(to: file)
        let regularIdentity = try XCTUnwrap(FileIdentity.capture(path: file.path))
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let allowedRequest = PrivilegedDeletionRequest(
            path: "\(home)/Downloads/archive.bin",
            identity: regularIdentity,
            operation: .largeFile
        )
        XCTAssertNoThrow(try defaultPolicy.validate(allowedRequest))

        let directoryIdentity = try XCTUnwrap(FileIdentity.capture(path: allowedURL.path))
        let directoryRequest = PrivilegedDeletionRequest(
            path: "\(home)/Downloads/folder",
            identity: directoryIdentity,
            operation: .largeFile
        )
        XCTAssertThrowsError(try defaultPolicy.validate(directoryRequest))
    }

    func testRejectsPathWhoseBytesPlusTerminatorExceedPATHMAX() throws {
        let tooLong = "/" + String(repeating: "a", count: Int(PATH_MAX) - 1)
        XCTAssertThrowsError(try policy.canonicalPath(tooLong))
    }

    func testPrivilegedClientChunksLargeRequestSetsWithoutDroppingOrder() throws {
        let identity = try XCTUnwrap(FileIdentity.capture(path: allowedURL.path))
        let requests = (0..<513).map { index in
            PrivilegedDeletionRequest(
                path: allowedURL.appendingPathComponent("item-\(index)").path,
                identity: identity,
                operation: .cleaner
            )
        }

        let batches = PrivilegedCleaningClient.batches(for: requests)

        XCTAssertEqual(batches.count, 5)
        XCTAssertTrue(batches.allSatisfy {
            $0.count <= PrivilegedCleaningConstants.maximumBatchCount
        })
        XCTAssertEqual(batches.flatMap { $0 }.map(\.id), requests.map(\.id))
    }

    func testFilesystemMutationCoordinatorWaitsForAnotherProcess() async throws {
        let lockDirectory = containerURL.appendingPathComponent(
            "mutation-lock",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: lockDirectory,
            withIntermediateDirectories: true
        )
        let lockURL = lockDirectory.appendingPathComponent("filesystem-mutation.lock")
        let childInput = Pipe()
        let childOutput = Pipe()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = [
            "-c",
            """
            import fcntl, os, sys
            fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o600)
            fcntl.lockf(fd, fcntl.LOCK_EX)
            sys.stdout.write("ready\\n")
            sys.stdout.flush()
            sys.stdin.readline()
            fcntl.lockf(fd, fcntl.LOCK_UN)
            os.close(fd)
            """,
            lockURL.path,
        ]
        child.standardInput = childInput
        child.standardOutput = childOutput
        child.standardError = childOutput
        try child.run()
        defer {
            if child.isRunning { child.terminate() }
            child.waitUntilExit()
        }

        let readyData = childOutput.fileHandleForReading.availableData
        XCTAssertEqual(String(data: readyData, encoding: .utf8), "ready\n")

        let coordinator = FilesystemMutationCoordinator(
            lockDirectoryURL: lockDirectory
        )
        let probe = MutationLeaseProbe()
        let acquisitionTask = Task {
            do {
                try await coordinator.acquire()
                await probe.recordAcquired()
                await coordinator.release()
            } catch {
                await probe.recordFailure(error)
            }
        }

        try await Task.sleep(nanoseconds: 150_000_000)
        let acquiredWhileChildHeldLock = await probe.acquired
        XCTAssertFalse(acquiredWhileChildHeldLock)

        childInput.fileHandleForWriting.write(Data("release\n".utf8))
        childInput.fileHandleForWriting.closeFile()
        await acquisitionTask.value
        child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0)

        let acquiredAfterRelease = await probe.acquired
        let acquisitionFailure = await probe.failure
        XCTAssertTrue(acquiredAfterRelease)
        XCTAssertNil(acquisitionFailure)
    }

    func testPrivilegedClientRejectsReorderedDuplicateOrMismatchedResponses() throws {
        let identity = try XCTUnwrap(FileIdentity.capture(path: allowedURL.path))
        let first = PrivilegedDeletionRequest(
            path: allowedURL.appendingPathComponent("first").path,
            identity: identity,
            operation: .cleaner
        )
        let second = PrivilegedDeletionRequest(
            path: allowedURL.appendingPathComponent("second").path,
            identity: identity,
            operation: .cleaner
        )
        let requests = [first, second]
        let firstResponse = PrivilegedDeletionResponse(
            requestID: first.id,
            path: first.path,
            status: .deleted,
            message: nil
        )
        let secondResponse = PrivilegedDeletionResponse(
            requestID: second.id,
            path: second.path,
            status: .deleted,
            message: nil
        )
        let wrongPath = PrivilegedDeletionResponse(
            requestID: second.id,
            path: first.path,
            status: .deleted,
            message: nil
        )

        XCTAssertTrue(PrivilegedCleaningClient.responsesAreValid(
            [firstResponse, secondResponse],
            for: requests
        ))
        XCTAssertFalse(PrivilegedCleaningClient.responsesAreValid(
            [secondResponse, firstResponse],
            for: requests
        ))
        XCTAssertFalse(PrivilegedCleaningClient.responsesAreValid(
            [firstResponse, firstResponse],
            for: requests
        ))
        XCTAssertFalse(PrivilegedCleaningClient.responsesAreValid(
            [firstResponse, wrongPath],
            for: requests
        ))
    }

    func testPrivilegedClientValidatesBatchCorrelationAndDispositionMatrix() throws {
        let identity = try XCTUnwrap(FileIdentity.capture(path: allowedURL.path))
        let request = PrivilegedDeletionRequest(
            path: allowedURL.appendingPathComponent("item").path,
            identity: identity,
            operation: .cleaner
        )
        let batchID = UUID()
        let terminal = PrivilegedDeletionResponse(
            requestID: request.id,
            path: request.path,
            status: .deleted,
            message: nil
        )
        let unknown = PrivilegedDeletionResponse(
            requestID: request.id,
            path: request.path,
            status: .unknown,
            message: "lost reply"
        )

        XCTAssertTrue(PrivilegedCleaningClient.batchResponseIsValid(
            PrivilegedDeletionBatchResponse(batchID: batchID, responses: [terminal]),
            batchID: batchID,
            requests: [request]
        ))
        XCTAssertFalse(PrivilegedCleaningClient.batchResponseIsValid(
            PrivilegedDeletionBatchResponse(batchID: UUID(), responses: [terminal]),
            batchID: batchID,
            requests: [request]
        ))
        XCTAssertFalse(PrivilegedCleaningClient.batchResponseIsValid(
            PrivilegedDeletionBatchResponse(batchID: batchID, responses: [unknown]),
            batchID: batchID,
            requests: [request]
        ))
        XCTAssertTrue(PrivilegedCleaningClient.batchResponseIsValid(
            PrivilegedDeletionBatchResponse(
                batchID: batchID,
                disposition: .notAccepted,
                message: "busy",
                responses: []
            ),
            batchID: batchID,
            requests: [request]
        ))
        XCTAssertFalse(PrivilegedCleaningClient.batchResponseIsValid(
            PrivilegedDeletionBatchResponse(
                batchID: batchID,
                disposition: .notAccepted,
                message: "busy",
                responses: [terminal]
            ),
            batchID: batchID,
            requests: [request]
        ))
    }

    func testPrivilegedDTOsRoundTripSecurityPolicyVersionAndUnknownStatus() throws {
        let identity = try XCTUnwrap(FileIdentity.capture(path: allowedURL.path))
        let request = PrivilegedDeletionRequest(
            path: allowedURL.appendingPathComponent("item").path,
            identity: identity,
            operation: .cleaner
        )
        let batch = PrivilegedDeletionBatch(
            requests: [request],
            authorization: Data(repeating: 7, count: 32),
            deadline: Date().addingTimeInterval(30)
        )
        let decodedBatch = try PropertyListDecoder().decode(
            PrivilegedDeletionBatch.self,
            from: PropertyListEncoder().encode(batch)
        )
        XCTAssertEqual(
            decodedBatch.securityPolicyVersion,
            PrivilegedCleaningConstants.securityPolicyVersion
        )
        XCTAssertEqual(decodedBatch.id, batch.id)

        let response = PrivilegedDeletionBatchResponse(
            batchID: batch.id,
            responses: [
                PrivilegedDeletionResponse(
                    requestID: request.id,
                    path: request.path,
                    status: .unknown,
                    message: "lost reply"
                ),
            ]
        )
        let decodedResponse = try PropertyListDecoder().decode(
            PrivilegedDeletionBatchResponse.self,
            from: PropertyListEncoder().encode(response)
        )
        XCTAssertEqual(decodedResponse.batchID, batch.id)
        XCTAssertEqual(decodedResponse.disposition.rawValue, "completed")
        XCTAssertEqual(decodedResponse.responses.first?.status, .unknown)
        XCTAssertEqual(
            decodedResponse.securityPolicyVersion,
            PrivilegedCleaningConstants.securityPolicyVersion
        )

        let info = PrivilegedCleaningServiceInfo(
            recoveryState: .recovering,
            recoveryMessage: "restoring a prepared transaction"
        )
        let decodedInfo = try PropertyListDecoder().decode(
            PrivilegedCleaningServiceInfo.self,
            from: PropertyListEncoder().encode(info)
        )
        XCTAssertEqual(
            decodedInfo.securityPolicyVersion,
            PrivilegedCleaningConstants.securityPolicyVersion
        )
        XCTAssertEqual(
            decodedInfo.helperBundleIdentifier,
            PrivilegedCleaningConstants.helperBundleIdentifier
        )
        XCTAssertEqual(
            decodedInfo.protocolVersion,
            PrivilegedCleaningConstants.protocolVersion
        )
        XCTAssertEqual(decodedInfo.recoveryState, .recovering)
        XCTAssertEqual(
            decodedInfo.recoveryMessage,
            "restoring a prepared transaction"
        )
    }

    private func request(for url: URL) throws -> PrivilegedDeletionRequest {
        let identity = try XCTUnwrap(identity(for: url), "Missing lstat identity for \(url.path)")
        return PrivilegedDeletionRequest(path: url.path, identity: identity, operation: .cleaner)
    }

    private func identity(for url: URL) -> FileIdentity? {
        guard let path = try? policy.canonicalPath(url.path) else { return nil }
        return FileIdentity.capture(path: path)
    }

    private func makeRecoveryFixture(
        state: PrivilegedQuarantineJournal.State,
        victim: URL
    ) throws -> (deleter: SecureFileDeleter, quarantineURL: URL) {
        let deleter = SecureFileDeleter(
            policy: policy,
            isolation: .privilegedQuarantine,
            privilegedStagingRootPathOverride: stagingURL.path
        )
        try deleter.recoverPendingQuarantines()

        let canonicalPath = try policy.canonicalPath(victim.path)
        let scannedIdentity = try XCTUnwrap(FileIdentity.capture(path: canonicalPath))
        let request = PrivilegedDeletionRequest(
            path: canonicalPath,
            identity: scannedIdentity,
            operation: .cleaner
        )
        let validated = try policy.validatedRequest(request)
        let sourceParentPath = (canonicalPath as NSString).deletingLastPathComponent
        let sourceParentIdentity = try XCTUnwrap(
            FileIdentity.capture(path: sourceParentPath)
        )
        let transactionID = UUID()
        let quarantineName = "\(PrivilegedCleaningConstants.quarantineDirectoryPrefix)\(getuid())-\(transactionID.uuidString)"
        let quarantineURL = stagingURL.appendingPathComponent(
            quarantineName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: quarantineURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )

        let journal = PrivilegedQuarantineJournal(
            state: state,
            transactionID: transactionID,
            operationID: UUID(),
            initiatingUserID: getuid(),
            request: request,
            sourceParentPath: sourceParentPath,
            sourceParentIdentity: sourceParentIdentity,
            sourceName: (canonicalPath as NSString).lastPathComponent,
            boundaryPath: validated.boundaryPath,
            boundaryDevice: scannedIdentity.device
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let journalURL = quarantineURL.appendingPathComponent(
            PrivilegedQuarantineJournal.fileName
        )
        try encoder.encode(journal).write(to: journalURL)
        XCTAssertEqual(Darwin.chmod(journalURL.path, mode_t(0o600)), 0)
        try FileManager.default.moveItem(
            at: victim,
            to: quarantineURL.appendingPathComponent("item")
        )
        return (deleter, quarantineURL)
    }

    private func runChmod(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}

private enum InjectedDeletionError: Error {
    case afterRename
}

private final class OneShotGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}
