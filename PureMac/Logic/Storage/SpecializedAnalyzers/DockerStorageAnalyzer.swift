import Darwin
import Foundation

struct DockerCommandRequest: Equatable, Sendable {
    let executableURL: URL
    let arguments: [String]
}

struct DockerCommandResult: Equatable, Sendable {
    let terminationStatus: Int32
    let stdout: String
    let stderr: String
    let launchError: String?
    let wasCancelled: Bool
}

/// Read-only analysis of Docker's host-side files and runtime-reported usage.
///
/// Host storage is scanned with `FileTreeScanner`. Runtime accounting is kept
/// as a separate, non-additive view obtained from structured Docker CLI
/// inspection commands. This analyzer has no dependency on `CleaningEngine`.
struct DockerStorageAnalyzer: Sendable {
    typealias ExecutableLocator = @Sendable () -> URL?
    typealias CommandRunner = @Sendable (DockerCommandRequest) async -> DockerCommandResult

    static let contextInspectionArguments = ["context", "inspect", "--format", "json"]
    static let runtimeAccountingArguments = ["system", "df", "--format", "json"]

    static var currentUserHostStorageRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let library = home.appendingPathComponent("Library", isDirectory: true)
        return [
            library
                .appendingPathComponent("Containers", isDirectory: true)
                .appendingPathComponent("com.docker.docker", isDirectory: true),
            library
                .appendingPathComponent("Group Containers", isDirectory: true)
                .appendingPathComponent("group.com.docker", isDirectory: true),
            library
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("Docker Desktop", isDirectory: true),
            library
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("com.docker.docker", isDirectory: true),
            home.appendingPathComponent(".docker", isDirectory: true),
        ]
    }

    private let hostStorageRoots: [URL]
    private let scanner: FileTreeScanner
    private let executableLocator: ExecutableLocator
    private let commandRunner: CommandRunner

    init(
        hostStorageRoots: [URL] = DockerStorageAnalyzer.currentUserHostStorageRoots,
        scanner: FileTreeScanner = FileTreeScanner(),
        executableLocator: @escaping ExecutableLocator = {
            DockerStorageAnalyzer.discoverDockerExecutable()
        },
        commandRunner: @escaping CommandRunner = { request in
            await DockerStorageAnalyzer.runReadOnlyCommand(request)
        }
    ) {
        self.hostStorageRoots = hostStorageRoots
        self.scanner = scanner
        self.executableLocator = executableLocator
        self.commandRunner = commandRunner
    }

    func analyze() async -> DockerStorageReport {
        let roots = Self.existingNonOverlappingRoots(hostStorageRoots)
        var hostResults: [StorageAnalysisResult] = []

        for root in roots {
            guard !Task.isCancelled else { break }
            hostResults.append(await scanner.scan(root: root))
        }

        let hostFootprint = await Task.detached(priority: .utility) {
            Self.makeHostFootprint(from: hostResults)
        }.value
        let virtualDisks = await Task.detached(priority: .utility) {
            Self.findVirtualDisks(in: hostResults)
        }.value
        var issues = Self.filesystemIssues(from: hostResults)

        guard !Task.isCancelled,
              !hostResults.contains(where: \.wasCancelled) else {
            issues.append(.init(
                kind: .cancelled,
                message: "Docker storage analysis was cancelled.",
                path: nil
            ))
            return Self.report(
                hostFootprint: hostFootprint,
                virtualDisks: virtualDisks,
                runtimeStatus: .cancelled,
                runtimeAccounting: nil,
                dockerExecutablePath: nil,
                wasCancelled: true,
                issues: issues
            )
        }

        guard let executableURL = executableLocator() else {
            issues.append(.init(
                kind: .executableNotFound,
                message: "Docker CLI was not found in a supported application or executable path.",
                path: nil
            ))
            return Self.report(
                hostFootprint: hostFootprint,
                virtualDisks: virtualDisks,
                runtimeStatus: .notInstalled,
                runtimeAccounting: nil,
                dockerExecutablePath: nil,
                wasCancelled: false,
                issues: issues
            )
        }

        let contextCommandResult = await commandRunner(DockerCommandRequest(
            executableURL: executableURL,
            arguments: Self.contextInspectionArguments
        ))

        if Task.isCancelled || contextCommandResult.wasCancelled {
            issues.append(.init(
                kind: .cancelled,
                message: "Docker context inspection was cancelled.",
                path: nil
            ))
            return Self.report(
                hostFootprint: hostFootprint,
                virtualDisks: virtualDisks,
                runtimeStatus: .cancelled,
                runtimeAccounting: nil,
                dockerExecutablePath: executableURL.path,
                wasCancelled: true,
                issues: issues
            )
        }

        let contextInspection = Self.inspectRuntimeContext(contextCommandResult)
        if let issue = contextInspection.issue {
            issues.append(issue)
        }

        let commandResult = await commandRunner(DockerCommandRequest(
            executableURL: executableURL,
            arguments: Self.runtimeAccountingArguments
        ))

        if Task.isCancelled || commandResult.wasCancelled {
            issues.append(.init(
                kind: .cancelled,
                message: "Docker runtime accounting was cancelled.",
                path: nil
            ))
            return Self.report(
                hostFootprint: hostFootprint,
                virtualDisks: virtualDisks,
                runtimeStatus: .cancelled,
                runtimeAccounting: nil,
                dockerExecutablePath: executableURL.path,
                runtimeContext: contextInspection.context,
                wasCancelled: true,
                issues: issues
            )
        }

        guard commandResult.launchError == nil, commandResult.terminationStatus == 0 else {
            let detail = Self.commandFailureDetail(commandResult)
            let daemonUnavailable = Self.indicatesUnavailableDaemon(detail)
            issues.append(.init(
                kind: daemonUnavailable ? .daemonUnavailable : .commandFailed,
                message: detail,
                path: nil
            ))
            return Self.report(
                hostFootprint: hostFootprint,
                virtualDisks: virtualDisks,
                runtimeStatus: daemonUnavailable ? .installedDaemonUnavailable : .commandFailed,
                runtimeAccounting: nil,
                dockerExecutablePath: executableURL.path,
                runtimeContext: contextInspection.context,
                wasCancelled: false,
                issues: issues
            )
        }

        let parsed = Self.parseRuntimeAccounting(commandResult.stdout)
        if parsed.isPartial {
            issues.append(.init(
                kind: .malformedRuntimeOutput,
                message: "Docker returned incomplete or malformed structured storage accounting.",
                path: nil
            ))
        }

        return Self.report(
            hostFootprint: hostFootprint,
            virtualDisks: virtualDisks,
            runtimeStatus: parsed.isPartial ? .partiallyReadable : .installedAndReachable,
            runtimeAccounting: parsed.accounting,
            dockerExecutablePath: executableURL.path,
            runtimeContext: contextInspection.context,
            wasCancelled: false,
            issues: issues
        )
    }
}

