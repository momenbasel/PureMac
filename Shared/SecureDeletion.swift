import Darwin
import Foundation

enum PrivilegedDeletionOperation: String, Codable, Sendable {
    case cleaner
    case largeFile
    case uninstall
}

struct FileIdentity: Codable, Equatable, Sendable {
    enum LookupResult: Sendable {
        case found(FileIdentity)
        case missing
        case failed(Int32)
    }

    let device: UInt64
    let inode: UInt64
    let fileType: UInt32
    let owner: UInt32
    let generation: UInt32
    let birthtimeSeconds: Int64
    let birthtimeNanoseconds: Int64

    init(
        device: UInt64,
        inode: UInt64,
        fileType: UInt32,
        owner: UInt32,
        generation: UInt32,
        birthtimeSeconds: Int64,
        birthtimeNanoseconds: Int64
    ) {
        self.device = device
        self.inode = inode
        self.fileType = fileType
        self.owner = owner
        self.generation = generation
        self.birthtimeSeconds = birthtimeSeconds
        self.birthtimeNanoseconds = birthtimeNanoseconds
    }

    init(stat info: stat) {
        device = UInt64(bitPattern: Int64(info.st_dev))
        inode = UInt64(info.st_ino)
        fileType = UInt32(info.st_mode) & UInt32(S_IFMT)
        owner = UInt32(info.st_uid)
        generation = UInt32(info.st_gen)
        birthtimeSeconds = Int64(info.st_birthtimespec.tv_sec)
        birthtimeNanoseconds = Int64(info.st_birthtimespec.tv_nsec)
    }

    static func capture(path: String) -> FileIdentity? {
        guard case let .found(identity) = lookup(path: path) else {
            return nil
        }
        return identity
    }

    static func lookup(path: String) -> LookupResult {
        var info = stat()
        let status = path.withCString { pointer in
            Darwin.lstat(pointer, &info)
        }
        guard status == 0 else {
            let code = errno
            return code == ENOENT ? .missing : .failed(code)
        }
        return .found(FileIdentity(stat: info))
    }

    var isDirectory: Bool { fileType == UInt32(S_IFDIR) }
    var isRegularFile: Bool { fileType == UInt32(S_IFREG) }
    var isSymbolicLink: Bool { fileType == UInt32(S_IFLNK) }
    var isFIFO: Bool { fileType == UInt32(S_IFIFO) }
    var isSocket: Bool { fileType == UInt32(S_IFSOCK) }

    var isSupportedType: Bool {
        isDirectory || isRegularFile || isSymbolicLink || isFIFO || isSocket
    }
}

struct PrivilegedDeletionRequest: Codable, Sendable {
    let id: UUID
    let path: String
    let identity: FileIdentity
    let operation: PrivilegedDeletionOperation

    init(
        id: UUID = UUID(),
        path: String,
        identity: FileIdentity,
        operation: PrivilegedDeletionOperation
    ) {
        self.id = id
        self.path = path
        self.identity = identity
        self.operation = operation
    }
}

enum PrivilegedDeletionStatus: String, Codable, Equatable, Sendable {
    case deleted
    case missing
    case rejected
    case failed
    /// The transport failed after submission, so the client cannot know
    /// whether this identity-bound request ran. The client waits for a helper
    /// reconciliation barrier before exposing this status, ensuring a retry
    /// cannot observe a temporary quarantine absence.
    case unknown
}

struct PrivilegedDeletionResponse: Codable, Sendable {
    let requestID: UUID
    let path: String
    let status: PrivilegedDeletionStatus
    let message: String?
}

struct PrivilegedDeletionBatch: Codable, Sendable {
    let id: UUID
    let protocolVersion: Int
    let securityPolicyVersion: Int
    let requests: [PrivilegedDeletionRequest]
    /// Opaque Authorization Services external form. It is created only in
    /// memory by the app and revalidated by the root helper for every batch.
    let authorization: Data
    let deadline: Date

    init(
        id: UUID = UUID(),
        protocolVersion: Int = PrivilegedCleaningConstants.protocolVersion,
        securityPolicyVersion: Int = PrivilegedCleaningConstants.securityPolicyVersion,
        requests: [PrivilegedDeletionRequest],
        authorization: Data,
        deadline: Date
    ) {
        self.id = id
        self.protocolVersion = protocolVersion
        self.securityPolicyVersion = securityPolicyVersion
        self.requests = requests
        self.authorization = authorization
        self.deadline = deadline
    }
}

enum PrivilegedDeletionBatchDisposition: String, Codable, Sendable {
    case completed
    /// The helper proves this operation ID was never admitted for mutation.
    case notAccepted
}

struct PrivilegedDeletionBatchResponse: Codable, Sendable {
    let batchID: UUID
    let protocolVersion: Int
    let securityPolicyVersion: Int
    let disposition: PrivilegedDeletionBatchDisposition
    let message: String?
    let responses: [PrivilegedDeletionResponse]

    init(
        batchID: UUID,
        protocolVersion: Int = PrivilegedCleaningConstants.protocolVersion,
        securityPolicyVersion: Int = PrivilegedCleaningConstants.securityPolicyVersion,
        disposition: PrivilegedDeletionBatchDisposition = .completed,
        message: String? = nil,
        responses: [PrivilegedDeletionResponse]
    ) {
        self.batchID = batchID
        self.protocolVersion = protocolVersion
        self.securityPolicyVersion = securityPolicyVersion
        self.disposition = disposition
        self.message = message
        self.responses = responses
    }
}

enum PrivilegedDeletionReconciliationState: String, Codable, Sendable {
    /// The operation completed or failed with its namespace fully settled.
    case settled
    /// Reconciliation arrived first and permanently tombstoned this ID, or
    /// the batch was explicitly rejected before any mutation.
    case notAccepted
    case pending
    case unavailable
    case recoveryFailed
}

struct PrivilegedDeletionReconciliationResponse: Codable, Sendable {
    let protocolVersion: Int
    let securityPolicyVersion: Int
    let batchID: UUID
    let state: PrivilegedDeletionReconciliationState
    let message: String?

    init(
        protocolVersion: Int = PrivilegedCleaningConstants.protocolVersion,
        securityPolicyVersion: Int = PrivilegedCleaningConstants.securityPolicyVersion,
        batchID: UUID,
        state: PrivilegedDeletionReconciliationState,
        message: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.securityPolicyVersion = securityPolicyVersion
        self.batchID = batchID
        self.state = state
        self.message = message
    }
}

struct PrivilegedQuarantineJournal: Codable, Sendable {
    enum State: String, Codable, Sendable {
        case prepared
        case committed
    }

    static let formatVersion = 2
    static let fileName = ".puremac-journal"
    static let temporaryFilePrefix = ".puremac-journal-new-"
    static let maximumEncodedSize = 65_536

    let formatVersion: Int
    let protocolVersion: Int
    let securityPolicyVersion: Int
    let state: State
    let transactionID: UUID
    let operationID: UUID
    let initiatingUserID: UInt32
    let request: PrivilegedDeletionRequest
    let sourceParentPath: String
    let sourceParentIdentity: FileIdentity
    let sourceName: String
    let boundaryPath: String
    let boundaryDevice: UInt64

    init(
        state: State,
        transactionID: UUID,
        operationID: UUID,
        initiatingUserID: uid_t,
        request: PrivilegedDeletionRequest,
        sourceParentPath: String,
        sourceParentIdentity: FileIdentity,
        sourceName: String,
        boundaryPath: String,
        boundaryDevice: UInt64
    ) {
        formatVersion = Self.formatVersion
        protocolVersion = PrivilegedCleaningConstants.protocolVersion
        securityPolicyVersion = PrivilegedCleaningConstants.securityPolicyVersion
        self.state = state
        self.transactionID = transactionID
        self.operationID = operationID
        self.initiatingUserID = UInt32(initiatingUserID)
        self.request = request
        self.sourceParentPath = sourceParentPath
        self.sourceParentIdentity = sourceParentIdentity
        self.sourceName = sourceName
        self.boundaryPath = boundaryPath
        self.boundaryDevice = boundaryDevice
    }

    func changingState(to state: State) -> PrivilegedQuarantineJournal {
        PrivilegedQuarantineJournal(
            state: state,
            transactionID: transactionID,
            operationID: operationID,
            initiatingUserID: uid_t(initiatingUserID),
            request: request,
            sourceParentPath: sourceParentPath,
            sourceParentIdentity: sourceParentIdentity,
            sourceName: sourceName,
            boundaryPath: boundaryPath,
            boundaryDevice: boundaryDevice
        )
    }
}

enum PrivilegedCleaningRecoveryState: String, Codable, Sendable {
    case recovering
    case ready
    case failed
}

struct PrivilegedCleaningServiceInfo: Codable, Sendable {
    let protocolVersion: Int
    let securityPolicyVersion: Int
    let helperBundleIdentifier: String
    /// Optional so a service-info reply from an older protocol can still be
    /// decoded far enough to identify an explicit version mismatch. A helper
    /// advertising the current protocol must always provide this field.
    let recoveryState: PrivilegedCleaningRecoveryState?
    let recoveryMessage: String?

    init(
        protocolVersion: Int = PrivilegedCleaningConstants.protocolVersion,
        securityPolicyVersion: Int = PrivilegedCleaningConstants.securityPolicyVersion,
        helperBundleIdentifier: String = PrivilegedCleaningConstants.helperBundleIdentifier,
        recoveryState: PrivilegedCleaningRecoveryState = .ready,
        recoveryMessage: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.securityPolicyVersion = securityPolicyVersion
        self.helperBundleIdentifier = helperBundleIdentifier
        self.recoveryState = recoveryState
        self.recoveryMessage = recoveryMessage
    }
}

