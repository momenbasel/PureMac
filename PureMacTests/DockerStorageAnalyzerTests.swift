import Darwin
import XCTest
@testable import PureMac

final class DockerStorageAnalyzerTests: XCTestCase {
    func testDockerNotInstalledIsExplicitAndDoesNotRunCommand() async {
        let recorder = DockerCommandRecorder(result: successfulDockerResult())
        let analyzer = DockerStorageAnalyzer(
            hostStorageRoots: [],
            executableLocator: { nil },
            commandRunner: { request in await recorder.run(request) }
        )

        let report = await analyzer.analyze()

        XCTAssertEqual(report.runtimeStatus, .notInstalled)
        XCTAssertNil(report.runtimeAccounting)
        XCTAssertNil(report.dockerExecutablePath)
        XCTAssertTrue(report.issues.contains { $0.kind == .executableNotFound })
        XCTAssertTrue(recorder.recordedRequests.isEmpty)
    }

    func testInstalledDockerWithUnavailableDaemonKeepsExplicitStatus() async {
        let recorder = DockerCommandRecorder(result: .init(
            terminationStatus: 1,
            stdout: "",
            stderr: "Cannot connect to the Docker daemon. Is the docker daemon running?",
            launchError: nil,
            wasCancelled: false
        ))
        let analyzer = makeDockerAnalyzer(roots: [], recorder: recorder)

        let report = await analyzer.analyze()

        XCTAssertEqual(report.runtimeStatus, .installedDaemonUnavailable)
        XCTAssertNil(report.runtimeAccounting)
        XCTAssertTrue(report.issues.contains { $0.kind == .daemonUnavailable })
        XCTAssertEqual(recorder.recordedRequests.count, 2)
    }

    func testAvailableDockerParsesAllRuntimeAccountingCategoriesAndCounts() async throws {
        let recorder = DockerCommandRecorder(result: successfulDockerResult())
        let report = await makeDockerAnalyzer(roots: [], recorder: recorder).analyze()
        let accounting = try XCTUnwrap(report.runtimeAccounting)

        XCTAssertEqual(report.runtimeStatus, .installedAndReachable)
        XCTAssertEqual(accounting.images?.totalBytes, 8_000_000_000)
        XCTAssertEqual(accounting.images?.objectCount, 10)
        XCTAssertEqual(accounting.images?.activeCount, 4)
        XCTAssertEqual(accounting.containers?.totalBytes, 2_000_000_000)
        XCTAssertEqual(accounting.localVolumes?.totalBytes, 4_000_000_000)
        XCTAssertEqual(accounting.buildCache?.totalBytes, 1_000_000_000)
        XCTAssertEqual(report.totalRuntimeReportedBytes, 15_000_000_000)
        XCTAssertTrue(accounting.isComplete)
    }

    func testMalformedDockerOutputReturnsPartialStatusWithoutFilesystemFailure() async {
        let recorder = DockerCommandRecorder(result: .init(
            terminationStatus: 0,
            stdout: """
            not-json
            {"Type":"Images","TotalCount":"1","Active":"0","Size":"not-a-size","Reclaimable":"0B (0%)"}
            """,
            stderr: "",
            launchError: nil,
            wasCancelled: false
        ))

        let report = await makeDockerAnalyzer(roots: [], recorder: recorder).analyze()

        XCTAssertEqual(report.runtimeStatus, .partiallyReadable)
        XCTAssertNil(report.runtimeAccounting?.images?.totalBytes)
        XCTAssertTrue(report.issues.contains { $0.kind == .malformedRuntimeOutput })
        XCTAssertEqual(report.hostFootprint.allocatedSize, 0)
    }

