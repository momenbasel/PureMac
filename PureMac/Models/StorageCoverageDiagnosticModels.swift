import Foundation

/// Why a storage measurement or coverage statement is incomplete.
///
/// These values describe observation quality only. They never imply that an
/// item is junk or eligible for a filesystem mutation.
enum StorageCoverageDiagnosticCategory: String, Codable, CaseIterable, Sendable {
    case permissionDenied
    case inaccessible
    case enumerationFailure
    case metadataFailure
    case differentVolumeBoundary
    case cancelled
    case missingOptionalRoot
    case failedAnalyzer
    case uncoveredFilesystemRegion
    case nonAdditiveAPFSStorage
    case possibleSharedExtentAccounting
    case concurrentFilesystemChange
    case unknown
}

enum StorageCoverageDiagnosticSeverity: String, Codable, Sendable {
    case informational
    case warning
}

enum StorageCoverageDiagnosticSource: Hashable, Codable, Sendable {
    case analyzer(StorageAnalyzerStage)
    case canonicalRoot(StorageCanonicalRoot)
    case coverageDiscovery
    case reconciliation
    case apfs

    var identifier: String {
        switch self {
        case let .analyzer(stage): return "analyzer:\(stage.rawValue)"
        case let .canonicalRoot(root): return "root:\(root.rawValue)"
        case .coverageDiscovery: return "coverage-discovery"
        case .reconciliation: return "reconciliation"
        case .apfs: return "apfs"
        }
    }
}

/// Semantic measurement confidence. Percentages are intentionally avoided
/// because the scanner does not know the size of unreadable or uncovered data.
enum StorageMeasurementConfidence: String, Codable, Sendable {
    case completeMeasurement
    case knownLowerBound
    case partialCoverage
    case nonAdditiveMetadata
    case unmeasured
}

struct StorageCoverageDiagnosticCategoryCount: Identifiable, Hashable, Codable, Sendable {
    let category: StorageCoverageDiagnosticCategory
    let count: Int

    var id: String { category.rawValue }
}

struct StorageCoverageDiagnosticAnalyzerCount: Identifiable, Hashable, Codable, Sendable {
    let analyzer: StorageAnalyzerStage
    let count: Int

    var id: String { analyzer.rawValue }
}

struct StorageCoverageDiagnosticRootCount: Identifiable, Hashable, Codable, Sendable {
    let root: StorageCanonicalRoot
    let configuredPath: String
    let count: Int

    var id: String { root.rawValue }
}

struct StorageCoverageDiagnosticErrnoCount: Identifiable, Hashable, Codable, Sendable {
    let errorCode: Int32
    let count: Int

    var id: Int32 { errorCode }
}

struct StorageCoverageDiagnosticParentCount: Identifiable, Hashable, Codable, Sendable {
    let parentPath: String
    let count: Int

    var id: String { parentPath }
}

/// A compact issue group. Only a bounded number of example paths are retained;
/// `count` still represents every unique issue occurrence in the group.
struct StorageCoverageDiagnosticIssueGroup: Identifiable, Hashable, Codable, Sendable {
    let category: StorageCoverageDiagnosticCategory
    let severity: StorageCoverageDiagnosticSeverity
    let source: StorageCoverageDiagnosticSource
    let contributingSources: [StorageCoverageDiagnosticSource]
    let canonicalRoot: StorageCanonicalRoot?
    let posixErrorCode: Int32?
    let count: Int
    let representativePaths: [String]
    let explanation: String

    var id: String {
        let root = canonicalRoot?.rawValue ?? "none"
        let errorCode = posixErrorCode.map(String.init) ?? "none"
        return "\(category.rawValue)|\(source.identifier)|\(root)|\(errorCode)"
    }

    init(
        category: StorageCoverageDiagnosticCategory,
        severity: StorageCoverageDiagnosticSeverity,
        source: StorageCoverageDiagnosticSource,
        contributingSources: [StorageCoverageDiagnosticSource]? = nil,
        canonicalRoot: StorageCanonicalRoot?,
        posixErrorCode: Int32?,
        count: Int,
        representativePaths: [String],
        explanation: String
    ) {
        self.category = category
        self.severity = severity
        self.source = source
        self.contributingSources = contributingSources ?? [source]
        self.canonicalRoot = canonicalRoot
        self.posixErrorCode = posixErrorCode
        self.count = count
        self.representativePaths = representativePaths
        self.explanation = explanation
    }
}

struct StorageCoverageIssueAggregation: Hashable, Codable, Sendable {
    let totalIssueCount: Int
    let categoryCounts: [StorageCoverageDiagnosticCategoryCount]
    let analyzerCounts: [StorageCoverageDiagnosticAnalyzerCount]
    let canonicalRootCounts: [StorageCoverageDiagnosticRootCount]
    let errnoCounts: [StorageCoverageDiagnosticErrnoCount]
    let topAffectedParentPaths: [StorageCoverageDiagnosticParentCount]
    let groups: [StorageCoverageDiagnosticIssueGroup]

