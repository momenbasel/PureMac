import XCTest
@testable import PureMac

final class APFSStorageAnalyzerTests: XCTestCase {
    func testBasicVolumeCapacityAndUsedFreeCalculation() async {
        let report = await makeAnalyzer(
            statistics: statistics(total: 1_000, available: 350, important: 500)
        ).analyze()

        XCTAssertEqual(report.volume.capacity.totalCapacity, 1_000)
        XCTAssertEqual(report.volume.capacity.availableCapacity, 350)
        XCTAssertEqual(report.volume.capacity.usedCapacity, 650)
    }

    func testSharedPurgeableEstimateMatchesExistingFormula() {
        let result = VolumeStatisticsProvider.calculate(
            totalCapacity: 1_000,
            availableCapacity: 300,
            availableCapacityForImportantUsage: 475
        )

        XCTAssertEqual(result.purgeableEstimate, 175)
        XCTAssertEqual(result.usedCapacity, 700)
    }

    func testExistingDiskInfoKeepsOriginalPurgeableThreshold() {
        let aboveThreshold = VolumeStatisticsProvider.calculate(
            totalCapacity: 100_000_000,
            availableCapacity: 20_000_000,
            availableCapacityForImportantUsage: 35_000_000
        )
        let belowThreshold = VolumeStatisticsProvider.calculate(
            totalCapacity: 100_000_000,
            availableCapacity: 20_000_000,
            availableCapacityForImportantUsage: 25_000_000
        )

        XCTAssertEqual(ScanEngine.makeDiskInfo(from: aboveThreshold).purgeableSpace, 15_000_000)
        XCTAssertEqual(ScanEngine.makeDiskInfo(from: belowThreshold).purgeableSpace, 0)
    }

    func testPurgeableEstimateIsExplicitlyEstimated() async {
        let report = await makeAnalyzer(
            statistics: statistics(total: 1_000, available: 300, important: 475)
        ).analyze()

        XCTAssertEqual(report.volume.capacity.purgeableEstimate, 175)
        XCTAssertEqual(report.volume.capacity.purgeableEstimateKnowledge, .estimated)
    }

    func testPurgeableEstimateUnavailableWithoutImportantUsageCapacity() async {
        let report = await makeAnalyzer(
            statistics: statistics(total: 1_000, available: 300, important: nil)
        ).analyze()

        XCTAssertNil(report.volume.capacity.purgeableEstimate)
        XCTAssertEqual(report.volume.capacity.purgeableEstimateKnowledge, .unavailable)
    }

    func testAPFSVolumeMetadataAndDataRelationship() async {
        let info = plist([
            "FilesystemType": "apfs",
            "MountPoint": "/",
            "VolumeName": "Macintosh HD - Data",
            "DeviceIdentifier": "disk3s5",
            "VolumeUUID": "VOL-UUID",
            "APFSContainerReference": "disk3",
            "APFSVolumeGroupID": "GROUP-UUID",
            "Roles": ["Data"],
        ])
        let report = await makeAnalyzer(info: info).analyze()

        XCTAssertEqual(report.volume.filesystemKind, .apfs)
        XCTAssertEqual(report.volume.name, "Macintosh HD - Data")
        XCTAssertEqual(report.volume.volumeIdentifier, "disk3s5")
        XCTAssertEqual(report.volume.containerIdentifier, "disk3")
        XCTAssertEqual(report.volume.dataVolumeRelationship, .dataVolume)
    }

    func testSystemVolumeRelationshipIsDiscoverable() async {
        let info = plist([
            "FilesystemType": "apfs",
            "MountPoint": "/",
            "APFSVolumeGroupID": "GROUP-UUID",
            "Roles": ["System"],
        ])
        let report = await makeAnalyzer(info: info).analyze()

        XCTAssertEqual(report.volume.dataVolumeRelationship, .systemVolume)
    }

    func testNonAPFSVolumeReturnsTypedStateWithoutSnapshotCommands() async {
        let recorder = APFSCommandRecorder(responses: [
            key(.diskInfo, mount: "/"): success(plist([
                "FilesystemType": "hfs",
                "MountPoint": "/",
            ])),
        ])
        let analyzer = makeAnalyzer(recorder: recorder)
        let report = await analyzer.analyze()
        let requests = await recorder.requests

        XCTAssertEqual(report.state, .nonAPFS)
        XCTAssertEqual(report.volume.filesystemKind, .nonAPFS)
        XCTAssertEqual(report.volume.dataVolumeRelationship, .notApplicable)
        XCTAssertTrue(report.snapshots.isEmpty)
        XCTAssertEqual(requests.count, 1)
    }