enum PrivilegedCleaningConstants {
    static let machServiceName = "com.puremac.privileged-cleaning"
    static let launchDaemonPlistName = "com.puremac.privileged-cleaning.plist"
    static let appBundleIdentifier = "com.puremac.app"
    static let helperBundleIdentifier = "com.puremac.privileged-helper"
    static let teamIdentifier = "H3WXHVTP97"
    static let authorizationRight = "com.puremac.app.delete-items"
    static let authorizationRightTimeout = 300
    static let protocolVersion = 3
    /// Increment this whenever privileged allowlists or deletion semantics
    /// change. The app checks it before sending any paths, so an older daemon
    /// cannot keep applying stale root policy after an application update.
    static let securityPolicyVersion = 3
    static let maximumBatchCount = 128
    static let maximumEncodedSize = 1_048_576
    static let quarantineDirectoryPrefix = ".puremac-delete-"
    static let quarantineRootPath = "/private/var/db/com.puremac/quarantine"

    static let appCodeSigningRequirement = "anchor apple generic and identifier \"\(appBundleIdentifier)\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    static let helperCodeSigningRequirement = "anchor apple generic and identifier \"\(helperBundleIdentifier)\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
}

@objc protocol PrivilegedCleaningXPCProtocol {
    func serviceInfo(withReply reply: @escaping (NSData) -> Void)
    func reconcileDeletion(
        _ batchID: NSUUID,
        withReply reply: @escaping (NSData) -> Void
    )
    func deleteItems(
        _ batchID: NSUUID,
        encodedBatch: NSData,
        withReply reply: @escaping (NSData) -> Void
    )
}

enum SecureDeletionError: LocalizedError {
    case invalidPath(String)
    case outsideAllowlist(String)
    case unsupportedType(String)
    case ownerMismatch(path: String, owner: uid_t)
    case identityChanged(String)
    case topLevelMissing(String)
    case crossedDeviceBoundary(String)
    case traversalLimitExceeded(String)
    case quarantineRecoveryFailed(String)
    case operationCancelled(String)
    case deadlineExceeded(String)
    case posix(operation: String, path: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case let .invalidPath(path):
            return "Invalid deletion path: \(path)"
        case let .outsideAllowlist(path):
            return "Path is outside the deletion allowlist: \(path)"
        case let .unsupportedType(path):
            return "Unsupported filesystem object type: \(path)"
        case let .ownerMismatch(path, owner):
            return "Refusing object owned by uid \(owner): \(path)"
        case let .identityChanged(path):
            return "Filesystem identity changed before deletion: \(path)"
        case let .topLevelMissing(path):
            return "Filesystem object disappeared before deletion: \(path)"
        case let .crossedDeviceBoundary(path):
            return "Refusing to cross a mounted filesystem while deleting: \(path)"
        case let .traversalLimitExceeded(path):
            return "Deletion traversal safety limit exceeded: \(path)"
        case let .quarantineRecoveryFailed(path):
            return "A raced filesystem object could not be restored safely: \(path)"
        case let .operationCancelled(path):
            return "Privileged deletion was canceled: \(path)"
        case let .deadlineExceeded(path):
            return "Privileged deletion deadline exceeded: \(path)"
        case let .posix(operation, path, code):
            return "\(operation) failed for \(path): \(String(cString: strerror(code)))"
        }
    }
}

struct SecureDeletionPolicy: Sendable {
    struct Root: Sendable {
        let path: String
        let mayDeleteRoot: Bool
    }

    struct ValidatedRequest: Sendable {
        let path: String
        /// The structural allowlist root. Its device is captured while the
        /// descriptor walk crosses it, so a mountpoint below the root cannot
        /// redirect recursive deletion onto another filesystem.
        let boundaryPath: String
    }

    let userID: uid_t
    let homeDirectory: String
    private let cleanerRoots: [Root]
    private let largeFileRoots: [String]

    init(
        userID: uid_t,
        homeDirectory: String,
        cleanerRootsOverride: [Root]? = nil,
        largeFileRootsOverride: [String]? = nil
    ) {
        self.userID = userID
        self.homeDirectory = (homeDirectory as NSString).standardizingPath

        if let cleanerRootsOverride {
            cleanerRoots = cleanerRootsOverride.map { root in
                Root(path: Self.normalizeSystemAliases(root.path), mayDeleteRoot: root.mayDeleteRoot)
            }
        } else {
            let home = self.homeDirectory
            cleanerRoots = [
                Root(path: "\(home)/Library/Caches", mayDeleteRoot: false),
                Root(path: "\(home)/Library/Logs", mayDeleteRoot: false),
                Root(path: "\(home)/Library/Saved Application State", mayDeleteRoot: false),
                Root(path: "\(home)/Library/HTTPStorages", mayDeleteRoot: false),
                Root(path: "\(home)/Library/WebKit", mayDeleteRoot: false),
                Root(path: "\(home)/Library/Containers", mayDeleteRoot: false),
                Root(path: "\(home)/Library/Group Containers", mayDeleteRoot: false),
                Root(path: "\(home)/Library/Application Support", mayDeleteRoot: false),
                Root(path: "\(home)/Library/Preferences", mayDeleteRoot: false),
                Root(path: "\(home)/Library/LaunchAgents", mayDeleteRoot: false),
                Root(path: "\(home)/Library/Mail Downloads", mayDeleteRoot: false),
                Root(path: "\(home)/Library/Developer/Xcode/DerivedData", mayDeleteRoot: true),
                Root(path: "\(home)/Library/Developer/Xcode/Archives", mayDeleteRoot: true),
                Root(path: "\(home)/Library/Developer/CoreSimulator/Caches", mayDeleteRoot: true),
                Root(path: "\(home)/.Trash", mayDeleteRoot: false),
                Root(path: "\(home)/.npm", mayDeleteRoot: true),
                Root(path: "\(home)/.cache", mayDeleteRoot: false),
                Root(path: "\(home)/Library/Containers/com.docker.docker", mayDeleteRoot: false),
                Root(path: "/Library/Caches", mayDeleteRoot: false),
                Root(path: "/Library/Logs", mayDeleteRoot: false),
                Root(path: "/private/var/log", mayDeleteRoot: false),
                Root(path: "/private/var/tmp", mayDeleteRoot: false),
                Root(path: "/private/tmp", mayDeleteRoot: false),
            ]
        }

        if let largeFileRootsOverride {
            largeFileRoots = largeFileRootsOverride.map(Self.normalizeSystemAliases)
        } else {
            let home = self.homeDirectory
            largeFileRoots = [
                "\(home)/Downloads",
                "\(home)/Documents",
                "\(home)/Desktop",
            ]
        }
    }

    func canonicalPath(_ untrustedPath: String) throws -> String {
        guard !untrustedPath.isEmpty,
              untrustedPath.hasPrefix("/"),
              !untrustedPath.utf8.contains(0),
              untrustedPath != "/",
              untrustedPath.utf8.count < Int(PATH_MAX)
        else {
            throw SecureDeletionError.invalidPath(untrustedPath)
        }

        let rawComponents = untrustedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard rawComponents.first == "",
              rawComponents.count <= 129,
              !rawComponents.dropFirst().contains(where: {
                  $0.isEmpty || $0 == "." || $0 == ".." || $0.utf8.count > Int(NAME_MAX)
              })
        else {
            throw SecureDeletionError.invalidPath(untrustedPath)
        }

        let normalized = Self.normalizeSystemAliases(untrustedPath)
        guard normalized.utf8.count < Int(PATH_MAX) else {
            throw SecureDeletionError.invalidPath(untrustedPath)
        }
        return normalized
    }

    func validate(_ request: PrivilegedDeletionRequest) throws -> String {
        try validatedRequest(request).path
    }

    func validatedRequest(_ request: PrivilegedDeletionRequest) throws -> ValidatedRequest {
        let path = try canonicalPath(request.path)
        guard request.identity.isSupportedType else {
            throw SecureDeletionError.unsupportedType(path)
        }
        guard request.identity.owner == UInt32(userID) || request.identity.owner == 0 else {
            throw SecureDeletionError.ownerMismatch(path: path, owner: uid_t(request.identity.owner))
        }

        let boundaryPath: String?
        switch request.operation {
        case .cleaner:
            let matchedRoot = cleanerRoots
                .filter { isInside(path, root: $0.path, includeRoot: true) }
                .max { $0.path.utf8.count < $1.path.utf8.count }
            if let matchedRoot,
               path != matchedRoot.path || matchedRoot.mayDeleteRoot {
                boundaryPath = matchedRoot.path
            } else {
                boundaryPath = nil
            }
        case .largeFile:
            guard request.identity.isRegularFile else {
                throw SecureDeletionError.unsupportedType(path)
            }
            boundaryPath = largeFileRoots
                .filter { isInside(path, root: $0, includeRoot: false) }
                .max { $0.utf8.count < $1.utf8.count }
        case .uninstall:
            boundaryPath = safeUninstallBoundary(path, identity: request.identity)
        }

        guard let boundaryPath else {
            throw SecureDeletionError.outsideAllowlist(path)
        }
        return ValidatedRequest(path: path, boundaryPath: boundaryPath)
    }

    func quarantineParentPath(for validated: ValidatedRequest) -> String {
        validated.path == validated.boundaryPath
            ? (validated.boundaryPath as NSString).deletingLastPathComponent
            : validated.boundaryPath
    }

    var quarantineParentPaths: [String] {
        var paths = cleanerRoots.map(\.path)
        paths.append(contentsOf: cleanerRoots.compactMap { root in
            root.mayDeleteRoot ? (root.path as NSString).deletingLastPathComponent : nil
        })
        paths.append(contentsOf: largeFileRoots)
        paths.append(contentsOf: [
            "/Applications",
            "\(homeDirectory)/Applications",
            "/private/var/db/receipts",
            "/Library/LaunchDaemons",
            "/Library/LaunchAgents",
        ])
        return Array(Set(paths.map(Self.normalizeSystemAliases))).sorted()
    }

