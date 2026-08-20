import Foundation

/// The universal accounting rule between Docker's host files and runtime data.
/// Runtime categories must never be added to host bytes as Mac disk usage.
enum DockerAccountingRelationship: String, Codable, Sendable {
    case runtimeBreakdownIsNonAdditiveToHostFootprint
}

/// Where the Docker engine behind the inspected active context is running.
enum DockerRuntimeLocation: String, Codable, Sendable {
    case local
    case remote
    case unknown
}

/// Whether runtime accounting can help explain the local host-side Docker
/// footprint. Even for a local runtime, accounting remains non-additive.
enum DockerHostRuntimeRelationship: String, Codable, Sendable {
    case localRuntimeMayExplainHostFootprint
    case remoteRuntimeNotRelatedToHostFootprint
    case unknownRelationship
}

/// Sanitized metadata for the active Docker context. The endpoint never
/// retains user information, passwords, query parameters, or fragments.
struct DockerRuntimeContext: Hashable, Codable, Sendable {
    let name: String?
    let sanitizedEndpoint: String?
    let location: DockerRuntimeLocation

    static let unknown = DockerRuntimeContext(
        name: nil,
        sanitizedEndpoint: nil,
        location: .unknown
    )
}

enum DockerRuntimeStatus: String, Codable, Sendable {
    case notInstalled
    case installedDaemonUnavailable
    case installedAndReachable
    case commandFailed
    case partiallyReadable
    case cancelled
}

enum DockerRuntimeStorageCategory: String, Codable, CaseIterable, Sendable {
    case images
    case containers
    case localVolumes
    case buildCache
}

/// One category from Docker's read-only `system df` report.
struct DockerRuntimeStorageUsage: Hashable, Codable, Sendable {
    let category: DockerRuntimeStorageCategory
    let totalBytes: Int64?
    let reclaimableBytes: Int64?
    let reclaimablePercentage: Double?
    let objectCount: Int?
    let activeCount: Int?

    /// Docker local volumes commonly contain databases and other durable app
    /// state. Reclaimability does not change this application-data meaning.
    var isApplicationData: Bool { category == .localVolumes }
}

/// Docker's internal view of storage. These values explain runtime contents;
/// they are not additional host filesystem bytes.
struct DockerRuntimeAccounting: Hashable, Codable, Sendable {
    let images: DockerRuntimeStorageUsage?
    let containers: DockerRuntimeStorageUsage?
    let localVolumes: DockerRuntimeStorageUsage?
    let buildCache: DockerRuntimeStorageUsage?

    var categories: [DockerRuntimeStorageUsage] {
        [images, containers, localVolumes, buildCache].compactMap { $0 }
    }

    var totalRuntimeReportedBytes: Int64? {
        let values = categories.compactMap(\.totalBytes)
        return values.isEmpty ? nil : values.reduce(0, +)
    }

    var reclaimableBytes: Int64? {
        let values = categories.compactMap(\.reclaimableBytes)
        return values.isEmpty ? nil : values.reduce(0, +)
    }

    /// An aggregate percentage is only reported when all four categories
    /// supplied both total and reclaimable bytes.
    var reclaimablePercentage: Double? {
        guard isComplete,
              let totalRuntimeReportedBytes,
              let reclaimableBytes,
              totalRuntimeReportedBytes > 0 else {
            return nil
        }
        return Double(reclaimableBytes) / Double(totalRuntimeReportedBytes) * 100
    }

    var isComplete: Bool {
        let allCategories = [images, containers, localVolumes, buildCache]
        return allCategories.allSatisfy {
            $0?.totalBytes != nil && $0?.reclaimableBytes != nil
        }
    }
}

struct DockerHostFootprint: Hashable, Codable, Sendable {
    let locations: [StorageAnalysisResult]
    let logicalSize: Int64
    let allocatedSize: Int64
}

enum DockerVirtualDiskFormat: String, Codable, Sendable {
    case raw
    case img
    case qcow2
    case vmdk
    case sparseBundle
}

enum DockerSparseState: String, Codable, Sendable {
    case sparse
    case notSparse
    case unknown
}

/// A recognized Docker-side virtual disk backed by its original StorageNode.
/// Keeping the node avoids creating a second filesystem fact model.
struct DockerVirtualDisk: Hashable, Codable, Sendable {
    let storageNode: StorageNode
    let format: DockerVirtualDiskFormat
    let sparseState: DockerSparseState

    var absolutePath: String { storageNode.absolutePath }
    var logicalSize: Int64 { storageNode.logicalSize }
    var allocatedSize: Int64 { storageNode.allocatedSize }
    var accessibility: StorageAccessibility { storageNode.accessibility }
    var scanIssues: [StorageScanIssue] { storageNode.scanIssues }
}

enum DockerStorageIssueKind: String, Codable, Sendable {
    case filesystem
    case executableNotFound
    case contextInspectionFailed
    case runtimeLocationUnknown
    case daemonUnavailable
    case commandFailed
    case malformedRuntimeOutput
    case cancelled
}

struct DockerStorageIssue: Identifiable, Hashable, Codable, Sendable {
    var id: String { "\(kind.rawValue)|\(path ?? "")|\(message)" }

    let kind: DockerStorageIssueKind
    let message: String
    let path: String?
}

/// A read-only Docker storage report with intentionally separate host and
/// runtime perspectives.
struct DockerStorageReport: Hashable, Codable, Sendable {
    let hostFootprint: DockerHostFootprint
    let virtualDisks: [DockerVirtualDisk]
    let runtimeStatus: DockerRuntimeStatus
    let runtimeAccounting: DockerRuntimeAccounting?
    let dockerExecutablePath: String?
    let runtimeContext: DockerRuntimeContext
    let hostRuntimeRelationship: DockerHostRuntimeRelationship
    let accountingRelationship: DockerAccountingRelationship
    let wasCancelled: Bool
    let issues: [DockerStorageIssue]

    /// The only Docker value suitable for contribution to total Mac disk
    /// usage. Runtime-reported bytes are deliberately excluded.
    var macDiskUsageBytes: Int64 { hostFootprint.allocatedSize }

    var totalRuntimeReportedBytes: Int64? {
        runtimeAccounting?.totalRuntimeReportedBytes
    }

    var reclaimableBytes: Int64? {
        runtimeAccounting?.reclaimableBytes
    }
}
