import AppKit
import Darwin
import Foundation

struct ManagedAppUpdate: Identifiable, Hashable, Sendable {
    let token: String
    let installedVersions: [String]
    let currentVersion: String
    let isPinned: Bool

    var id: String { token }

    var installedVersion: String {
        installedVersions.joined(separator: ", ")
    }
}

struct InstalledCaskPresentation: @unchecked Sendable {
    let displayName: String
    let bundlePath: String?
    let icon: NSImage?
    let isBundleMissing: Bool
}

enum ApplicationUpdaterError: LocalizedError, Equatable {
    case homebrewNotInstalled
    case invalidResponse
    case invalidCaskIdentifier(String)
    case noSelection
    case commandFailed(String)
    case timedOut
    case outputLimitExceeded

    var errorDescription: String? {
        switch self {
        case .homebrewNotInstalled:
            return String(localized: "Homebrew was not found in a standard installation location.")
        case .invalidResponse:
            return String(localized: "Homebrew returned update information PureMac could not read.")
        case .invalidCaskIdentifier(let token):
            return String(localized: "Homebrew returned an invalid cask identifier: \(token)")
        case .noSelection:
            return String(localized: "Select at least one app to update.")
        case .commandFailed(let message):
            return message
        case .timedOut:
            return String(localized: "Homebrew did not finish before the operation timed out.")
        case .outputLimitExceeded:
            return String(localized: "Homebrew produced more output than PureMac could safely retain.")
        }
    }
}

