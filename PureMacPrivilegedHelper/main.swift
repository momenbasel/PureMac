import Darwin
import Foundation
import Security

private final class PrivilegedCleaningListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        let userID = newConnection.effectiveUserIdentifier
        guard userID != 0, let homeDirectory = homeDirectory(for: userID) else {
            return false
        }

        let cancellation = ConnectionCancellation()
        newConnection.exportedInterface = NSXPCInterface(with: PrivilegedCleaningXPCProtocol.self)
        newConnection.exportedObject = PrivilegedCleaningSession(
            userID: userID,
            homeDirectory: homeDirectory,
            cancellation: cancellation
        )
        newConnection.invalidationHandler = { cancellation.cancel() }
        newConnection.interruptionHandler = { cancellation.cancel() }
        newConnection.activate()
        return true
    }

    private func homeDirectory(for userID: uid_t) -> String? {
        var record = passwd()
        var result: UnsafeMutablePointer<passwd>?
        let configuredSize = sysconf(_SC_GETPW_R_SIZE_MAX)
        let bufferSize = max(configuredSize > 0 ? Int(configuredSize) : 16_384, 16_384)
        var buffer = [CChar](repeating: 0, count: bufferSize)

        let status = buffer.withUnsafeMutableBufferPointer { pointer in
            getpwuid_r(userID, &record, pointer.baseAddress, pointer.count, &result)
        }
        guard status == 0, result != nil, let directory = record.pw_dir else {
            return nil
        }
        return String(cString: directory)
    }
}

private final class ConnectionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

private struct PrivilegedDeletionOperationKey: Hashable {
    let userID: uid_t
    let batchID: UUID
}

/// Serializes mutation admission and gives reconciliation an atomic view of
/// each operation ID. Terminal entries are deliberately short lived: request
/// identities make a replay safe after expiry, while the bounds prevent a
/// signed-but-compromised client from growing root-owned memory indefinitely.
private final class PrivilegedDeletionOperationRegistry: @unchecked Sendable {
    enum Admission {
        case accepted
        /// The operation ID was retained as a fence, so the helper can prove
        /// this delivered invocation was never admitted for mutation.
        case notAccepted(String)
        /// No fence was retained. The caller must treat this as a transport
        /// failure and reconcile instead of trusting a notAccepted claim.
        case unavailable(String)
    }

    enum Completion {
        case settled
        case notAccepted(String)
        case recoveryFailed(String)
    }

    struct Reconciliation {
        let state: PrivilegedDeletionReconciliationState
        let message: String?
    }

    private enum State {
        case active
        case fenced(expiresAt: UInt64, message: String)
        case settled(expiresAt: UInt64)
        case recoveryFailed(expiresAt: UInt64, message: String)
    }

    private enum RecoveryState {
        case pending
        case ready
        case failed(String)
    }

    private let lock = NSLock()
    private let maximumEntryCount = 256
    private let maximumEntryCountPerUser = 64
    private let retentionNanoseconds = UInt64(
        PrivilegedCleaningConstants.authorizationRightTimeout + 60
    ) * 1_000_000_000
    private var entries: [PrivilegedDeletionOperationKey: State] = [:]
    private var activeKey: PrivilegedDeletionOperationKey?
    /// Admission starts closed. The helper opens it only after durable startup
    /// recovery has completed on the same serial queue used for deletion.
    private var recoveryState: RecoveryState = .pending

    func recoveryStatus() -> (
        state: PrivilegedCleaningRecoveryState,
        message: String?
    ) {
        lock.lock()
        defer { lock.unlock() }
        switch recoveryState {
        case .pending:
            return (.recovering, "Privileged quarantine recovery is in progress")
        case .ready:
            return (.ready, nil)
        case .failed(let message):
            return (.failed, message)
        }
    }

    func markStartupRecoverySucceeded() {
        lock.lock()
        recoveryState = .ready
        lock.unlock()
    }

    func markRecoveryFailed(_ message: String) {
        lock.lock()
        recoveryState = .failed(message)
        lock.unlock()
    }

