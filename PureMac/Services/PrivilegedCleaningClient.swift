import Darwin
import Foundation
import Security
@preconcurrency import ServiceManagement

enum PrivilegedCleaningClientError: LocalizedError {
    case helperNotFound
    case helperRequiresApproval
    case helperRegistrationFailed(String)
    case helperIncompatible
    case helperRecovering(String)
    case helperRecoveryFailed(String)
    case authorizationFailed(OSStatus)
    case requestTooLarge
    case invalidResponse
    case requestTimedOut
    case requestCancelled
    case reconciliationPending(String)
    case connectionFailed(String)

    var errorDescription: String? {
        switch self {
        case .helperNotFound:
            return "The PureMac privileged helper is missing from the app bundle."
        case .helperRequiresApproval:
            return "Enable the PureMac privileged helper in System Settings → General → Login Items, then try again."
        case let .helperRegistrationFailed(detail):
            return "Could not register the PureMac privileged helper: \(detail)"
        case .helperIncompatible:
            return "The installed PureMac privileged helper uses an incompatible security protocol."
        case let .helperRecovering(detail):
            return "The PureMac privileged helper is recovering an interrupted deletion: \(detail)"
        case let .helperRecoveryFailed(detail):
            return "The PureMac privileged helper could not recover an interrupted deletion: \(detail)"
        case let .authorizationFailed(status):
            if status == errAuthorizationCanceled {
                return "Administrator authorization was canceled."
            }
            return "Administrator authorization failed (\(status))."
        case .requestTooLarge:
            return "The privileged deletion request exceeded the safety limit."
        case .invalidResponse:
            return "The privileged helper returned an invalid response."
        case .requestTimedOut:
            return "The privileged helper did not respond in time."
        case .requestCancelled:
            return "The privileged deletion request was canceled."
        case let .reconciliationPending(detail):
            return "A previous privileged deletion has not been safely reconciled yet: \(detail)"
        case let .connectionFailed(detail):
            return "Could not contact the PureMac privileged helper: \(detail)"
        }
    }
}

/// Thin client for the single-purpose privileged deletion service. No paths
/// are written to disk and the connection accepts only the helper signed with
/// PureMac's bundle identifier and Team ID.
final class PrivilegedCleaningClient: @unchecked Sendable {
    private static let unresolvedOperations = PrivilegedDeletionOperationLatch()

    func deleteItems(_ requests: [PrivilegedDeletionRequest]) async throws -> [PrivilegedDeletionResponse] {
        guard !requests.isEmpty else { return [] }

        try await ensureFilesystemIsReconciled()
        try ensureHelperIsEnabled()
        try await ensureCompatibleHelper()
        let authorization = try PrivilegedAuthorization()
        defer { authorization.destroy() }
        let authorizationToken = try authorization.externalForm()
        let operationDeadline = Date().addingTimeInterval(120)

        return try await sendAllBatches(
            requests,
            authorization: authorizationToken,
            deadline: operationDeadline
        )
    }

    /// Blocks every new filesystem mutation while an earlier XPC operation
    /// could still own an entry in the privileged quarantine. The latch is
    /// persisted before submission, so an application restart cannot turn a
    /// transient source-path absence into a confirmed deletion.
    func ensureFilesystemIsReconciled() async throws {
        let pendingIDs = try Self.unresolvedOperations.snapshot()
        guard !pendingIDs.isEmpty else { return }

        try ensureHelperIsEnabled()
        try await ensureCompatibleHelper()

        for batchID in pendingIDs {
            switch await waitForDeletionReconciliation(batchID: batchID) {
            case .settled, .notAccepted:
                try Self.unresolvedOperations.resolve(batchID)
            case let .unresolved(detail):
                throw PrivilegedCleaningClientError.reconciliationPending(detail)
            }
        }
    }