    func testHostDockerStorageIsReturnedWhenDaemonIsUnavailable() async throws {
        let temporaryDirectory = try DockerTestDirectory()
        let payload = temporaryDirectory.url.appendingPathComponent("host-storage.dat")
        try Data(repeating: 0x21, count: 65_536).write(to: payload)
        let recorder = DockerCommandRecorder(result: .init(
            terminationStatus: 1,
            stdout: "",
            stderr: "Cannot connect to the Docker daemon",
            launchError: nil,
            wasCancelled: false
        ))

        let report = await makeDockerAnalyzer(
            roots: [temporaryDirectory.url],
            recorder: recorder
        ).analyze()

        XCTAssertEqual(report.runtimeStatus, .installedDaemonUnavailable)
        XCTAssertEqual(report.hostFootprint.locations.count, 1)
        XCTAssertGreaterThan(report.hostFootprint.logicalSize, 0)
        XCTAssertGreaterThan(report.hostFootprint.allocatedSize, 0)
        XCTAssertNotNil(
            dockerNode(at: payload.path, in: report.hostFootprint.locations[0].root)
        )
    }

    func testDetectsSparseDockerVirtualDiskAndPreservesSparseStatus() async throws {
        let temporaryDirectory = try DockerTestDirectory()
        let virtualDisk = temporaryDirectory.url.appendingPathComponent("Docker.raw")
        XCTAssertTrue(FileManager.default.createFile(atPath: virtualDisk.path, contents: nil))
        let logicalByteCount: UInt64 = 64 * 1_024 * 1_024
        let handle = try FileHandle(forWritingTo: virtualDisk)
        try handle.truncate(atOffset: logicalByteCount)
        try handle.close()

        let report = await makeDockerAnalyzer(
            roots: [temporaryDirectory.url],
            installed: false
        ).analyze()
        let disk = try XCTUnwrap(report.virtualDisks.first { $0.absolutePath == virtualDisk.path })

        XCTAssertEqual(disk.format, .raw)
        XCTAssertEqual(disk.logicalSize, Int64(logicalByteCount))
        if disk.allocatedSize >= disk.logicalSize {
            throw XCTSkip("The test filesystem eagerly allocated the sparse virtual disk.")
        }
        XCTAssertEqual(disk.sparseState, .sparse)
    }

    func testVirtualDiskLogicalAndAllocatedSizesMatchFilesystemMetadata() async throws {
        let temporaryDirectory = try DockerTestDirectory()
        let virtualDisk = temporaryDirectory.url.appendingPathComponent("desktop.qcow2")
        try Data(repeating: 0x31, count: 32_768).write(to: virtualDisk)
        let expected = try dockerStatValues(for: virtualDisk.path)

        let report = await makeDockerAnalyzer(
            roots: [temporaryDirectory.url],
            installed: false
        ).analyze()
        let disk = try XCTUnwrap(report.virtualDisks.first { $0.absolutePath == virtualDisk.path })

        XCTAssertEqual(disk.logicalSize, expected.logical)
        XCTAssertEqual(disk.allocatedSize, expected.allocated)
        XCTAssertEqual(disk.storageNode.ownLogicalSize, expected.logical)
        XCTAssertEqual(disk.storageNode.ownAllocatedSize, expected.allocated)
    }

    func testRuntimeTotalsRemainSeparateFromHostMacDiskUsage() async throws {
        let temporaryDirectory = try DockerTestDirectory()
        try Data(repeating: 0x41, count: 1_048_576).write(
            to: temporaryDirectory.url.appendingPathComponent("host.dat")
        )
        let recorder = DockerCommandRecorder(result: successfulDockerResult())

        let report = await makeDockerAnalyzer(
            roots: [temporaryDirectory.url],
            recorder: recorder
        ).analyze()
        let runtimeBytes = try XCTUnwrap(report.totalRuntimeReportedBytes)

        XCTAssertEqual(
            report.accountingRelationship,
            .runtimeBreakdownIsNonAdditiveToHostFootprint
        )
        XCTAssertEqual(report.macDiskUsageBytes, report.hostFootprint.allocatedSize)
        XCTAssertNotEqual(
            report.macDiskUsageBytes,
            report.hostFootprint.allocatedSize + runtimeBytes
        )
    }