    func testNoSnapshotsIsAValidCompleteResult() async {
        let report = await makeAnalyzer().analyze()

        XCTAssertEqual(report.state, .complete)
        XCTAssertTrue(report.snapshots.isEmpty)
    }

    func testTimeMachineSnapshotParsing() async {
        let name = "com.apple.TimeMachine.2026-08-18-120000.local"
        let report = await makeAnalyzer(tmutil: Data("Snapshots for disk /:\n\(name)\n".utf8))
            .analyze()

        XCTAssertEqual(report.snapshots.count, 1)
        XCTAssertEqual(report.snapshots[0].name, name)
        XCTAssertEqual(report.snapshots[0].type, .timeMachine)
        XCTAssertEqual(report.snapshots[0].source, .tmutil)
        XCTAssertNotNil(report.snapshots[0].creationDate)
    }

    func testAPFSPlistSnapshotParsesUUIDNameAndDate() async {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshots = plist(["Snapshots": [[
            "SnapshotName": "com.example.snapshot",
            "SnapshotUUID": "SNAP-UUID",
            "SnapshotDate": date,
        ]]])
        let report = await makeAnalyzer(snapshots: snapshots).analyze()
        let snapshot = try! XCTUnwrap(report.snapshots.first)

        XCTAssertEqual(snapshot.identifier, "SNAP-UUID")
        XCTAssertEqual(snapshot.name, "com.example.snapshot")
        XCTAssertEqual(snapshot.uuid, "SNAP-UUID")
        XCTAssertEqual(snapshot.creationDate, date)
        XCTAssertEqual(snapshot.source, .diskutil)
    }

    func testSnapshotTypesRemainDistinct() async {
        let snapshots = plist(["Snapshots": [
            ["SnapshotName": "com.apple.TimeMachine.2026-08-18-120000.local"],
            ["SnapshotName": "com.apple.os.update-123"],
            ["SnapshotName": "com.vendor.backup"],
        ]])
        let report = await makeAnalyzer(snapshots: snapshots).analyze()
        let types = Set(report.snapshots.map(\.type))

        XCTAssertEqual(types, [.timeMachine, .operatingSystemUpdate, .otherAPFS])
    }

    func testTMUtilUnknownSnapshotTypeIsNotAssumedTimeMachine() async {
        let report = await makeAnalyzer(
            tmutil: Data("Snapshots for disk /:\ncom.apple.custom.snapshot\n".utf8)
        ).analyze()

        XCTAssertEqual(report.snapshots.first?.type, .unknown)
    }

    func testDuplicateSnapshotIsMergedAcrossSources() async {
        let name = "com.apple.TimeMachine.2026-08-18-120000.local"
        let snapshots = plist(["Snapshots": [[
            "SnapshotName": name,
            "SnapshotUUID": "SNAP-UUID",
            "DataSize": 2_048,
        ]]])
        let tmutil = Data("Snapshots for disk /:\n\(name)\n".utf8)
        let report = await makeAnalyzer(snapshots: snapshots, tmutil: tmutil).analyze()

        XCTAssertEqual(report.snapshots.count, 1)
        XCTAssertEqual(report.snapshots[0].source, .tmutilAndDiskutil)
        XCTAssertEqual(report.snapshots[0].uuid, "SNAP-UUID")
        XCTAssertEqual(report.snapshots[0].size, 2_048)
    }

    func testSnapshotWithoutReportedSizeRemainsUnknown() async {
        let snapshots = plist(["Snapshots": [["SnapshotName": "com.example.snapshot"]]])
        let report = await makeAnalyzer(snapshots: snapshots).analyze()
        let snapshot = try! XCTUnwrap(report.snapshots.first)

        XCTAssertNil(snapshot.size)
        XCTAssertEqual(snapshot.sizeKnowledge, .unavailable)
        XCTAssertEqual(snapshot.storageRelationship, .sizeUnavailable)
    }

    func testReliableSystemReportedSnapshotSizeIsPreserved() async {
        let snapshots = plist(["Snapshots": [[
            "SnapshotName": "com.example.snapshot",
            "DataSize": 4_096,
        ]]])
        let report = await makeAnalyzer(snapshots: snapshots).analyze()
        let snapshot = try! XCTUnwrap(report.snapshots.first)

        XCTAssertEqual(snapshot.size, 4_096)
        XCTAssertEqual(snapshot.sizeKnowledge, .reportedBySystem)
        XCTAssertEqual(snapshot.storageRelationship, .sharedNonAdditive)
    }

