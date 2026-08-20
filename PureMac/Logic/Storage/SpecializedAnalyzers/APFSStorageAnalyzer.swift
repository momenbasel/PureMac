import Foundation

/// Read-only volume and snapshot inspection for the configured mount point.
///
/// Capacity metadata and snapshots intentionally remain separate from
/// `StorageNode`: APFS copy-on-write and shared extents make these values
/// unsuitable for direct addition to filesystem-tree totals.
struct APFSStorageAnalyzer: Sendable {
    typealias VolumeStatisticsReader = @Sendable (URL) -> VolumeStatisticsReadResult
    typealias CommandRunner = @Sendable (APFSCommandRequest) async -> APFSCommandResult

    static let diskutilURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
    static let tmutilURL = URL(fileURLWithPath: "/usr/bin/tmutil")

    private let mountPointURL: URL
    private let volumeStatisticsReader: VolumeStatisticsReader
    private let commandRunner: CommandRunner

    init(
        mountPointURL: URL = URL(fileURLWithPath: "/", isDirectory: true),
        volumeStatisticsReader: @escaping VolumeStatisticsReader = {
            VolumeStatisticsProvider.read(at: $0)
        },
        commandRunner: @escaping CommandRunner = {
            await APFSStorageAnalyzer.runReadOnlyCommand($0)
        }
    ) {
        self.mountPointURL = mountPointURL.standardizedFileURL
        self.volumeStatisticsReader = volumeStatisticsReader
        self.commandRunner = commandRunner
    }