// MARK: - Active Context Inspection

private extension DockerStorageAnalyzer {
    struct ContextInspectionResult {
        let context: DockerRuntimeContext
        let issue: DockerStorageIssue?
    }

    static func inspectRuntimeContext(
        _ result: DockerCommandResult
    ) -> ContextInspectionResult {
        guard result.launchError == nil, result.terminationStatus == 0 else {
            let detail = contextFailureDetail(result)
            return ContextInspectionResult(
                context: .unknown,
                issue: DockerStorageIssue(
                    kind: .contextInspectionFailed,
                    message: detail,
                    path: nil
                )
            )
        }

        guard let object = contextObject(from: result.stdout) else {
            return ContextInspectionResult(
                context: .unknown,
                issue: DockerStorageIssue(
                    kind: .contextInspectionFailed,
                    message: "Docker returned malformed structured context information.",
                    path: nil
                )
            )
        }

        let name = nonemptyString(caseInsensitiveValue(named: "Name", in: object))
        let endpoints = caseInsensitiveValue(named: "Endpoints", in: object) as? [String: Any]
        let dockerEndpoint = endpoints.flatMap { dictionary in
            dictionary.first { $0.key.caseInsensitiveCompare("docker") == .orderedSame }?.value
                as? [String: Any]
        }
        let rawEndpoint = dockerEndpoint.flatMap {
            nonemptyString(caseInsensitiveValue(named: "Host", in: $0))
        }
        let location = rawEndpoint.map(runtimeLocation(for:)) ?? .unknown
        let context = DockerRuntimeContext(
            name: name,
            sanitizedEndpoint: rawEndpoint.flatMap(sanitizeEndpoint),
            location: location
        )

        guard location == .unknown else {
            return ContextInspectionResult(context: context, issue: nil)
        }
        return ContextInspectionResult(
            context: context,
            issue: DockerStorageIssue(
                kind: .runtimeLocationUnknown,
                message: rawEndpoint == nil
                    ? "The active Docker context did not provide a Docker endpoint."
                    : "The active Docker endpoint could not be reliably classified as local or remote.",
                path: nil
            )
        )
    }

