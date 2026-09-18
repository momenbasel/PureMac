import Darwin
import Foundation

enum ProtectionCheck: String, CaseIterable, Identifiable, Sendable {
    case gatekeeper
    case fileVault
    case firewall
    case systemIntegrityProtection
    case xProtect

    var id: String { rawValue }
}

enum ProtectionStatus: Sendable, Equatable {
    case enabled
    case disabled
    case unknown
}

struct ProtectionFinding: Identifiable, Sendable, Equatable {
    let check: ProtectionCheck
    let status: ProtectionStatus
    let detail: String
    let version: String?

    var id: ProtectionCheck { check }
}

struct ProtectionSnapshot: Sendable, Equatable {
    let findings: [ProtectionFinding]
    let checkedAt: Date
}

enum ProtectionCommand: CaseIterable, Hashable, Sendable {
    case gatekeeper
    case fileVault
    case firewall
    case systemIntegrityProtection

    var executableURL: URL {
        switch self {
        case .gatekeeper:
            return URL(fileURLWithPath: "/usr/sbin/spctl")
        case .fileVault:
            return URL(fileURLWithPath: "/usr/bin/fdesetup")
        case .firewall:
            return URL(fileURLWithPath: "/usr/libexec/ApplicationFirewall/socketfilterfw")
        case .systemIntegrityProtection:
            return URL(fileURLWithPath: "/usr/bin/csrutil")
        }
    }

    var arguments: [String] {
        switch self {
        case .gatekeeper:
            return ["--status"]
        case .fileVault:
            return ["status"]
        case .firewall:
            return ["--getglobalstate"]
        case .systemIntegrityProtection:
            return ["status"]
        }
    }

    var check: ProtectionCheck {
        switch self {
        case .gatekeeper:
            return .gatekeeper
        case .fileVault:
            return .fileVault
        case .firewall:
            return .firewall
        case .systemIntegrityProtection:
            return .systemIntegrityProtection
        }
    }
}

struct ProtectionCommandResult: Sendable, Equatable {
    let exitCode: Int32?
    let stdout: String
    let stderr: String
    let timedOut: Bool
    let cancelled: Bool
    let launchError: String?

    var succeeded: Bool {
        exitCode == 0 && !timedOut && !cancelled && launchError == nil
    }
}

struct ProtectionProcessRequest: Sendable {
    let executableURL: URL
    let arguments: [String]
}

private final class ProtectionOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let limit = 65_536

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard data.count < limit else { return }
        data.append(chunk.prefix(limit - data.count))
    }

    func string() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class ProtectionProcessController: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancellationRequested = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancellationRequested
    }

    func install(_ process: Process) {
        lock.lock()
        self.process = process
        let shouldStop = cancellationRequested
        lock.unlock()
        if shouldStop { stop(process) }
    }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        let process = process
        lock.unlock()
        if let process { stop(process) }
    }

    private func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let processID = process.processIdentifier
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) {
            guard process.isRunning else { return }
            Darwin.kill(processID, SIGKILL)
        }
    }
}

enum ProtectionCommandRunner {
    static func run(_ command: ProtectionCommand, timeout: TimeInterval = 4) async -> ProtectionCommandResult {
        await run(
            ProtectionProcessRequest(
                executableURL: command.executableURL,
                arguments: command.arguments
            ),
            timeout: timeout
        )
    }

    static func run(
        _ request: ProtectionProcessRequest,
        timeout: TimeInterval
    ) async -> ProtectionCommandResult {
        let controller = ProtectionProcessController()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(
                        returning: runBlocking(request, timeout: max(timeout, 0), controller: controller)
                    )
                }
            }
        } onCancel: {
            controller.cancel()
        }
    }

    private static func runBlocking(
        _ request: ProtectionProcessRequest,
        timeout: TimeInterval,
        controller: ProtectionProcessController
    ) -> ProtectionCommandResult {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let exitSignal = DispatchSemaphore(value: 0)
        let readers = DispatchGroup()
        let output = ProtectionOutputBuffer()
        let errors = ProtectionOutputBuffer()

        process.executableURL = request.executableURL
        process.arguments = request.arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { _ in exitSignal.signal() }
        controller.install(process)

        guard !controller.isCancelled else {
            return ProtectionCommandResult(
                exitCode: nil,
                stdout: "",
                stderr: "",
                timedOut: false,
                cancelled: true,
                launchError: nil
            )
        }

        do {
            try process.run()
        } catch {
            return ProtectionCommandResult(
                exitCode: nil,
                stdout: "",
                stderr: "",
                timedOut: false,
                cancelled: controller.isCancelled,
                launchError: error.localizedDescription
            )
        }

        if controller.isCancelled {
            controller.cancel()
        }

        drain(outputPipe.fileHandleForReading, into: output, group: readers)
        drain(errorPipe.fileHandleForReading, into: errors, group: readers)

        let deadline = DispatchTime.now() + timeout
        var exited = exitSignal.wait(timeout: deadline) == .success
        let timedOut = !exited

        if !exited {
            process.terminate()
            exited = exitSignal.wait(timeout: .now() + 0.25) == .success
        }

        if !exited {
            Darwin.kill(process.processIdentifier, SIGKILL)
            exited = exitSignal.wait(timeout: .now() + 0.75) == .success
        }

        if readers.wait(timeout: .now() + 0.25) == .timedOut {
            try? outputPipe.fileHandleForReading.close()
            try? errorPipe.fileHandleForReading.close()
            _ = readers.wait(timeout: .now() + 0.25)
        }

        return ProtectionCommandResult(
            exitCode: exited ? process.terminationStatus : nil,
            stdout: output.string(),
            stderr: errors.string(),
            timedOut: timedOut,
            cancelled: controller.isCancelled,
            launchError: nil
        )
    }

    private static func drain(
        _ handle: FileHandle,
        into buffer: ProtectionOutputBuffer,
        group: DispatchGroup
    ) {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { group.leave() }
            while true {
                do {
                    guard let chunk = try handle.read(upToCount: 4_096), !chunk.isEmpty else { return }
                    buffer.append(chunk)
                } catch {
                    return
                }
            }
        }
    }
}