    func analyze() async -> APFSStorageReport {
        let mountPointURL = mountPointURL
        let statisticsReader = volumeStatisticsReader
        let statistics = await Task.detached(priority: .utility) {
            statisticsReader(mountPointURL)
        }.value
        var issues = Self.volumeIssues(statistics.issues)
        var metadata = DiskInfoMetadata.empty

        guard !Task.isCancelled else {
            return Self.report(
                statistics: statistics.statistics,
                metadata: metadata,
                snapshots: [],
                state: .cancelled,
                wasCancelled: true,
                issues: issues + [Self.cancelledIssue(source: "volume-statistics")]
            )
        }

        let infoResult = await commandRunner(Self.diskInfoRequest(for: mountPointURL))
        guard !Task.isCancelled, !infoResult.wasCancelled else {
            return Self.report(
                statistics: statistics.statistics,
                metadata: metadata,
                snapshots: [],
                state: .cancelled,
                wasCancelled: true,
                issues: issues + [Self.cancelledIssue(source: "diskutil-info")]
            )
        }

        if let commandIssue = Self.commandIssue(infoResult, source: "diskutil-info") {
            issues.append(commandIssue)
        } else if let parsed = Self.parseDiskInfo(infoResult.stdout) {
            metadata = parsed.metadata
            if parsed.isPartial {
                issues.append(.init(
                    kind: .partialMetadata,
                    message: "Disk Utility returned incomplete volume metadata.",
                    source: "diskutil-info"
                ))
            }
        } else {
            issues.append(.init(
                kind: .malformedPlist,
                message: "Disk Utility returned malformed volume information.",
                source: "diskutil-info"
            ))
        }

        let effectiveFilesystemKind = metadata.filesystemKind == .unknown
            ? Self.classifyFilesystem(statistics.statistics.filesystemDescription)
            : metadata.filesystemKind
        if effectiveFilesystemKind == .nonAPFS {
            return Self.report(
                statistics: statistics.statistics,
                metadata: metadata,
                snapshots: [],
                state: .nonAPFS,
                wasCancelled: false,
                issues: issues
            )
        }

        guard !Task.isCancelled else {
            return Self.report(
                statistics: statistics.statistics,
                metadata: metadata,
                snapshots: [],
                state: .cancelled,
                wasCancelled: true,
                issues: issues + [Self.cancelledIssue(source: "diskutil-snapshots")]
            )
        }

        var diskutilSnapshots: [SnapshotCandidate] = []
        var diskutilSnapshotsSucceeded = false
        let snapshotResult = await commandRunner(Self.diskSnapshotsRequest(for: mountPointURL))
        guard !Task.isCancelled, !snapshotResult.wasCancelled else {
            return Self.report(
                statistics: statistics.statistics,
                metadata: metadata,
                snapshots: [],
                state: .cancelled,
                wasCancelled: true,
                issues: issues + [Self.cancelledIssue(source: "diskutil-snapshots")]
            )
        }

        if let commandIssue = Self.commandIssue(snapshotResult, source: "diskutil-snapshots") {
            issues.append(commandIssue)
        } else if let parsed = Self.parseDiskutilSnapshots(snapshotResult.stdout) {
            diskutilSnapshotsSucceeded = true
            diskutilSnapshots = parsed.snapshots
            if parsed.isPartial {
                issues.append(.init(
                    kind: .partialMetadata,
                    message: "Some APFS snapshot records were incomplete.",
                    source: "diskutil-snapshots"
                ))
            }
        } else {
            issues.append(.init(
                kind: .malformedPlist,
                message: "Disk Utility returned a malformed snapshot property list.",
                source: "diskutil-snapshots"
            ))
        }

        guard !Task.isCancelled else {
            return Self.report(
                statistics: statistics.statistics,
                metadata: metadata,
                snapshots: Self.makeSnapshots(diskutilSnapshots),
                state: .cancelled,
                wasCancelled: true,
                issues: issues + [Self.cancelledIssue(source: "tmutil-snapshots")]
            )
        }

        var tmutilSnapshots: [SnapshotCandidate] = []
        var tmutilSnapshotsSucceeded = false
        let tmutilResult = await commandRunner(Self.timeMachineSnapshotsRequest(for: mountPointURL))
        guard !Task.isCancelled, !tmutilResult.wasCancelled else {
            return Self.report(
                statistics: statistics.statistics,
                metadata: metadata,
                snapshots: Self.makeSnapshots(diskutilSnapshots),
                state: .cancelled,
                wasCancelled: true,
                issues: issues + [Self.cancelledIssue(source: "tmutil-snapshots")]
            )
        }

        if let commandIssue = Self.commandIssue(tmutilResult, source: "tmutil-snapshots") {
            issues.append(commandIssue)
        } else {
            tmutilSnapshotsSucceeded = true
            let parsed = Self.parseTMUtilSnapshots(tmutilResult.stdout)
            tmutilSnapshots = parsed.snapshots
            if parsed.isPartial {
                issues.append(.init(
                    kind: .malformedOutput,
                    message: "Time Machine returned unrecognized snapshot output.",
                    source: "tmutil-snapshots"
                ))
            }
        }

        let snapshots = Self.makeSnapshots(
            Self.deduplicate(diskutilSnapshots + tmutilSnapshots)
        )
        let hasVolumeMetadata = metadata.hasUsefulMetadata
            || statistics.statistics.totalCapacity != nil
            || statistics.statistics.availableCapacity != nil
        let state: APFSAnalysisState
        if !hasVolumeMetadata && snapshots.isEmpty
            && !diskutilSnapshotsSucceeded && !tmutilSnapshotsSucceeded {
            state = .unavailable
        } else if issues.isEmpty {
            state = .complete
        } else {
            state = .partial
        }

        return Self.report(
            statistics: statistics.statistics,
            metadata: metadata,
            snapshots: snapshots,
            state: state,
            wasCancelled: false,
            issues: issues
        )
    }
}

// MARK: - Requests and Process Execution

extension APFSStorageAnalyzer {
    static func diskInfoRequest(for mountPoint: URL) -> APFSCommandRequest {
        APFSCommandRequest(
            executableURL: diskutilURL,
            arguments: ["info", "-plist", mountPoint.path]
        )
    }

    static func diskSnapshotsRequest(for mountPoint: URL) -> APFSCommandRequest {
        APFSCommandRequest(
            executableURL: diskutilURL,
            arguments: ["apfs", "listSnapshots", mountPoint.path, "-plist"]
        )
    }

    static func timeMachineSnapshotsRequest(for mountPoint: URL) -> APFSCommandRequest {
        APFSCommandRequest(
            executableURL: tmutilURL,
            arguments: ["listlocalsnapshots", mountPoint.path]
        )
    }