    static func contextObject(from output: String) -> [String: Any]? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8), !data.isEmpty,
              let value = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        if let object = value as? [String: Any] { return object }
        if let objects = value as? [[String: Any]], objects.count == 1 {
            return objects[0]
        }
        return nil
    }

    static func caseInsensitiveValue(
        named name: String,
        in dictionary: [String: Any]
    ) -> Any? {
        dictionary.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    static func nonemptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(512))
    }

    static func runtimeLocation(for endpoint: String) -> DockerRuntimeLocation {
        guard let components = URLComponents(string: endpoint),
              let scheme = components.scheme?.lowercased() else {
            return .unknown
        }

        switch scheme {
        case "unix":
            let host = components.host?.lowercased()
            guard (host == nil || host == "" || host == "localhost"),
                  components.path.hasPrefix("/") else {
                return .unknown
            }
            return .local
        case "ssh":
            return .remote
        case "tcp", "http", "https":
            guard let host = components.host, !host.isEmpty else { return .unknown }
            return isLoopbackHost(host) ? .unknown : .remote
        default:
            return .unknown
        }
    }

    static func isLoopbackHost(_ host: String) -> Bool {
        let normalized = host.lowercased()
        return normalized == "localhost"
            || normalized == "127.0.0.1"
            || normalized == "::1"
            || normalized.hasPrefix("127.")
    }

    static func sanitizeEndpoint(_ endpoint: String) -> String? {
        guard let components = URLComponents(string: endpoint),
              let scheme = components.scheme?.lowercased() else {
            return "<unrecognized endpoint>"
        }

        if scheme == "unix" {
            guard components.path.hasPrefix("/") else { return "unix://<redacted>" }
            return "unix://\(sanitizeUnixSocketPath(components.path))"
        }

        guard let host = components.host, !host.isEmpty else {
            return "\(scheme)://<redacted>"
        }
        let displayedHost = host.contains(":") ? "[\(host)]" : host
        let port = components.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(displayedHost)\(port)"
    }

    static func sanitizeUnixSocketPath(_ path: String) -> String {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        if path == homePath { return "~" }
        if path.hasPrefix(homePath + "/") {
            return "~/" + path.dropFirst(homePath.count + 1)
        }

        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        if components.count >= 2, components[0] == "Users" {
            return "/Users/<redacted>/" + components.dropFirst(2).joined(separator: "/")
        }
        return path
    }

    static func relationship(
        for location: DockerRuntimeLocation
    ) -> DockerHostRuntimeRelationship {
        switch location {
        case .local: return .localRuntimeMayExplainHostFootprint
        case .remote: return .remoteRuntimeNotRelatedToHostFootprint
        case .unknown: return .unknownRelationship
        }
    }

    static func contextFailureDetail(_ result: DockerCommandResult) -> String {
        if result.launchError != nil {
            return "Docker context inspection could not be launched."
        }
        return "Docker context inspection failed with exit status \(result.terminationStatus)."
    }
}

// MARK: - Host Footprint