    func testOverlappingHostRootsAreScannedOnceWithoutDoubleCounting() async throws {
        let temporaryDirectory = try DockerTestDirectory()
        let nested = temporaryDirectory.url.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        try Data(repeating: 0x51, count: 8_192).write(
            to: nested.appendingPathComponent("payload.dat")
        )

        let report = await makeDockerAnalyzer(
            roots: [temporaryDirectory.url, nested, temporaryDirectory.url],
            installed: false
        ).analyze()
        let location = try XCTUnwrap(report.hostFootprint.locations.first)

        XCTAssertEqual(report.hostFootprint.locations.count, 1)
        XCTAssertEqual(location.root.absolutePath, temporaryDirectory.url.path)
        XCTAssertEqual(report.hostFootprint.logicalSize, location.root.logicalSize)
        XCTAssertEqual(report.hostFootprint.allocatedSize, location.root.allocatedSize)
    }

    func testParsesReclaimableBytesAndPercentages() async throws {
        let report = await makeDockerAnalyzer(
            roots: [],
            recorder: DockerCommandRecorder(result: successfulDockerResult())
        ).analyze()
        let accounting = try XCTUnwrap(report.runtimeAccounting)

        XCTAssertEqual(accounting.images?.reclaimableBytes, 2_000_000_000)
        XCTAssertEqual(accounting.images?.reclaimablePercentage, 25)
        XCTAssertEqual(accounting.buildCache?.reclaimableBytes, 500_000_000)
        XCTAssertEqual(accounting.buildCache?.reclaimablePercentage, 50)
        XCTAssertEqual(report.reclaimableBytes, 4_000_000_000)
        XCTAssertEqual(accounting.reclaimablePercentage ?? 0, 26.666_666, accuracy: 0.001)
    }

    func testLocalVolumesRemainASeparateApplicationDataRuntimeCategory() async throws {
        let report = await makeDockerAnalyzer(
            roots: [],
            recorder: DockerCommandRecorder(result: successfulDockerResult())
        ).analyze()
        let volumes = try XCTUnwrap(report.runtimeAccounting?.localVolumes)

        XCTAssertEqual(volumes.category, .localVolumes)
        XCTAssertEqual(volumes.totalBytes, 4_000_000_000)
        XCTAssertEqual(volumes.reclaimableBytes, 1_000_000_000)
        XCTAssertEqual(volumes.objectCount, 3)
        XCTAssertEqual(volumes.activeCount, 1)
        XCTAssertTrue(volumes.isApplicationData)
    }

    func testPermissionDeniedHostLocationIsPreservedAsFilesystemIssue() async throws {
        guard geteuid() != 0 else {
            throw XCTSkip("A root process can read mode-000 test directories.")
        }

        let temporaryDirectory = try DockerTestDirectory()
        let inaccessible = temporaryDirectory.url.appendingPathComponent("inaccessible", isDirectory: true)
        try FileManager.default.createDirectory(at: inaccessible, withIntermediateDirectories: false)
        try Data(repeating: 0x61, count: 128).write(
            to: inaccessible.appendingPathComponent("payload.dat")
        )
        XCTAssertEqual(chmod(inaccessible.path, 0), 0)
        defer { _ = chmod(inaccessible.path, mode_t(S_IRWXU)) }

        let report = await makeDockerAnalyzer(
            roots: [temporaryDirectory.url],
            installed: false
        ).analyze()
        let root = try XCTUnwrap(report.hostFootprint.locations.first?.root)
        let inaccessibleNode = try XCTUnwrap(dockerNode(at: inaccessible.path, in: root))

        XCTAssertEqual(inaccessibleNode.accessibility, .inaccessible)
        XCTAssertTrue(inaccessibleNode.scanIssues.contains { $0.kind == .permissionDenied })
        XCTAssertTrue(report.issues.contains {
            $0.kind == .filesystem && $0.path == inaccessible.path
        })
    }