    static func runReadOnlyCommand(_ request: APFSCommandRequest) async -> APFSCommandResult {
        let cancellation = APFSProcessCancellationState()
        let worker = Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = request.executableURL
            process.arguments = request.arguments
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            guard cancellation.register(process) else {
                return APFSCommandResult(
                    terminationStatus: -1,
                    stdout: Data(),
                    stderr: Data(),
                    launchError: nil,
                    wasCancelled: true
                )
            }

            do {
                try process.run()
            } catch {
                return APFSCommandResult(
                    terminationStatus: -1,
                    stdout: Data(),
                    stderr: Data(),
                    launchError: error.localizedDescription,
                    wasCancelled: cancellation.isCancelled
                )
            }

            cancellation.terminateIfCancelled()
            let stdoutTask = Task.detached {
                stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            }
            let stderrTask = Task.detached {
                stderrPipe.fileHandleForReading.readDataToEndOfFile()
            }
            process.waitUntilExit()
            let stdout = await stdoutTask.value
            let stderr = await stderrTask.value
            return APFSCommandResult(
                terminationStatus: process.terminationStatus,
                stdout: stdout,
                stderr: stderr,
                launchError: nil,
                wasCancelled: cancellation.isCancelled
            )
        }

        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            cancellation.cancel()
        }
    }
}

// MARK: - Parsing

extension APFSStorageAnalyzer {
    struct DiskInfoParseResult: Sendable {
        let metadata: DiskInfoMetadata
        let isPartial: Bool
    }

    struct ParsedSnapshots: Sendable {
        let snapshots: [SnapshotCandidate]
        let isPartial: Bool
    }

    struct DiskInfoMetadata: Sendable {
        let name: String?
        let volumeIdentifier: String?
        let volumeUUID: String?
        let containerIdentifier: String?
        let volumeGroupIdentifier: String?
        let filesystemType: String?
        let filesystemKind: APFSFilesystemKind
        let mountPoint: String?
        let dataVolumeRelationship: APFSDataVolumeRelationship
        let totalCapacity: Int64?
        let availableCapacity: Int64?

        static let empty = DiskInfoMetadata(
            name: nil,
            volumeIdentifier: nil,
            volumeUUID: nil,
            containerIdentifier: nil,
            volumeGroupIdentifier: nil,
            filesystemType: nil,
            filesystemKind: .unknown,
            mountPoint: nil,
            dataVolumeRelationship: .unknown,
            totalCapacity: nil,
            availableCapacity: nil
        )

        var hasUsefulMetadata: Bool {
            name != nil || volumeIdentifier != nil || volumeUUID != nil
                || filesystemType != nil || mountPoint != nil
        }
    }

    struct SnapshotCandidate: Sendable {
        let name: String?
        let uuid: String?
        let creationDate: Date?
        let size: Int64?
        let type: APFSSnapshotType
        let source: APFSSnapshotSource
    }

    static func parseDiskInfo(_ data: Data) -> DiskInfoParseResult? {
        guard let plist = propertyListDictionary(data) else { return nil }
        let filesystemType = string(plist, keys: [
            "FilesystemType", "FilesystemName", "FilesystemUserVisibleName"
        ])
        let filesystemKind = classifyFilesystem(filesystemType)
        let roles = stringArray(plist["Roles"] ?? plist["APFSVolumeRole"])
        let groupID = string(plist, keys: ["APFSVolumeGroupID", "VolumeGroupUUID"])
        let relationship = dataRelationship(
            filesystemKind: filesystemKind,
            roles: roles,
            hasVolumeGroup: groupID != nil
        )
        let metadata = DiskInfoMetadata(
            name: string(plist, keys: ["VolumeName", "MediaName"]),
            volumeIdentifier: string(plist, keys: ["DeviceIdentifier"]),
            volumeUUID: string(plist, keys: ["VolumeUUID", "APFSVolumeUUID"]),
            containerIdentifier: string(plist, keys: [
                "APFSContainerReference", "ContainerIdentifier"
            ]),
            volumeGroupIdentifier: groupID,
            filesystemType: filesystemType,
            filesystemKind: filesystemKind,
            mountPoint: string(plist, keys: ["MountPoint"]),
            dataVolumeRelationship: relationship,
            totalCapacity: nonnegativeInteger(plist, keys: ["TotalSize", "VolumeSize"]),
            availableCapacity: nonnegativeInteger(plist, keys: [
                "FreeSpace", "VolumeFreeSpace"
            ])
        )
        let isPartial = metadata.filesystemType == nil || metadata.mountPoint == nil
        return DiskInfoParseResult(metadata: metadata, isPartial: isPartial)
    }