    private func sendAllBatches(
        _ requests: [PrivilegedDeletionRequest],
        authorization: Data,
        deadline: Date
    ) async throws -> [PrivilegedDeletionResponse] {
        var allResponses: [PrivilegedDeletionResponse] = []
        allResponses.reserveCapacity(requests.count)
        for batchRequests in Self.batches(for: requests) {
            do {
                let delivery = try await sendBatch(
                    batchRequests,
                    authorization: authorization,
                    deadline: deadline
                )
                allResponses.append(contentsOf: delivery.responses)
                if let latchFailure = delivery.latchFailure {
                    allResponses.append(contentsOf: requests.dropFirst(allResponses.count).map { request in
                        PrivilegedDeletionResponse(
                            requestID: request.id,
                            path: request.path,
                            status: .failed,
                            message: "Not submitted because the local reconciliation latch could not be updated: \(latchFailure)"
                        )
                    })
                    return allResponses
                }
                if case .notAccepted = delivery.disposition {
                    let detail = delivery.responses.first?.message
                        ?? "The privileged helper did not accept this deletion batch."
                    allResponses.append(contentsOf: requests.dropFirst(allResponses.count).map { request in
                        PrivilegedDeletionResponse(
                            requestID: request.id,
                            path: request.path,
                            status: .failed,
                            message: "Not submitted after an earlier batch was rejected: \(detail)"
                        )
                    })
                    return allResponses
                }
            } catch let failure as SubmittedDeletionBatchFailure {
                // Preserve confirmed results from earlier batches. The caller
                // can update those rows while every unconfirmed request gets
                // an identity-correlated unknown result instead of either
                // disappearing or being falsely reported as a confirmed
                // failure. A lost reply may follow a completed deletion.
                let reconciliation = await waitForDeletionReconciliation(
                    batchID: failure.batchID
                )
                let status: PrivilegedDeletionStatus
                let detail: String
                switch reconciliation {
                case .settled:
                    try? Self.unresolvedOperations.resolve(failure.batchID)
                    status = .unknown
                    detail = "Deletion completed or rolled back safely, but its reply was lost: \(failure.underlying.localizedDescription)"
                case .notAccepted:
                    try? Self.unresolvedOperations.resolve(failure.batchID)
                    status = .failed
                    detail = "Deletion was not accepted by the helper: \(failure.underlying.localizedDescription)"
                case let .unresolved(reconciliationDetail):
                    // Keep the write-ahead latch. Any later Trash/direct
                    // mutation or privileged batch must reconcile this exact
                    // operation ID before it may act on a possibly quarantined
                    // path.
                    status = .unknown
                    detail = "Deletion outcome is unresolved: \(reconciliationDetail)"
                }
                allResponses.append(contentsOf: requests.dropFirst(allResponses.count).map { request in
                    PrivilegedDeletionResponse(
                        requestID: request.id,
                        path: request.path,
                        status: status,
                        message: detail
                    )
                })
                return allResponses
            } catch {
                guard !allResponses.isEmpty else { throw error }
                allResponses.append(contentsOf: requests.dropFirst(allResponses.count).map { request in
                    PrivilegedDeletionResponse(
                        requestID: request.id,
                        path: request.path,
                        status: .failed,
                        message: "Not submitted after a local client failure: \(error.localizedDescription)"
                    )
                })
                return allResponses
            }
        }
        return allResponses
    }

    private enum ReconciliationOutcome: Sendable {
        case settled
        case notAccepted
        case unresolved(String)
    }

    private func waitForDeletionReconciliation(
        batchID: UUID
    ) async -> ReconciliationOutcome {
        await Task.detached(priority: .userInitiated) { [self] in
            let deadline = Date().addingTimeInterval(130)
            var lastFailure = "the helper did not confirm a safe terminal state"
            repeat {
                do {
                    let response = try await reconciliationState(for: batchID)
                    switch response.state {
                    case .settled:
                        return .settled
                    case .notAccepted:
                        return .notAccepted
                    case .pending:
                        lastFailure = response.message ?? "the operation is still active"
                    case .unavailable:
                        lastFailure = response.message ?? "the helper could not install an operation fence"
                    case .recoveryFailed:
                        return .unresolved(
                            response.message ?? "privileged quarantine recovery failed"
                        )
                    }
                } catch {
                    lastFailure = error.localizedDescription
                }

                if Date() >= deadline { return .unresolved(lastFailure) }
                try? await Task.sleep(nanoseconds: 200_000_000)
            } while true
        }.value
    }