    func testCancellationReturnsCancelledReportAndCancelsInjectedRunner() async {
        let analyzer = DockerStorageAnalyzer(
            hostStorageRoots: [],
            executableLocator: { fakeDockerURL },
            commandRunner: { _ in
                do {
                    try await Task.sleep(nanoseconds: 10_000_000_000)
                    return successfulDockerResult()
                } catch {
                    return .init(
                        terminationStatus: -1,
                        stdout: "",
                        stderr: "",
                        launchError: nil,
                        wasCancelled: true
                    )
                }
            }
        )
        let task = Task { await analyzer.analyze() }
        try? await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()

        let report = await task.value

        XCTAssertTrue(report.wasCancelled)
        XCTAssertEqual(report.runtimeStatus, .cancelled)
        XCTAssertTrue(report.issues.contains { $0.kind == .cancelled })
    }

    func testCommandFailureDoesNotDiscardHostFilesystemResults() async throws {
        let temporaryDirectory = try DockerTestDirectory()
        let hostFile = temporaryDirectory.url.appendingPathComponent("Docker.img")
        try Data(repeating: 0x71, count: 16_384).write(to: hostFile)
        let recorder = DockerCommandRecorder(result: .init(
            terminationStatus: 126,
            stdout: "",
            stderr: "Docker command execution denied",
            launchError: nil,
            wasCancelled: false
        ))

        let report = await makeDockerAnalyzer(
            roots: [temporaryDirectory.url],
            recorder: recorder
        ).analyze()

        XCTAssertEqual(report.runtimeStatus, .commandFailed)
        XCTAssertGreaterThan(report.hostFootprint.allocatedSize, 0)
        XCTAssertEqual(report.virtualDisks.first?.absolutePath, hostFile.path)
        XCTAssertTrue(report.issues.contains { $0.kind == .commandFailed })
    }

    func testEmptyDockerStorageReturnsZeroHostFootprint() async {
        let report = await makeDockerAnalyzer(roots: [], installed: false).analyze()

        XCTAssertTrue(report.hostFootprint.locations.isEmpty)
        XCTAssertEqual(report.hostFootprint.logicalSize, 0)
        XCTAssertEqual(report.hostFootprint.allocatedSize, 0)
        XCTAssertEqual(report.macDiskUsageBytes, 0)
        XCTAssertTrue(report.virtualDisks.isEmpty)
    }

    func testVerifiedLocalUnixSocketContextIsAttributedAsLocal() async {
        let recorder = DockerCommandRecorder(
            contextResult: successfulDockerContextResult(
                name: "desktop-linux",
                endpoint: "unix:///var/run/docker.sock"
            ),
            runtimeResult: successfulDockerResult()
        )

        let report = await makeDockerAnalyzer(roots: [], recorder: recorder).analyze()

        XCTAssertEqual(report.runtimeContext.name, "desktop-linux")
        XCTAssertEqual(report.runtimeContext.sanitizedEndpoint, "unix:///var/run/docker.sock")
        XCTAssertEqual(report.runtimeContext.location, .local)
        XCTAssertEqual(report.hostRuntimeRelationship, .localRuntimeMayExplainHostFootprint)
    }

    func testRemoteSSHContextIsAttributedAsRemote() async {
        let recorder = DockerCommandRecorder(
            contextResult: successfulDockerContextResult(
                name: "production",
                endpoint: "ssh://operator@remote.example.com:2222"
            ),
            runtimeResult: successfulDockerResult()
        )

        let report = await makeDockerAnalyzer(roots: [], recorder: recorder).analyze()

        XCTAssertEqual(report.runtimeContext.location, .remote)
        XCTAssertEqual(report.runtimeContext.sanitizedEndpoint, "ssh://remote.example.com:2222")
        XCTAssertEqual(report.hostRuntimeRelationship, .remoteRuntimeNotRelatedToHostFootprint)
    }

    func testRemoteTCPContextIsAttributedAsRemote() async {
        let recorder = DockerCommandRecorder(
            contextResult: successfulDockerContextResult(
                name: "tcp-engine",
                endpoint: "tcp://docker.example.net:2376"
            ),
            runtimeResult: successfulDockerResult()
        )

        let report = await makeDockerAnalyzer(roots: [], recorder: recorder).analyze()

        XCTAssertEqual(report.runtimeContext.location, .remote)
        XCTAssertEqual(report.hostRuntimeRelationship, .remoteRuntimeNotRelatedToHostFootprint)
    }