@MainActor
final class ApplicationUpdater: ObservableObject {
    nonisolated static let trustedBrewPaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]

    @Published private(set) var updates: [ManagedAppUpdate] = []
    @Published private(set) var isChecking = false
    @Published private(set) var isUpgrading = false
    @Published private(set) var hasChecked = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var statusMessage: String?
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var brewURL: URL?
    @Published private(set) var caskPresentations: [String: InstalledCaskPresentation] = [:]
    @Published var selectedTokens: Set<String> = []

    init() {
        brewURL = Self.findBrewExecutable()
    }

    var isHomebrewAvailable: Bool { brewURL != nil }
    var isBusy: Bool { isChecking || isUpgrading }
    var selectedCount: Int { selectedTokens.count }

    func refreshAvailability() {
        brewURL = Self.findBrewExecutable()
    }

    func setSelected(_ selected: Bool, token: String) {
        guard updates.contains(where: { $0.token == token && !$0.isPinned }) else { return }
        if selected {
            selectedTokens.insert(token)
        } else {
            selectedTokens.remove(token)
        }
    }

    func checkForUpdates() async {
        guard !isBusy else { return }
        refreshAvailability()
        guard let brewURL else {
            errorMessage = ApplicationUpdaterError.homebrewNotInstalled.localizedDescription
            hasChecked = false
            return
        }

        isChecking = true
        errorMessage = nil
        statusMessage = nil
        defer { isChecking = false }

        do {
            updates = try await Self.fetchUpdates(using: brewURL)
            caskPresentations = await Self.fetchCaskPresentations(for: updates, using: brewURL)
            selectedTokens.formIntersection(Set(updates.filter { !$0.isPinned }.map(\.token)))
            hasChecked = true
            lastCheckedAt = Date()
        } catch is CancellationError {
            return
        } catch {
            errorMessage = Self.displayMessage(for: error)
        }
    }

    func upgrade(_ selection: [ManagedAppUpdate]) async {
        guard !isBusy else { return }
        guard let brewURL else {
            errorMessage = ApplicationUpdaterError.homebrewNotInstalled.localizedDescription
            return
        }

        let availableTokens = Set(updates.filter { !$0.isPinned }.map(\.token))
        let tokens = selection
            .filter { availableTokens.contains($0.token) && !$0.isPinned }
            .map(\.token)
            .sorted()

        isUpgrading = true
        errorMessage = nil
        statusMessage = nil
        defer { isUpgrading = false }

        do {
            let arguments = try Self.upgradeArguments(caskTokens: tokens)
            let output = try await BrewProcessRunner.run(
                executableURL: brewURL,
                arguments: arguments,
                timeout: 1_800
            )
            guard output.status == 0 else {
                throw ApplicationUpdaterError.commandFailed(Self.failureMessage(from: output))
            }

            do {
                updates = try await Self.fetchUpdates(using: brewURL)
                caskPresentations = await Self.fetchCaskPresentations(for: updates, using: brewURL)
                hasChecked = true
                lastCheckedAt = Date()
                let remaining = Set(updates.map(\.token)).intersection(tokens)
                selectedTokens.formIntersection(Set(updates.filter { !$0.isPinned }.map(\.token)))
                if remaining.isEmpty {
                    statusMessage = tokens.count == 1
                        ? String(localized: "Homebrew updated the selected app.")
                        : String(localized: "Homebrew updated the \(tokens.count) selected apps.")
                } else {
                    statusMessage = remaining.count == 1
                        ? String(localized: "Homebrew finished, but 1 selected app still reports an update.")
                        : String(localized: "Homebrew finished, but \(remaining.count) selected apps still report updates.")
                }
            } catch is CancellationError {
                statusMessage = String(localized: "Homebrew finished. Check again to verify installed versions.")
            } catch {
                statusMessage = String(localized: "Homebrew finished. Check again to verify installed versions.")
                errorMessage = Self.displayMessage(for: error)
            }
        } catch is CancellationError {
            return
        } catch {
            errorMessage = Self.displayMessage(for: error)
        }
    }

    func openAppStoreUpdates() {
        guard let url = URL(string: "macappstore://showUpdatesPage") else { return }
        NSWorkspace.shared.open(url)
    }

    nonisolated static func parseOutdatedCasks(_ data: Data) throws -> [ManagedAppUpdate] {
        let payload: OutdatedPayload
        do {
            payload = try JSONDecoder().decode(OutdatedPayload.self, from: data)
        } catch {
            throw ApplicationUpdaterError.invalidResponse
        }

        var seenTokens = Set<String>()
        return try payload.casks.map { cask in
            guard isValidCaskIdentifier(cask.name),
                  !cask.installedVersions.isEmpty,
                  !cask.currentVersion.isEmpty
            else {
                if !isValidCaskIdentifier(cask.name) {
                    throw ApplicationUpdaterError.invalidCaskIdentifier(cask.name)
                }
                throw ApplicationUpdaterError.invalidResponse
            }
            guard seenTokens.insert(cask.name).inserted else {
                throw ApplicationUpdaterError.invalidResponse
            }
            return ManagedAppUpdate(
                token: cask.name,
                installedVersions: cask.installedVersions,
                currentVersion: cask.currentVersion,
                isPinned: cask.pinned
            )
        }
        .sorted { $0.token.localizedStandardCompare($1.token) == .orderedAscending }
    }

    nonisolated static func parseOutdatedCasks(_ json: String) throws -> [ManagedAppUpdate] {
        guard let data = json.data(using: .utf8) else {
            throw ApplicationUpdaterError.invalidResponse
        }
        return try parseOutdatedCasks(data)
    }

    nonisolated static func isValidCaskIdentifier(_ token: String) -> Bool {
        guard !token.isEmpty, token.count <= 128,
              let first = token.unicodeScalars.first,
              isLowercaseLetterOrDigit(first)
        else { return false }

        return token.unicodeScalars.dropFirst().allSatisfy { scalar in
            isLowercaseLetterOrDigit(scalar) || "+-.@_".unicodeScalars.contains(scalar)
        }
    }

    nonisolated static func upgradeArguments(caskTokens: [String]) throws -> [String] {
        guard !caskTokens.isEmpty else { throw ApplicationUpdaterError.noSelection }
        for token in caskTokens where !isValidCaskIdentifier(token) {
            throw ApplicationUpdaterError.invalidCaskIdentifier(token)
        }
        return ["upgrade", "--cask", "--"] + caskTokens
    }

    nonisolated static func parseCaskPresentationDescriptors(
        _ data: Data,
        requestedTokens: Set<String>
    ) throws -> [String: (displayName: String, bundlePaths: [String])] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let casks = root["casks"] as? [[String: Any]]
        else { throw ApplicationUpdaterError.invalidResponse }

        var result: [String: (displayName: String, bundlePaths: [String])] = [:]
        for cask in casks {
            guard let token = cask["token"] as? String,
                  requestedTokens.contains(token),
                  isValidCaskIdentifier(token)
            else { continue }

            let names = cask["name"] as? [String]
            let displayName = names?.first(where: { !$0.isEmpty })
                ?? token
            let artifacts = cask["artifacts"] as? [[String: Any]] ?? []
            var bundlePaths: [String] = []

            for artifact in artifacts {
                guard let apps = artifact["app"] as? [Any] else { continue }
                let explicitTarget = artifact["target"] as? String
                for case let app as String in apps where app.hasSuffix(".app") {
                    let proposedPath = explicitTarget ?? "/Applications/\((app as NSString).lastPathComponent)"
                    if let path = trustedApplicationPath(proposedPath) {
                        bundlePaths.append(path)
                    }
                }
            }

            result[token] = (displayName, Array(Set(bundlePaths)).sorted())
        }
        return result
    }

    nonisolated static func findBrewExecutable(
        isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)
    ) -> URL? {
        trustedBrewPaths.first(where: isExecutable).map { URL(fileURLWithPath: $0) }
    }

    nonisolated private static func isLowercaseLetterOrDigit(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 97 && scalar.value <= 122) || (scalar.value >= 48 && scalar.value <= 57)
    }

    nonisolated private static func displayMessage(for error: Error) -> String {
        if let updaterError = error as? ApplicationUpdaterError {
            return updaterError.localizedDescription
        }
        return error.localizedDescription
    }

    nonisolated private static func failureMessage(from output: BrewProcessOutput) -> String {
        let stderr = String(decoding: output.stderr, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stdout = String(decoding: output.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = stderr.isEmpty ? stdout : stderr
        return detail.isEmpty ? String(localized: "Homebrew exited with status \(output.status).") : detail
    }

    nonisolated private static func fetchUpdates(using brewURL: URL) async throws -> [ManagedAppUpdate] {
        let output = try await BrewProcessRunner.run(
            executableURL: brewURL,
            arguments: ["outdated", "--cask", "--json=v2"],
            timeout: 300
        )
        guard output.status == 0 else {
            throw ApplicationUpdaterError.commandFailed(failureMessage(from: output))
        }
        return try parseOutdatedCasks(output.stdout)
    }

    nonisolated private static func fetchCaskPresentations(
        for updates: [ManagedAppUpdate],
        using brewURL: URL
    ) async -> [String: InstalledCaskPresentation] {
        let tokens = updates.map(\.token)
        guard !tokens.isEmpty,
              let output = try? await BrewProcessRunner.run(
                executableURL: brewURL,
                arguments: ["info", "--json=v2", "--cask", "--"] + tokens,
                timeout: 60
              ),
              output.status == 0,
              let descriptors = try? parseCaskPresentationDescriptors(
                output.stdout,
                requestedTokens: Set(tokens)
              )
        else { return [:] }

        return await Task.detached(priority: .utility) {
            var presentations: [String: InstalledCaskPresentation] = [:]
            for (token, descriptor) in descriptors {
                let existingPath = descriptor.bundlePaths.first {
                    FileManager.default.fileExists(atPath: $0)
                }
                let icon = existingPath.map { NSWorkspace.shared.icon(forFile: $0) }
                presentations[token] = InstalledCaskPresentation(
                    displayName: descriptor.displayName,
                    bundlePath: existingPath ?? descriptor.bundlePaths.first,
                    icon: icon,
                    isBundleMissing: !descriptor.bundlePaths.isEmpty && existingPath == nil
                )
            }
            return presentations
        }.value
    }

    nonisolated private static func trustedApplicationPath(_ rawPath: String) -> String? {
        let expanded = (rawPath as NSString).expandingTildeInPath
        let standardized = (expanded as NSString).standardizingPath
        guard (standardized as NSString).pathExtension.lowercased() == "app" else { return nil }
        let roots = ["/Applications", "\(FileManager.default.homeDirectoryForCurrentUser.path)/Applications"]
        guard roots.contains(where: { standardized.hasPrefix($0 + "/") }) else { return nil }
        return standardized
    }

    private struct OutdatedPayload: Decodable {
        let casks: [OutdatedCask]
    }

    private struct OutdatedCask: Decodable {
        let name: String
        let installedVersions: [String]
        let currentVersion: String
        let pinned: Bool

        enum CodingKeys: String, CodingKey {
            case name
            case installedVersions = "installed_versions"
            case currentVersion = "current_version"
            case pinned
        }
    }
}

struct BrewProcessOutput: Sendable {
    let stdout: Data
    let stderr: Data
    let status: Int32
}

enum BrewProcessRunner {
    static let maxCapturedBytes = 4 * 1_024 * 1_024

    static func run(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval,
        environment: [String: String]? = nil
    ) async throws -> BrewProcessOutput {
        let handle = BrewProcessHandle()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let execution = BrewProcessExecution(
                    executableURL: executableURL,
                    arguments: arguments,
                    timeout: timeout,
                    environment: environment,
                    continuation: continuation
                )
                handle.attach(execution)
                execution.start()
            }
        } onCancel: {
            handle.cancel()
        }
    }
}