    private func safeUninstallBoundary(_ path: String, identity: FileIdentity) -> String? {
        let systemApplications = "/Applications"
        let userApplications = "\(homeDirectory)/Applications"
        let receipts = "/private/var/db/receipts"
        let launchDaemons = "/Library/LaunchDaemons"
        let launchAgents = "/Library/LaunchAgents"

        if identity.isDirectory && isAppBundlePath(path, rootedAt: systemApplications) {
            return systemApplications
        }
        if identity.isDirectory && isAppBundlePath(path, rootedAt: userApplications) {
            return userApplications
        }
        if identity.isRegularFile && isReceiptPath(path, rootedAt: receipts) {
            return receipts
        }
        if identity.isRegularFile && isPlist(path, directlyUnder: launchDaemons) {
            return launchDaemons
        }
        if identity.isRegularFile && isPlist(path, directlyUnder: launchAgents) {
            return launchAgents
        }
        return nil
    }

    private func isAppBundlePath(_ path: String, rootedAt root: String) -> Bool {
        guard isInside(path, root: root, includeRoot: false) else { return false }
        let relative = String(path.dropFirst(root.count + 1))
        let components = relative.split(separator: "/").map(String.init)
        guard let bundleName = components.last,
              bundleName.lowercased().hasSuffix(".app")
        else {
            return false
        }
        // A selected app may live in an Applications subfolder, but never
        // authorize a nested helper app or other bundle inside another .app.
        return !components.dropLast().contains {
            $0.lowercased().hasSuffix(".app")
        }
    }

    private func isReceiptPath(_ path: String, rootedAt root: String) -> Bool {
        let parent = (path as NSString).deletingLastPathComponent
        let ext = (path as NSString).pathExtension.lowercased()
        return parent == root && (ext == "plist" || ext == "bom")
    }

    private func isPlist(_ path: String, directlyUnder root: String) -> Bool {
        (path as NSString).deletingLastPathComponent == root
            && (path as NSString).pathExtension.lowercased() == "plist"
    }

    private func isInside(_ path: String, root: String, includeRoot: Bool) -> Bool {
        let normalizedRoot = Self.normalizeSystemAliases(root)
        if path == normalizedRoot { return includeRoot }
        return path.hasPrefix(normalizedRoot + "/")
    }

    private static func normalizeSystemAliases(_ path: String) -> String {
        var normalized = (path as NSString).standardizingPath
        if normalized == "/tmp" || normalized.hasPrefix("/tmp/") {
            normalized = "/private" + normalized
        } else if normalized == "/var" || normalized.hasPrefix("/var/") {
            normalized = "/private" + normalized
        }
        return normalized
    }
}

enum SecureDeletionIsolation: Sendable {
    /// Used by the unprivileged process. The entry is revalidated immediately
    /// before unlinkat, and every path component is descriptor-walked.
    case direct
    /// Used only by the root helper. The selected entry is atomically moved
    /// into a root-owned directory and its identity is checked *after* that
    /// move, closing the final check-to-unlink race for privileged deletion.
    case privilegedQuarantine
}

struct SecureFileDeleter: Sendable {
    private struct PrivilegedStagingRoot {
        let descriptor: Int32
        let path: String
        let identity: FileIdentity
        let expectedOwner: uid_t
    }

    let policy: SecureDeletionPolicy
    let isolation: SecureDeletionIsolation
    /// Production always uses the fixed root-owned staging directory. Tests
    /// may inject a private directory owned by the effective test uid; the
    /// same-device, no-follow and mode checks remain mandatory.
    let privilegedStagingRootPathOverride: String?
    /// The helper may bind journal records to its batch/operation identifier.
    /// Existing direct and test callers fall back to the request identifier.
    let privilegedOperationID: UUID?
    /// Deterministic race injection point used by the security tests. Shipping
    /// callers leave it nil.
    let beforeQuarantineRename: (@Sendable () throws -> Void)?
    let afterQuarantineRename: (@Sendable () throws -> Void)?
    let beforeDirectoryUnlink: (@Sendable (String) throws -> Void)?
    let cancellationCheck: (@Sendable () throws -> Void)?
    private let maximumDepth = 64
    private let maximumEntries = 100_000
    private let maximumTransactions = 4_096

    init(
        policy: SecureDeletionPolicy,
        isolation: SecureDeletionIsolation = .direct,
        beforeQuarantineRename: (@Sendable () throws -> Void)? = nil,
        afterQuarantineRename: (@Sendable () throws -> Void)? = nil,
        beforeDirectoryUnlink: (@Sendable (String) throws -> Void)? = nil,
        cancellationCheck: (@Sendable () throws -> Void)? = nil,
        privilegedStagingRootPathOverride: String? = nil,
        privilegedOperationID: UUID? = nil
    ) {
        self.policy = policy
        self.isolation = isolation
        self.privilegedStagingRootPathOverride = privilegedStagingRootPathOverride
        self.privilegedOperationID = privilegedOperationID
        self.beforeQuarantineRename = beforeQuarantineRename
        self.afterQuarantineRename = afterQuarantineRename
        self.beforeDirectoryUnlink = beforeDirectoryUnlink
        self.cancellationCheck = cancellationCheck
    }

    /// Synchronous production startup recovery. The privileged helper calls
    /// this before accepting XPC connections. Every uid represented in the
    /// fixed root-owned staging root must settle successfully or startup stays
    /// fail-closed.
    static func recoverInterruptedQuarantines() throws {
        guard geteuid() == 0 else {
            throw SecureDeletionError.quarantineRecoveryFailed(
                PrivilegedCleaningConstants.quarantineRootPath
            )
        }

        let scanner = SecureFileDeleter(
            policy: SecureDeletionPolicy(userID: 0, homeDirectory: "/var/root"),
            isolation: .privilegedQuarantine
        )
        let userIDs = try scanner.pendingTransactionUserIDs()
        for userID in userIDs.sorted() {
            guard let passwordEntry = Darwin.getpwuid(userID),
                  let homePointer = passwordEntry.pointee.pw_dir
            else {
                throw SecureDeletionError.quarantineRecoveryFailed(
                    PrivilegedCleaningConstants.quarantineRootPath
                )
            }
            let homeDirectory = String(cString: homePointer)
            let deleter = SecureFileDeleter(
                policy: SecureDeletionPolicy(
                    userID: userID,
                    homeDirectory: homeDirectory
                ),
                isolation: .privilegedQuarantine
            )
            try deleter.recoverPendingQuarantines()
        }
    }

    /// Instance recovery also supports the explicitly injected private
    /// staging root used by XCTest. Production callers should use the static
    /// startup API above.
    func recoverPendingQuarantines() throws {
        guard case .privilegedQuarantine = isolation else { return }
        // Recovery is an internal durability obligation. A deadline or test
        // callback belonging to a newly submitted request must not interrupt
        // or mutate recovery of a previous committed transaction.
        let recoveryDeleter = SecureFileDeleter(
            policy: policy,
            isolation: .privilegedQuarantine,
            privilegedStagingRootPathOverride: privilegedStagingRootPathOverride
        )
        try recoveryDeleter.recoverPendingQuarantinesWithoutCallbacks()
    }

    private func recoverPendingQuarantinesWithoutCallbacks() throws {
        let stagingRoot = try openPrivilegedStagingRoot(createIfMissing: true)
        defer { Darwin.close(stagingRoot.descriptor) }

        let names = try directoryEntryNames(
            directoryFD: stagingRoot.descriptor,
            displayPath: stagingRoot.path,
            maximumCount: maximumTransactions
        ).sorted()
        for name in names {
            guard let parsed = parseQuarantineDirectoryName(name) else {
                throw SecureDeletionError.quarantineRecoveryFailed(stagingRoot.path)
            }
            guard parsed.userID == policy.userID else { continue }
            do {
                try recoverQuarantineTransaction(
                    stagingRoot: stagingRoot,
                    quarantineName: name,
                    transactionID: parsed.transactionID
                )
            } catch {
                let path = (stagingRoot.path as NSString).appendingPathComponent(name)
                throw SecureDeletionError.quarantineRecoveryFailed(path)
            }
        }
    }

    private func pendingTransactionUserIDs() throws -> Set<uid_t> {
        let stagingRoot = try openPrivilegedStagingRoot(createIfMissing: true)
        defer { Darwin.close(stagingRoot.descriptor) }
        let names = try directoryEntryNames(
            directoryFD: stagingRoot.descriptor,
            displayPath: stagingRoot.path,
            maximumCount: maximumTransactions
        )
        var result = Set<uid_t>()
        for name in names {
            guard let parsed = parseQuarantineDirectoryName(name) else {
                throw SecureDeletionError.quarantineRecoveryFailed(stagingRoot.path)
            }
            result.insert(parsed.userID)
        }
        return result
    }