    func testUnrecognizedEndpointKeepsRelationshipUnknown() async {
        let recorder = DockerCommandRecorder(
            contextResult: successfulDockerContextResult(
                name: "custom-engine",
                endpoint: "custom-transport://engine-id/session"
            ),
            runtimeResult: successfulDockerResult()
        )

        let report = await makeDockerAnalyzer(roots: [], recorder: recorder).analyze()

        XCTAssertEqual(report.runtimeContext.location, .unknown)
        XCTAssertEqual(report.hostRuntimeRelationship, .unknownRelationship)
        XCTAssertTrue(report.issues.contains { $0.kind == .runtimeLocationUnknown })
    }

    func testContextInspectionFailureIsReportedWithoutFailingRuntimeAccounting() async {
        let recorder = DockerCommandRecorder(
            contextResult: failedDockerContextResult(),
            runtimeResult: successfulDockerResult()
        )

        let report = await makeDockerAnalyzer(roots: [], recorder: recorder).analyze()

        XCTAssertEqual(report.runtimeContext.location, .unknown)
        XCTAssertEqual(report.hostRuntimeRelationship, .unknownRelationship)
        XCTAssertEqual(report.runtimeStatus, .installedAndReachable)
        XCTAssertNotNil(report.runtimeAccounting)
        XCTAssertTrue(report.issues.contains { $0.kind == .contextInspectionFailed })
    }

    func testRuntimeAccountingRemainsAvailableForUnknownEndpoint() async {
        let recorder = DockerCommandRecorder(
            contextResult: successfulDockerContextResult(
                endpoint: "fd://docker-engine"
            ),
            runtimeResult: successfulDockerResult()
        )

        let report = await makeDockerAnalyzer(roots: [], recorder: recorder).analyze()

        XCTAssertEqual(report.runtimeContext.location, .unknown)
        XCTAssertEqual(report.totalRuntimeReportedBytes, 15_000_000_000)
        XCTAssertEqual(report.runtimeStatus, .installedAndReachable)
    }

    func testHostFilesystemFindingsSurviveContextInspectionFailure() async throws {
        let temporaryDirectory = try DockerTestDirectory()
        let hostFile = temporaryDirectory.url.appendingPathComponent("Docker.raw")
        try Data(repeating: 0x81, count: 32_768).write(to: hostFile)
        let recorder = DockerCommandRecorder(
            contextResult: failedDockerContextResult(),
            runtimeResult: successfulDockerResult()
        )

        let report = await makeDockerAnalyzer(
            roots: [temporaryDirectory.url],
            recorder: recorder
        ).analyze()

        XCTAssertGreaterThan(report.hostFootprint.allocatedSize, 0)
        XCTAssertEqual(report.virtualDisks.first?.absolutePath, hostFile.path)
        XCTAssertNotNil(report.runtimeAccounting)
    }

    func testRemoteRuntimeIsExplicitlyUnrelatedToLocalHostFootprint() async throws {
        let temporaryDirectory = try DockerTestDirectory()
        try Data(repeating: 0x91, count: 16_384).write(
            to: temporaryDirectory.url.appendingPathComponent("host.dat")
        )
        let recorder = DockerCommandRecorder(
            contextResult: successfulDockerContextResult(endpoint: "ssh://remote.example.com"),
            runtimeResult: successfulDockerResult()
        )

        let report = await makeDockerAnalyzer(
            roots: [temporaryDirectory.url],
            recorder: recorder
        ).analyze()

        XCTAssertGreaterThan(report.hostFootprint.allocatedSize, 0)
        XCTAssertNotNil(report.runtimeAccounting)
        XCTAssertEqual(report.hostRuntimeRelationship, .remoteRuntimeNotRelatedToHostFootprint)
    }