private final class BrewProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var execution: BrewProcessExecution?
    private var cancelled = false

    func attach(_ execution: BrewProcessExecution) {
        lock.lock()
        self.execution = execution
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { execution.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let execution = execution
        lock.unlock()
        execution?.cancel()
    }
}

private final class BrewProcessExecution: @unchecked Sendable {
    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private lazy var stdoutReader = BrewPipeReader(maxBytes: BrewProcessRunner.maxCapturedBytes) { [weak self] in
        self?.failForOutputLimit()
    }
    private lazy var stderrReader = BrewPipeReader(maxBytes: BrewProcessRunner.maxCapturedBytes) { [weak self] in
        self?.failForOutputLimit()
    }
    private let readers = DispatchGroup()
    private let timeout: TimeInterval
    private let continuation: CheckedContinuation<BrewProcessOutput, Error>
    private let lock = NSLock()
    private var startupError: Error?
    private var timedOut = false
    private var cancelled = false
    private var outputLimitExceeded = false
    private var completed = false
    private var started = false
    private var selfRetainer: BrewProcessExecution?

    init(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval,
        environment: [String: String]?,
        continuation: CheckedContinuation<BrewProcessOutput, Error>
    ) {
        self.timeout = timeout
        self.continuation = continuation
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        var childEnvironment = environment ?? ProcessInfo.processInfo.environment
        childEnvironment["HOMEBREW_NO_ANALYTICS"] = "1"
        childEnvironment["HOMEBREW_NO_ENV_HINTS"] = "1"
        childEnvironment["HOMEBREW_NO_ASK"] = "1"
        childEnvironment["HOMEBREW_NO_COLOR"] = "1"
        process.environment = childEnvironment
    }