    func testSnapshotAndVolumeAccountingIsExplicitlyNonAdditive() async {
        let report = await makeAnalyzer(snapshots: plist(["Snapshots": [[
            "SnapshotName": "com.example.snapshot",
            "DataSize": 4_096,
        ]]])).analyze()

        XCTAssertEqual(
            report.accountingRelationship,
            .volumeMetadataAndSnapshotsAreNonAdditiveToFilesystemTrees
        )
        XCTAssertFalse(report.volume.capacity.usedCapacity == 604_096)
    }

    func testDiskutilInfoFailurePreservesFoundationVolumeStatistics() async {
        let recorder = APFSCommandRecorder(responses: [
            key(.diskInfo, mount: "/"): failure(status: 1),
            key(.snapshots, mount: "/"): success(emptySnapshotPlist),
            key(.tmutil, mount: "/"): success(emptyTMUtilOutput),
        ])
        let report = await makeAnalyzer(recorder: recorder).analyze()

        XCTAssertEqual(report.volume.capacity.totalCapacity, 1_000)
        XCTAssertEqual(report.volume.capacity.availableCapacity, 400)
        XCTAssertEqual(report.state, .partial)
        XCTAssertTrue(report.issues.contains { $0.source == "diskutil-info" })
    }

    func testTMUtilFailurePreservesDiskutilSnapshotData() async {
        let snapshotData = plist(["Snapshots": [[
            "SnapshotName": "com.example.snapshot",
            "SnapshotUUID": "UUID",
        ]]])
        let recorder = APFSCommandRecorder(responses: [
            key(.diskInfo, mount: "/"): success(defaultInfoPlist),
            key(.snapshots, mount: "/"): success(snapshotData),
            key(.tmutil, mount: "/"): failure(status: 1),
        ])
        let report = await makeAnalyzer(recorder: recorder).analyze()

        XCTAssertEqual(report.snapshots.count, 1)
        XCTAssertEqual(report.snapshots[0].uuid, "UUID")
        XCTAssertEqual(report.state, .partial)
    }

    func testMalformedSnapshotPlistProducesTypedIssue() async {
        let report = await makeAnalyzer(snapshots: Data("not a plist".utf8)).analyze()

        XCTAssertEqual(report.state, .partial)
        XCTAssertTrue(report.issues.contains {
            $0.kind == .malformedPlist && $0.source == "diskutil-snapshots"
        })
    }

    func testPartialDiskInfoMetadataProducesTypedIssue() async {
        let report = await makeAnalyzer(info: plist(["FilesystemType": "apfs"])).analyze()

        XCTAssertEqual(report.state, .partial)
        XCTAssertTrue(report.issues.contains { $0.kind == .partialMetadata })
        XCTAssertEqual(report.volume.mountPoint, "/")
    }

    func testPermissionFailureIsNormalizedWithoutRawStderr() async {
        let secret = "permission denied for /Users/example/private-secret"
        let recorder = APFSCommandRecorder(responses: [
            key(.diskInfo, mount: "/"): success(defaultInfoPlist),
            key(.snapshots, mount: "/"): failure(status: 77, stderr: secret),
            key(.tmutil, mount: "/"): success(emptyTMUtilOutput),
        ])
        let report = await makeAnalyzer(recorder: recorder).analyze()
        let issue = try! XCTUnwrap(report.issues.first { $0.kind == .permissionDenied })

        XCTAssertFalse(issue.message.contains("private-secret"))
        XCTAssertEqual(issue.source, "diskutil-snapshots")
    }

    func testCancellationStopsBeforeSubsequentCommands() async {
        let runner = CancellingAPFSCommandRunner()
        let volumeStatistics = statistics()
        let analyzer = APFSStorageAnalyzer(
            volumeStatisticsReader: { _ in volumeStatistics },
            commandRunner: { request in await runner.run(request) }
        )
        let task = Task { await analyzer.analyze() }
        await runner.waitUntilStarted()
        task.cancel()
        let report = await task.value
        let requests = await runner.requests

        XCTAssertTrue(report.wasCancelled)
        XCTAssertEqual(report.state, .cancelled)
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(report.issues.contains { $0.kind == .cancelled })
    }