    private func reconciliationState(
        for batchID: UUID
    ) async throws -> PrivilegedDeletionReconciliationResponse {
        let state = PrivilegedXPCRequestState<PrivilegedDeletionReconciliationResponse>()
        return try await withCheckedThrowingContinuation { continuation in
            let connection = NSXPCConnection(
                machServiceName: PrivilegedCleaningConstants.machServiceName,
                options: .privileged
            )
            guard state.install(continuation: continuation, connection: connection) else {
                return
            }
            connection.remoteObjectInterface = NSXPCInterface(
                with: PrivilegedCleaningXPCProtocol.self
            )
            connection.setCodeSigningRequirement(
                PrivilegedCleaningConstants.helperCodeSigningRequirement
            )
            connection.interruptionHandler = {
                state.finish(
                    throwing: PrivilegedCleaningClientError.connectionFailed(
                        "reconciliation connection interrupted"
                    )
                )
            }
            connection.invalidationHandler = {
                state.finish(
                    throwing: PrivilegedCleaningClientError.connectionFailed(
                        "reconciliation connection invalidated"
                    )
                )
            }
            connection.activate()
            state.scheduleTimeout(after: 3)

            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                state.finish(
                    throwing: PrivilegedCleaningClientError.connectionFailed(
                        error.localizedDescription
                    )
                )
            }) as? PrivilegedCleaningXPCProtocol else {
                state.finish(throwing: PrivilegedCleaningClientError.invalidResponse)
                return
            }
            proxy.reconcileDeletion(batchID as NSUUID) { encodedResponse in
                do {
                    guard encodedResponse.length <= 16_384 else {
                        throw PrivilegedCleaningClientError.invalidResponse
                    }
                    let response = try PropertyListDecoder().decode(
                        PrivilegedDeletionReconciliationResponse.self,
                        from: encodedResponse as Data
                    )
                    guard response.protocolVersion == PrivilegedCleaningConstants.protocolVersion,
                          response.securityPolicyVersion == PrivilegedCleaningConstants.securityPolicyVersion,
                          response.batchID == batchID
                    else {
                        throw PrivilegedCleaningClientError.invalidResponse
                    }
                    state.finish(returning: response)
                } catch {
                    state.finish(throwing: error)
                }
            }
        }
    }

    static func batches(
        for requests: [PrivilegedDeletionRequest]
    ) -> [[PrivilegedDeletionRequest]] {
        guard !requests.isEmpty else { return [] }
        var batches: [[PrivilegedDeletionRequest]] = []
        batches.reserveCapacity(
            (requests.count + PrivilegedCleaningConstants.maximumBatchCount - 1)
                / PrivilegedCleaningConstants.maximumBatchCount
        )
        var start = requests.startIndex
        while start < requests.endIndex {
            let end = requests.index(
                start,
                offsetBy: PrivilegedCleaningConstants.maximumBatchCount,
                limitedBy: requests.endIndex
            ) ?? requests.endIndex
            batches.append(Array(requests[start..<end]))
            start = end
        }
        return batches
    }

    static func responsesAreValid(
        _ responses: [PrivilegedDeletionResponse],
        for requests: [PrivilegedDeletionRequest]
    ) -> Bool {
        responses.count == requests.count
            && zip(requests, responses).allSatisfy { request, response in
                response.requestID == request.id && response.path == request.path
            }
    }

    static func batchResponseIsValid(
        _ response: PrivilegedDeletionBatchResponse,
        batchID: UUID,
        requests: [PrivilegedDeletionRequest]
    ) -> Bool {
        guard response.protocolVersion == PrivilegedCleaningConstants.protocolVersion,
              response.securityPolicyVersion == PrivilegedCleaningConstants.securityPolicyVersion,
              response.batchID == batchID
        else {
            return false
        }

        switch response.disposition {
        case .completed:
            return responsesAreValid(response.responses, for: requests)
                && !response.responses.contains(where: { $0.status == .unknown })
        case .notAccepted:
            return response.responses.isEmpty
        }
    }

    private struct BatchDelivery {
        let disposition: PrivilegedDeletionBatchDisposition
        let responses: [PrivilegedDeletionResponse]
        let latchFailure: String?
    }

    private func sendBatch(
        _ requests: [PrivilegedDeletionRequest],
        authorization: Data,
        deadline: Date
    ) async throws -> BatchDelivery {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let batch = PrivilegedDeletionBatch(
            requests: requests,
            authorization: authorization,
            deadline: deadline
        )
        let payload = try encoder.encode(batch)
        guard payload.count <= PrivilegedCleaningConstants.maximumEncodedSize else {
            throw PrivilegedCleaningClientError.requestTooLarge
        }

        try Self.unresolvedOperations.register(batch.id)
        let state = PrivilegedXPCRequestState<PrivilegedDeletionBatchResponse>()
        do {
            let response = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
            let connection = NSXPCConnection(
                machServiceName: PrivilegedCleaningConstants.machServiceName,
                options: .privileged
            )
            guard state.install(continuation: continuation, connection: connection) else {
                return
            }
            connection.remoteObjectInterface = NSXPCInterface(with: PrivilegedCleaningXPCProtocol.self)
            connection.setCodeSigningRequirement(PrivilegedCleaningConstants.helperCodeSigningRequirement)

            connection.interruptionHandler = {
                state.finish(
                    throwing: PrivilegedCleaningClientError.connectionFailed("connection interrupted")
                )
            }
            connection.invalidationHandler = {
                state.finish(
                    throwing: PrivilegedCleaningClientError.connectionFailed("connection invalidated")
                )
            }
            connection.activate()
            state.scheduleTimeout(after: 130)

            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                state.finish(
                    throwing: PrivilegedCleaningClientError.connectionFailed(error.localizedDescription)
                )
            }) as? PrivilegedCleaningXPCProtocol else {
                state.finish(throwing: PrivilegedCleaningClientError.invalidResponse)
                return
            }

            proxy.deleteItems(batch.id as NSUUID, encodedBatch: payload as NSData) { encodedResponse in
                do {
                    guard encodedResponse.length <= PrivilegedCleaningConstants.maximumEncodedSize else {
                        throw PrivilegedCleaningClientError.invalidResponse
                    }
                    let response = try PropertyListDecoder().decode(
                        PrivilegedDeletionBatchResponse.self,
                        from: encodedResponse as Data
                    )
                    state.finish(returning: response)
                } catch {
                    state.finish(throwing: error)
                }
            }
                }
            } onCancel: {
                state.finish(throwing: PrivilegedCleaningClientError.requestCancelled)
            }

            let responses: [PrivilegedDeletionResponse]
            guard Self.batchResponseIsValid(
                response,
                batchID: batch.id,
                requests: requests
            ) else {
                throw PrivilegedCleaningClientError.invalidResponse
            }
            switch response.disposition {
            case .completed:
                responses = response.responses
            case .notAccepted:
                let message = response.message ?? "The privileged helper did not accept this deletion batch."
                responses = requests.map { request in
                    PrivilegedDeletionResponse(
                        requestID: request.id,
                        path: request.path,
                        status: .failed,
                        message: message
                    )
                }
            }

            let latchFailure: String?
            do {
                try Self.unresolvedOperations.resolve(batch.id)
                latchFailure = nil
            } catch {
                // The authenticated helper reply is already terminal, so keep
                // its item-level results. Leave the operation ID on disk and
                // stop before another batch; the next mutation must reconcile
                // and clear that fail-closed marker.
                latchFailure = error.localizedDescription
            }
            return BatchDelivery(
                disposition: response.disposition,
                responses: responses,
                latchFailure: latchFailure
            )
        } catch {
            throw SubmittedDeletionBatchFailure(batchID: batch.id, underlying: error)
        }
    }

    private func ensureHelperIsEnabled() throws {
        let service = SMAppService.daemon(
            plistName: PrivilegedCleaningConstants.launchDaemonPlistName
        )

        switch service.status {
        case .enabled:
            return
        case .notRegistered:
            do {
                try service.register()
            } catch {
                if service.status == .requiresApproval {
                    openHelperApprovalSettings()
                    throw PrivilegedCleaningClientError.helperRequiresApproval
                }
                throw PrivilegedCleaningClientError.helperRegistrationFailed(error.localizedDescription)
            }

            guard service.status == .enabled else {
                openHelperApprovalSettings()
                throw PrivilegedCleaningClientError.helperRequiresApproval
            }
        case .requiresApproval:
            openHelperApprovalSettings()
            throw PrivilegedCleaningClientError.helperRequiresApproval
        case .notFound:
            throw PrivilegedCleaningClientError.helperNotFound
        @unknown default:
            throw PrivilegedCleaningClientError.helperRegistrationFailed("unknown helper status")
        }
    }

    private func ensureCompatibleHelper() async throws {
        let recoveryDeadline = Date().addingTimeInterval(130)
        var transportFailureCount = 0
        var didRefreshIncompatibleHelper = false
        var lastError: Error = PrivilegedCleaningClientError.connectionFailed(
            "the helper did not answer its compatibility handshake"
        )

        while Date() < recoveryDeadline {
            do {
                try await verifyHelperCompatibility()
                return
            } catch PrivilegedCleaningClientError.requestCancelled {
                throw PrivilegedCleaningClientError.requestCancelled
            } catch PrivilegedCleaningClientError.helperIncompatible {
                // Refresh only after a successfully decoded service-info reply
                // explicitly proves a version mismatch. Transport silence may
                // be a daemon launch failure and must never be used to kill a
                // helper that is durably recovering a COMMITTED transaction.
                guard !didRefreshIncompatibleHelper else {
                    throw PrivilegedCleaningClientError.helperIncompatible
                }
                try await refreshHelperRegistration()
                didRefreshIncompatibleHelper = true
                transportFailureCount = 0
                lastError = PrivilegedCleaningClientError.helperIncompatible
            } catch let error as PrivilegedCleaningClientError {
                switch error {
                case .helperRecovering:
                    transportFailureCount = 0
                    lastError = error
                case .helperRecoveryFailed:
                    throw error
                default:
                    transportFailureCount += 1
                    lastError = error
                    if transportFailureCount >= 4 {
                        throw error
                    }
                }
            } catch {
                transportFailureCount += 1
                lastError = error
                if transportFailureCount >= 4 {
                    throw error
                }
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw lastError
    }

    private func verifyHelperCompatibility() async throws {
        let info = try await fetchServiceInfo()
        guard info.protocolVersion == PrivilegedCleaningConstants.protocolVersion,
              info.securityPolicyVersion == PrivilegedCleaningConstants.securityPolicyVersion,
              info.helperBundleIdentifier == PrivilegedCleaningConstants.helperBundleIdentifier
        else {
            throw PrivilegedCleaningClientError.helperIncompatible
        }
        guard let recoveryState = info.recoveryState else {
            throw PrivilegedCleaningClientError.invalidResponse
        }
        switch recoveryState {
        case .ready:
            return
        case .recovering:
            throw PrivilegedCleaningClientError.helperRecovering(
                info.recoveryMessage ?? "recovery is still in progress"
            )
        case .failed:
            throw PrivilegedCleaningClientError.helperRecoveryFailed(
                info.recoveryMessage ?? "recovery failed without a diagnostic"
            )
        }
    }

    private func fetchServiceInfo() async throws -> PrivilegedCleaningServiceInfo {
        let state = PrivilegedXPCRequestState<PrivilegedCleaningServiceInfo>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let connection = NSXPCConnection(
                    machServiceName: PrivilegedCleaningConstants.machServiceName,
                    options: .privileged
                )
                guard state.install(continuation: continuation, connection: connection) else {
                    return
                }
                connection.remoteObjectInterface = NSXPCInterface(
                    with: PrivilegedCleaningXPCProtocol.self
                )
                connection.setCodeSigningRequirement(
                    PrivilegedCleaningConstants.helperCodeSigningRequirement
                )
                connection.interruptionHandler = {
                    state.finish(
                        throwing: PrivilegedCleaningClientError.connectionFailed("connection interrupted")
                    )
                }
                connection.invalidationHandler = {
                    state.finish(
                        throwing: PrivilegedCleaningClientError.connectionFailed("connection invalidated")
                    )
                }
                connection.activate()
                state.scheduleTimeout(after: 3)

                guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                    state.finish(
                        throwing: PrivilegedCleaningClientError.connectionFailed(error.localizedDescription)
                    )
                }) as? PrivilegedCleaningXPCProtocol else {
                    state.finish(throwing: PrivilegedCleaningClientError.invalidResponse)
                    return
                }

                proxy.serviceInfo { encodedInfo in
                    do {
                        guard encodedInfo.length <= 16_384 else {
                            throw PrivilegedCleaningClientError.invalidResponse
                        }
                        let info = try PropertyListDecoder().decode(
                            PrivilegedCleaningServiceInfo.self,
                            from: encodedInfo as Data
                        )
                        state.finish(returning: info)
                    } catch {
                        state.finish(throwing: error)
                    }
                }
            }
        } onCancel: {
            state.finish(throwing: PrivilegedCleaningClientError.requestCancelled)
        }
    }

    private func refreshHelperRegistration() async throws {
        let service = SMAppService.daemon(
            plistName: PrivilegedCleaningConstants.launchDaemonPlistName
        )
        do {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                service.unregister { error in
                    if let error, service.status != .notRegistered {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
            try service.register()
        } catch {
            if service.status == .requiresApproval {
                openHelperApprovalSettings()
                throw PrivilegedCleaningClientError.helperRequiresApproval
            }
            throw PrivilegedCleaningClientError.helperRegistrationFailed(error.localizedDescription)
        }
        guard service.status == .enabled else {
            openHelperApprovalSettings()
            throw PrivilegedCleaningClientError.helperRequiresApproval
        }
    }

    private func openHelperApprovalSettings() {
        DispatchQueue.main.async {
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}

private struct SubmittedDeletionBatchFailure: Error, @unchecked Sendable {
    let batchID: UUID
    let underlying: Error
}

/// A write-ahead, fail-closed list of XPC operation IDs whose terminal reply
/// has not yet been authenticated. The file contains no paths or credentials;
/// it exists only to force an exact-ID helper reconciliation after an app crash.
private final class PrivilegedDeletionOperationLatch: @unchecked Sendable {
    private static let maximumCount = 256
    private static let maximumEncodedSize = 65_536

    private let lock = NSLock()
    private let directoryURL: URL
    private let fileURL: URL
    private let lockFileURL: URL

    init() {
        let manager = FileManager.default
        let base = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? manager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        directoryURL = base.appendingPathComponent("PureMac", isDirectory: true)
        fileURL = directoryURL
            .appendingPathComponent("privileged-deletion-latch.plist")
        lockFileURL = directoryURL
            .appendingPathComponent("privileged-deletion-latch.lock")
    }

    func snapshot() throws -> [UUID] {
        lock.lock()
        defer { lock.unlock() }
        return try withInterprocessLock {
            try loadFromDisk().sorted { $0.uuidString < $1.uuidString }
        }
    }

    func register(_ operationID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        try withInterprocessLock {
            var updated = try loadFromDisk()
            guard updated.count < Self.maximumCount || updated.contains(operationID) else {
                throw PrivilegedCleaningClientError.reconciliationPending(
                    "too many unresolved privileged operations"
                )
            }
            updated.insert(operationID)
            try persist(updated)
        }
    }

    func resolve(_ operationID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        try withInterprocessLock {
            var updated = try loadFromDisk()
            guard updated.remove(operationID) != nil else { return }
            try persist(updated)
        }
    }

    private func withInterprocessLock<T>(_ body: () throws -> T) throws -> T {
        let manager = FileManager.default
        do {
            try manager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw latchError("create latch directory", detail: error.localizedDescription)
        }

        let descriptor = Darwin.open(
            lockFileURL.path,
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            throw latchError("open latch lock", code: errno)
        }
        defer { Darwin.close(descriptor) }

        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0 else {
            throw latchError("inspect latch lock", code: errno)
        }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              info.st_uid == geteuid(),
              info.st_nlink == 1
        else {
            throw latchError("validate latch lock", detail: "unexpected owner or file type")
        }
        guard Darwin.fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            throw latchError("harden latch lock", code: errno)
        }

        while Darwin.lockf(descriptor, F_LOCK, 0) != 0 {
            if errno == EINTR { continue }
            throw latchError("lock operation latch", code: errno)
        }
        defer { _ = Darwin.lockf(descriptor, F_ULOCK, 0) }
        return try body()
    }

    private func loadFromDisk() throws -> Set<UUID> {
        let descriptor = Darwin.open(
            fileURL.path,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        )
        if descriptor < 0, errno == ENOENT { return [] }
        guard descriptor >= 0 else {
            throw latchError("open operation latch", code: errno)
        }
        defer { Darwin.close(descriptor) }

        var initialInfo = stat()
        guard Darwin.fstat(descriptor, &initialInfo) == 0 else {
            throw latchError("inspect operation latch", code: errno)
        }
        guard (initialInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              initialInfo.st_uid == geteuid(),
              initialInfo.st_nlink == 1,
              initialInfo.st_size > 0,
              initialInfo.st_size <= off_t(Self.maximumEncodedSize)
        else {
            throw latchError("validate operation latch", detail: "unexpected owner, type, or size")
        }

        let byteCount = Int(initialInfo.st_size)
        var encoded = Data(count: byteCount)
        try encoded.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < byteCount {
                let count = Darwin.pread(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    byteCount - offset,
                    off_t(offset)
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    throw latchError("read operation latch", code: errno)
                }
                guard count > 0 else {
                    throw latchError("read operation latch", detail: "unexpected end of file")
                }
                offset += count
            }
        }

        var finalInfo = stat()
        guard Darwin.fstat(descriptor, &finalInfo) == 0,
              FileIdentity(stat: finalInfo) == FileIdentity(stat: initialInfo),
              finalInfo.st_size == initialInfo.st_size,
              finalInfo.st_nlink == 1
        else {
            throw latchError("revalidate operation latch", detail: "file changed while reading")
        }

        do {
            let rawIDs = try PropertyListDecoder().decode([String].self, from: encoded)
            guard rawIDs.count <= Self.maximumCount else {
                throw PrivilegedCleaningClientError.invalidResponse
            }
            let decoded = rawIDs.compactMap(UUID.init(uuidString:))
            guard decoded.count == rawIDs.count,
                  Set(decoded).count == decoded.count
            else {
                throw PrivilegedCleaningClientError.invalidResponse
            }
            return Set(decoded)
        } catch {
            throw latchError("decode operation latch", detail: error.localizedDescription)
        }
    }

    private func persist(_ operationIDs: Set<UUID>) throws {
        let rawIDs = operationIDs.map(\.uuidString).sorted()
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let encoded: Data
        do {
            encoded = try encoder.encode(rawIDs)
        } catch {
            throw latchError("encode operation latch", detail: error.localizedDescription)
        }
        guard !encoded.isEmpty, encoded.count <= Self.maximumEncodedSize else {
            throw PrivilegedCleaningClientError.requestTooLarge
        }

        let directoryFD = Darwin.open(
            directoryURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directoryFD >= 0 else {
            throw latchError("open latch directory", code: errno)
        }
        defer { Darwin.close(directoryFD) }

        let temporaryName = ".privileged-deletion-latch-\(UUID().uuidString)"
        let temporaryFD = temporaryName.withCString { pointer in
            Darwin.openat(
                directoryFD,
                pointer,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard temporaryFD >= 0 else {
            throw latchError("create operation latch", code: errno)
        }
        var shouldRemoveTemporary = true
        defer {
            Darwin.close(temporaryFD)
            if shouldRemoveTemporary {
                temporaryName.withCString { pointer in
                    _ = Darwin.unlinkat(directoryFD, pointer, 0)
                }
            }
        }

        try encoded.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(
                    temporaryFD,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if written < 0 {
                    if errno == EINTR { continue }
                    throw latchError("write operation latch", code: errno)
                }
                guard written > 0 else {
                    throw latchError("write operation latch", detail: "zero-byte write")
                }
                offset += written
            }
        }
        guard Darwin.fsync(temporaryFD) == 0 else {
            throw latchError("sync operation latch", code: errno)
        }

        let renameStatus = temporaryName.withCString { temporaryPointer in
            fileURL.lastPathComponent.withCString { filePointer in
                Darwin.renameat(directoryFD, temporaryPointer, directoryFD, filePointer)
            }
        }
        guard renameStatus == 0 else {
            throw latchError("install operation latch", code: errno)
        }
        shouldRemoveTemporary = false
        guard Darwin.fsync(directoryFD) == 0 else {
            throw latchError("sync latch directory", code: errno)
        }
    }

    private func latchError(
        _ operation: String,
        code: Int32? = nil,
        detail: String? = nil
    ) -> PrivilegedCleaningClientError {
        let explanation: String
        if let detail {
            explanation = detail
        } else if let code {
            explanation = String(cString: strerror(code))
        } else {
            explanation = "unknown error"
        }
        return .reconciliationPending(
            "\(operation) failed (\(explanation))"
        )
    }
}

actor FilesystemMutationCoordinator {
    static let shared = FilesystemMutationCoordinator()

    private static let blockingLockQueue = DispatchQueue(
        label: "com.puremac.filesystem-mutation-lock",
        qos: .userInitiated
    )

    private let lockDirectoryURL: URL
    private var isAvailable = true
    private var lockDescriptor: Int32?
    private var waiters: [CheckedContinuation<Void, Error>] = []

    init(lockDirectoryURL: URL? = nil) {
        if let lockDirectoryURL {
            self.lockDirectoryURL = lockDirectoryURL
        } else {
            let manager = FileManager.default
            let base = manager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? manager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
            self.lockDirectoryURL = base.appendingPathComponent(
                "PureMac",
                isDirectory: true
            )
        }
    }

    /// Acquires both an in-process FIFO lease and an advisory lock shared by
    /// every running copy of PureMac. All legitimate mutation entry points hold
    /// this lease across `reconcile -> mutation`, so one process cannot observe
    /// another process's temporary privileged quarantine absence as ENOENT.
    func acquire() async throws {
        guard isAvailable else {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(continuation)
            }
            return
        }

        isAvailable = false
        do {
            lockDescriptor = try await Self.acquireInterprocessLock(
                directoryURL: lockDirectoryURL
            )
        } catch {
            isAvailable = true
            let blockedWaiters = waiters
            waiters.removeAll(keepingCapacity: true)
            for waiter in blockedWaiters {
                waiter.resume(throwing: error)
            }
            throw error
        }
    }

    func release() {
        guard let descriptor = lockDescriptor else {
            // A failed acquire never grants a lease. Keep this fail-closed and
            // do not accidentally wake a waiter without the process lock.
            return
        }
        guard !waiters.isEmpty else {
            _ = Darwin.lockf(descriptor, F_ULOCK, 0)
            Darwin.close(descriptor)
            lockDescriptor = nil
            isAvailable = true
            return
        }
        let next = waiters.removeFirst()
        // Transfer the existing process + interprocess lease without an
        // unlock window in which another app instance could interleave.
        next.resume(returning: ())
    }

    private static func acquireInterprocessLock(
        directoryURL: URL
    ) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            blockingLockQueue.async {
                do {
                    continuation.resume(
                        returning: try openAndLockMutationFile(
                            directoryURL: directoryURL
                        )
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func openAndLockMutationFile(
        directoryURL: URL
    ) throws -> Int32 {
        let manager = FileManager.default
        do {
            try manager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw mutationLockError(
                "create mutation-lock directory",
                detail: error.localizedDescription
            )
        }

        let directoryFD = Darwin.open(
            directoryURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directoryFD >= 0 else {
            throw mutationLockError("open mutation-lock directory", code: errno)
        }
        defer { Darwin.close(directoryFD) }

        var directoryInfo = stat()
        guard Darwin.fstat(directoryFD, &directoryInfo) == 0 else {
            throw mutationLockError("inspect mutation-lock directory", code: errno)
        }
        guard (directoryInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              directoryInfo.st_uid == geteuid()
        else {
            throw mutationLockError(
                "validate mutation-lock directory",
                detail: "unexpected owner or file type"
            )
        }
        guard Darwin.fchmod(directoryFD, mode_t(S_IRWXU)) == 0 else {
            throw mutationLockError("harden mutation-lock directory", code: errno)
        }

        let lockName = "filesystem-mutation.lock"
        let descriptor = lockName.withCString { pointer in
            Darwin.openat(
                directoryFD,
                pointer,
                O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard descriptor >= 0 else {
            throw mutationLockError("open filesystem mutation lock", code: errno)
        }

        do {
            var info = stat()
            guard Darwin.fstat(descriptor, &info) == 0 else {
                throw mutationLockError("inspect filesystem mutation lock", code: errno)
            }
            guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
                  info.st_uid == geteuid(),
                  info.st_nlink == 1
            else {
                throw mutationLockError(
                    "validate filesystem mutation lock",
                    detail: "unexpected owner or file type"
                )
            }
            guard Darwin.fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
                throw mutationLockError("harden filesystem mutation lock", code: errno)
            }

            while Darwin.lockf(descriptor, F_LOCK, 0) != 0 {
                if errno == EINTR { continue }
                throw mutationLockError("lock filesystem mutation", code: errno)
            }

            var namedInfo = stat()
            let namedStatus = lockName.withCString { pointer in
                Darwin.fstatat(directoryFD, pointer, &namedInfo, AT_SYMLINK_NOFOLLOW)
            }
            guard namedStatus == 0,
                  FileIdentity(stat: namedInfo) == FileIdentity(stat: info)
            else {
                _ = Darwin.lockf(descriptor, F_ULOCK, 0)
                throw mutationLockError(
                    "revalidate filesystem mutation lock",
                    detail: "lock file changed while acquiring it"
                )
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func mutationLockError(
        _ operation: String,
        code: Int32? = nil,
        detail: String? = nil
    ) -> PrivilegedCleaningClientError {
        let explanation: String
        if let detail {
            explanation = detail
        } else if let code {
            explanation = String(cString: strerror(code))
        } else {
            explanation = "unknown error"
        }
        return .reconciliationPending("\(operation) failed (\(explanation))")
    }
}

private final class PrivilegedAuthorization {
    private var reference: AuthorizationRef?

    init() throws {
        var createdReference: AuthorizationRef?
        let createStatus = AuthorizationCreate(
            nil,
            nil,
            [.interactionAllowed],
            &createdReference
        )
        guard createStatus == errAuthorizationSuccess,
              let createdReference
        else {
            throw PrivilegedCleaningClientError.authorizationFailed(createStatus)
        }

        do {
            try Self.installAuthorizationRightIfNeeded(using: createdReference)
        } catch {
            AuthorizationFree(createdReference, [])
            throw error
        }

        let authorizationStatus = PrivilegedCleaningConstants.authorizationRight.withCString { rightName in
            var item = AuthorizationItem(
                name: rightName,
                valueLength: 0,
                value: nil,
                flags: 0
            )
            return withUnsafeMutablePointer(to: &item) { itemPointer in
                var rights = AuthorizationRights(count: 1, items: itemPointer)
                return AuthorizationCopyRights(
                    createdReference,
                    &rights,
                    nil,
                    [.interactionAllowed, .extendRights, .preAuthorize],
                    nil
                )
            }
        }
        guard authorizationStatus == errAuthorizationSuccess else {
            AuthorizationFree(createdReference, [])
            throw PrivilegedCleaningClientError.authorizationFailed(authorizationStatus)
        }
        reference = createdReference
    }

    private static func installAuthorizationRightIfNeeded(
        using authorization: AuthorizationRef
    ) throws {
        var existingDefinition: CFDictionary?
        let getStatus = PrivilegedCleaningConstants.authorizationRight.withCString { rightName in
            AuthorizationRightGet(rightName, &existingDefinition)
        }

        if getStatus == errAuthorizationSuccess,
           let existingDefinition,
           authorizationRightIsCurrent(existingDefinition)
        {
            return
        }
        guard getStatus == errAuthorizationSuccess || getStatus == errAuthorizationDenied else {
            throw PrivilegedCleaningClientError.authorizationFailed(getStatus)
        }

        let definition: [String: Any] = [
            "class": "rule",
            kAuthorizationRightRule: kAuthorizationRuleAuthenticateAsAdmin,
            "shared": false,
            "timeout": PrivilegedCleaningConstants.authorizationRightTimeout,
            "version": PrivilegedCleaningConstants.securityPolicyVersion,
            kAuthorizationComment: "Authorizes deletion of explicitly selected, policy-validated items by PureMac",
        ]
        let description = "PureMac needs permission to delete the selected protected items." as CFString
        let setStatus = PrivilegedCleaningConstants.authorizationRight.withCString { rightName in
            AuthorizationRightSet(
                authorization,
                rightName,
                definition as CFDictionary,
                description,
                nil,
                nil
            )
        }
        guard setStatus == errAuthorizationSuccess else {
            throw PrivilegedCleaningClientError.authorizationFailed(setStatus)
        }
    }

    private static func authorizationRightIsCurrent(_ definition: CFDictionary) -> Bool {
        let values = definition as NSDictionary
        guard values["class"] as? String == "rule",
              values[kAuthorizationRightRule] as? String == kAuthorizationRuleAuthenticateAsAdmin,
              let shared = values["shared"] as? Bool,
              shared == false,
              let timeout = values["timeout"] as? NSNumber,
              timeout.intValue == PrivilegedCleaningConstants.authorizationRightTimeout,
              let version = values["version"] as? NSNumber,
              version.intValue == PrivilegedCleaningConstants.securityPolicyVersion
        else {
            return false
        }
        return true
    }

    func externalForm() throws -> Data {
        guard let reference else {
            throw PrivilegedCleaningClientError.authorizationFailed(errAuthorizationInvalidRef)
        }
        var externalForm = AuthorizationExternalForm()
        let status = AuthorizationMakeExternalForm(reference, &externalForm)
        guard status == errAuthorizationSuccess else {
            throw PrivilegedCleaningClientError.authorizationFailed(status)
        }
        return withUnsafeBytes(of: &externalForm) { Data($0) }
    }

    func destroy() {
        guard let reference else { return }
        self.reference = nil
        AuthorizationFree(reference, [.destroyRights])
    }

    deinit {
        destroy()
    }
}

private final class PrivilegedXPCRequestState<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var connection: NSXPCConnection?
    private var terminalResult: Result<Value, Error>?
    private var timeoutWorkItem: DispatchWorkItem?

    func install(
        continuation: CheckedContinuation<Value, Error>,
        connection: NSXPCConnection
    ) -> Bool {
        lock.lock()
        if let terminalResult {
            lock.unlock()
            connection.invalidate()
            continuation.resume(with: terminalResult)
            return false
        }
        self.continuation = continuation
        self.connection = connection
        lock.unlock()
        return true
    }

    func scheduleTimeout(after seconds: TimeInterval) {
        let workItem = DispatchWorkItem { [weak self] in
            self?.finish(throwing: PrivilegedCleaningClientError.requestTimedOut)
        }
        lock.lock()
        guard terminalResult == nil else {
            lock.unlock()
            return
        }
        timeoutWorkItem = workItem
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + seconds,
            execute: workItem
        )
    }

    func finish(returning value: Value) {
        finish(with: .success(value))
    }

    func finish(throwing error: Error) {
        finish(with: .failure(error))
    }

    private func finish(with result: Result<Value, Error>) {
        lock.lock()
        guard terminalResult == nil else {
            lock.unlock()
            return
        }
        terminalResult = result
        let pendingContinuation = continuation
        continuation = nil
        let activeConnection = connection
        connection = nil
        let timeout = timeoutWorkItem
        timeoutWorkItem = nil
        lock.unlock()

        timeout?.cancel()
        activeConnection?.invalidate()
        pendingContinuation?.resume(with: result)
    }
}