    func testLocalRuntimeAccountingRemainsNonAdditiveToHostFootprint() async throws {
        let temporaryDirectory = try DockerTestDirectory()
        try Data(repeating: 0xA1, count: 16_384).write(
            to: temporaryDirectory.url.appendingPathComponent("host.dat")
        )
        let report = await makeDockerAnalyzer(
            roots: [temporaryDirectory.url],
            recorder: DockerCommandRecorder(result: successfulDockerResult())
        ).analyze()
        let runtimeBytes = try XCTUnwrap(report.totalRuntimeReportedBytes)

        XCTAssertEqual(report.runtimeContext.location, .local)
        XCTAssertEqual(report.hostRuntimeRelationship, .localRuntimeMayExplainHostFootprint)
        XCTAssertEqual(report.accountingRelationship, .runtimeBreakdownIsNonAdditiveToHostFootprint)
        XCTAssertEqual(report.macDiskUsageBytes, report.hostFootprint.allocatedSize)
        XCTAssertNotEqual(report.macDiskUsageBytes, report.hostFootprint.allocatedSize + runtimeBytes)
    }

    func testEndpointSanitizationRemovesCredentialsAndRemotePathDetails() async {
        let recorder = DockerCommandRecorder(
            contextResult: successfulDockerContextResult(
                endpoint: "ssh://operator:secret@remote.example.com:2222/private/socket?token=abc#fragment"
            ),
            runtimeResult: successfulDockerResult()
        )

        let report = await makeDockerAnalyzer(roots: [], recorder: recorder).analyze()
        let endpoint = report.runtimeContext.sanitizedEndpoint

        XCTAssertEqual(endpoint, "ssh://remote.example.com:2222")
        XCTAssertFalse(endpoint?.contains("operator") == true)
        XCTAssertFalse(endpoint?.contains("secret") == true)
        XCTAssertFalse(endpoint?.contains("token") == true)
        XCTAssertFalse(endpoint?.contains("private") == true)
    }

    func testContextAttributionNeverGeneratesContextSwitchOrMutationCommands() async {
        let recorder = DockerCommandRecorder(result: successfulDockerResult())

        _ = await makeDockerAnalyzer(roots: [], recorder: recorder).analyze()

        XCTAssertEqual(recorder.recordedRequests.map(\.arguments), [
            ["context", "inspect", "--format", "json"],
            ["system", "df", "--format", "json"],
        ])
        let arguments = Set(recorder.recordedRequests.flatMap(\.arguments).map { $0.lowercased() })
        XCTAssertTrue(arguments.isDisjoint(with: ["use", "create", "update", "rm", "prune"]))
    }

    func testCancellationDuringContextInspectionDoesNotStartRuntimeAccounting() async {
        let recorder = DockerCancellableCommandRecorder()
        let analyzer = DockerStorageAnalyzer(
            hostStorageRoots: [],
            executableLocator: { fakeDockerURL },
            commandRunner: { request in await recorder.run(request) }
        )
        let task = Task { await analyzer.analyze() }
        try? await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()

        let report = await task.value

        XCTAssertTrue(report.wasCancelled)
        XCTAssertEqual(report.runtimeStatus, .cancelled)
        XCTAssertEqual(recorder.recordedRequests.map(\.arguments), [
            ["context", "inspect", "--format", "json"],
        ])
    }

    func testAnalyzerOnlyGeneratesStructuredReadOnlyDockerCommand() async {
        let recorder = DockerCommandRecorder(result: successfulDockerResult())
        _ = await makeDockerAnalyzer(roots: [], recorder: recorder).analyze()
        let requests = recorder.recordedRequests

        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.executableURL == fakeDockerURL })
        XCTAssertEqual(requests[0].arguments, ["context", "inspect", "--format", "json"])
        XCTAssertEqual(requests[1].arguments, ["system", "df", "--format", "json"])

        let generatedArguments = Set(requests.flatMap(\.arguments).map { $0.lowercased() })
        let destructiveArguments = Set(["prune", "remove", "delete", "stop", "kill", "rm"])
        XCTAssertTrue(generatedArguments.isDisjoint(with: destructiveArguments))
        XCTAssertFalse(requests.contains { $0.arguments.contains("use") })
    }
}

private let fakeDockerURL = URL(fileURLWithPath: "/fake/bin/docker")