    func begin(_ key: PrivilegedDeletionOperationKey) -> Admission {
        lock.lock()
        defer { lock.unlock() }

        let now = DispatchTime.now().uptimeNanoseconds
        purgeExpiredEntries(now: now)

        switch recoveryState {
        case .pending:
            return .unavailable("Quarantine recovery is still in progress")
        case .failed(let message):
            return .unavailable("Quarantine recovery is required: \(message)")
        case .ready:
            break
        }
        if let state = entries[key] {
            switch state {
            case .active:
                return .unavailable("This deletion operation is already pending")
            case .fenced(_, let message):
                return .notAccepted(message)
            case .settled:
                return .unavailable("This deletion operation has already settled")
            case .recoveryFailed(_, let message):
                return .unavailable("Quarantine recovery is required: \(message)")
            }
        }

        guard activeKey == nil else {
            let message = "Privileged deletion service is busy"
            if retainFenceIfPossible(key, message: message, now: now) {
                return .notAccepted(message)
            }
            return .unavailable(message)
        }
        guard canRetain(key) else {
            return .unavailable("Privileged deletion operation registry is full")
        }

        entries[key] = .active
        activeKey = key
        return .accepted
    }

    /// Records an ID even when payload validation fails before admission, so
    /// the correlated notAccepted reply cannot later race with a retry using
    /// the same ID.
    @discardableResult
    func fence(_ key: PrivilegedDeletionOperationKey, message: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let now = DispatchTime.now().uptimeNanoseconds
        purgeExpiredEntries(now: now)
        guard case .ready = recoveryState else { return false }
        if let state = entries[key] {
            guard case .fenced = state else { return false }
            return true
        }
        return retainFenceIfPossible(key, message: message, now: now)
    }

    func finish(_ key: PrivilegedDeletionOperationKey, completion: Completion) {
        lock.lock()
        defer { lock.unlock() }

        guard let state = entries[key], case .active = state else {
            return
        }

        if activeKey == key {
            activeKey = nil
        }
        let expiry = expiration(after: DispatchTime.now().uptimeNanoseconds)
        switch completion {
        case .settled:
            entries[key] = .settled(expiresAt: expiry)
        case .notAccepted(let message):
            entries[key] = .fenced(expiresAt: expiry, message: message)
        case .recoveryFailed(let message):
            entries[key] = .recoveryFailed(expiresAt: expiry, message: message)
            recoveryState = .failed(message)
        }
    }

    func reconcile(_ key: PrivilegedDeletionOperationKey) -> Reconciliation {
        lock.lock()
        defer { lock.unlock() }

        let now = DispatchTime.now().uptimeNanoseconds
        purgeExpiredEntries(now: now)

        switch recoveryState {
        case .pending:
            return Reconciliation(
                state: .unavailable,
                message: "Quarantine recovery is still in progress"
            )
        case .failed(let message):
            return Reconciliation(state: .recoveryFailed, message: message)
        case .ready:
            break
        }

        if let state = entries[key] {
            switch state {
            case .active:
                return Reconciliation(state: .pending, message: nil)
            case .fenced(_, let message):
                return Reconciliation(state: .notAccepted, message: message)
            case .settled:
                return Reconciliation(state: .settled, message: nil)
            case .recoveryFailed(_, let message):
                return Reconciliation(state: .recoveryFailed, message: message)
            }
        }

        // The in-memory registry is intentionally lost across helper restarts.
        // Durable recovery can prove the namespace is settled, but not whether
        // this ID reached a pre-restart COMMITTED transaction. Install a
        // settled tombstone atomically so a later deleteItems delivery cannot
        // run, then report the conservative outcome instead of notAccepted.
        guard canRetain(key) else {
            return Reconciliation(
                state: .unavailable,
                message: "Privileged deletion operation registry is full"
            )
        }
        entries[key] = .settled(expiresAt: expiration(after: now))
        return Reconciliation(
            state: .settled,
            message: "No live operation remained after durable recovery"
        )
    }

    private func retainFenceIfPossible(
        _ key: PrivilegedDeletionOperationKey,
        message: String,
        now: UInt64
    ) -> Bool {
        guard canRetain(key) else { return false }
        entries[key] = .fenced(
            expiresAt: expiration(after: now),
            message: message
        )
        return true
    }