    func testGeneratedCommandsAreInspectionOnlyAndNeverPurge() async {
        let recorder = defaultRecorder()
        _ = await makeAnalyzer(recorder: recorder).analyze()
        let requests = await recorder.requests
        let allArguments = requests.flatMap(\.arguments).map { $0.lowercased() }

        XCTAssertEqual(requests.count, 3)
        XCTAssertFalse(allArguments.contains { argument in
            ["delete", "purgepurgeable", "erase", "resize", "revert", "mount", "unmount"]
                .contains(argument)
        })
        XCTAssertFalse(requests.contains { $0.executableURL.path.contains("sudo") })
    }

    func testCommandArgumentsPreserveInjectedMountPointAsOneLiteralArgument() async {
        let mount = "/private/tmp/volume;$(touch should-not-run)"
        let recorder = APFSCommandRecorder(responses: [
            key(.diskInfo, mount: mount): success(defaultInfoPlist),
            key(.snapshots, mount: mount): success(emptySnapshotPlist),
            key(.tmutil, mount: mount): success(emptyTMUtilOutput),
        ])
        let analyzer = makeAnalyzer(
            mountPoint: URL(fileURLWithPath: mount, isDirectory: true),
            recorder: recorder
        )
        _ = await analyzer.analyze()
        let requests = await recorder.requests

        XCTAssertEqual(requests.map { $0.arguments.last }, [mount, "-plist", mount])
        XCTAssertEqual(requests[1].arguments, ["apfs", "listSnapshots", mount, "-plist"])
    }

    func testCommandLaunchFailureUsesTypedIssue() async {
        let recorder = APFSCommandRecorder(responses: [
            key(.diskInfo, mount: "/"): launchFailure,
            key(.snapshots, mount: "/"): launchFailure,
            key(.tmutil, mount: "/"): launchFailure,
        ])
        let report = await makeAnalyzer(recorder: recorder).analyze()

        XCTAssertEqual(report.state, .partial)
        XCTAssertEqual(report.issues.filter { $0.kind == .commandUnavailable }.count, 3)
    }

    func testMalformedTMUtilOutputDoesNotDiscardDiskutilResults() async {
        let snapshots = plist(["Snapshots": [["SnapshotName": "com.example.snapshot"]]])
        let report = await makeAnalyzer(
            snapshots: snapshots,
            tmutil: Data("unexpected private output".utf8)
        ).analyze()

        XCTAssertEqual(report.snapshots.count, 1)
        XCTAssertTrue(report.issues.contains { $0.kind == .malformedOutput })
    }

    func testDiskutilCapacityFillsMissingFoundationCapacity() async {
        let stats = VolumeStatisticsReadResult(
            statistics: VolumeStatisticsProvider.calculate(
                totalCapacity: nil,
                availableCapacity: nil,
                availableCapacityForImportantUsage: nil
            ),
            issues: [.init(
                kind: .capacityUnavailable,
                message: "Complete total and available capacity values are unavailable."
            )]
        )
        let info = plist([
            "FilesystemType": "apfs",
            "MountPoint": "/",
            "TotalSize": 2_000,
            "FreeSpace": 750,
        ])
        let report = await makeAnalyzer(statistics: stats, info: info).analyze()

        XCTAssertEqual(report.volume.capacity.totalCapacity, 2_000)
        XCTAssertEqual(report.volume.capacity.availableCapacity, 750)
        XCTAssertEqual(report.volume.capacity.usedCapacity, 1_250)
        XCTAssertEqual(report.state, .partial)
    }
}

// MARK: - Fixtures

private extension APFSStorageAnalyzerTests {
    enum CommandKind { case diskInfo, snapshots, tmutil }

    var defaultInfoPlist: Data {
        plist([
            "FilesystemType": "apfs",
            "MountPoint": "/",
            "VolumeName": "Macintosh HD - Data",
            "DeviceIdentifier": "disk3s5",
            "VolumeUUID": "VOL-UUID",
            "APFSContainerReference": "disk3",
            "APFSVolumeGroupID": "GROUP-UUID",
            "Roles": ["Data"],
        ])
    }

    var emptySnapshotPlist: Data { plist(["Snapshots": []]) }
    var emptyTMUtilOutput: Data { Data("Snapshots for disk /:\n".utf8) }
    var launchFailure: APFSCommandResult {
        APFSCommandResult(
            terminationStatus: -1,
            stdout: Data(),
            stderr: Data(),
            launchError: "not found",
            wasCancelled: false
        )
    }