    func start() {
        lock.lock()
        selfRetainer = self
        let wasCancelled = cancelled
        lock.unlock()

        readers.enter()
        stdoutReader.start(stdoutPipe.fileHandleForReading) { [readers] in readers.leave() }
        readers.enter()
        stderrReader.start(stderrPipe.fileHandleForReading) { [readers] in readers.leave() }

        if wasCancelled {
            lock.lock()
            startupError = CancellationError()
            lock.unlock()
            closeWriters()
            finishWhenDrained()
            return
        }

        process.terminationHandler = { [weak self] _ in
            self?.closeWriters()
            self?.finishWhenDrained()
        }

        do {
            try process.run()
        } catch {
            lock.lock()
            startupError = error
            lock.unlock()
            closeWriters()
            finishWhenDrained()
            return
        }

        lock.lock()
        started = true
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel {
            terminateProcess()
        }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.terminateForTimeout()
        }
    }

    func cancel() {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        cancelled = true
        let hasStarted = started
        let running = process.isRunning
        lock.unlock()

        if !hasStarted {
            return
        } else if running {
            terminateProcess()
        } else {
            forceFinish()
        }
    }

    private func closeWriters() {
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()
    }

    private func finishWhenDrained() {
        readers.notify(queue: .global(qos: .utility)) { [weak self] in
            self?.finish()
        }
    }

    private func terminateForTimeout() {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        timedOut = true
        let running = process.isRunning
        lock.unlock()

        if running {
            terminateProcess()
        } else {
            forceFinish()
        }
    }

    private func failForOutputLimit() {
        lock.lock()
        guard !completed, !outputLimitExceeded else {
            lock.unlock()
            return
        }
        outputLimitExceeded = true
        let running = process.isRunning
        lock.unlock()

        if running {
            terminateProcess()
        } else {
            forceFinish()
        }
    }

    private func terminateProcess() {
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.process.isRunning else { return }
            Darwin.kill(self.process.processIdentifier, SIGKILL)
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.forceFinish()
        }
    }

    private func forceFinish() {
        closeWriters()
        stdoutReader.stop()
        stderrReader.stop()
        finishWhenDrained()
    }

    private func finish() {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let didTimeOut = timedOut
        let wasCancelled = cancelled
        let exceededOutputLimit = outputLimitExceeded
        let launchError = startupError
        selfRetainer = nil
        lock.unlock()

        if let launchError {
            continuation.resume(throwing: launchError)
        } else if didTimeOut {
            continuation.resume(throwing: ApplicationUpdaterError.timedOut)
        } else if wasCancelled {
            continuation.resume(throwing: CancellationError())
        } else if exceededOutputLimit {
            continuation.resume(throwing: ApplicationUpdaterError.outputLimitExceeded)
        } else {
            continuation.resume(returning: BrewProcessOutput(
                stdout: stdoutReader.data,
                stderr: stderrReader.data,
                status: process.terminationStatus
            ))
        }
    }
}