private extension DockerStorageAnalyzer {
    static func existingNonOverlappingRoots(_ candidates: [URL]) -> [URL] {
        let uniquePaths = Set(candidates.map { $0.standardizedFileURL.path })
        let existingPaths = uniquePaths.filter(pathExistsWithoutFollowingLinks)
        let orderedPaths = existingPaths.sorted {
            let leftDepth = $0.split(separator: "/").count
            let rightDepth = $1.split(separator: "/").count
            if leftDepth != rightDepth { return leftDepth < rightDepth }
            return $0 < $1
        }

        var retained: [String] = []
        for path in orderedPaths {
            guard !retained.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else {
                continue
            }
            retained.append(path)
        }
        return retained.sorted().map { URL(fileURLWithPath: $0) }
    }

    static func pathExistsWithoutFollowingLinks(_ path: String) -> Bool {
        var metadata = stat()
        return lstat(path, &metadata) == 0
    }

    static func makeHostFootprint(
        from results: [StorageAnalysisResult]
    ) -> DockerHostFootprint {
        DockerHostFootprint(
            locations: results.sorted { $0.root.absolutePath < $1.root.absolutePath },
            logicalSize: results.reduce(0) { $0 + $1.root.logicalSize },
            allocatedSize: results.reduce(0) { $0 + $1.root.allocatedSize }
        )
    }

    static func filesystemIssues(
        from results: [StorageAnalysisResult]
    ) -> [DockerStorageIssue] {
        results.flatMap(\.issues).map {
            DockerStorageIssue(
                kind: .filesystem,
                message: $0.message,
                path: $0.path
            )
        }
    }

    static func findVirtualDisks(
        in results: [StorageAnalysisResult]
    ) -> [DockerVirtualDisk] {
        var disks: [DockerVirtualDisk] = []
        var pending = results.map(\.root)

        while let node = pending.popLast() {
            if !node.isSymbolicLink,
               let format = virtualDiskFormat(for: node) {
                disks.append(DockerVirtualDisk(
                    storageNode: node,
                    format: format,
                    sparseState: sparseState(for: node)
                ))
            }
            pending.append(contentsOf: node.children)
        }

        return disks.sorted {
            if $0.allocatedSize != $1.allocatedSize {
                return $0.allocatedSize > $1.allocatedSize
            }
            if $0.logicalSize != $1.logicalSize {
                return $0.logicalSize > $1.logicalSize
            }
            return $0.absolutePath < $1.absolutePath
        }
    }

    static func virtualDiskFormat(for node: StorageNode) -> DockerVirtualDiskFormat? {
        guard node.itemType == .regularFile || node.itemType == .directory else {
            return nil
        }

        switch URL(fileURLWithPath: node.absolutePath).pathExtension.lowercased() {
        case "raw": return .raw
        case "img": return .img
        case "qcow2": return .qcow2
        case "vmdk": return .vmdk
        case "sparsebundle": return .sparseBundle
        default: return node.name.localizedCaseInsensitiveCompare("Docker.raw") == .orderedSame
            ? .raw
            : nil
        }
    }

    static func sparseState(for node: StorageNode) -> DockerSparseState {
        guard node.itemType == .regularFile else { return .unknown }
        return node.logicalSize > node.allocatedSize ? .sparse : .notSparse
    }
}

// MARK: - Runtime Parsing

private extension DockerStorageAnalyzer {
    struct RuntimeParseResult {
        let accounting: DockerRuntimeAccounting?
        let isPartial: Bool
    }

    struct ReclaimableValue {
        let bytes: Int64?
        let percentage: Double?
    }

