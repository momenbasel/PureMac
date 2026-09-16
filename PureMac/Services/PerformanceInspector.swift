import Darwin
import Foundation

enum PerformanceStartupDomain: String, CaseIterable, Hashable, Sendable {
    case userAgent
    case systemAgent
    case systemDaemon

    var title: String {
        switch self {
        case .userAgent: return String(localized: "User agent")
        case .systemAgent: return String(localized: "System-wide agent")
        case .systemDaemon: return String(localized: "System daemon")
        }
    }
}

struct PerformanceStartupItem: Identifiable, Hashable, Sendable {
    let label: String
    let program: String?
    let arguments: [String]
    let sourceURL: URL
    let domain: PerformanceStartupDomain
    let isDisabled: Bool
    let triggers: [String]

    var id: String { sourceURL.path }
}

struct PerformanceSnapshot: Identifiable, Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case timeMachine
        case systemUpdate
        case local

        var title: String {
            switch self {
            case .timeMachine: return String(localized: "Time Machine")
            case .systemUpdate: return String(localized: "System update")
            case .local: return String(localized: "Local snapshot")
            }
        }
    }

    let identifier: String
    let kind: Kind
    let date: Date?

    var id: String { identifier }
}

struct PerformanceInspectionIssue: Identifiable, Hashable, Sendable {
    let title: String
    let detail: String

    var id: String { "\(title)\u{0}\(detail)" }
}

struct PerformanceInspection: Sendable {
    let startupItems: [PerformanceStartupItem]
    let snapshots: [PerformanceSnapshot]
    let issues: [PerformanceInspectionIssue]
}

enum PerformanceInspectorError: LocalizedError, Equatable {
    case invalidPropertyList
    case invalidSnapshotIdentifier
    case timedOut(String)
    case commandFailed(String, Int32, String)

    var errorDescription: String? {
        switch self {
        case .invalidPropertyList:
            return String(localized: "The launch item is not a property-list dictionary.")
        case .invalidSnapshotIdentifier:
            return String(localized: "This snapshot does not have a verified Time Machine timestamp.")
        case .timedOut(let command):
            return String(format: String(localized: "%@ did not finish within the allowed time."), command)
        case .commandFailed(let command, let status, let detail):
            let suffix = detail.isEmpty ? "" : ": \(detail)"
            return String(format: String(localized: "%@ exited with status %lld%@"), command, Int64(status), suffix)
        }
    }
}

final class PerformanceInspector {
    private struct StartupScanResult: Sendable {
        let items: [PerformanceStartupItem]
        let issues: [PerformanceInspectionIssue]
    }

    private struct CommandResult: Sendable {
        let status: Int32
        let standardOutput: String
        let standardError: String
    }

    private static let startupDirectories: [(URL, PerformanceStartupDomain)] = [
        (
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/LaunchAgents", isDirectory: true),
            .userAgent
        ),
        (URL(fileURLWithPath: "/Library/LaunchAgents", isDirectory: true), .systemAgent),
        (URL(fileURLWithPath: "/Library/LaunchDaemons", isDirectory: true), .systemDaemon),
    ]

    func inspect() async throws -> PerformanceInspection {
        async let startupScan = Self.scanStartupItems()
        async let snapshotScan = Self.scanSnapshots()
        let (startup, snapshotResult) = try await (startupScan, snapshotScan)
        return PerformanceInspection(
            startupItems: startup.items,
            snapshots: snapshotResult.snapshots,
            issues: startup.issues + snapshotResult.issues
        )
    }