    private func canRetain(_ key: PrivilegedDeletionOperationKey) -> Bool {
        guard entries.count < maximumEntryCount else { return false }
        let userEntryCount = entries.keys.reduce(into: 0) { count, existingKey in
            if existingKey.userID == key.userID {
                count += 1
            }
        }
        return userEntryCount < maximumEntryCountPerUser
    }

    private func purgeExpiredEntries(now: UInt64) {
        let expiredKeys = entries.compactMap { key, state -> PrivilegedDeletionOperationKey? in
            switch state {
            case .active:
                return nil
            case .fenced(let expiresAt, _),
                 .settled(let expiresAt),
                 .recoveryFailed(let expiresAt, _):
                return expiresAt <= now ? key : nil
            }
        }
        for key in expiredKeys {
            entries.removeValue(forKey: key)
        }
    }

    private func expiration(after now: UInt64) -> UInt64 {
        let (result, overflow) = now.addingReportingOverflow(retentionNanoseconds)
        return overflow ? UInt64.max : result
    }
}

private final class PrivilegedCleaningSession: NSObject, PrivilegedCleaningXPCProtocol, @unchecked Sendable {
    private static let deletionQueue = DispatchQueue(
        label: "com.puremac.privileged-cleaning.deletion",
        qos: .userInitiated
    )
    private static let operationRegistry = PrivilegedDeletionOperationRegistry()
    private let userID: uid_t
    private let homeDirectory: String
    private let cancellation: ConnectionCancellation

    init(
        userID: uid_t,
        homeDirectory: String,
        cancellation: ConnectionCancellation
    ) {
        self.userID = userID
        self.homeDirectory = homeDirectory
        self.cancellation = cancellation
    }

    /// Starts immediately after listener activation. Service-info requests can
    /// therefore distinguish a live recovery from an incompatible or missing
    /// helper, while the registry keeps mutation admission closed. Recovery
    /// and every later deletion share this serial queue.
    static func beginStartupRecovery() {
        deletionQueue.async {
            do {
                try SecureFileDeleter.recoverInterruptedQuarantines()
                operationRegistry.markStartupRecoverySucceeded()
            } catch {
                operationRegistry.markRecoveryFailed(error.localizedDescription)
            }
        }
    }

    func serviceInfo(withReply reply: @escaping (NSData) -> Void) {
        let recovery = Self.operationRegistry.recoveryStatus()
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let info = PrivilegedCleaningServiceInfo(
            recoveryState: recovery.state,
            recoveryMessage: recovery.message
        )
        reply(((try? encoder.encode(info)) ?? Data()) as NSData)
    }

    func reconcileDeletion(
        _ batchID: NSUUID,
        withReply reply: @escaping (NSData) -> Void
    ) {
        let operationID = batchID as UUID
        let reconciliation = Self.operationRegistry.reconcile(
            PrivilegedDeletionOperationKey(userID: userID, batchID: operationID)
        )
        let response = PrivilegedDeletionReconciliationResponse(
            batchID: operationID,
            state: reconciliation.state,
            message: reconciliation.message
        )
        reply(encode(response))
    }

    func deleteItems(
        _ batchID: NSUUID,
        encodedBatch: NSData,
        withReply reply: @escaping (NSData) -> Void
    ) {
        let operationID = batchID as UUID
        let operationKey = PrivilegedDeletionOperationKey(
            userID: userID,
            batchID: operationID
        )

        // Reject oversized values before copying them. The external operation
        // ID still gives the reply a trustworthy correlation value even though
        // the payload itself was never decoded.
        guard encodedBatch.length <= PrivilegedCleaningConstants.maximumEncodedSize else {
            let message = "Rejected oversized deletion batch"
            if Self.operationRegistry.fence(operationKey, message: message) {
                reply(encodeNotAcceptedResponse(batchID: operationID, message: message))
            } else {
                reply(encodeUnavailableTransport())
            }
            return
        }

        switch Self.operationRegistry.begin(operationKey) {
        case .accepted:
            break
        case .notAccepted(let message):
            reply(encodeNotAcceptedResponse(batchID: operationID, message: message))
            return
        case .unavailable:
            reply(encodeUnavailableTransport())
            return
        }

        // Copy the immutable XPC value before returning to Foundation's
        // delivery queue. Actual filesystem work runs on a separate serial
        // queue so connection invalidation can set the cancellation flag while
        // a recursive deletion is in progress.
        let immutableBatch = encodedBatch.copy() as! NSData
        Self.deletionQueue.async { [self] in
            let result = autoreleasepool {
                processBatch(immutableBatch, expectedBatchID: operationID)
            }
            // Publish the terminal state and release the single mutation slot
            // before invoking the XPC reply. A racing reconnect therefore sees
            // settled/notAccepted, never a stale busy state after its reply.
            Self.operationRegistry.finish(operationKey, completion: result.completion)
            reply(result.response)
        }
    }