    static func parseRuntimeAccounting(_ output: String) -> RuntimeParseResult {
        let decoded = decodeJSONObjects(output)
        var usages: [DockerRuntimeStorageCategory: DockerRuntimeStorageUsage] = [:]
        var hadMalformedEntry = decoded.malformedCount > 0

        for object in decoded.objects {
            guard let usage = runtimeUsage(from: object) else {
                hadMalformedEntry = true
                continue
            }
            if usages[usage.category] != nil {
                hadMalformedEntry = true
            } else {
                usages[usage.category] = usage
            }
        }

        guard !usages.isEmpty else {
            return RuntimeParseResult(accounting: nil, isPartial: true)
        }

        let accounting = DockerRuntimeAccounting(
            images: usages[.images],
            containers: usages[.containers],
            localVolumes: usages[.localVolumes],
            buildCache: usages[.buildCache]
        )
        return RuntimeParseResult(
            accounting: accounting,
            isPartial: hadMalformedEntry || !accounting.isComplete
        )
    }

    static func decodeJSONObjects(
        _ output: String
    ) -> (objects: [[String: Any]], malformedCount: Int) {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ([], 1) }

        if let data = trimmed.data(using: .utf8),
           let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return (array, 0)
        }
        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return ([object], 0)
        }

        var objects: [[String: Any]] = []
        var malformedCount = 0
        for line in trimmed.split(whereSeparator: \.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                malformedCount += 1
                continue
            }
            objects.append(object)
        }
        return (objects, malformedCount)
    }

    static func runtimeUsage(from object: [String: Any]) -> DockerRuntimeStorageUsage? {
        let values = Dictionary(uniqueKeysWithValues: object.map { ($0.key.lowercased(), $0.value) })
        guard let type = values["type"] as? String,
              let category = runtimeCategory(type) else {
            return nil
        }

        let reclaimable = parseReclaimable(values["reclaimable"])
        return DockerRuntimeStorageUsage(
            category: category,
            totalBytes: parseByteValue(values["size"]),
            reclaimableBytes: reclaimable.bytes,
            reclaimablePercentage: reclaimable.percentage,
            objectCount: parseInteger(values["totalcount"]),
            activeCount: parseInteger(values["active"])
        )
    }

    static func runtimeCategory(_ type: String) -> DockerRuntimeStorageCategory? {
        switch type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "images": return .images
        case "containers": return .containers
        case "local volumes", "volumes": return .localVolumes
        case "build cache", "buildcache": return .buildCache
        default: return nil
        }
    }

    static func parseReclaimable(_ value: Any?) -> ReclaimableValue {
        guard let value else { return ReclaimableValue(bytes: nil, percentage: nil) }
        if let number = value as? NSNumber {
            return ReclaimableValue(bytes: number.int64Value, percentage: nil)
        }
        guard let text = value as? String else {
            return ReclaimableValue(bytes: nil, percentage: nil)
        }

        let byteText = text.split(separator: "(", maxSplits: 1).first.map(String.init) ?? text
        let percentage: Double? = {
            guard let open = text.firstIndex(of: "("),
                  let close = text[open...].firstIndex(of: ")") else {
                return nil
            }
            let raw = text[text.index(after: open)..<close]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "%", with: "")
            return Double(raw)
        }()
        return ReclaimableValue(bytes: parseHumanBytes(byteText), percentage: percentage)
    }

    static func parseByteValue(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let text = value as? String { return parseHumanBytes(text) }
        return nil
    }

    static func parseInteger(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    static func parseHumanBytes(_ value: String) -> Int64? {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
        guard !normalized.isEmpty else { return nil }

        let units: [(suffix: String, multiplier: Double)] = [
            ("PiB", 1_125_899_906_842_624),
            ("TiB", 1_099_511_627_776),
            ("GiB", 1_073_741_824),
            ("MiB", 1_048_576),
            ("KiB", 1_024),
            ("PB", 1_000_000_000_000_000),
            ("TB", 1_000_000_000_000),
            ("GB", 1_000_000_000),
            ("MB", 1_000_000),
            ("kB", 1_000),
            ("B", 1),
        ]
        for unit in units where normalized.lowercased().hasSuffix(unit.suffix.lowercased()) {
            let numberText = String(normalized.dropLast(unit.suffix.count))
            guard let number = Double(numberText), number >= 0 else { return nil }
            let bytes = number * unit.multiplier
            guard bytes <= Double(Int64.max) else { return nil }
            return Int64(bytes)
        }
        return nil
    }
}