    static func parseDiskutilSnapshots(_ data: Data) -> ParsedSnapshots? {
        guard let plist = propertyListDictionary(data) else { return nil }
        let rawSnapshots = (plist["Snapshots"] as? [[String: Any]])
            ?? (plist["APFSSnapshots"] as? [[String: Any]])
            ?? []
        var snapshots: [SnapshotCandidate] = []
        var isPartial = false

        for raw in rawSnapshots {
            let name = string(raw, keys: ["SnapshotName", "Name"])
            let uuid = string(raw, keys: ["SnapshotUUID", "UUID"])
            guard name != nil || uuid != nil else {
                isPartial = true
                continue
            }
            let date = dateValue(raw, keys: [
                "SnapshotDate", "CreationDate", "Date"
            ]) ?? name.flatMap(dateFromSnapshotName)
            let size = nonnegativeInteger(raw, keys: [
                "DataSize", "SnapshotSize", "Size"
            ])
            snapshots.append(SnapshotCandidate(
                name: name,
                uuid: uuid,
                creationDate: date,
                size: size,
                type: classifySnapshot(name: name, explicitType: string(
                    raw,
                    keys: ["SnapshotType", "Type", "Role"]
                ), diskutilSource: true),
                source: .diskutil
            ))
        }
        return ParsedSnapshots(snapshots: snapshots, isPartial: isPartial)
    }

    static func parseTMUtilSnapshots(_ data: Data) -> ParsedSnapshots {
        guard let output = String(data: data, encoding: .utf8) else {
            return ParsedSnapshots(snapshots: [], isPartial: !data.isEmpty)
        }
        var snapshots: [SnapshotCandidate] = []
        var isPartial = false
        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("Snapshots for ") { continue }
            guard line.hasPrefix("com.apple.") else {
                isPartial = true
                continue
            }
            snapshots.append(SnapshotCandidate(
                name: line,
                uuid: nil,
                creationDate: dateFromSnapshotName(line),
                size: nil,
                type: classifySnapshot(name: line, explicitType: nil, diskutilSource: false),
                source: .tmutil
            ))
        }
        return ParsedSnapshots(snapshots: snapshots, isPartial: isPartial)
    }
}

// MARK: - Snapshot Deduplication and Report Construction

extension APFSStorageAnalyzer {
    static func deduplicate(_ candidates: [SnapshotCandidate]) -> [SnapshotCandidate] {
        var unique: [SnapshotCandidate] = []
        for candidate in candidates {
            if let index = unique.firstIndex(where: { sameSnapshot($0, candidate) }) {
                unique[index] = merge(unique[index], candidate)
            } else {
                unique.append(candidate)
            }
        }
        return unique.sorted {
            if $0.creationDate != $1.creationDate {
                return ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast)
            }
            return ($0.name ?? $0.uuid ?? "") < ($1.name ?? $1.uuid ?? "")
        }
    }

    static func makeSnapshots(_ candidates: [SnapshotCandidate]) -> [APFSSnapshotInformation] {
        candidates.compactMap { candidate in
            guard let identifier = candidate.uuid ?? candidate.name else { return nil }
            return APFSSnapshotInformation(
                identifier: identifier,
                name: candidate.name,
                uuid: candidate.uuid,
                creationDate: candidate.creationDate,
                size: candidate.size,
                sizeKnowledge: candidate.size == nil ? .unavailable : .reportedBySystem,
                type: candidate.type,
                source: candidate.source,
                storageRelationship: candidate.size == nil
                    ? .sizeUnavailable
                    : .sharedNonAdditive
            )
        }
    }
}