private final class DockerCommandRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [DockerCommandRequest] = []
    private let contextResult: DockerCommandResult
    private let runtimeResult: DockerCommandResult

    init(result: DockerCommandResult) {
        contextResult = successfulDockerContextResult()
        runtimeResult = result
    }

    init(contextResult: DockerCommandResult, runtimeResult: DockerCommandResult) {
        self.contextResult = contextResult
        self.runtimeResult = runtimeResult
    }

    var recordedRequests: [DockerCommandRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func run(_ request: DockerCommandRequest) async -> DockerCommandResult {
        record(request)
        return request.arguments == DockerStorageAnalyzer.contextInspectionArguments
            ? contextResult
            : runtimeResult
    }

    private func record(_ request: DockerCommandRequest) {
        lock.lock()
        requests.append(request)
        lock.unlock()
    }
}

private final class DockerCancellableCommandRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [DockerCommandRequest] = []

    var recordedRequests: [DockerCommandRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func run(_ request: DockerCommandRequest) async -> DockerCommandResult {
        lock.lock()
        requests.append(request)
        lock.unlock()
        do {
            try await Task.sleep(nanoseconds: 10_000_000_000)
            return successfulDockerContextResult()
        } catch {
            return DockerCommandResult(
                terminationStatus: -1,
                stdout: "",
                stderr: "",
                launchError: nil,
                wasCancelled: true
            )
        }
    }
}

private final class DockerTestDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PureMac-DockerStorageAnalyzerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

private func makeDockerAnalyzer(
    roots: [URL],
    installed: Bool = true,
    recorder: DockerCommandRecorder? = nil
) -> DockerStorageAnalyzer {
    let commandRecorder = recorder ?? DockerCommandRecorder(result: successfulDockerResult())
    return DockerStorageAnalyzer(
        hostStorageRoots: roots,
        executableLocator: { installed ? fakeDockerURL : nil },
        commandRunner: { request in await commandRecorder.run(request) }
    )
}

private func successfulDockerResult() -> DockerCommandResult {
    DockerCommandResult(
        terminationStatus: 0,
        stdout: """
        {"Type":"Images","TotalCount":"10","Active":"4","Size":"8GB","Reclaimable":"2GB (25%)"}
        {"Type":"Containers","TotalCount":"5","Active":"2","Size":"2GB","Reclaimable":"500MB (25%)"}
        {"Type":"Local Volumes","TotalCount":"3","Active":"1","Size":"4GB","Reclaimable":"1GB (25%)"}
        {"Type":"Build Cache","TotalCount":"20","Active":"0","Size":"1GB","Reclaimable":"500MB (50%)"}
        """,
        stderr: "",
        launchError: nil,
        wasCancelled: false
    )
}

private func successfulDockerContextResult(
    name: String = "desktop-linux",
    endpoint: String = "unix:///var/run/docker.sock"
) -> DockerCommandResult {
    let object: [[String: Any]] = [[
        "Name": name,
        "Endpoints": [
            "docker": ["Host": endpoint],
        ],
    ]]
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return DockerCommandResult(
        terminationStatus: 0,
        stdout: String(decoding: data, as: UTF8.self),
        stderr: "",
        launchError: nil,
        wasCancelled: false
    )
}

private func failedDockerContextResult() -> DockerCommandResult {
    DockerCommandResult(
        terminationStatus: 1,
        stdout: "",
        stderr: "unable to inspect Docker context",
        launchError: nil,
        wasCancelled: false
    )
}

private func dockerNode(at path: String, in root: StorageNode) -> StorageNode? {
    var pending = [root]
    while let candidate = pending.popLast() {
        if candidate.absolutePath == path { return candidate }
        pending.append(contentsOf: candidate.children)
    }
    return nil
}

private func dockerStatValues(for path: String) throws -> (logical: Int64, allocated: Int64) {
    var metadata = stat()
    guard lstat(path, &metadata) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: Darwin.errno) ?? .EIO)
    }
    return (
        logical: Int64(metadata.st_size),
        allocated: Int64(metadata.st_blocks) * 512
    )
}