    private struct OperationResult {
        let completion: PrivilegedDeletionOperationRegistry.Completion
        let response: NSData
    }

    private func processBatch(
        _ encodedBatch: NSData,
        expectedBatchID: UUID
    ) -> OperationResult {
        guard let batch = try? PropertyListDecoder().decode(
            PrivilegedDeletionBatch.self,
            from: encodedBatch as Data
        ),
            batch.id == expectedBatchID,
            batch.protocolVersion == PrivilegedCleaningConstants.protocolVersion,
            batch.securityPolicyVersion == PrivilegedCleaningConstants.securityPolicyVersion,
            !batch.requests.isEmpty,
            batch.requests.count <= PrivilegedCleaningConstants.maximumBatchCount,
            Set(batch.requests.map(\.id)).count == batch.requests.count
        else {
            let message = "Rejected malformed deletion batch"
            return OperationResult(
                completion: .notAccepted(message),
                response: encodeNotAcceptedResponse(
                    batchID: expectedBatchID,
                    message: message
                )
            )
        }

        guard isAuthorized(batch.authorization) else {
            return completedResult(
                batchID: batch.id,
                responses: batch.requests.map { request in
                    PrivilegedDeletionResponse(
                        requestID: request.id,
                        path: request.path,
                        status: .rejected,
                        message: "Administrator authorization is missing or expired"
                    )
                }
            )
        }

        let now = Date()
        guard batch.deadline > now else {
            return completedResult(
                batchID: batch.id,
                responses: batch.requests.map { request in
                    PrivilegedDeletionResponse(
                        requestID: request.id,
                        path: request.path,
                        status: .failed,
                        message: "Privileged deletion deadline expired"
                    )
                }
            )
        }
        let effectiveDeadline = min(batch.deadline, now.addingTimeInterval(120))

        let policy = SecureDeletionPolicy(userID: userID, homeDirectory: homeDirectory)
        var responses: [PrivilegedDeletionResponse] = []
        responses.reserveCapacity(batch.requests.count)
        var recoveryFailure: String?

        for request in batch.requests {
            if let recoveryFailure {
                responses.append(
                    PrivilegedDeletionResponse(
                        requestID: request.id,
                        path: request.path,
                        status: .failed,
                        message: "Skipped because quarantine recovery is required: \(recoveryFailure)"
                    )
                )
                continue
            }

            do {
                let deleter = SecureFileDeleter(
                    policy: policy,
                    isolation: .privilegedQuarantine,
                    cancellationCheck: { [cancellation] in
                        if cancellation.isCancelled {
                            throw SecureDeletionError.operationCancelled(request.path)
                        }
                        if Date() >= effectiveDeadline {
                            throw SecureDeletionError.deadlineExceeded(request.path)
                        }
                    },
                    privilegedOperationID: batch.id
                )
                // Policy, type, owner and scan identity are deliberately
                // checked here in the root process, even though the app
                // performs the same validation before opening XPC.
                try deleter.remove(request)
                responses.append(
                    PrivilegedDeletionResponse(
                        requestID: request.id,
                        path: request.path,
                        status: .deleted,
                        message: nil
                    )
                )
            } catch SecureDeletionError.topLevelMissing {
                responses.append(
                    PrivilegedDeletionResponse(
                        requestID: request.id,
                        path: request.path,
                        status: .missing,
                        message: nil
                    )
                )
            } catch let error as SecureDeletionError {
                let message = error.localizedDescription
                if case .quarantineRecoveryFailed = error {
                    recoveryFailure = message
                }
                responses.append(
                    PrivilegedDeletionResponse(
                        requestID: request.id,
                        path: request.path,
                        status: isPolicyRejection(error) ? .rejected : .failed,
                        message: message
                    )
                )
            } catch {
                responses.append(
                    PrivilegedDeletionResponse(
                        requestID: request.id,
                        path: request.path,
                        status: .failed,
                        message: error.localizedDescription
                    )
                )
            }
        }

        let response = encode(
            PrivilegedDeletionBatchResponse(
                batchID: batch.id,
                responses: responses
            )
        )
        if let recoveryFailure {
            return OperationResult(
                completion: .recoveryFailed(recoveryFailure),
                response: response
            )
        }
        return OperationResult(completion: .settled, response: response)
    }