    func statistics(
        total: Int64? = 1_000,
        available: Int64? = 400,
        important: Int64? = 500
    ) -> VolumeStatisticsReadResult {
        VolumeStatisticsReadResult(
            statistics: VolumeStatisticsProvider.calculate(
                totalCapacity: total,
                availableCapacity: available,
                availableCapacityForImportantUsage: important,
                availableCapacityForOpportunisticUsage: 450,
                volumeName: "Foundation Volume",
                volumeIdentifier: "FOUNDATION-UUID",
                filesystemDescription: "APFS",
                mountPoint: "/"
            ),
            issues: []
        )
    }

    func makeAnalyzer(
        mountPoint: URL = URL(fileURLWithPath: "/", isDirectory: true),
        statistics: VolumeStatisticsReadResult? = nil,
        info: Data? = nil,
        snapshots: Data? = nil,
        tmutil: Data? = nil,
        recorder: APFSCommandRecorder? = nil
    ) -> APFSStorageAnalyzer {
        let resolvedStatistics = statistics ?? self.statistics()
        let resolvedInfo = info ?? defaultInfoPlist
        let resolvedSnapshots = snapshots ?? emptySnapshotPlist
        let resolvedTMUtil = tmutil ?? emptyTMUtilOutput
        let commandRecorder = recorder ?? APFSCommandRecorder(responses: [
            key(.diskInfo, mount: mountPoint.path): success(resolvedInfo),
            key(.snapshots, mount: mountPoint.path): success(resolvedSnapshots),
            key(.tmutil, mount: mountPoint.path): success(resolvedTMUtil),
        ])
        return APFSStorageAnalyzer(
            mountPointURL: mountPoint,
            volumeStatisticsReader: { _ in resolvedStatistics },
            commandRunner: { request in await commandRecorder.run(request) }
        )
    }

    func defaultRecorder() -> APFSCommandRecorder {
        APFSCommandRecorder(responses: [
            key(.diskInfo, mount: "/"): success(defaultInfoPlist),
            key(.snapshots, mount: "/"): success(emptySnapshotPlist),
            key(.tmutil, mount: "/"): success(emptyTMUtilOutput),
        ])
    }

    func key(_ kind: CommandKind, mount: String) -> String {
        let request: APFSCommandRequest
        switch kind {
        case .diskInfo:
            request = APFSStorageAnalyzer.diskInfoRequest(
                for: URL(fileURLWithPath: mount, isDirectory: true)
            )
        case .snapshots:
            request = APFSStorageAnalyzer.diskSnapshotsRequest(
                for: URL(fileURLWithPath: mount, isDirectory: true)
            )
        case .tmutil:
            request = APFSStorageAnalyzer.timeMachineSnapshotsRequest(
                for: URL(fileURLWithPath: mount, isDirectory: true)
            )
        }
        return APFSCommandRecorder.key(request)
    }

    func success(_ stdout: Data) -> APFSCommandResult {
        APFSCommandResult(
            terminationStatus: 0,
            stdout: stdout,
            stderr: Data(),
            launchError: nil,
            wasCancelled: false
        )
    }

    func failure(status: Int32, stderr: String = "failed") -> APFSCommandResult {
        APFSCommandResult(
            terminationStatus: status,
            stdout: Data(),
            stderr: Data(stderr.utf8),
            launchError: nil,
            wasCancelled: false
        )
    }

    func plist(_ value: Any) -> Data {
        try! PropertyListSerialization.data(
            fromPropertyList: value,
            format: .xml,
            options: 0
        )
    }
}

private actor APFSCommandRecorder {
    private let responses: [String: APFSCommandResult]
    private(set) var requests: [APFSCommandRequest] = []

    init(responses: [String: APFSCommandResult]) {
        self.responses = responses
    }

    func run(_ request: APFSCommandRequest) -> APFSCommandResult {
        requests.append(request)
        return responses[Self.key(request)] ?? APFSCommandResult(
            terminationStatus: 127,
            stdout: Data(),
            stderr: Data("missing test response".utf8),
            launchError: nil,
            wasCancelled: false
        )
    }

    static func key(_ request: APFSCommandRequest) -> String {
        ([request.executableURL.path] + request.arguments).joined(separator: "\u{0}")
    }
}

private actor CancellingAPFSCommandRunner {
    private(set) var requests: [APFSCommandRequest] = []
    private var started = false

    func run(_ request: APFSCommandRequest) async -> APFSCommandResult {
        requests.append(request)
        started = true
        while !Task.isCancelled {
            await Task.yield()
        }
        return APFSCommandResult(
            terminationStatus: -1,
            stdout: Data(),
            stderr: Data(),
            launchError: nil,
            wasCancelled: true
        )
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }
}