    private func recoverQuarantineTransaction(
        stagingRoot: PrivilegedStagingRoot,
        quarantineName: String,
        transactionID: UUID
    ) throws {
        let quarantineFD = quarantineName.withCString { pointer in
            Darwin.openat(
                stagingRoot.descriptor,
                pointer,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard quarantineFD >= 0 else {
            throw SecureDeletionError.quarantineRecoveryFailed(stagingRoot.path)
        }
        defer { Darwin.close(quarantineFD) }

        let quarantinePath = (stagingRoot.path as NSString)
            .appendingPathComponent(quarantineName)
        let quarantineIdentity = try validatePrivateDirectoryDescriptor(
            quarantineFD,
            expectedOwner: stagingRoot.expectedOwner,
            expectedDevice: stagingRoot.identity.device,
            displayPath: quarantinePath
        )

        let journal: PrivilegedQuarantineJournal
        do {
            journal = try readQuarantineJournal(
                quarantineFD: quarantineFD,
                expectedOwner: stagingRoot.expectedOwner,
                boundaryDevice: stagingRoot.identity.device,
                displayPath: quarantinePath
            )
        } catch let SecureDeletionError.posix(_, _, code) where code == ENOENT {
            try recoverUnjournaledTransaction(
                stagingRoot: stagingRoot,
                quarantineFD: quarantineFD,
                quarantineName: quarantineName,
                quarantineIdentity: quarantineIdentity,
                displayPath: quarantinePath
            )
            return
        } catch {
            throw SecureDeletionError.quarantineRecoveryFailed(quarantinePath)
        }

        try validateRecoveredJournal(
            journal,
            transactionID: transactionID,
            stagingDevice: stagingRoot.identity.device,
            displayPath: quarantinePath
        )
        try validateTransactionEntrySet(
            quarantineFD: quarantineFD,
            displayPath: quarantinePath,
            journalRequired: true
        )

        let stagedIdentity = try optionalIdentityAt(
            parentFD: quarantineFD,
            name: "item",
            displayPath: journal.request.path
        )
        switch journal.state {
        case .prepared:
            if let stagedIdentity {
                guard stagedIdentity.device == journal.boundaryDevice,
                      stagedIdentity.isSupportedType
                else {
                    throw SecureDeletionError.quarantineRecoveryFailed(quarantinePath)
                }
                let sourceParentFD = try openRecoverySourceParent(journal)
                defer { Darwin.close(sourceParentFD) }
                try restoreQuarantinedEntry(
                    quarantineFD: quarantineFD,
                    stagedName: "item",
                    destinationParentFD: sourceParentFD,
                    destinationName: journal.sourceName,
                    displayPath: journal.request.path
                )
                try synchronizeDirectory(
                    sourceParentFD,
                    displayPath: journal.sourceParentPath
                )
                try synchronizeDirectory(quarantineFD, displayPath: quarantinePath)
            }
            try cleanupQuarantineTransaction(
                stagingRootFD: stagingRoot.descriptor,
                stagingRootPath: stagingRoot.path,
                quarantineFD: quarantineFD,
                quarantineName: quarantineName,
                quarantineIdentity: quarantineIdentity,
                expectedOwner: stagingRoot.expectedOwner,
                displayPath: quarantinePath
            )

        case .committed:
            if let stagedIdentity {
                guard stagedIdentity == journal.request.identity else {
                    throw SecureDeletionError.quarantineRecoveryFailed(quarantinePath)
                }
                var remainingEntries = maximumEntries
                try removeEntry(
                    parentFD: quarantineFD,
                    name: "item",
                    displayPath: journal.request.path,
                    expectedIdentity: journal.request.identity,
                    observedIdentity: stagedIdentity,
                    boundaryDevice: journal.boundaryDevice,
                    depth: 0,
                    remainingEntries: &remainingEntries
                )
                try synchronizeDirectory(quarantineFD, displayPath: quarantinePath)
            }
            try cleanupQuarantineTransaction(
                stagingRootFD: stagingRoot.descriptor,
                stagingRootPath: stagingRoot.path,
                quarantineFD: quarantineFD,
                quarantineName: quarantineName,
                quarantineIdentity: quarantineIdentity,
                expectedOwner: stagingRoot.expectedOwner,
                displayPath: quarantinePath
            )
        }
    }

    private func recoverUnjournaledTransaction(
        stagingRoot: PrivilegedStagingRoot,
        quarantineFD: Int32,
        quarantineName: String,
        quarantineIdentity: FileIdentity,
        displayPath: String
    ) throws {
        // A crash before the initial atomic journal install can leave only a
        // root-owned temporary journal file. `item` is never renamed until
        // PREPARED is installed and synced, so any other entry is unresolved.
        try validateTransactionEntrySet(
            quarantineFD: quarantineFD,
            displayPath: displayPath,
            journalRequired: false
        )
        try cleanupQuarantineTransaction(
            stagingRootFD: stagingRoot.descriptor,
            stagingRootPath: stagingRoot.path,
            quarantineFD: quarantineFD,
            quarantineName: quarantineName,
            quarantineIdentity: quarantineIdentity,
            expectedOwner: stagingRoot.expectedOwner,
            displayPath: displayPath
        )
    }

    private func openPrivilegedStagingRoot(
        createIfMissing: Bool
    ) throws -> PrivilegedStagingRoot {
        let isOverride = privilegedStagingRootPathOverride != nil
        if !isOverride, geteuid() != 0 {
            throw SecureDeletionError.quarantineRecoveryFailed(
                PrivilegedCleaningConstants.quarantineRootPath
            )
        }

        let rawPath = privilegedStagingRootPathOverride
            ?? PrivilegedCleaningConstants.quarantineRootPath
        let path = try policy.canonicalPath(rawPath)
        if !isOverride, path != PrivilegedCleaningConstants.quarantineRootPath {
            throw SecureDeletionError.quarantineRecoveryFailed(path)
        }
        let components = path.split(separator: "/").map(String.init)
        guard !components.isEmpty else {
            throw SecureDeletionError.quarantineRecoveryFailed(path)
        }

        let firstCreatableIndex: Int
        let expectedOwner: uid_t
        if isOverride {
            // The caller creates the unique test parent; only its final private
            // staging component may be created here.
            firstCreatableIndex = components.count - 1
            expectedOwner = geteuid()
        } else {
            let baseComponents = ["private", "var", "db"]
            guard components.starts(with: baseComponents),
                  components.count > baseComponents.count
            else {
                throw SecureDeletionError.quarantineRecoveryFailed(path)
            }
            firstCreatableIndex = baseComponents.count
            expectedOwner = 0
        }

        var currentFD = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard currentFD >= 0 else { throw posixError("open", path: "/") }
        var traversed = ""

        do {
            for (index, component) in components.enumerated() {
                let parentPath = traversed.isEmpty ? "/" : traversed
                traversed += "/" + component
                var created = false
                var nextFD = component.withCString { pointer in
                    Darwin.openat(
                        currentFD,
                        pointer,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                if nextFD < 0, errno == ENOENT, createIfMissing,
                   index >= firstCreatableIndex {
                    let createStatus = component.withCString { pointer in
                        Darwin.mkdirat(currentFD, pointer, mode_t(S_IRWXU))
                    }
                    if createStatus != 0, errno != EEXIST {
                        throw posixError("mkdirat", path: traversed)
                    }
                    created = createStatus == 0
                    nextFD = component.withCString { pointer in
                        Darwin.openat(
                            currentFD,
                            pointer,
                            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                        )
                    }
                }
                guard nextFD >= 0 else {
                    throw posixError("openat", path: traversed)
                }

                do {
                    if created {
                        try hardenQuarantineDirectory(nextFD, path: traversed)
                    }
                    if index >= firstCreatableIndex {
                        _ = try validatePrivateDirectoryDescriptor(
                            nextFD,
                            expectedOwner: expectedOwner,
                            expectedDevice: nil,
                            displayPath: traversed
                        )
                    } else {
                        let ancestor = try descriptorIdentity(nextFD, displayPath: traversed)
                        let allowedOwner = isOverride
                            ? ancestor.owner == 0 || ancestor.owner == UInt32(expectedOwner)
                            : ancestor.owner == 0
                        guard ancestor.isDirectory, allowedOwner else {
                            throw SecureDeletionError.quarantineRecoveryFailed(traversed)
                        }
                    }
                    if created {
                        try synchronizeDirectory(nextFD, displayPath: traversed)
                        try synchronizeDirectory(currentFD, displayPath: parentPath)
                    }
                } catch {
                    Darwin.close(nextFD)
                    throw error
                }

                Darwin.close(currentFD)
                currentFD = nextFD
            }

            let identity = try validatePrivateDirectoryDescriptor(
                currentFD,
                expectedOwner: expectedOwner,
                expectedDevice: nil,
                displayPath: path
            )
            return PrivilegedStagingRoot(
                descriptor: currentFD,
                path: path,
                identity: identity,
                expectedOwner: expectedOwner
            )
        } catch {
            Darwin.close(currentFD)
            throw error
        }
    }

    private func quarantineDirectoryName(
        transactionID: UUID,
        userID: uid_t
    ) -> String {
        "\(PrivilegedCleaningConstants.quarantineDirectoryPrefix)\(userID)-\(transactionID.uuidString)"
    }

    private func parseQuarantineDirectoryName(
        _ name: String
    ) -> (userID: uid_t, transactionID: UUID)? {
        let prefix = PrivilegedCleaningConstants.quarantineDirectoryPrefix
        guard name.hasPrefix(prefix) else { return nil }
        let suffix = name.dropFirst(prefix.count)
        guard let separator = suffix.firstIndex(of: "-") else { return nil }
        let userPart = suffix[..<separator]
        let uuidPart = suffix[suffix.index(after: separator)...]
        guard let userValue = UInt32(userPart),
              let transactionID = UUID(uuidString: String(uuidPart))
        else {
            return nil
        }
        let userID = uid_t(userValue)
        guard quarantineDirectoryName(
            transactionID: transactionID,
            userID: userID
        ) == name else {
            return nil
        }
        return (userID, transactionID)
    }

    private func validateRecoveredJournal(
        _ journal: PrivilegedQuarantineJournal,
        transactionID: UUID,
        stagingDevice: UInt64,
        displayPath: String
    ) throws {
        guard journal.formatVersion == PrivilegedQuarantineJournal.formatVersion,
              journal.protocolVersion == PrivilegedCleaningConstants.protocolVersion,
              journal.securityPolicyVersion == PrivilegedCleaningConstants.securityPolicyVersion,
              journal.transactionID == transactionID,
              journal.initiatingUserID == UInt32(policy.userID),
              journal.boundaryDevice == stagingDevice,
              journal.request.identity.device == stagingDevice,
              journal.request.identity.isSupportedType,
              journal.sourceParentIdentity.isDirectory,
              journal.sourceParentIdentity.device == stagingDevice,
              !journal.sourceName.isEmpty,
              !journal.sourceName.contains("/"),
              journal.sourceName != ".",
              journal.sourceName != ".."
        else {
            throw SecureDeletionError.quarantineRecoveryFailed(displayPath)
        }

        guard let validated = try? policy.validatedRequest(journal.request),
              validated.path == journal.request.path,
              validated.boundaryPath == journal.boundaryPath,
              (validated.path as NSString).lastPathComponent == journal.sourceName,
              (validated.path as NSString).deletingLastPathComponent == journal.sourceParentPath
        else {
            throw SecureDeletionError.quarantineRecoveryFailed(displayPath)
        }
    }

    private func openRecoverySourceParent(
        _ journal: PrivilegedQuarantineJournal
    ) throws -> Int32 {
        let components = journal.sourceParentPath.split(separator: "/").map(String.init)
        var parentFD = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parentFD >= 0 else { throw posixError("open", path: "/") }
        var traversed = ""

        do {
            for component in components {
                traversed += "/" + component
                let nextFD = component.withCString { pointer in
                    Darwin.openat(
                        parentFD,
                        pointer,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                guard nextFD >= 0 else {
                    throw SecureDeletionError.quarantineRecoveryFailed(
                        journal.request.path
                    )
                }
                do {
                    let identity = try validateDirectoryDescriptor(nextFD, path: traversed)
                    if traversed == journal.boundaryPath
                        || traversed.hasPrefix(journal.boundaryPath + "/") {
                        guard identity.device == journal.boundaryDevice else {
                            throw SecureDeletionError.quarantineRecoveryFailed(
                                journal.request.path
                            )
                        }
                    }
                } catch {
                    Darwin.close(nextFD)
                    throw error
                }
                Darwin.close(parentFD)
                parentFD = nextFD
            }

            let observed = try descriptorIdentity(
                parentFD,
                displayPath: journal.sourceParentPath
            )
            guard observed == journal.sourceParentIdentity else {
                throw SecureDeletionError.quarantineRecoveryFailed(journal.request.path)
            }
            return parentFD
        } catch {
            Darwin.close(parentFD)
            throw error
        }
    }

    private func validateTransactionEntrySet(
        quarantineFD: Int32,
        displayPath: String,
        journalRequired: Bool
    ) throws {
        let entries = try directoryEntryNames(
            directoryFD: quarantineFD,
            displayPath: displayPath,
            maximumCount: maximumEntries
        )
        let hasJournal = entries.contains(PrivilegedQuarantineJournal.fileName)
        guard hasJournal == journalRequired else {
            throw SecureDeletionError.quarantineRecoveryFailed(displayPath)
        }
        if !journalRequired, entries.contains("item") {
            throw SecureDeletionError.quarantineRecoveryFailed(displayPath)
        }

        let quarantineIdentity = try descriptorIdentity(
            quarantineFD,
            displayPath: displayPath
        )
        for entry in entries {
            if entry == "item" { continue }
            guard entry == PrivilegedQuarantineJournal.fileName
                    || entry.hasPrefix(PrivilegedQuarantineJournal.temporaryFilePrefix)
            else {
                throw SecureDeletionError.quarantineRecoveryFailed(displayPath)
            }
            try validateMetadataFile(
                parentFD: quarantineFD,
                name: entry,
                expectedOwner: uid_t(quarantineIdentity.owner),
                expectedDevice: quarantineIdentity.device,
                displayPath: displayPath
            )
        }
    }

    private func cleanupQuarantineTransaction(
        stagingRootFD: Int32,
        stagingRootPath: String,
        quarantineFD: Int32,
        quarantineName: String,
        quarantineIdentity: FileIdentity,
        expectedOwner: uid_t,
        displayPath: String
    ) throws {
        let entries = try directoryEntryNames(
            directoryFD: quarantineFD,
            displayPath: displayPath,
            maximumCount: maximumEntries
        )
        guard !entries.contains("item") else {
            throw SecureDeletionError.quarantineRecoveryFailed(displayPath)
        }
        for entry in entries where entry != PrivilegedQuarantineJournal.fileName {
            guard entry.hasPrefix(PrivilegedQuarantineJournal.temporaryFilePrefix) else {
                throw SecureDeletionError.quarantineRecoveryFailed(displayPath)
            }
            try unlinkMetadataFile(
                parentFD: quarantineFD,
                name: entry,
                expectedOwner: expectedOwner,
                expectedDevice: quarantineIdentity.device,
                displayPath: displayPath
            )
        }
        if entries.contains(PrivilegedQuarantineJournal.fileName) {
            try unlinkMetadataFile(
                parentFD: quarantineFD,
                name: PrivilegedQuarantineJournal.fileName,
                expectedOwner: expectedOwner,
                expectedDevice: quarantineIdentity.device,
                displayPath: displayPath
            )
        }
        try synchronizeDirectory(quarantineFD, displayPath: displayPath)
        let remaining = try directoryEntryNames(
            directoryFD: quarantineFD,
            displayPath: displayPath,
            maximumCount: 1
        )
        guard remaining.isEmpty else {
            throw SecureDeletionError.quarantineRecoveryFailed(displayPath)
        }
        try verifyNamedIdentity(
            parentFD: stagingRootFD,
            name: quarantineName,
            displayPath: displayPath,
            expectedIdentity: quarantineIdentity
        )
        let removeStatus = quarantineName.withCString { pointer in
            Darwin.unlinkat(stagingRootFD, pointer, AT_REMOVEDIR)
        }
        guard removeStatus == 0 else {
            throw posixError("unlinkat", path: displayPath)
        }
        try synchronizeDirectory(stagingRootFD, displayPath: stagingRootPath)
    }

    private func validateMetadataFile(
        parentFD: Int32,
        name: String,
        expectedOwner: uid_t,
        expectedDevice: UInt64,
        displayPath: String
    ) throws {
        var info = stat()
        let status = name.withCString { pointer in
            Darwin.fstatat(parentFD, pointer, &info, AT_SYMLINK_NOFOLLOW)
        }
        guard status == 0 else { throw posixError("fstatat", path: displayPath) }
        let identity = FileIdentity(stat: info)
        guard identity.isRegularFile,
              identity.owner == UInt32(expectedOwner),
              identity.device == expectedDevice,
              info.st_nlink == 1,
              (info.st_mode & mode_t(0o777)) == mode_t(0o600)
        else {
            throw SecureDeletionError.quarantineRecoveryFailed(displayPath)
        }
    }

    private func unlinkMetadataFile(
        parentFD: Int32,
        name: String,
        expectedOwner: uid_t,
        expectedDevice: UInt64,
        displayPath: String
    ) throws {
        try validateMetadataFile(
            parentFD: parentFD,
            name: name,
            expectedOwner: expectedOwner,
            expectedDevice: expectedDevice,
            displayPath: displayPath
        )
        let status = name.withCString { pointer in
            Darwin.unlinkat(parentFD, pointer, 0)
        }
        guard status == 0 else { throw posixError("unlinkat", path: displayPath) }
    }

    func remove(_ request: PrivilegedDeletionRequest) throws {
        if case .privilegedQuarantine = isolation {
            // No new namespace mutation is admitted while a durable prior
            // transaction for this uid remains unresolved.
            try recoverPendingQuarantines()
        }
        try cancellationCheck?()
        let validated = try policy.validatedRequest(request)
        let path = validated.path
        let components = path.split(separator: "/").map(String.init)
        guard let leafName = components.last else {
            throw SecureDeletionError.invalidPath(path)
        }

        var parentFD = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parentFD >= 0 else {
            throw posixError("open", path: "/")
        }
        defer { Darwin.close(parentFD) }

        var boundaryDevice: UInt64?
        var traversed = ""

        for component in components.dropLast() {
            try cancellationCheck?()
            traversed += "/" + component
            let nextFD = component.withCString { pointer in
                Darwin.openat(parentFD, pointer, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard nextFD >= 0 else {
                if errno == ENOENT {
                    // No mutation has begun yet. If an ancestor disappeared,
                    // the exact scanned object is unreachable and therefore
                    // already gone just like a missing final component.
                    throw SecureDeletionError.topLevelMissing(path)
                }
                throw posixError("openat", path: traversed)
            }

            do {
                let identity = try validateDirectoryDescriptor(nextFD, path: traversed)
                if traversed == validated.boundaryPath {
                    boundaryDevice = identity.device
                } else if let boundaryDevice, identity.device != boundaryDevice {
                    throw SecureDeletionError.crossedDeviceBoundary(traversed)
                }
            } catch {
                Darwin.close(nextFD)
                throw error
            }
            Darwin.close(parentFD)
            parentFD = nextFD
        }

        let observed: FileIdentity
        do {
            observed = try identityAt(parentFD: parentFD, name: leafName, displayPath: path)
        } catch let SecureDeletionError.posix(_, _, code) where code == ENOENT {
            // Absence during the initial descriptor walk is an "already gone"
            // result. Nested races after mutation begins are handled inside
            // the recursive walker and never promote the whole request.
            throw SecureDeletionError.topLevelMissing(path)
        }

        if path == validated.boundaryPath {
            boundaryDevice = observed.device
        }
        guard let boundaryDevice else {
            throw SecureDeletionError.outsideAllowlist(path)
        }
        guard observed.device == boundaryDevice else {
            throw SecureDeletionError.crossedDeviceBoundary(path)
        }

        var remainingEntries = maximumEntries
        switch isolation {
        case .direct:
            try removeEntry(
                parentFD: parentFD,
                name: leafName,
                displayPath: path,
                expectedIdentity: request.identity,
                observedIdentity: observed,
                boundaryDevice: boundaryDevice,
                depth: 0,
                remainingEntries: &remainingEntries
            )
        case .privilegedQuarantine:
            try removeViaQuarantine(
                sourceParentFD: parentFD,
                sourceName: leafName,
                displayPath: path,
                request: request,
                validated: validated,
                initiallyObservedIdentity: observed,
                boundaryDevice: boundaryDevice,
                remainingEntries: &remainingEntries
            )
        }
    }

    private func removeViaQuarantine(
        sourceParentFD: Int32,
        sourceName: String,
        displayPath: String,
        request: PrivilegedDeletionRequest,
        validated: SecureDeletionPolicy.ValidatedRequest,
        initiallyObservedIdentity: FileIdentity,
        boundaryDevice: UInt64,
        remainingEntries: inout Int
    ) throws {
        let expectedIdentity = request.identity
        guard initiallyObservedIdentity == expectedIdentity else {
            throw SecureDeletionError.identityChanged(displayPath)
        }

        let sourceParentPath = (displayPath as NSString).deletingLastPathComponent
        let sourceParentIdentity = try descriptorIdentity(
            sourceParentFD,
            displayPath: sourceParentPath
        )
        guard sourceParentIdentity.isDirectory,
              sourceParentIdentity.device == boundaryDevice
        else {
            throw SecureDeletionError.identityChanged(displayPath)
        }

        let stagingRoot = try openPrivilegedStagingRoot(createIfMissing: true)
        defer { Darwin.close(stagingRoot.descriptor) }
        guard stagingRoot.identity.device == boundaryDevice else {
            throw SecureDeletionError.crossedDeviceBoundary(displayPath)
        }

        let transactionID = UUID()
        let quarantine = try createQuarantineDirectory(
            parentFD: stagingRoot.descriptor,
            transactionID: transactionID,
            expectedOwner: stagingRoot.expectedOwner,
            boundaryDevice: boundaryDevice,
            displayPath: displayPath
        )
        defer { Darwin.close(quarantine.descriptor) }
        do {
            try synchronizeDirectory(stagingRoot.descriptor, displayPath: stagingRoot.path)
        } catch let synchronizationError {
            do {
                try cleanupQuarantineTransaction(
                    stagingRootFD: stagingRoot.descriptor,
                    stagingRootPath: stagingRoot.path,
                    quarantineFD: quarantine.descriptor,
                    quarantineName: quarantine.name,
                    quarantineIdentity: quarantine.identity,
                    expectedOwner: stagingRoot.expectedOwner,
                    displayPath: displayPath
                )
            } catch {
                throw SecureDeletionError.quarantineRecoveryFailed(displayPath)
            }
            throw synchronizationError
        }

        let canonicalRequest = PrivilegedDeletionRequest(
            id: request.id,
            path: displayPath,
            identity: request.identity,
            operation: request.operation
        )
        let preparedJournal = PrivilegedQuarantineJournal(
            state: .prepared,
            transactionID: transactionID,
            operationID: privilegedOperationID ?? request.id,
            initiatingUserID: policy.userID,
            request: canonicalRequest,
            sourceParentPath: sourceParentPath,
            sourceParentIdentity: sourceParentIdentity,
            sourceName: sourceName,
            boundaryPath: validated.boundaryPath,
            boundaryDevice: boundaryDevice
        )
        do {
            try installQuarantineJournal(
                preparedJournal,
                quarantineFD: quarantine.descriptor,
                expectedOwner: stagingRoot.expectedOwner,
                boundaryDevice: boundaryDevice,
                replacingExisting: false,
                displayPath: displayPath
            )
        } catch let journalError {
            do {
                try cleanupQuarantineTransaction(
                    stagingRootFD: stagingRoot.descriptor,
                    stagingRootPath: stagingRoot.path,
                    quarantineFD: quarantine.descriptor,
                    quarantineName: quarantine.name,
                    quarantineIdentity: quarantine.identity,
                    expectedOwner: stagingRoot.expectedOwner,
                    displayPath: displayPath
                )
            } catch {
                throw SecureDeletionError.quarantineRecoveryFailed(displayPath)
            }
            throw journalError
        }

        let stagedName = "item"
        var didRename = false
        do {
            try beforeQuarantineRename?()
            // PREPARED is durable before the first namespace mutation.
            try cancellationCheck?()
            let renameStatus = sourceName.withCString { sourcePointer in
                stagedName.withCString { stagedPointer in
                    Darwin.renameatx_np(
                        sourceParentFD,
                        sourcePointer,
                        quarantine.descriptor,
                        stagedPointer,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            guard renameStatus == 0 else {
                if errno == ENOENT {
                    throw SecureDeletionError.identityChanged(displayPath)
                }
                throw posixError("renameatx_np", path: displayPath)
            }
            didRename = true
            try synchronizeDirectory(sourceParentFD, displayPath: sourceParentPath)
            try synchronizeDirectory(quarantine.descriptor, displayPath: displayPath)

            try afterQuarantineRename?()
            let stagedIdentity = try identityAt(
                parentFD: quarantine.descriptor,
                name: stagedName,
                displayPath: displayPath
            )
            guard stagedIdentity == expectedIdentity else {
                throw SecureDeletionError.identityChanged(displayPath)
            }
        } catch let preparationError {
            do {
                if didRename {
                    try restoreQuarantinedEntry(
                        quarantineFD: quarantine.descriptor,
                        stagedName: stagedName,
                        destinationParentFD: sourceParentFD,
                        destinationName: sourceName,
                        displayPath: displayPath
                    )
                    try synchronizeDirectory(sourceParentFD, displayPath: sourceParentPath)
                    try synchronizeDirectory(quarantine.descriptor, displayPath: displayPath)
                }
                try cleanupQuarantineTransaction(
                    stagingRootFD: stagingRoot.descriptor,
                    stagingRootPath: stagingRoot.path,
                    quarantineFD: quarantine.descriptor,
                    quarantineName: quarantine.name,
                    quarantineIdentity: quarantine.identity,
                    expectedOwner: stagingRoot.expectedOwner,
                    displayPath: displayPath
                )
            } catch {
                // Keep PREPARED and any staged entry intact when durable
                // restore/cleanup cannot be proven. The next recovery pass
                // must settle it before admitting another deletion.
                throw SecureDeletionError.quarantineRecoveryFailed(displayPath)
            }
            throw preparationError
        }

        // Atomically replacing the complete journal is the commit point. If
        // this transition reports an error, leave the transaction untouched:
        // recovery will observe either the complete PREPARED generation and
        // restore it, or the complete COMMITTED generation and finish it.
        let committedJournal = preparedJournal.changingState(to: .committed)
        do {
            try installQuarantineJournal(
                committedJournal,
                quarantineFD: quarantine.descriptor,
                expectedOwner: stagingRoot.expectedOwner,
                boundaryDevice: boundaryDevice,
                replacingExisting: true,
                displayPath: displayPath
            )
        } catch {
            throw SecureDeletionError.quarantineRecoveryFailed(displayPath)
        }

        do {
            let stagedIdentity = try identityAt(
                parentFD: quarantine.descriptor,
                name: stagedName,
                displayPath: displayPath
            )
            guard stagedIdentity == expectedIdentity else {
                throw SecureDeletionError.identityChanged(displayPath)
            }
            try removeEntry(
                parentFD: quarantine.descriptor,
                name: stagedName,
                displayPath: displayPath,
                expectedIdentity: expectedIdentity,
                observedIdentity: stagedIdentity,
                boundaryDevice: boundaryDevice,
                depth: 0,
                remainingEntries: &remainingEntries
            )
            try synchronizeDirectory(quarantine.descriptor, displayPath: displayPath)
            try cleanupQuarantineTransaction(
                stagingRootFD: stagingRoot.descriptor,
                stagingRootPath: stagingRoot.path,
                quarantineFD: quarantine.descriptor,
                quarantineName: quarantine.name,
                quarantineIdentity: quarantine.identity,
                expectedOwner: stagingRoot.expectedOwner,
                displayPath: displayPath
            )
        } catch {
            // A COMMITTED tree is never restored after recursive deletion may
            // have started. Its exact top-level identity and journal remain
            // available for descriptor-relative startup recovery.
            throw SecureDeletionError.quarantineRecoveryFailed(displayPath)
        }
    }

    private func createQuarantineDirectory(
        parentFD: Int32,
        transactionID: UUID,
        expectedOwner: uid_t,
        boundaryDevice: UInt64,
        displayPath: String
    ) throws -> (descriptor: Int32, name: String, identity: FileIdentity) {
        let name = quarantineDirectoryName(transactionID: transactionID, userID: policy.userID)
        let createStatus = name.withCString { pointer in
            Darwin.mkdirat(parentFD, pointer, mode_t(S_IRWXU))
        }
        guard createStatus == 0 else {
            throw posixError("mkdirat", path: displayPath)
        }

        let descriptor = name.withCString { pointer in
            Darwin.openat(parentFD, pointer, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw posixError("openat", path: displayPath)
        }

        var initialInfo = stat()
        guard Darwin.fstat(descriptor, &initialInfo) == 0 else {
            Darwin.close(descriptor)
            throw posixError("fstat", path: displayPath)
        }
        let initialIdentity = FileIdentity(stat: initialInfo)
        guard initialIdentity.isDirectory,
              initialIdentity.device == boundaryDevice,
              initialIdentity.owner == UInt32(expectedOwner)
        else {
            Darwin.close(descriptor)
            throw SecureDeletionError.identityChanged(displayPath)
        }

        do {
            try hardenQuarantineDirectory(descriptor, path: displayPath)
            let inheritedEntries = try directoryEntryNames(
                directoryFD: descriptor,
                displayPath: displayPath,
                maximumCount: 1
            )
            guard inheritedEntries.isEmpty else {
                throw SecureDeletionError.identityChanged(displayPath)
            }
        } catch {
            Darwin.close(descriptor)
            removeEmptyDirectoryIfIdentityMatches(
                parentFD: parentFD,
                name: name,
                expectedIdentity: initialIdentity,
                displayPath: displayPath
            )
            throw error
        }

        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0 else {
            Darwin.close(descriptor)
            name.withCString { pointer in
                _ = Darwin.unlinkat(parentFD, pointer, AT_REMOVEDIR)
            }
            throw posixError("fstat", path: displayPath)
        }
        let identity = FileIdentity(stat: info)
        let hasPrivateMode = (info.st_mode & mode_t(0o777)) == mode_t(0o700)
        guard identity == initialIdentity,
              identity.owner == UInt32(expectedOwner),
              hasPrivateMode
        else {
            Darwin.close(descriptor)
            removeEmptyDirectoryIfIdentityMatches(
                parentFD: parentFD,
                name: name,
                expectedIdentity: initialIdentity,
                displayPath: displayPath
            )
            throw SecureDeletionError.identityChanged(displayPath)
        }
        return (descriptor, name, identity)
    }

    private func hardenQuarantineDirectory(_ descriptor: Int32, path: String) throws {
        guard let fileSecurity = filesec_init() else {
            throw posixError("filesec_init", path: path)
        }
        defer { filesec_free(fileSecurity) }

        // `_FILESEC_REMOVE_ACL` is the sentinel pointer value 1 in Darwin's
        // fcntl.h, but that macro is not imported into Swift.
        let removeACL = UnsafeRawPointer(bitPattern: 1)
        guard filesec_set_property(fileSecurity, FILESEC_ACL, removeACL) == 0,
              Darwin.fchmodx_np(descriptor, fileSecurity) == 0
        else {
            throw posixError("fchmodx_np", path: path)
        }
        guard Darwin.fchmod(descriptor, mode_t(S_IRWXU)) == 0 else {
            throw posixError("fchmod", path: path)
        }

        errno = 0
        if let inheritedACL = Darwin.acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) {
            Darwin.acl_free(UnsafeMutableRawPointer(inheritedACL))
            throw SecureDeletionError.identityChanged(path)
        }
        guard errno == ENOENT || errno == EOPNOTSUPP else {
            throw posixError("acl_get_fd_np", path: path)
        }
    }

    private func installQuarantineJournal(
        _ journal: PrivilegedQuarantineJournal,
        quarantineFD: Int32,
        expectedOwner: uid_t,
        boundaryDevice: UInt64,
        replacingExisting: Bool,
        displayPath: String
    ) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let encoded = try encoder.encode(journal)
        guard !encoded.isEmpty,
              encoded.count <= PrivilegedQuarantineJournal.maximumEncodedSize
        else {
            throw SecureDeletionError.traversalLimitExceeded(displayPath)
        }

        if replacingExisting {
            let existing = try readQuarantineJournal(
                quarantineFD: quarantineFD,
                expectedOwner: expectedOwner,
                boundaryDevice: boundaryDevice,
                displayPath: displayPath
            )
            guard existing.state == .prepared,
                  existing.transactionID == journal.transactionID,
                  existing.request.id == journal.request.id,
                  journal.state == .committed
            else {
                throw SecureDeletionError.quarantineRecoveryFailed(displayPath)
            }
        }

        let temporaryName = "\(PrivilegedQuarantineJournal.temporaryFilePrefix)\(UUID().uuidString)"
        let descriptor = temporaryName.withCString { pointer in
            Darwin.openat(
                quarantineFD,
                pointer,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard descriptor >= 0 else {
            throw posixError("openat", path: displayPath)
        }
        var shouldRemove = true
        defer {
            Darwin.close(descriptor)
            if shouldRemove {
                temporaryName.withCString { pointer in
                    _ = Darwin.unlinkat(quarantineFD, pointer, 0)
                }
            }
        }

        guard Darwin.fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            throw posixError("fchmod", path: displayPath)
        }
        try writeAll(encoded, descriptor: descriptor, displayPath: displayPath)

        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0 else {
            throw posixError("fstat", path: displayPath)
        }
        let identity = FileIdentity(stat: info)
        guard identity.isRegularFile,
              identity.device == boundaryDevice,
              identity.owner == UInt32(expectedOwner),
              info.st_nlink == 1,
              (info.st_mode & mode_t(0o777)) == mode_t(0o600)
        else {
            throw SecureDeletionError.identityChanged(displayPath)
        }
        try validateNoExtendedACL(descriptor, displayPath: displayPath)
        try synchronizeFile(descriptor, displayPath: displayPath)

        let renameStatus: Int32
        if replacingExisting {
            renameStatus = temporaryName.withCString { temporaryPointer in
                PrivilegedQuarantineJournal.fileName.withCString { journalPointer in
                    Darwin.renameat(
                        quarantineFD,
                        temporaryPointer,
                        quarantineFD,
                        journalPointer
                    )
                }
            }
        } else {
            renameStatus = temporaryName.withCString { temporaryPointer in
                PrivilegedQuarantineJournal.fileName.withCString { journalPointer in
                    Darwin.renameatx_np(
                        quarantineFD,
                        temporaryPointer,
                        quarantineFD,
                        journalPointer,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
        }
        guard renameStatus == 0 else {
            throw posixError("renameat", path: displayPath)
        }

        shouldRemove = false
        try synchronizeDirectory(quarantineFD, displayPath: displayPath)

        let installed = try readQuarantineJournal(
            quarantineFD: quarantineFD,
            expectedOwner: expectedOwner,
            boundaryDevice: boundaryDevice,
            displayPath: displayPath
        )
        guard installed.transactionID == journal.transactionID,
              installed.state == journal.state,
              installed.request.id == journal.request.id
        else {
            throw SecureDeletionError.quarantineRecoveryFailed(displayPath)
        }
    }

    private func readQuarantineJournal(
        quarantineFD: Int32,
        expectedOwner: uid_t,
        boundaryDevice: UInt64,
        displayPath: String
    ) throws -> PrivilegedQuarantineJournal {
        let descriptor = PrivilegedQuarantineJournal.fileName.withCString { pointer in
            Darwin.openat(
                quarantineFD,
                pointer,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
            )
        }
        guard descriptor >= 0 else { throw posixError("openat", path: displayPath) }
        defer { Darwin.close(descriptor) }

        var initialInfo = stat()
        guard Darwin.fstat(descriptor, &initialInfo) == 0 else {
            throw posixError("fstat", path: displayPath)
        }
        let initialIdentity = FileIdentity(stat: initialInfo)
        guard initialIdentity.isRegularFile,
              initialIdentity.device == boundaryDevice,
              initialIdentity.owner == UInt32(expectedOwner),
              initialInfo.st_nlink == 1,
              (initialInfo.st_mode & mode_t(0o777)) == mode_t(0o600),
              initialInfo.st_size > 0,
              initialInfo.st_size <= off_t(PrivilegedQuarantineJournal.maximumEncodedSize)
        else {
            throw SecureDeletionError.quarantineRecoveryFailed(displayPath)
        }
        try validateNoExtendedACL(descriptor, displayPath: displayPath)

        let byteCount = Int(initialInfo.st_size)
        var encoded = Data(count: byteCount)
        try encoded.withUnsafeMutableBytes { (rawBuffer: UnsafeMutableRawBufferPointer) in
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
                    throw posixError("pread", path: displayPath)
                }
                guard count > 0 else {
                    throw SecureDeletionError.quarantineRecoveryFailed(displayPath)
                }
                offset += count
            }
        }

        var finalInfo = stat()
        guard Darwin.fstat(descriptor, &finalInfo) == 0 else {
            throw posixError("fstat", path: displayPath)
        }
        guard FileIdentity(stat: finalInfo) == initialIdentity,
              finalInfo.st_size == initialInfo.st_size,
              finalInfo.st_nlink == 1
        else {
            throw SecureDeletionError.quarantineRecoveryFailed(displayPath)
        }
        return try PropertyListDecoder().decode(
            PrivilegedQuarantineJournal.self,
            from: encoded
        )
    }

    private func writeAll(
        _ data: Data,
        descriptor: Int32,
        displayPath: String
    ) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if written < 0 {
                    if errno == EINTR { continue }
                    throw posixError("write", path: displayPath)
                }
                guard written > 0 else {
                    throw SecureDeletionError.posix(
                        operation: "write",
                        path: displayPath,
                        code: EIO
                    )
                }
                offset += written
            }
        }
    }

    private func synchronizeFile(_ descriptor: Int32, displayPath: String) throws {
        guard Darwin.fsync(descriptor) == 0 else {
            throw posixError("fsync", path: displayPath)
        }
        guard Darwin.fcntl(descriptor, F_FULLFSYNC) == 0 else {
            throw posixError("F_FULLFSYNC", path: displayPath)
        }
    }

    private func synchronizeDirectory(_ descriptor: Int32, displayPath: String) throws {
        guard Darwin.fsync(descriptor) == 0 else {
            throw posixError("fsync", path: displayPath)
        }
        guard Darwin.fcntl(descriptor, F_FULLFSYNC) == 0 else {
            throw posixError("F_FULLFSYNC", path: displayPath)
        }
    }

    private func descriptorIdentity(
        _ descriptor: Int32,
        displayPath: String
    ) throws -> FileIdentity {
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0 else {
            throw posixError("fstat", path: displayPath)
        }
        return FileIdentity(stat: info)
    }

    private func validatePrivateDirectoryDescriptor(
        _ descriptor: Int32,
        expectedOwner: uid_t,
        expectedDevice: UInt64?,
        displayPath: String
    ) throws -> FileIdentity {
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0 else {
            throw posixError("fstat", path: displayPath)
        }
        let identity = FileIdentity(stat: info)
        guard identity.isDirectory,
              identity.owner == UInt32(expectedOwner),
              expectedDevice == nil || identity.device == expectedDevice,
              (info.st_mode & mode_t(0o777)) == mode_t(0o700)
        else {
            throw SecureDeletionError.quarantineRecoveryFailed(displayPath)
        }
        try validateNoExtendedACL(descriptor, displayPath: displayPath)
        return identity
    }

    private func validateNoExtendedACL(
        _ descriptor: Int32,
        displayPath: String
    ) throws {
        errno = 0
        if let accessControlList = Darwin.acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) {
            Darwin.acl_free(UnsafeMutableRawPointer(accessControlList))
            throw SecureDeletionError.quarantineRecoveryFailed(displayPath)
        }
        guard errno == ENOENT || errno == EOPNOTSUPP else {
            throw posixError("acl_get_fd_np", path: displayPath)
        }
    }

    private func optionalIdentityAt(
        parentFD: Int32,
        name: String,
        displayPath: String
    ) throws -> FileIdentity? {
        do {
            return try identityAt(
                parentFD: parentFD,
                name: name,
                displayPath: displayPath
            )
        } catch let SecureDeletionError.posix(_, _, code) where code == ENOENT {
            return nil
        }
    }

    private func removeFileIfIdentityMatches(
        parentFD: Int32,
        name: String,
        expectedIdentity: FileIdentity,
        displayPath: String
    ) {
        guard let observed = try? identityAt(
            parentFD: parentFD,
            name: name,
            displayPath: displayPath
        ), observed == expectedIdentity, observed.isRegularFile
        else {
            return
        }
        name.withCString { pointer in
            _ = Darwin.unlinkat(parentFD, pointer, 0)
        }
    }

    private func removeEmptyDirectoryIfIdentityMatches(
        parentFD: Int32,
        name: String,
        expectedIdentity: FileIdentity,
        displayPath: String
    ) {
        guard let observed = try? identityAt(
            parentFD: parentFD,
            name: name,
            displayPath: displayPath
        ), observed == expectedIdentity, observed.isDirectory
        else {
            return
        }
        name.withCString { pointer in
            _ = Darwin.unlinkat(parentFD, pointer, AT_REMOVEDIR)
        }
    }

    private func restoreQuarantinedEntry(
        quarantineFD: Int32,
        stagedName: String,
        destinationParentFD: Int32,
        destinationName: String,
        displayPath: String
    ) throws {
        for _ in 0..<4 {
            let restoreStatus = stagedName.withCString { stagedPointer in
                destinationName.withCString { destinationPointer in
                    Darwin.renameatx_np(
                        quarantineFD,
                        stagedPointer,
                        destinationParentFD,
                        destinationPointer,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            if restoreStatus == 0 { return }

            if errno == ENOENT { continue }
            guard errno == EEXIST else {
                throw SecureDeletionError.quarantineRecoveryFailed(displayPath)
            }

            // Preserve both entries if something raced into the original
            // name. Swap atomically, then give the interfering entry a fresh
            // recovery name instead of deleting or overwriting it.
            let swapStatus = stagedName.withCString { stagedPointer in
                destinationName.withCString { destinationPointer in
                    Darwin.renameatx_np(
                        quarantineFD,
                        stagedPointer,
                        destinationParentFD,
                        destinationPointer,
                        UInt32(RENAME_SWAP)
                    )
                }
            }
            if swapStatus != 0 {
                if errno == ENOENT { continue }
                throw SecureDeletionError.quarantineRecoveryFailed(displayPath)
            }

            for _ in 0..<8 {
                let recoveryName = ".puremac-recovered-\(UUID().uuidString)"
                let recoveryStatus = stagedName.withCString { stagedPointer in
                    recoveryName.withCString { recoveryPointer in
                        Darwin.renameatx_np(
                            quarantineFD,
                            stagedPointer,
                            destinationParentFD,
                            recoveryPointer,
                            UInt32(RENAME_EXCL)
                        )
                    }
                }
                if recoveryStatus == 0 { return }
                if errno != EEXIST {
                    throw SecureDeletionError.quarantineRecoveryFailed(displayPath)
                }
            }
            throw SecureDeletionError.quarantineRecoveryFailed(displayPath)
        }
        throw SecureDeletionError.quarantineRecoveryFailed(displayPath)
    }

    private func removeEntry(
        parentFD: Int32,
        name: String,
        displayPath: String,
        expectedIdentity: FileIdentity,
        observedIdentity: FileIdentity,
        boundaryDevice: UInt64,
        depth: Int,
        remainingEntries: inout Int
    ) throws {
        try cancellationCheck?()
        guard depth <= maximumDepth, remainingEntries > 0 else {
            throw SecureDeletionError.traversalLimitExceeded(displayPath)
        }
        remainingEntries -= 1

        guard observedIdentity == expectedIdentity else {
            throw SecureDeletionError.identityChanged(displayPath)
        }
        guard observedIdentity.device == boundaryDevice else {
            throw SecureDeletionError.crossedDeviceBoundary(displayPath)
        }
        try validateOwnerAndType(observedIdentity, path: displayPath)

        if observedIdentity.isDirectory {
            let directoryFD = name.withCString { pointer in
                Darwin.openat(parentFD, pointer, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard directoryFD >= 0 else {
                throw posixError("openat", path: displayPath)
            }
            defer { Darwin.close(directoryFD) }

            var openedInfo = stat()
            guard Darwin.fstat(directoryFD, &openedInfo) == 0 else {
                throw posixError("fstat", path: displayPath)
            }
            guard FileIdentity(stat: openedInfo) == observedIdentity else {
                throw SecureDeletionError.identityChanged(displayPath)
            }

            while true {
                try removeDirectoryContents(
                    directoryFD: directoryFD,
                    displayPath: displayPath,
                    boundaryDevice: boundaryDevice,
                    depth: depth,
                    remainingEntries: &remainingEntries
                )
                try verifyNamedIdentity(
                    parentFD: parentFD,
                    name: name,
                    displayPath: displayPath,
                    expectedIdentity: observedIdentity
                )
                try beforeDirectoryUnlink?(displayPath)

                let status = name.withCString { pointer in
                    Darwin.unlinkat(parentFD, pointer, AT_REMOVEDIR)
                }
                if status == 0 { return }
                if errno != ENOTEMPTY {
                    throw posixError("unlinkat", path: displayPath)
                }
            }
        }

        try verifyNamedIdentity(
            parentFD: parentFD,
            name: name,
            displayPath: displayPath,
            expectedIdentity: observedIdentity
        )
        let status = name.withCString { pointer in
            Darwin.unlinkat(parentFD, pointer, 0)
        }
        guard status == 0 else {
            throw posixError("unlinkat", path: displayPath)
        }
    }

    private func removeDirectoryContents(
        directoryFD: Int32,
        displayPath: String,
        boundaryDevice: UInt64,
        depth: Int,
        remainingEntries: inout Int
    ) throws {
        while true {
            try cancellationCheck?()
            let names = try directoryEntryNames(
                directoryFD: directoryFD,
                displayPath: displayPath,
                maximumCount: remainingEntries
            )
            if names.isEmpty { return }

            for name in names {
                try cancellationCheck?()
                let childPath = displayPath + "/" + name
                do {
                    let childIdentity = try identityAt(
                        parentFD: directoryFD,
                        name: name,
                        displayPath: childPath
                    )
                    guard childIdentity.device == boundaryDevice else {
                        throw SecureDeletionError.crossedDeviceBoundary(childPath)
                    }
                    try validateOwnerAndType(childIdentity, path: childPath)
                    try removeEntry(
                        parentFD: directoryFD,
                        name: name,
                        displayPath: childPath,
                        expectedIdentity: childIdentity,
                        observedIdentity: childIdentity,
                        boundaryDevice: boundaryDevice,
                        depth: depth + 1,
                        remainingEntries: &remainingEntries
                    )
                } catch let SecureDeletionError.posix(_, _, code) where code == ENOENT {
                    // A child can disappear concurrently. It no longer resides
                    // in the selected tree, so continue; only the top-level
                    // initial lookup may produce the public `missing` status.
                    continue
                }
            }
        }
    }

    private func directoryEntryNames(
        directoryFD: Int32,
        displayPath: String,
        maximumCount: Int
    ) throws -> [String] {
        // `dup` would share the directory offset with the original open file
        // description. A second pass after ENOTEMPTY could then stay at EOF
        // forever while a concurrently added entry remains. Opening `.`
        // creates an independent description whose offset starts at zero.
        let iterationFD = Darwin.openat(
            directoryFD,
            ".",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard iterationFD >= 0 else {
            throw posixError("openat", path: displayPath)
        }
        guard let directory = Darwin.fdopendir(iterationFD) else {
            Darwin.close(iterationFD)
            throw posixError("fdopendir", path: displayPath)
        }
        defer { Darwin.closedir(directory) }

        var names: [String] = []
        while true {
            errno = 0
            guard let entry = Darwin.readdir(directory) else {
                if errno != 0 { throw posixError("readdir", path: displayPath) }
                return names
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer -> String? in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(validatingUTF8: $0)
                }
            }
            guard let name else {
                throw SecureDeletionError.invalidPath(displayPath + "/<non-UTF8 entry>")
            }
            if name == "." || name == ".." { continue }
            guard names.count < maximumCount else {
                throw SecureDeletionError.traversalLimitExceeded(displayPath)
            }
            names.append(name)
        }
    }

    private func identityAt(parentFD: Int32, name: String, displayPath: String) throws -> FileIdentity {
        var info = stat()
        let status = name.withCString { pointer in
            Darwin.fstatat(parentFD, pointer, &info, AT_SYMLINK_NOFOLLOW)
        }
        guard status == 0 else {
            throw posixError("fstatat", path: displayPath)
        }
        return FileIdentity(stat: info)
    }

    private func verifyNamedIdentity(
        parentFD: Int32,
        name: String,
        displayPath: String,
        expectedIdentity: FileIdentity
    ) throws {
        let observed = try identityAt(parentFD: parentFD, name: name, displayPath: displayPath)
        guard observed == expectedIdentity else {
            throw SecureDeletionError.identityChanged(displayPath)
        }
    }

    private func validateDirectoryDescriptor(_ descriptor: Int32, path: String) throws -> FileIdentity {
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0 else {
            throw posixError("fstat", path: path)
        }
        let identity = FileIdentity(stat: info)
        guard identity.isDirectory else {
            throw SecureDeletionError.unsupportedType(path)
        }
        guard identity.owner == UInt32(policy.userID) || identity.owner == 0 else {
            throw SecureDeletionError.ownerMismatch(path: path, owner: uid_t(identity.owner))
        }
        return identity
    }

    private func validateOwnerAndType(_ identity: FileIdentity, path: String) throws {
        guard identity.isSupportedType else {
            throw SecureDeletionError.unsupportedType(path)
        }
        guard identity.owner == UInt32(policy.userID) || identity.owner == 0 else {
            throw SecureDeletionError.ownerMismatch(path: path, owner: uid_t(identity.owner))
        }
    }

    private func posixError(_ operation: String, path: String) -> SecureDeletionError {
        SecureDeletionError.posix(operation: operation, path: path, code: errno)
    }
}