    private func completedResult(
        batchID: UUID,
        responses: [PrivilegedDeletionResponse]
    ) -> OperationResult {
        OperationResult(
            completion: .settled,
            response: encode(
                PrivilegedDeletionBatchResponse(
                    batchID: batchID,
                    responses: responses
                )
            )
        )
    }

    private func isPolicyRejection(_ error: SecureDeletionError) -> Bool {
        switch error {
        case .invalidPath, .outsideAllowlist, .unsupportedType, .ownerMismatch,
             .identityChanged, .topLevelMissing, .crossedDeviceBoundary,
             .traversalLimitExceeded:
            return true
        case .quarantineRecoveryFailed, .operationCancelled, .deadlineExceeded, .posix:
            return false
        }
    }

    private func isAuthorized(_ token: Data) -> Bool {
        guard authorizationRightDefinitionIsCurrent() else {
            return false
        }
        guard token.count == MemoryLayout<AuthorizationExternalForm>.size else {
            return false
        }

        var externalForm = AuthorizationExternalForm()
        _ = withUnsafeMutableBytes(of: &externalForm) { buffer in
            token.copyBytes(to: buffer)
        }

        var authorization: AuthorizationRef?
        let createStatus = AuthorizationCreateFromExternalForm(
            &externalForm,
            &authorization
        )
        guard createStatus == errAuthorizationSuccess,
              let authorization
        else {
            return false
        }
        defer { AuthorizationFree(authorization, []) }

        let rightsStatus = PrivilegedCleaningConstants.authorizationRight.withCString { rightName in
            var item = AuthorizationItem(
                name: rightName,
                valueLength: 0,
                value: nil,
                flags: 0
            )
            return withUnsafeMutablePointer(to: &item) { itemPointer in
                var rights = AuthorizationRights(count: 1, items: itemPointer)
                return AuthorizationCopyRights(
                    authorization,
                    &rights,
                    nil,
                    [],
                    nil
                )
            }
        }
        return rightsStatus == errAuthorizationSuccess
    }

    private func authorizationRightDefinitionIsCurrent() -> Bool {
        var definition: CFDictionary?
        let status = PrivilegedCleaningConstants.authorizationRight.withCString { rightName in
            AuthorizationRightGet(rightName, &definition)
        }
        guard status == errAuthorizationSuccess, let definition else {
            return false
        }

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

    private func encodeNotAcceptedResponse(batchID: UUID, message: String) -> NSData {
        encode(
            PrivilegedDeletionBatchResponse(
                batchID: batchID,
                disposition: .notAccepted,
                message: message,
                responses: []
            )
        )
    }

    private func encodeUnavailableTransport() -> NSData {
        // There is deliberately no valid batch response here. Returning an
        // undecodable value prevents the client from treating busy/full or an
        // unresolved recovery gate as proof that the operation ID was fenced.
        Data() as NSData
    }

    private func encode<Value: Encodable>(_ value: Value) -> NSData {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return ((try? encoder.encode(value)) ?? Data()) as NSData
    }
}

private let listener = NSXPCListener(
    machServiceName: PrivilegedCleaningConstants.machServiceName
)
private let delegate = PrivilegedCleaningListenerDelegate()
listener.delegate = delegate
listener.setConnectionCodeSigningRequirement(
    PrivilegedCleaningConstants.appCodeSigningRequirement
)
listener.activate()
PrivilegedCleaningSession.beginStartupRecovery()
dispatchMain()