private extension APFSStorageAnalyzer {
    static func report(
        statistics: VolumeCapacityStatistics,
        metadata: DiskInfoMetadata,
        snapshots: [APFSSnapshotInformation],
        state: APFSAnalysisState,
        wasCancelled: Bool,
        issues: [APFSStorageIssue]
    ) -> APFSStorageReport {
        let total = statistics.totalCapacity ?? metadata.totalCapacity
        let available = statistics.availableCapacity ?? metadata.availableCapacity
        let used: Int64?
        if let total, let available {
            used = max(0, total - min(total, available))
        } else {
            used = statistics.usedCapacity
        }
        let filesystemType = metadata.filesystemType ?? statistics.filesystemDescription
        let filesystemKind = metadata.filesystemKind == .unknown
            ? classifyFilesystem(filesystemType)
            : metadata.filesystemKind
        let relationship = filesystemKind == .nonAPFS
            ? APFSDataVolumeRelationship.notApplicable
            : metadata.dataVolumeRelationship
        let volume = APFSVolumeInformation(
            name: metadata.name ?? statistics.volumeName,
            volumeIdentifier: metadata.volumeIdentifier,
            volumeUUID: metadata.volumeUUID ?? statistics.volumeIdentifier,
            containerIdentifier: metadata.containerIdentifier,
            volumeGroupIdentifier: metadata.volumeGroupIdentifier,
            filesystemType: filesystemType,
            filesystemKind: filesystemKind,
            mountPoint: metadata.mountPoint ?? statistics.mountPoint,
            dataVolumeRelationship: relationship,
            capacity: APFSVolumeCapacity(
                totalCapacity: total,
                availableCapacity: available,
                usedCapacity: used,
                availableCapacityForImportantUsage: statistics.availableCapacityForImportantUsage,
                availableCapacityForOpportunisticUsage: statistics.availableCapacityForOpportunisticUsage,
                purgeableEstimate: statistics.purgeableEstimate,
                purgeableEstimateKnowledge: statistics.purgeableEstimate == nil
                    ? .unavailable
                    : .estimated
            )
        )
        return APFSStorageReport(
            volume: volume,
            snapshots: snapshots,
            state: state,
            accountingRelationship: .volumeMetadataAndSnapshotsAreNonAdditiveToFilesystemTrees,
            wasCancelled: wasCancelled,
            issues: uniqueIssues(issues).sorted {
                ($0.source ?? "", $0.kind.rawValue, $0.message)
                    < ($1.source ?? "", $1.kind.rawValue, $1.message)
            }
        )
    }

    static func volumeIssues(_ input: [VolumeStatisticsReadIssue]) -> [APFSStorageIssue] {
        input.map {
            APFSStorageIssue(
                kind: .volumeStatisticsUnavailable,
                message: $0.message,
                source: "foundation-volume-statistics"
            )
        }
    }

    static func uniqueIssues(_ issues: [APFSStorageIssue]) -> [APFSStorageIssue] {
        var seen: Set<APFSStorageIssue> = []
        return issues.filter { seen.insert($0).inserted }
    }

    static func commandIssue(
        _ result: APFSCommandResult,
        source: String
    ) -> APFSStorageIssue? {
        if result.launchError != nil {
            return APFSStorageIssue(
                kind: .commandUnavailable,
                message: "The required read-only system inspection command could not be launched.",
                source: source
            )
        }
        guard result.terminationStatus != 0 else { return nil }
        let stderr = String(data: result.stderr, encoding: .utf8)?.lowercased() ?? ""
        let isPermissionFailure = stderr.contains("permission denied")
            || stderr.contains("not permitted")
            || stderr.contains("authorization")
        return APFSStorageIssue(
            kind: isPermissionFailure ? .permissionDenied : .commandFailed,
            message: isPermissionFailure
                ? "The system denied access to this read-only storage metadata."
                : "A read-only system storage inspection command failed with status \(result.terminationStatus).",
            source: source
        )
    }

    static func cancelledIssue(source: String) -> APFSStorageIssue {
        APFSStorageIssue(
            kind: .cancelled,
            message: "APFS storage inspection was cancelled.",
            source: source
        )
    }