// MARK: - Executable Discovery and Read-Only Process Execution

extension DockerStorageAnalyzer {
    static func discoverDockerExecutable(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        var candidatePaths = [
            "/usr/local/bin/docker",
            "/opt/homebrew/bin/docker",
            "/Applications/Docker.app/Contents/Resources/bin/docker",
            "/Applications/OrbStack.app/Contents/MacOS/xbin/docker",
        ]
        if let path = environment["PATH"] {
            candidatePaths.append(contentsOf: path.split(separator: ":").compactMap { directory in
                guard directory.hasPrefix("/") else { return nil }
                return URL(fileURLWithPath: String(directory), isDirectory: true)
                    .appendingPathComponent("docker", isDirectory: false)
                    .path
            })
        }

        var visited = Set<String>()
        for path in candidatePaths {
            let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
            guard visited.insert(standardizedPath).inserted,
                  fileManager.isExecutableFile(atPath: standardizedPath) else {
                continue
            }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: standardizedPath, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                continue
            }
            return URL(fileURLWithPath: standardizedPath).resolvingSymlinksInPath()
        }
        return nil
    }

    static func runReadOnlyCommand(_ request: DockerCommandRequest) async -> DockerCommandResult {
        let cancellation = DockerProcessCancellationState()
        let worker = Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = request.executableURL
            process.arguments = request.arguments
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            guard cancellation.register(process) else {
                return DockerCommandResult(
                    terminationStatus: -1,
                    stdout: "",
                    stderr: "",
                    launchError: nil,
                    wasCancelled: true
                )
            }

            do {
                try process.run()
            } catch {
                return DockerCommandResult(
                    terminationStatus: -1,
                    stdout: "",
                    stderr: "",
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
            let stdoutData = await stdoutTask.value
            let stderrData = await stderrTask.value

            return DockerCommandResult(
                terminationStatus: process.terminationStatus,
                stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                stderr: String(data: stderrData, encoding: .utf8) ?? "",
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

private extension DockerStorageAnalyzer {
    static func report(
        hostFootprint: DockerHostFootprint,
        virtualDisks: [DockerVirtualDisk],
        runtimeStatus: DockerRuntimeStatus,
        runtimeAccounting: DockerRuntimeAccounting?,
        dockerExecutablePath: String?,
        runtimeContext: DockerRuntimeContext = .unknown,
        wasCancelled: Bool,
        issues: [DockerStorageIssue]
    ) -> DockerStorageReport {
        DockerStorageReport(
            hostFootprint: hostFootprint,
            virtualDisks: virtualDisks,
            runtimeStatus: runtimeStatus,
            runtimeAccounting: runtimeAccounting,
            dockerExecutablePath: dockerExecutablePath,
            runtimeContext: runtimeContext,
            hostRuntimeRelationship: relationship(for: runtimeContext.location),
            accountingRelationship: .runtimeBreakdownIsNonAdditiveToHostFootprint,
            wasCancelled: wasCancelled,
            issues: issues
        )
    }

    static func commandFailureDetail(_ result: DockerCommandResult) -> String {
        let candidate = result.launchError ?? (result.stderr.isEmpty ? result.stdout : result.stderr)
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Docker storage inspection failed with exit status \(result.terminationStatus)."
        }
        return String(trimmed.prefix(1_024))
    }

    static func indicatesUnavailableDaemon(_ detail: String) -> Bool {
        let normalized = detail.lowercased()
        return normalized.contains("cannot connect")
            || normalized.contains("daemon is not running")
            || normalized.contains("is the docker daemon running")
            || normalized.contains("connection refused")
            || normalized.contains("dial unix")
    }
}

private final class DockerProcessCancellationState: @unchecked Sendable {
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
        let runningProcess = process?.isRunning == true ? process : nil
        lock.unlock()
        runningProcess?.terminate()
    }

    func terminateIfCancelled() {
        lock.lock()
        let runningProcess = cancelled && process?.isRunning == true ? process : nil
        lock.unlock()
        runningProcess?.terminate()
    }
}