    func deleteSnapshot(_ snapshot: PerformanceSnapshot) async throws {
        guard let timestamp = Self.deletionTimestamp(for: snapshot) else {
            throw PerformanceInspectorError.invalidSnapshotIdentifier
        }
        let executable = URL(fileURLWithPath: "/usr/bin/tmutil")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw PerformanceInspectorError.commandFailed("tmutil deletelocalsnapshots", -1, "tmutil is unavailable")
        }
        let result = try await Self.runCommand(
            executable: executable,
            arguments: ["deletelocalsnapshots", timestamp],
            timeout: 30
        )
        guard result.status == 0 else {
            throw PerformanceInspectorError.commandFailed(
                "tmutil deletelocalsnapshots",
                result.status,
                result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    static func parseLaunchItem(
        data: Data,
        sourceURL: URL,
        domain: PerformanceStartupDomain
    ) throws -> PerformanceStartupItem {
        let value = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let dictionary = value as? [String: Any] else {
            throw PerformanceInspectorError.invalidPropertyList
        }

        let programArguments = stringArray(dictionary["ProgramArguments"])
        let bundleArguments = stringArray(dictionary["BundleProgramArguments"])
        let declaredProgram = nonEmptyString(dictionary["Program"])
            ?? nonEmptyString(dictionary["BundleProgram"])
        let inferredArguments = programArguments.isEmpty ? bundleArguments : programArguments
        let program = declaredProgram ?? inferredArguments.first
        let arguments = program == inferredArguments.first
            ? Array(inferredArguments.dropFirst())
            : inferredArguments
        let fallbackLabel = sourceURL.deletingPathExtension().lastPathComponent
        let label = nonEmptyString(dictionary["Label"]) ?? fallbackLabel

        var triggers: [String] = []
        if bool(dictionary["RunAtLoad"]) == true {
            triggers.append(String(localized: "At login"))
        }
        if let keepAlive = dictionary["KeepAlive"] {
            if bool(keepAlive) == true {
                triggers.append(String(localized: "Keep alive"))
            } else if let conditions = keepAlive as? [String: Any], !conditions.isEmpty {
                triggers.append(String(localized: "Conditional keep alive"))
            }
        }
        if let interval = number(dictionary["StartInterval"]), interval.intValue > 0 {
            triggers.append(String(format: String(localized: "Every %lld seconds"), Int64(interval.intValue)))
        }
        if dictionary["StartCalendarInterval"] != nil {
            triggers.append(String(localized: "Scheduled"))
        }
        if !stringArray(dictionary["WatchPaths"]).isEmpty {
            triggers.append(String(localized: "Watches paths"))
        }
        if !stringArray(dictionary["QueueDirectories"]).isEmpty {
            triggers.append(String(localized: "Watches folders"))
        }
        if bool(dictionary["NetworkState"]) == true {
            triggers.append(String(localized: "Network state"))
        }

        return PerformanceStartupItem(
            label: label,
            program: program,
            arguments: arguments,
            sourceURL: sourceURL,
            domain: domain,
            isDisabled: bool(dictionary["Disabled"]) == true,
            triggers: triggers
        )
    }

    static func parseTimeMachineSnapshots(_ output: String) -> [PerformanceSnapshot] {
        output
            .split(whereSeparator: \Character.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Snapshots for disk") }
            .map { identifier in
                let kind: PerformanceSnapshot.Kind
                if identifier.hasPrefix("com.apple.TimeMachine.") {
                    kind = .timeMachine
                } else if identifier.hasPrefix("com.apple.os.update-") {
                    kind = .systemUpdate
                } else {
                    kind = .local
                }
                return PerformanceSnapshot(
                    identifier: identifier,
                    kind: kind,
                    date: snapshotDate(from: identifier)
                )
            }
            .sorted { left, right in
                switch (left.date, right.date) {
                case let (leftDate?, rightDate?): return leftDate > rightDate
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return left.identifier < right.identifier
                }
            }
    }

    static func deletionTimestamp(for snapshot: PerformanceSnapshot) -> String? {
        guard snapshot.kind == .timeMachine else { return nil }
        let prefix = "com.apple.TimeMachine."
        let suffix = ".local"
        guard snapshot.identifier.hasPrefix(prefix), snapshot.identifier.hasSuffix(suffix) else { return nil }
        let start = snapshot.identifier.index(snapshot.identifier.startIndex, offsetBy: prefix.count)
        let end = snapshot.identifier.index(snapshot.identifier.endIndex, offsetBy: -suffix.count)
        let timestamp = String(snapshot.identifier[start..<end])
        let separators = Set([4, 7, 10])
        guard timestamp.utf8.count == 17,
              timestamp.utf8.enumerated().allSatisfy({ index, byte in
                  separators.contains(index) ? byte == 45 : (48...57).contains(byte)
              }),
              parseSnapshotTimestamp(timestamp) != nil else { return nil }
        return timestamp
    }

    private static func scanStartupItems() async throws -> StartupScanResult {
        try await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager()
            var items: [PerformanceStartupItem] = []
            var issues: [PerformanceInspectionIssue] = []

            for (directory, domain) in startupDirectories {
                try Task.checkCancellation()
                guard fileManager.fileExists(atPath: directory.path) else { continue }

                let files: [URL]
                do {
                    files = try fileManager.contentsOfDirectory(
                        at: directory,
                        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                        options: [.skipsHiddenFiles]
                    )
                } catch {
                    issues.append(
                        PerformanceInspectionIssue(
                            title: String(format: String(localized: "Could not read %@"), directory.path),
                            detail: error.localizedDescription
                        )
                    )
                    continue
                }

                for file in files where file.pathExtension.lowercased() == "plist" {
                    try Task.checkCancellation()
                    do {
                        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                        guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                        let data = try Data(contentsOf: file, options: [.mappedIfSafe])
                        items.append(try parseLaunchItem(data: data, sourceURL: file, domain: domain))
                    } catch {
                        issues.append(
                            PerformanceInspectionIssue(
                                title: String(format: String(localized: "Could not inspect %@"), file.lastPathComponent),
                                detail: error.localizedDescription
                            )
                        )
                    }
                }
            }

            return StartupScanResult(
                items: items.sorted {
                    if $0.domain != $1.domain {
                        return domainOrder($0.domain) < domainOrder($1.domain)
                    }
                    return $0.label.localizedStandardCompare($1.label) == .orderedAscending
                },
                issues: issues
            )
        }.value
    }

    private static func scanSnapshots() async throws -> (
        snapshots: [PerformanceSnapshot],
        issues: [PerformanceInspectionIssue]
    ) {
        let executable = URL(fileURLWithPath: "/usr/bin/tmutil")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            return (
                [],
                [PerformanceInspectionIssue(
                    title: String(localized: "Time Machine snapshots are unavailable"),
                    detail: String(localized: "tmutil is not available on this Mac.")
                )]
            )
        }

        do {
            let result = try await runCommand(
                executable: executable,
                arguments: ["listlocalsnapshots", "/"],
                timeout: 10
            )
            guard result.status == 0 else {
                throw PerformanceInspectorError.commandFailed(
                    "tmutil listlocalsnapshots",
                    result.status,
                    result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            return (parseTimeMachineSnapshots(result.standardOutput), [])
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return (
                [],
                [PerformanceInspectionIssue(
                    title: String(localized: "Could not list Time Machine snapshots"),
                    detail: error.localizedDescription
                )]
            )
        }
    }

    private static func runCommand(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> CommandResult {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = standardOutput
        process.standardError = standardError

        try Task.checkCancellation()
        try process.run()

        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: CommandResult.self) { group in
                group.addTask {
                    let outputReader = Task.detached {
                        standardOutput.fileHandleForReading.readDataToEndOfFile()
                    }
                    let errorReader = Task.detached {
                        standardError.fileHandleForReading.readDataToEndOfFile()
                    }
                    process.waitUntilExit()
                    let outputData = await outputReader.value
                    let errorData = await errorReader.value
                    return CommandResult(
                        status: process.terminationStatus,
                        standardOutput: String(decoding: outputData, as: UTF8.self),
                        standardError: String(decoding: errorData, as: UTF8.self)
                    )
                }
                group.addTask {
                    let nanoseconds = UInt64(max(0.1, timeout) * 1_000_000_000)
                    try await Task.sleep(nanoseconds: nanoseconds)
                    if process.isRunning {
                        process.terminate()
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                    }
                    if process.isRunning {
                        Darwin.kill(process.processIdentifier, SIGKILL)
                    }
                    throw PerformanceInspectorError.timedOut(executable.lastPathComponent)
                }

                guard let result = try await group.next() else {
                    throw CancellationError()
                }
                group.cancelAll()
                try Task.checkCancellation()
                return result
            }
        } onCancel: {
            if process.isRunning {
                process.terminate()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                    if process.isRunning {
                        Darwin.kill(process.processIdentifier, SIGKILL)
                    }
                }
            }
        }
    }

    private static func snapshotDate(from identifier: String) -> Date? {
        let prefix = "com.apple.TimeMachine."
        let suffix = ".local"
        guard identifier.hasPrefix(prefix), identifier.hasSuffix(suffix) else { return nil }
        let start = identifier.index(identifier.startIndex, offsetBy: prefix.count)
        let end = identifier.index(identifier.endIndex, offsetBy: -suffix.count)
        return parseSnapshotTimestamp(String(identifier[start..<end]))
    }

    private static func parseSnapshotTimestamp(_ timestamp: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.isLenient = false
        guard let date = formatter.date(from: timestamp), formatter.string(from: date) == timestamp else { return nil }
        return date
    }

    private static func domainOrder(_ domain: PerformanceStartupDomain) -> Int {
        switch domain {
        case .userAgent: return 0
        case .systemAgent: return 1
        case .systemDaemon: return 2
        }
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func stringArray(_ value: Any?) -> [String] {
        guard let values = value as? [Any] else { return [] }
        return values.compactMap(nonEmptyString)
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        return nil
    }

    private static func number(_ value: Any?) -> NSNumber? {
        value as? NSNumber
    }
}