    static func propertyListDictionary(_ data: Data) -> [String: Any]? {
        guard !data.isEmpty,
              let value = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) else {
            return nil
        }
        return value as? [String: Any]
    }

    static func string(_ dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dictionary[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }

    static func stringArray(_ value: Any?) -> [String] {
        if let values = value as? [String] { return values }
        if let value = value as? String { return [value] }
        return []
    }

    static func nonnegativeInteger(
        _ dictionary: [String: Any],
        keys: [String]
    ) -> Int64? {
        for key in keys {
            let number: Int64?
            if let value = dictionary[key] as? NSNumber {
                number = value.int64Value
            } else if let value = dictionary[key] as? Int64 {
                number = value
            } else if let value = dictionary[key] as? Int {
                number = Int64(value)
            } else {
                number = nil
            }
            if let number, number >= 0 { return number }
        }
        return nil
    }

    static func dateValue(_ dictionary: [String: Any], keys: [String]) -> Date? {
        for key in keys {
            if let date = dictionary[key] as? Date { return date }
            if let string = dictionary[key] as? String,
               let date = parseDateString(string) {
                return date
            }
        }
        return nil
    }

    static func parseDateString(_ value: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: value) { return date }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: value)
    }

    static func dateFromSnapshotName(_ name: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        for component in name.components(separatedBy: ".") {
            if let date = formatter.date(from: component) { return date }
        }
        return nil
    }

    static func classifyFilesystem(_ value: String?) -> APFSFilesystemKind {
        guard let normalized = value?.lowercased() else { return .unknown }
        return normalized.contains("apfs") ? .apfs : .nonAPFS
    }

    static func dataRelationship(
        filesystemKind: APFSFilesystemKind,
        roles: [String],
        hasVolumeGroup: Bool
    ) -> APFSDataVolumeRelationship {
        guard filesystemKind != .nonAPFS else { return .notApplicable }
        let normalized = roles.map { $0.lowercased() }
        if normalized.contains(where: { $0 == "data" }) { return .dataVolume }
        if normalized.contains(where: { $0 == "system" }) { return .systemVolume }
        if hasVolumeGroup { return .volumeGroupMember }
        return .unknown
    }

    static func classifySnapshot(
        name: String?,
        explicitType: String?,
        diskutilSource: Bool
    ) -> APFSSnapshotType {
        let evidence = [name, explicitType]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        if evidence.contains("timemachine") || evidence.contains("time machine") {
            return .timeMachine
        }
        if evidence.contains("com.apple.os.update")
            || evidence.contains("software update")
            || evidence.contains("system update") {
            return .operatingSystemUpdate
        }
        return diskutilSource ? .otherAPFS : .unknown
    }

    static func sameSnapshot(_ lhs: SnapshotCandidate, _ rhs: SnapshotCandidate) -> Bool {
        if let leftUUID = lhs.uuid?.lowercased(),
           let rightUUID = rhs.uuid?.lowercased(),
           leftUUID == rightUUID {
            return true
        }
        if let leftName = lhs.name, let rightName = rhs.name, leftName == rightName {
            return true
        }
        if let leftDate = lhs.creationDate, let rightDate = rhs.creationDate,
           leftDate == rightDate,
           lhs.type != .unknown, rhs.type != .unknown,
           lhs.type == rhs.type {
            return true
        }
        return false
    }

    static func merge(_ lhs: SnapshotCandidate, _ rhs: SnapshotCandidate) -> SnapshotCandidate {
        let source: APFSSnapshotSource = lhs.source == rhs.source
            ? lhs.source
            : .tmutilAndDiskutil
        let type: APFSSnapshotType
        if lhs.type == .unknown {
            type = rhs.type
        } else if rhs.type == .unknown || lhs.type == rhs.type {
            type = lhs.type
        } else {
            type = lhs.source == .diskutil ? lhs.type : rhs.type
        }
        return SnapshotCandidate(
            name: lhs.name ?? rhs.name,
            uuid: lhs.uuid ?? rhs.uuid,
            creationDate: lhs.creationDate ?? rhs.creationDate,
            size: lhs.size ?? rhs.size,
            type: type,
            source: source
        )
    }
}

private final class APFSProcessCancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func register(_ process: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        self.process = process
        return true
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let running = process?.isRunning == true ? process : nil
        lock.unlock()
        running?.terminate()
    }

    func terminateIfCancelled() {
        lock.lock()
        let running = cancelled && process?.isRunning == true ? process : nil
        lock.unlock()
        running?.terminate()
    }
}