struct ProtectionAudit: Sendable {
    typealias CommandExecutor = @Sendable (ProtectionCommand) async -> ProtectionCommandResult
    typealias XProtectInspector = @Sendable () -> ProtectionFinding

    private let commandExecutor: CommandExecutor
    private let xProtectInspector: XProtectInspector

    init(
        commandExecutor: @escaping CommandExecutor = { await ProtectionCommandRunner.run($0) },
        xProtectInspector: @escaping XProtectInspector = { ProtectionAudit.inspectXProtect() }
    ) {
        self.commandExecutor = commandExecutor
        self.xProtectInspector = xProtectInspector
    }

    func run() async -> ProtectionSnapshot {
        async let gatekeeper = run(.gatekeeper)
        async let fileVault = run(.fileVault)
        async let firewall = run(.firewall)
        async let systemIntegrityProtection = run(.systemIntegrityProtection)
        async let xProtect = xProtectInspector()

        let findings = await [
            gatekeeper,
            fileVault,
            firewall,
            systemIntegrityProtection,
            xProtect
        ]
        return ProtectionSnapshot(findings: findings, checkedAt: Date())
    }

    private func run(_ command: ProtectionCommand) async -> ProtectionFinding {
        Self.parse(command.check, result: await commandExecutor(command))
    }

    static func parse(_ check: ProtectionCheck, result: ProtectionCommandResult) -> ProtectionFinding {
        guard result.succeeded else {
            return ProtectionFinding(
                check: check,
                status: .unknown,
                detail: result.timedOut ? "The check timed out." : "PureMac could not read this setting.",
                version: nil
            )
        }

        let output = "\(result.stdout)\n\(result.stderr)".lowercased()
        switch check {
        case .gatekeeper:
            if output.contains("assessments enabled") {
                return finding(check, .enabled, "App downloads are checked before opening.")
            }
            if output.contains("assessments disabled") {
                return finding(check, .disabled, "Downloaded apps are not being assessed by Gatekeeper.")
            }
        case .fileVault:
            if output.contains("filevault is on") {
                return finding(check, .enabled, "The startup disk is encrypted with FileVault.")
            }
            if output.contains("filevault is off") {
                return finding(check, .disabled, "The startup disk is not encrypted with FileVault.")
            }
        case .firewall:
           if output.contains("firewall is enabled") || output.contains("state = 1") || output.contains("state = 2") {
                return finding(check, .enabled, "Incoming network connections are filtered.")
            }
            if output.contains("firewall is disabled") || output.contains("state = 0") {
                return finding(check, .disabled, "The macOS application firewall is turned off.")
            }
        case .systemIntegrityProtection:
            if output.contains("system integrity protection status: enabled") {
                return finding(check, .enabled, "Protected system locations and processes are restricted.")
            }
            if output.contains("system integrity protection status: disabled") {
                return finding(check, .disabled, "System Integrity Protection is turned off.")
            }
        case .xProtect:
            break
        }

        return ProtectionFinding(
            check: check,
            status: .unknown,
            detail: "The system returned an unrecognized status.",
            version: nil
        )
    }

    static func inspectXProtect() -> ProtectionFinding {
        let engine = bundleVersion(at: "/Library/Apple/System/Library/CoreServices/XProtect.app")
        let definitions = bundleVersion(at: "/Library/Apple/System/Library/CoreServices/XProtect.bundle")

        guard engine != nil || definitions != nil else {
            return ProtectionFinding(
                check: .xProtect,
                status: .unknown,
                detail: "PureMac could not confirm the local XProtect installation.",
                version: nil
            )
        }

        let parts = [
            engine.map { "engine \($0)" },
            definitions.map { "definitions \($0)" }
        ].compactMap { $0 }
        let version = parts.joined(separator: ", ")
        return ProtectionFinding(
            check: .xProtect,
            status: .enabled,
            detail: "Apple's built-in malware protection is installed. Update recency is managed by macOS.",
            version: version
        )
    }

    private static func bundleVersion(at path: String) -> String? {
        guard let bundle = Bundle(path: path) else { return nil }
        return bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    private static func finding(
        _ check: ProtectionCheck,
        _ status: ProtectionStatus,
        _ detail: String
    ) -> ProtectionFinding {
        ProtectionFinding(check: check, status: status, detail: detail, version: nil)
    }
}