    static let empty = StorageCoverageIssueAggregation(
        totalIssueCount: 0,
        categoryCounts: [],
        analyzerCounts: [],
        canonicalRootCounts: [],
        errnoCounts: [],
        topAffectedParentPaths: [],
        groups: []
    )
}

enum StorageCoverageGapKind: String, Codable, Sendable {
    case hiddenHomeEntry
    case unspecializedUserLibraryEntry
    case otherUsers
    case rootFilesystemRegion
    case inaccessibleSubtree
    case otherMountedVolume
}

enum StorageCoverageMapState: String, Codable, Sendable {
    case measured
    case partiallyMeasured
    case presentButUnmeasured
    case intentionallyUnmeasured
    case missingOptional
    case unavailable
    case nonAdditive
}

struct StorageCoverageGap: Identifiable, Hashable, Codable, Sendable {
    let kind: StorageCoverageGapKind
    let name: String
    let absolutePath: String?
    let category: StorageCoverageDiagnosticCategory
    let state: StorageCoverageMapState
    let confidence: StorageMeasurementConfidence
    let explanation: String

    var id: String {
        "\(kind.rawValue)|\(absolutePath.map { StoragePathNormalizer.normalize($0) } ?? name)"
    }
}

struct StorageCoverageMapEntry: Identifiable, Hashable, Codable, Sendable {
    let identifier: String
    let title: String
    let absolutePath: String?
    let source: StorageCoverageDiagnosticSource
    let state: StorageCoverageMapState
    let confidence: StorageMeasurementConfidence
    let explanation: String

    var id: String { identifier }
}

enum StorageAnalyzerDiagnosticState: String, Codable, Sendable {
    case complete
    case knownLowerBound
    case failed
    case cancelled
    case optionalRootMissing
    case nonAdditiveMetadata
}

struct StorageAnalyzerCoverageDiagnostic: Identifiable, Hashable, Codable, Sendable {
    let analyzer: StorageAnalyzerStage
    let state: StorageAnalyzerDiagnosticState
    let issueCount: Int
    let confidence: StorageMeasurementConfidence

    var id: String { analyzer.rawValue }
}

struct StorageCoverageExplanation: Identifiable, Hashable, Codable, Sendable {
    let category: StorageCoverageDiagnosticCategory
    let severity: StorageCoverageDiagnosticSeverity
    let title: String
    let detail: String

    var id: String { "\(category.rawValue)|\(title)" }
}

/// Shallow discovery output. Entries have no byte values because discovery
/// deliberately performs no recursive traversal or size calculation.
struct StorageCoverageDiscoveryResult: Hashable, Codable, Sendable {
    let homeDirectoryPath: String
    let hiddenHomeEntries: [StorageCoverageGap]
    let unspecializedLibraryEntries: [StorageCoverageGap]
    let issues: [StorageScanIssue]
    let wasCancelled: Bool

    static func empty(homeDirectoryPath: String) -> StorageCoverageDiscoveryResult {
        StorageCoverageDiscoveryResult(
            homeDirectoryPath: homeDirectoryPath,
            hiddenHomeEntries: [],
            unspecializedLibraryEntries: [],
            issues: [],
            wasCancelled: false
        )
    }
}

struct StorageCoverageDiagnostic: Hashable, Codable, Sendable {
    let measurementIssues: StorageCoverageIssueAggregation
    let coverageMap: [StorageCoverageMapEntry]
    let coverageGaps: [StorageCoverageGap]
    let analyzerStatuses: [StorageAnalyzerCoverageDiagnostic]
    let unexplainedSpaceExplanations: [StorageCoverageExplanation]
    let explainedStorageConfidence: StorageMeasurementConfidence
    let unexplainedStorageConfidence: StorageMeasurementConfidence
    let hiddenHomeEntryCount: Int
    let unspecializedLibraryEntryCount: Int

    var permissionDeniedIssueCount: Int {
        measurementIssues.categoryCounts.first {
            $0.category == .permissionDenied
        }?.count ?? 0
    }

    static let empty = StorageCoverageDiagnostic(
        measurementIssues: .empty,
        coverageMap: [],
        coverageGaps: [],
        analyzerStatuses: [],
        unexplainedSpaceExplanations: [],
        explainedStorageConfidence: .completeMeasurement,
        unexplainedStorageConfidence: .unmeasured,
        hiddenHomeEntryCount: 0,
        unspecializedLibraryEntryCount: 0
    )
}

extension StorageCanonicalRootCoverage {
    var measurementConfidence: StorageMeasurementConfidence {
        switch state {
        case .completed: return .completeMeasurement
        case .partiallyCompleted, .failed, .cancelled: return .knownLowerBound
        case .missingOptional: return .unmeasured
        }
    }
}