private final class BrewPipeReader: @unchecked Sendable {
    private let lock = NSLock()
    private let maxBytes: Int
    private let onLimitExceeded: @Sendable () -> Void
    private var storage = Data()
    private var finished = false
    private var limitReported = false
    private weak var handle: FileHandle?
    private var completion: (@Sendable () -> Void)?

    init(maxBytes: Int, onLimitExceeded: @escaping @Sendable () -> Void) {
        self.maxBytes = maxBytes
        self.onLimitExceeded = onLimitExceeded
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func start(_ handle: FileHandle, completion: @escaping @Sendable () -> Void) {
        lock.lock()
        self.handle = handle
        self.completion = completion
        lock.unlock()

        handle.readabilityHandler = { [weak self] readable in
            let chunk = readable.availableData
            guard let self else { return }

            self.lock.lock()
            guard !self.finished else {
                self.lock.unlock()
                return
            }
            if chunk.isEmpty {
                self.lock.unlock()
                self.stop()
            } else {
                let remaining = self.maxBytes - self.storage.count
                if remaining > 0 {
                    self.storage.append(chunk.prefix(remaining))
                }
                let exceededLimit = chunk.count > remaining && !self.limitReported
                if exceededLimit {
                    self.limitReported = true
                }
                self.lock.unlock()
                if exceededLimit {
                    self.onLimitExceeded()
                }
            }
        }
    }

    func stop() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let handle = handle
        let completion = completion
        self.handle = nil
        self.completion = nil
        lock.unlock()

        handle?.readabilityHandler = nil
        try? handle?.close()
        completion?()
    }
}
