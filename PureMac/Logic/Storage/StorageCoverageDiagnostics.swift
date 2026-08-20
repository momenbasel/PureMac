import Darwin
import Foundation

/// Performs only immediate-child metadata discovery. It never recurses and it
/// never calculates or assigns bytes to discovered coverage gaps.
struct StorageCoverageGapDiscovery: Sendable {
    private struct Child: Sendable {
        let name: String
        let path: String
        let isHidden: Bool
    }

    private struct DirectoryListing: Sendable {
        let children: [Child]
        let issue: StorageScanIssue?
        let wasCancelled: Bool
    }

    private static let specializedLibraryNames: Set<String> = [
        "Application Support",
        "Containers",
        "Group Containers",
    ]

    private let homeDirectoryURL: URL

    init(
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.homeDirectoryURL = homeDirectoryURL.standardizedFileURL
    }

    func discover() async -> StorageCoverageDiscoveryResult {
        let home = homeDirectoryURL
        let task = Task.detached(priority: .utility) {
            Self.discoverSynchronously(homeDirectoryURL: home)
        }
        return await withTaskCancellationHandler(operation: {
            await task.value
        }, onCancel: {
            task.cancel()
        })
    }

    static func discoverSynchronously(
        homeDirectoryURL: URL
    ) -> StorageCoverageDiscoveryResult {
        let home = homeDirectoryURL.standardizedFileURL
        let library = home.appendingPathComponent("Library", isDirectory: true)
        let homeListing = immediateChildren(at: home.path)

        if homeListing.wasCancelled {
            return StorageCoverageDiscoveryResult(
                homeDirectoryPath: home.path,
                hiddenHomeEntries: [],
                unspecializedLibraryEntries: [],
                issues: homeListing.issue.map { [$0] } ?? [],
                wasCancelled: true
            )
        }

        let libraryListing = immediateChildren(at: library.path)
        let hiddenHome = homeListing.children
            .filter(\.isHidden)
            .map { child in
                StorageCoverageGap(
                    kind: .hiddenHomeEntry,
                    name: child.name,
                    absolutePath: child.path,
                    category: .uncoveredFilesystemRegion,
                    state: .presentButUnmeasured,
                    confidence: .unmeasured,
                    explanation: "This hidden home entry exists but is intentionally outside the visible-home analyzer. No size was measured."
                )
            }
            .sorted { ($0.absolutePath ?? "") < ($1.absolutePath ?? "") }
        let unspecializedLibrary = libraryListing.children
            .filter { !specializedLibraryNames.contains($0.name) }
            .map { child in
                StorageCoverageGap(
                    kind: .unspecializedUserLibraryEntry,
                    name: child.name,
                    absolutePath: child.path,
                    category: .uncoveredFilesystemRegion,
                    state: .presentButUnmeasured,
                    confidence: .unmeasured,
                    explanation: "This immediate Library entry exists outside the three specialized user-Library analyzers. No size was measured."
                )
            }
            .sorted { ($0.absolutePath ?? "") < ($1.absolutePath ?? "") }

        return StorageCoverageDiscoveryResult(
            homeDirectoryPath: home.path,
            hiddenHomeEntries: hiddenHome,
            unspecializedLibraryEntries: unspecializedLibrary,
            issues: [homeListing.issue, libraryListing.issue]
                .compactMap { $0 }
                .sorted(by: issueSort),
            wasCancelled: libraryListing.wasCancelled
        )
    }

    private static func immediateChildren(at path: String) -> DirectoryListing {
        guard !Task.isCancelled else {
            return DirectoryListing(children: [], issue: cancellationIssue(path), wasCancelled: true)
        }
        guard let directory = opendir(path) else {
            let errorCode = Darwin.errno
            return DirectoryListing(
                children: [],
                issue: posixIssue(path: path, errorCode: errorCode, operation: "Coverage discovery"),
                wasCancelled: false
            )
        }
        defer { closedir(directory) }

        var children: [Child] = []
        while true {
            guard !Task.isCancelled else {
                return DirectoryListing(
                    children: children,
                    issue: cancellationIssue(path),
                    wasCancelled: true
                )
            }
            Darwin.errno = 0
            guard let entry = readdir(directory) else {
                let errorCode = Darwin.errno
                return DirectoryListing(
                    children: children.sorted { $0.path < $1.path },
                    issue: errorCode == 0
                        ? nil
                        : posixIssue(path: path, errorCode: errorCode, operation: "Coverage discovery"),
                    wasCancelled: false
                )
            }

            var nameBuffer = entry.pointee.d_name
            let capacity = MemoryLayout.size(ofValue: nameBuffer)
            let name = withUnsafePointer(to: &nameBuffer) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != ".." else { continue }

            let childPath = path == "/" ? "/\(name)" : "\(path)/\(name)"
            var metadata = stat()
            let metadataAvailable = lstat(childPath, &metadata) == 0
            let hiddenByFlag = metadataAvailable
                && (UInt32(metadata.st_flags) & UInt32(UF_HIDDEN)) != 0
            children.append(Child(
                name: name,
                path: childPath,
                isHidden: name.hasPrefix(".") || hiddenByFlag
            ))
        }
    }

    private static func posixIssue(
        path: String,
        errorCode: Int32,
        operation: String
    ) -> StorageScanIssue {
        let kind: StorageScanIssueKind
        if errorCode == EACCES || errorCode == EPERM {
            kind = .permissionDenied
        } else {
            kind = .directoryEnumerationFailed
        }
        return StorageScanIssue(
            path: path,
            kind: kind,
            message: "\(operation) failed: \(String(cString: strerror(errorCode)))",
            posixErrorCode: errorCode
        )
    }

    private static func cancellationIssue(_ path: String) -> StorageScanIssue {
        StorageScanIssue(
            path: path,
            kind: .cancelled,
            message: "Coverage discovery was cancelled before it completed.",
            posixErrorCode: nil
        )
    }

    private static func issueSort(_ left: StorageScanIssue, _ right: StorageScanIssue) -> Bool {
        if left.path != right.path { return left.path < right.path }
        if left.kind != right.kind { return left.kind.rawValue < right.kind.rawValue }
        return (left.posixErrorCode ?? 0) < (right.posixErrorCode ?? 0)
    }
}

/// Builds compact diagnostics from analyzer results that already exist. The
/// builder does not traverse filesystem trees and does not alter reconciliation
/// byte values.
struct StorageCoverageDiagnosticBuilder: Sendable {
    struct Event: Hashable, Sendable {
        let category: StorageCoverageDiagnosticCategory
        let severity: StorageCoverageDiagnosticSeverity
        let source: StorageCoverageDiagnosticSource
        let canonicalRoot: StorageCanonicalRoot?
        let originalPath: String?
        let normalizedPath: String?
        let posixErrorCode: Int32?
        let explanation: String
    }

    private let representativePathLimit: Int
    private let parentPathLimit: Int

    init(representativePathLimit: Int = 5, parentPathLimit: Int = 10) {
        self.representativePathLimit = max(representativePathLimit, 1)
        self.parentPathLimit = max(parentPathLimit, 1)
    }

    func build(
        analyzerResults: StorageAnalyzerResults,
        canonicalRootCoverage: [StorageCanonicalRootCoverage],
        filesystemContributions: [StorageFilesystemContribution],
        analysisIssues: [StorageReconciliationIssue],
        discovery: StorageCoverageDiscoveryResult,
        unexplainedBytes: Int64?,
        purgeableEstimateBytes: Int64?,
        incompleteCoverage: Bool,
        wasCancelled: Bool
    ) -> StorageCoverageDiagnostic {
        var events = filesystemEvents(
            from: analyzerResults,
            coverage: canonicalRootCoverage
        )
        events.append(contentsOf: canonicalRootEvents(from: canonicalRootCoverage))
        events.append(contentsOf: discovery.issues.map {
            event(
                for: $0,
                source: .coverageDiscovery,
                coverage: canonicalRootCoverage
            )
        })
        events.append(contentsOf: dockerEvents(
            from: analyzerResults.dockerStorage,
            existing: events,
            coverage: canonicalRootCoverage
        ))
        events.append(contentsOf: apfsEvents(from: analyzerResults.apfsStorage))
        events.append(contentsOf: reconciliationEvents(
            analysisIssues,
            existing: events,
            coverage: canonicalRootCoverage
        ))
        if wasCancelled, !events.contains(where: { $0.category == .cancelled }) {
            events.append(Event(
                category: .cancelled,
                severity: .warning,
                source: .reconciliation,
                canonicalRoot: nil,
                originalPath: nil,
                normalizedPath: nil,
                posixErrorCode: nil,
                explanation: Self.explanation(for: .cancelled)
            ))
        }

        let aggregation = aggregate(events, coverage: canonicalRootCoverage)
        let gaps = coverageGaps(
            discovery: discovery,
            coverage: canonicalRootCoverage,
            aggregation: aggregation,
            expansion: analyzerResults.coverageExpansion
        )
        let map = coverageMap(
            coverage: canonicalRootCoverage,
            contributions: filesystemContributions,
            gaps: gaps,
            hasAPFS: analyzerResults.apfsStorage != nil
        )
        let statuses = analyzerStatuses(
            results: analyzerResults,
            coverage: canonicalRootCoverage,
            issues: analysisIssues,
            aggregation: aggregation,
            wasCancelled: wasCancelled
        )
        let explanations = unexplainedExplanations(
            aggregation: aggregation,
            unexplainedBytes: unexplainedBytes,
            purgeableEstimateBytes: purgeableEstimateBytes,
            hasAPFS: analyzerResults.apfsStorage != nil,
            incompleteCoverage: incompleteCoverage
        )
        let explainedConfidence: StorageMeasurementConfidence
        if wasCancelled || canonicalRootCoverage.contains(where: {
            $0.state == .partiallyCompleted || $0.state == .failed || $0.state == .cancelled
        }) {
            explainedConfidence = .knownLowerBound
        } else if incompleteCoverage {
            explainedConfidence = .partialCoverage
        } else {
            explainedConfidence = .completeMeasurement
        }

        return StorageCoverageDiagnostic(
            measurementIssues: aggregation,
            coverageMap: map,
            coverageGaps: gaps,
            analyzerStatuses: statuses,
            unexplainedSpaceExplanations: explanations,
            explainedStorageConfidence: explainedConfidence,
            unexplainedStorageConfidence: .unmeasured,
            hiddenHomeEntryCount: discovery.hiddenHomeEntries.count,
            unspecializedLibraryEntryCount: discovery.unspecializedLibraryEntries.count
        )
    }
}

extension StorageCoverageDiagnosticBuilder {
    static func category(for issue: StorageScanIssue) -> StorageCoverageDiagnosticCategory {
        if issue.posixErrorCode == EACCES || issue.posixErrorCode == EPERM {
            return .permissionDenied
        }
        if issue.posixErrorCode == ENOENT {
            return .concurrentFilesystemChange
        }
        switch issue.kind {
        case .permissionDenied: return .permissionDenied
        case .unreadable, .notDirectory: return .inaccessible
        case .directoryEnumerationFailed: return .enumerationFailure
        case .metadataUnavailable: return .metadataFailure
        case .differentVolume: return .differentVolumeBoundary
        case .cancelled: return .cancelled
        }
    }

    static func explanation(for category: StorageCoverageDiagnosticCategory) -> String {
        switch category {
        case .permissionDenied:
            return "The operating system denied access to this location (EACCES or EPERM where reported)."
        case .inaccessible:
            return "The location could not be read for a reason that was not identified as a permission denial."
        case .enumerationFailure:
            return "The directory opened incompletely or its entries could not be enumerated."
        case .metadataFailure:
            return "Filesystem or analyzer metadata could not be read or parsed."
        case .differentVolumeBoundary:
            return "Traversal stopped at another mounted filesystem to preserve volume-local accounting."
        case .cancelled:
            return "The operation stopped before this measurement completed."
        case .missingOptionalRoot:
            return "An optional configured location was not present; no bytes were inferred."
        case .failedAnalyzer:
            return "An analyzer or one of its read-only inspection commands did not complete."
        case .uncoveredFilesystemRegion:
            return "This filesystem region is outside the current configured scan coverage."
        case .nonAdditiveAPFSStorage:
            return "APFS metadata and snapshot values are explanatory and not additive to file totals."
        case .possibleSharedExtentAccounting:
            return "Shared extents, clones, or cross-scope identity can limit direct physical attribution."
        case .concurrentFilesystemChange:
            return "The path disappeared while the scan was running (ENOENT) and is not a permission failure."
        case .unknown:
            return "The available issue metadata is insufficient for a more specific classification."
        }
    }
}

private extension StorageCoverageDiagnosticBuilder {
    func canonicalRootEvents(
        from coverage: [StorageCanonicalRootCoverage]
    ) -> [Event] {
        coverage.compactMap { item in
            guard item.state == .missingOptional else { return nil }
            return Event(
                category: .missingOptionalRoot,
                severity: .informational,
                source: .canonicalRoot(item.root),
                canonicalRoot: item.root,
                originalPath: item.configuredPath,
                normalizedPath: StoragePathNormalizer.normalize(item.configuredPath),
                posixErrorCode: nil,
                explanation: Self.explanation(for: .missingOptionalRoot)
            )
        }
    }

    func filesystemEvents(
        from results: StorageAnalyzerResults,
        coverage: [StorageCanonicalRootCoverage]
    ) -> [Event] {
        var pairs: [(StorageScanIssue, StorageAnalyzerStage)] = []
        append(results.userHomeStorage?.issues, stage: .userHomeStorage, to: &pairs)
        append(results.applicationSupport?.issues, stage: .applicationSupport, to: &pairs)
        append(results.containers?.issues, stage: .containers, to: &pairs)
        append(results.groupContainers?.issues, stage: .groupContainers, to: &pairs)
        append(results.systemLibrary?.issues, stage: .systemLibrary, to: &pairs)
        append(results.privateStorage?.issues, stage: .privateStorage, to: &pairs)
        append(results.dataVolumeHiddenStorage?.issues, stage: .dataVolumeHiddenStorage, to: &pairs)
        append(results.developerSystemStorage?.issues, stage: .developerSystemStorage, to: &pairs)
        append(results.coverageExpansion?.issues, stage: .coverageExpansion, to: &pairs)
        results.dockerStorage?.hostFootprint.locations.forEach {
            append($0.issues, stage: .dockerStorage, to: &pairs)
        }
        return pairs.map { issue, stage in
            event(for: issue, source: .analyzer(stage), coverage: coverage)
        }
    }

    func append(
        _ issues: [StorageScanIssue]?,
        stage: StorageAnalyzerStage,
        to pairs: inout [(StorageScanIssue, StorageAnalyzerStage)]
    ) {
        guard let issues else { return }
        pairs.append(contentsOf: issues.map { ($0, stage) })
    }

    func event(
        for issue: StorageScanIssue,
        source: StorageCoverageDiagnosticSource,
        coverage: [StorageCanonicalRootCoverage]
    ) -> Event {
        let category = Self.category(for: issue)
        let original = issue.path
        let norm = StoragePathNormalizer.normalize(original)
        let explanation: String
        if category == .permissionDenied && StoragePathNormalizer.isSystemProtectedLocation(norm) {
            explanation = "This system-managed location is protected by macOS security policies (EACCES/EPERM); it remains inaccessible even when Full Disk Access is granted."
        } else {
            explanation = Self.explanation(for: category)
        }
        return Event(
            category: category,
            severity: category == .differentVolumeBoundary ? .informational : .warning,
            source: source,
            canonicalRoot: canonicalRoot(for: original, coverage: coverage),
            originalPath: original,
            normalizedPath: norm,
            posixErrorCode: issue.posixErrorCode,
            explanation: explanation
        )
    }

    func dockerEvents(
        from report: DockerStorageReport?,
        existing: [Event],
        coverage: [StorageCanonicalRootCoverage]
    ) -> [Event] {
        guard let report else { return [] }
        let existingPaths = Set(existing.compactMap { event -> String? in
            guard event.source == .analyzer(.dockerStorage) else { return nil }
            return event.normalizedPath
        })
        return report.issues.compactMap { issue in
            if issue.kind == .filesystem,
               let path = issue.path.map({ StoragePathNormalizer.normalize($0) }),
               existingPaths.contains(path) {
                return nil
            }
            let category: StorageCoverageDiagnosticCategory
            switch issue.kind {
            case .filesystem: category = .inaccessible
            case .executableNotFound: category = .missingOptionalRoot
            case .cancelled: category = .cancelled
            case .contextInspectionFailed, .daemonUnavailable, .commandFailed:
                category = .failedAnalyzer
            case .malformedRuntimeOutput: category = .metadataFailure
            case .runtimeLocationUnknown: category = .unknown
            }
            let original = issue.path
            let norm = original.map { StoragePathNormalizer.normalize($0) }
            return Event(
                category: category,
                severity: category == .missingOptionalRoot || category == .unknown
                    ? .informational
                    : .warning,
                source: .analyzer(.dockerStorage),
                canonicalRoot: original.flatMap { canonicalRoot(for: $0, coverage: coverage) },
                originalPath: original,
                normalizedPath: norm,
                posixErrorCode: nil,
                explanation: Self.explanation(for: category)
            )
        }
    }

    func apfsEvents(from report: APFSStorageReport?) -> [Event] {
        guard let report else { return [] }
        return report.issues.map { issue in
            let category: StorageCoverageDiagnosticCategory
            switch issue.kind {
            case .permissionDenied: category = .permissionDenied
            case .cancelled: category = .cancelled
            case .commandUnavailable, .commandFailed: category = .failedAnalyzer
            case .volumeStatisticsUnavailable, .malformedPlist, .malformedOutput, .partialMetadata:
                category = .metadataFailure
            }
            return Event(
                category: category,
                severity: .warning,
                source: .analyzer(.apfsVolume),
                canonicalRoot: nil,
                originalPath: nil,
                normalizedPath: nil,
                posixErrorCode: nil,
                explanation: Self.explanation(for: category)
            )
        }
    }

    func reconciliationEvents(
        _ issues: [StorageReconciliationIssue],
        existing: [Event],
        coverage: [StorageCanonicalRootCoverage]
    ) -> [Event] {
        let existingCancellationStages = Set(existing.compactMap { event -> StorageAnalyzerStage? in
            guard event.category == .cancelled,
                  case let .analyzer(stage) = event.source else { return nil }
            return stage
        })
        let existingAnalyzerPaths = Set(existing.compactMap { event -> String? in
            guard case let .analyzer(stage) = event.source else { return nil }
            return "\(stage.rawValue)|\(event.normalizedPath ?? "<none>")"
        })
        return issues.compactMap { issue in
            let category: StorageCoverageDiagnosticCategory
            switch issue.kind {
            case .analyzerFailure: category = .failedAnalyzer
            case .cancelled:
                if let stage = issue.stage, existingCancellationStages.contains(stage) { return nil }
                category = .cancelled
            case .analyzerIssue, .permissionIncomplete:
                if let stage = issue.stage {
                    let path = issue.path.map { StoragePathNormalizer.normalize($0) } ?? "<none>"
                    if existingAnalyzerPaths.contains("\(stage.rawValue)|\(path)") {
                        return nil
                    }
                }
                category = .unknown
            default:
                return nil
            }
            let source = issue.stage.map(StorageCoverageDiagnosticSource.analyzer)
                ?? .reconciliation
            let original = issue.path
            let norm = original.map { StoragePathNormalizer.normalize($0) }
            return Event(
                category: category,
                severity: .warning,
                source: source,
                canonicalRoot: original.flatMap { canonicalRoot(for: $0, coverage: coverage) },
                originalPath: original,
                normalizedPath: norm,
                posixErrorCode: nil,
                explanation: Self.explanation(for: category)
            )
        }
    }

    func aggregate(
        _ events: [Event],
        coverage: [StorageCanonicalRootCoverage]
    ) -> StorageCoverageIssueAggregation {
        struct LocationKey: Hashable {
            let category: StorageCoverageDiagnosticCategory
            let normalizedPath: String?
            let posixErrorCode: Int32?
        }

        struct AggregatedLocation {
            let category: StorageCoverageDiagnosticCategory
            let severity: StorageCoverageDiagnosticSeverity
            let normalizedPath: String?
            let posixErrorCode: Int32?
            var originalPaths: Set<String>
            var sources: Set<StorageCoverageDiagnosticSource>
            var canonicalRoots: Set<StorageCanonicalRoot>
            var primarySource: StorageCoverageDiagnosticSource
            var primaryCanonicalRoot: StorageCanonicalRoot?
            var explanation: String
        }

        var locationsByKey: [LocationKey: AggregatedLocation] = [:]
        var orderedKeys: [LocationKey] = []

        for event in events {
            let key = LocationKey(
                category: event.category,
                normalizedPath: event.normalizedPath,
                posixErrorCode: event.posixErrorCode
            )

            if var existing = locationsByKey[key] {
                if let orig = event.originalPath {
                    existing.originalPaths.insert(orig)
                }
                existing.sources.insert(event.source)
                if let root = event.canonicalRoot {
                    existing.canonicalRoots.insert(root)
                }
                if existing.primarySource.identifier.starts(with: "reconciliation")
                    || existing.primarySource.identifier.starts(with: "coverage-discovery") {
                    existing.primarySource = event.source
                }
                if existing.primaryCanonicalRoot == nil {
                    existing.primaryCanonicalRoot = event.canonicalRoot
                }
                if event.explanation.contains("system-managed") {
                    existing.explanation = event.explanation
                }
                locationsByKey[key] = existing
            } else {
                var origSet = Set<String>()
                if let orig = event.originalPath {
                    origSet.insert(orig)
                }
                var rootSet = Set<StorageCanonicalRoot>()
                if let root = event.canonicalRoot {
                    rootSet.insert(root)
                }
                let newLocation = AggregatedLocation(
                    category: event.category,
                    severity: event.severity,
                    normalizedPath: event.normalizedPath,
                    posixErrorCode: event.posixErrorCode,
                    originalPaths: origSet,
                    sources: [event.source],
                    canonicalRoots: rootSet,
                    primarySource: event.source,
                    primaryCanonicalRoot: event.canonicalRoot,
                    explanation: event.explanation
                )
                locationsByKey[key] = newLocation
                orderedKeys.append(key)
            }
        }

        let deduplicatedLocations = orderedKeys.compactMap { locationsByKey[$0] }

        var categoryCounts: [StorageCoverageDiagnosticCategory: Int] = [:]
        var analyzerCounts: [StorageAnalyzerStage: Int] = [:]
        var rootCounts: [StorageCanonicalRoot: Int] = [:]
        var errnoCounts: [Int32: Int] = [:]
        var parentCounts: [String: Int] = [:]

        struct GroupIdentity: Hashable {
            let category: StorageCoverageDiagnosticCategory
            let severity: StorageCoverageDiagnosticSeverity
            let source: StorageCoverageDiagnosticSource
            let canonicalRoot: StorageCanonicalRoot?
            let posixErrorCode: Int32?
            let explanation: String
        }

        var groupedLocations: [GroupIdentity: [AggregatedLocation]] = [:]

        for location in deduplicatedLocations {
            categoryCounts[location.category, default: 0] += 1
            for src in location.sources {
                if case let .analyzer(stage) = src {
                    analyzerCounts[stage, default: 0] += 1
                }
            }
            for root in location.canonicalRoots {
                rootCounts[root, default: 0] += 1
            }
            if let errorCode = location.posixErrorCode {
                errnoCounts[errorCode, default: 0] += 1
            }
            if let path = location.normalizedPath {
                parentCounts[StoragePathNormalizer.parentPath(of: path), default: 0] += 1
            }

            let groupKey = GroupIdentity(
                category: location.category,
                severity: location.severity,
                source: location.primarySource,
                canonicalRoot: location.primaryCanonicalRoot,
                posixErrorCode: location.posixErrorCode,
                explanation: location.explanation
            )
            groupedLocations[groupKey, default: []].append(location)
        }

        let configuredPaths = Dictionary(
            uniqueKeysWithValues: coverage.map { ($0.root, $0.configuredPath) }
        )

        let groups = groupedLocations.map { identity, locs in
            var allRepresentativePaths: [String] = []
            var allContributingSources: Set<StorageCoverageDiagnosticSource> = []
            for loc in locs {
                if loc.originalPaths.isEmpty {
                    if let p = loc.normalizedPath {
                        allRepresentativePaths.append(p)
                    }
                } else {
                    allRepresentativePaths.append(contentsOf: loc.originalPaths)
                }
                allContributingSources.formUnion(loc.sources)
            }

            let sortedPaths = Array(Set(allRepresentativePaths))
                .sorted()
                .prefix(representativePathLimit)
                .map { $0 }

            let sortedSources = allContributingSources.sorted { $0.identifier < $1.identifier }

            return StorageCoverageDiagnosticIssueGroup(
                category: identity.category,
                severity: identity.severity,
                source: identity.source,
                contributingSources: sortedSources,
                canonicalRoot: identity.canonicalRoot,
                posixErrorCode: identity.posixErrorCode,
                count: locs.count,
                representativePaths: sortedPaths,
                explanation: identity.explanation
            )
        }.sorted(by: groupSort)

        return StorageCoverageIssueAggregation(
            totalIssueCount: deduplicatedLocations.count,
            categoryCounts: categoryCounts.map {
                StorageCoverageDiagnosticCategoryCount(category: $0.key, count: $0.value)
            }.sorted { $0.category.rawValue < $1.category.rawValue },
            analyzerCounts: analyzerCounts.map {
                StorageCoverageDiagnosticAnalyzerCount(analyzer: $0.key, count: $0.value)
            }.sorted { analyzerIndex($0.analyzer) < analyzerIndex($1.analyzer) },
            canonicalRootCounts: rootCounts.map {
                StorageCoverageDiagnosticRootCount(
                    root: $0.key,
                    configuredPath: configuredPaths[$0.key] ?? $0.key.rawValue,
                    count: $0.value
                )
            }.sorted { rootIndex($0.root) < rootIndex($1.root) },
            errnoCounts: errnoCounts.map {
                StorageCoverageDiagnosticErrnoCount(errorCode: $0.key, count: $0.value)
            }.sorted { $0.errorCode < $1.errorCode },
            topAffectedParentPaths: parentCounts.map {
                StorageCoverageDiagnosticParentCount(parentPath: $0.key, count: $0.value)
            }.sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return $0.parentPath < $1.parentPath
            }.prefix(parentPathLimit).map { $0 },
            groups: groups
        )
    }

    func coverageGaps(
        discovery: StorageCoverageDiscoveryResult,
        coverage: [StorageCanonicalRootCoverage],
        aggregation: StorageCoverageIssueAggregation,
        expansion: StorageCoverageExpansionReport? = nil
    ) -> [StorageCoverageGap] {
        var gaps: [StorageCoverageGap] = []

        let expansionCandidatesByNormPath = Dictionary(
            (expansion?.candidates ?? []).map { ($0.normalizedPath, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for rawGap in (discovery.hiddenHomeEntries + discovery.unspecializedLibraryEntries) {
            let norm = rawGap.absolutePath.map { StoragePathNormalizer.normalize($0) } ?? ""
            if let candidate = expansionCandidatesByNormPath[norm] {
                let state: StorageCoverageMapState
                let confidence: StorageMeasurementConfidence
                let isAdditive: Bool
                let explanation: String

                switch candidate.status {
                case .measured:
                    state = .measured
                    confidence = candidate.issue == nil ? .completeMeasurement : .knownLowerBound
                    isAdditive = candidate.contributesToExplainedBytes
                    explanation = "Discovered and measured by targeted coverage expansion pass."
                case .partiallyMeasured:
                    state = .partiallyMeasured
                    confidence = .knownLowerBound
                    isAdditive = candidate.contributesToExplainedBytes
                    explanation = candidate.exclusionReason ?? "Partially measured; some items had restricted access."
                case .inaccessible, .excludedProtectedSystem:
                    state = .partiallyMeasured
                    confidence = .knownLowerBound
                    isAdditive = false
                    explanation = candidate.exclusionReason ?? "Protected macOS location with restricted access."
                case .excludedAlreadyAccounted, .excludedNested, .skippedAlreadyOwned, .skippedUnsafeOverlap:
                    state = .measured
                    confidence = .nonAdditiveMetadata
                    isAdditive = false
                    explanation = candidate.exclusionReason ?? "Already accounted by a specialized canonical root."
                default:
                    state = rawGap.state
                    confidence = rawGap.confidence
                    isAdditive = false
                    explanation = rawGap.explanation
                }

                gaps.append(StorageCoverageGap(
                    kind: rawGap.kind,
                    name: rawGap.name,
                    absolutePath: rawGap.absolutePath,
                    category: rawGap.category,
                    state: state,
                    confidence: confidence,
                    explanation: explanation,
                    allocatedBytes: candidate.allocatedBytes,
                    logicalBytes: candidate.logicalBytes,
                    isFilesystemAdditive: isAdditive,
                    issueCount: candidate.issue == nil ? 0 : 1
                ))
            } else {
                gaps.append(rawGap)
            }
        }

        if let expansionCandidates = expansion?.candidates {
            for candidate in expansionCandidates {
                let norm = candidate.normalizedPath
                let alreadyInGaps = gaps.contains { ($0.absolutePath.map { StoragePathNormalizer.normalize($0) }) == norm }
                if !alreadyInGaps {
                    let kind: StorageCoverageGapKind
                    switch candidate.scope {
                    case .hiddenHome: kind = .hiddenHomeEntry
                    case .userLibrary: kind = .unspecializedUserLibraryEntry
                    case .dataVolumeRoot, .other: kind = .rootFilesystemRegion
                    }

                    let state: StorageCoverageMapState
                    let confidence: StorageMeasurementConfidence
                    let isAdditive: Bool
                    let explanation: String

                    switch candidate.status {
                    case .measured:
                        state = .measured
                        confidence = candidate.issue == nil ? .completeMeasurement : .knownLowerBound
                        isAdditive = candidate.contributesToExplainedBytes
                        explanation = "Discovered and measured by targeted coverage expansion pass."
                    case .partiallyMeasured:
                        state = .partiallyMeasured
                        confidence = .knownLowerBound
                        isAdditive = candidate.contributesToExplainedBytes
                        explanation = candidate.exclusionReason ?? "Partially measured; some items had restricted access."
                    case .inaccessible, .excludedProtectedSystem:
                        state = .partiallyMeasured
                        confidence = .knownLowerBound
                        isAdditive = false
                        explanation = candidate.exclusionReason ?? "Protected macOS location with restricted access."
                    case .excludedAlreadyAccounted, .excludedNested, .skippedAlreadyOwned, .skippedUnsafeOverlap:
                        state = .measured
                        confidence = .nonAdditiveMetadata
                        isAdditive = false
                        explanation = candidate.exclusionReason ?? "Already accounted by a specialized canonical root."
                    default:
                        state = .presentButUnmeasured
                        confidence = .unmeasured
                        isAdditive = false
                        explanation = candidate.exclusionReason ?? "Data-volume candidate discovered during coverage expansion pass."
                    }

                    gaps.append(StorageCoverageGap(
                        kind: kind,
                        name: candidate.name,
                        absolutePath: candidate.originalPath,
                        category: candidate.status == .excludedProtectedSystem ? .permissionDenied : .uncoveredFilesystemRegion,
                        state: state,
                        confidence: confidence,
                        explanation: explanation,
                        allocatedBytes: candidate.allocatedBytes,
                        logicalBytes: candidate.logicalBytes,
                        isFilesystemAdditive: isAdditive,
                        issueCount: candidate.issue == nil ? 0 : 1
                    ))
                }
            }
        }

        gaps.append(contentsOf: coverage.compactMap { item in
            guard item.state == .missingOptional else { return nil }
            return StorageCoverageGap(
                kind: .rootFilesystemRegion,
                name: item.root.rawValue,
                absolutePath: item.configuredPath,
                category: .missingOptionalRoot,
                state: .missingOptional,
                confidence: .unmeasured,
                explanation: "This optional configured root was not present; no bytes were inferred for it."
            )
        })
        gaps.append(StorageCoverageGap(
            kind: .otherUsers,
            name: "Other users",
            absolutePath: "/Users",
            category: .uncoveredFilesystemRegion,
            state: .intentionallyUnmeasured,
            confidence: .unmeasured,
            explanation: "Other user home directories are outside the current per-user scan coverage."
        ))
        gaps.append(StorageCoverageGap(
            kind: .rootFilesystemRegion,
            name: "Other root-level regions",
            absolutePath: "/",
            category: .uncoveredFilesystemRegion,
            state: .intentionallyUnmeasured,
            confidence: .unmeasured,
            explanation: "Root-level filesystem regions without a canonical analyzer are not recursively measured."
        ))
        gaps.append(StorageCoverageGap(
            kind: .otherMountedVolume,
            name: "Other mounted volumes",
            absolutePath: "/Volumes",
            category: .uncoveredFilesystemRegion,
            state: .intentionallyUnmeasured,
            confidence: .unmeasured,
            explanation: "Other mounted filesystems are intentionally excluded from startup-volume accounting."
        ))
        let incompleteCategories: Set<StorageCoverageDiagnosticCategory> = [
            .permissionDenied,
            .inaccessible,
            .enumerationFailure,
            .metadataFailure,
            .concurrentFilesystemChange,
        ]
        for group in aggregation.groups where incompleteCategories.contains(group.category) {
            for path in group.representativePaths {
                gaps.append(StorageCoverageGap(
                    kind: .inaccessibleSubtree,
                    name: URL(fileURLWithPath: path).lastPathComponent,
                    absolutePath: path,
                    category: group.category,
                    state: .partiallyMeasured,
                    confidence: .knownLowerBound,
                    explanation: group.explanation
                ))
            }
        }
        return gaps.uniqued(by: \StorageCoverageGap.id).sorted {
            if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
            return ($0.absolutePath ?? $0.name) < ($1.absolutePath ?? $1.name)
        }
    }

    func coverageMap(
        coverage: [StorageCanonicalRootCoverage],
        contributions: [StorageFilesystemContribution],
        gaps: [StorageCoverageGap],
        hasAPFS: Bool
    ) -> [StorageCoverageMapEntry] {
        var entries = coverage.map { item in
            StorageCoverageMapEntry(
                identifier: "canonical:\(item.root.rawValue)",
                title: rootTitle(item.root),
                absolutePath: item.configuredPath,
                source: .canonicalRoot(item.root),
                state: mapState(item.state),
                confidence: item.measurementConfidence,
                explanation: rootExplanation(item)
            )
        }
        for contribution in contributions where
            contribution.source == .dockerHostOutsideCanonicalRoots
                && contribution.relationship == .externalSpecializedUnique {
            entries.append(StorageCoverageMapEntry(
                identifier: "docker:\(contribution.normalizedPath)",
                title: "External Docker host storage",
                absolutePath: contribution.absolutePath,
                source: .analyzer(.dockerStorage),
                state: .measured,
                confidence: .completeMeasurement,
                explanation: "This non-overlapping Docker host path is measured by the Docker analyzer."
            ))
        }
        entries.append(contentsOf: gaps.map { gap in
            StorageCoverageMapEntry(
                identifier: "gap:\(gap.id)",
                title: gap.name,
                absolutePath: gap.absolutePath,
                source: .coverageDiscovery,
                state: gap.state,
                confidence: gap.confidence,
                explanation: gap.explanation
            )
        })
        if hasAPFS {
            entries.append(StorageCoverageMapEntry(
                identifier: "apfs:non-additive",
                title: "APFS metadata and snapshots",
                absolutePath: nil,
                source: .apfs,
                state: .nonAdditive,
                confidence: .nonAdditiveMetadata,
                explanation: "APFS metadata, snapshots, clones, and shared extents cannot be added directly to filesystem tree totals."
            ))
        }
        return entries.sorted { $0.identifier < $1.identifier }
    }

    func analyzerStatuses(
        results: StorageAnalyzerResults,
        coverage: [StorageCanonicalRootCoverage],
        issues: [StorageReconciliationIssue],
        aggregation: StorageCoverageIssueAggregation,
        wasCancelled: Bool
    ) -> [StorageAnalyzerCoverageDiagnostic] {
        let counts = Dictionary(uniqueKeysWithValues: aggregation.analyzerCounts.map {
            ($0.analyzer, $0.count)
        })
        let failedStages = Set(issues.compactMap {
            $0.kind == .analyzerFailure ? $0.stage : nil
        })
        let cancelledStages = Set(issues.compactMap {
            $0.kind == .cancelled ? $0.stage : nil
        })

        return StorageAnalyzerStage.allCases.map { stage in
            let state: StorageAnalyzerDiagnosticState
            if failedStages.contains(stage) {
                state = .failed
            } else if cancelledStages.contains(stage) {
                state = .cancelled
            } else if wasCancelled && !hasResult(for: stage, in: results) {
                state = .cancelled
            } else if stage == .apfsVolume {
                switch results.apfsStorage?.state {
                case .cancelled: state = .cancelled
                case .partial: state = .knownLowerBound
                case .unavailable, nil: state = .failed
                case .complete, .nonAPFS: state = .nonAdditiveMetadata
                }
            } else if stage == .dockerStorage {
                if results.dockerStorage?.wasCancelled == true {
                    state = .cancelled
                } else if results.dockerStorage == nil {
                    state = .failed
                } else {
                    state = .complete
                }
            } else {
                let roots = roots(for: stage, coverage: coverage)
                if roots.isEmpty {
                    state = .failed
                } else if roots.allSatisfy({ $0.state == .missingOptional }) {
                    state = .optionalRootMissing
                } else if roots.contains(where: { $0.state == .cancelled }) {
                    state = .cancelled
                } else if roots.contains(where: { $0.state == .failed }) {
                    state = .failed
                } else if roots.contains(where: { $0.state == .partiallyCompleted }) {
                    state = .knownLowerBound
                } else {
                    state = .complete
                }
            }
            return StorageAnalyzerCoverageDiagnostic(
                analyzer: stage,
                state: state,
                issueCount: counts[stage] ?? 0,
                confidence: confidence(for: state)
            )
        }
    }

    func unexplainedExplanations(
        aggregation: StorageCoverageIssueAggregation,
        unexplainedBytes: Int64?,
        purgeableEstimateBytes: Int64?,
        hasAPFS: Bool,
        incompleteCoverage: Bool
    ) -> [StorageCoverageExplanation] {
        var values: [StorageCoverageExplanation] = []
        if incompleteCoverage || unexplainedBytes != 0 {
            values.append(StorageCoverageExplanation(
                category: .uncoveredFilesystemRegion,
                severity: .informational,
                title: "Filesystem coverage gaps",
                detail: "Unexplained capacity may include filesystem regions that PureMac does not currently scan or descendants it could not measure."
            ))
        }
        if hasAPFS {
            values.append(StorageCoverageExplanation(
                category: .nonAdditiveAPFSStorage,
                severity: .informational,
                title: "APFS storage is non-additive",
                detail: "Snapshots and APFS metadata can share physical extents with live files, so they are not added to explained filesystem bytes."
            ))
            values.append(StorageCoverageExplanation(
                category: .possibleSharedExtentAccounting,
                severity: .informational,
                title: "Shared extents and clones",
                detail: "APFS clones and shared extents can make physical attribution differ from a simple sum of directory trees."
            ))
        }
        if purgeableEstimateBytes != nil {
            values.append(StorageCoverageExplanation(
                category: .nonAdditiveAPFSStorage,
                severity: .informational,
                title: "Purgeable capacity is an estimate",
                detail: "The system purgeable estimate remains separate from explained and unexplained storage."
            ))
        }
        if aggregation.categoryCounts.contains(where: {
            $0.category == .concurrentFilesystemChange && $0.count > 0
        }) {
            values.append(StorageCoverageExplanation(
                category: .concurrentFilesystemChange,
                severity: .informational,
                title: "Files changed during analysis",
                detail: "Some paths disappeared while the scan was running, which can leave a small point-in-time accounting difference."
            ))
        }
        return values.sorted {
            if $0.category != $1.category { return $0.category.rawValue < $1.category.rawValue }
            return $0.title < $1.title
        }
    }

    func canonicalRoot(
        for path: String,
        coverage: [StorageCanonicalRootCoverage]
    ) -> StorageCanonicalRoot? {
        let candidate = normalized(path)
        return coverage
            .filter { contains(parent: normalized($0.configuredPath), child: candidate) }
            .max { normalized($0.configuredPath).count < normalized($1.configuredPath).count }?
            .root
    }

    func roots(
        for stage: StorageAnalyzerStage,
        coverage: [StorageCanonicalRootCoverage]
    ) -> [StorageCanonicalRootCoverage] {
        let expected: Set<StorageCanonicalRoot>
        switch stage {
        case .userHomeStorage: expected = [.userHomeVisibleStorage]
        case .applications: expected = [.applications]
        case .applicationSupport: expected = [.applicationSupport]
        case .containers: expected = [.containers]
        case .groupContainers: expected = [.groupContainers]
        case .systemLibrary: expected = [.systemLibrary]
        case .privateStorage: expected = [.privateStorage]
        case .dataVolumeHiddenStorage: expected = [.dataVolumeHiddenStorage]
        case .developerSystemStorage: expected = [.opt, .usrLocal]
        case .coverageExpansion: expected = [.additionalCoverageGap]
        case .dockerStorage, .apfsVolume: expected = []
        }
        return coverage.filter { expected.contains($0.root) }
    }

    func confidence(for state: StorageAnalyzerDiagnosticState) -> StorageMeasurementConfidence {
        switch state {
        case .complete: return .completeMeasurement
        case .knownLowerBound, .failed, .cancelled: return .knownLowerBound
        case .optionalRootMissing: return .unmeasured
        case .nonAdditiveMetadata: return .nonAdditiveMetadata
        }
    }

    func hasResult(
        for stage: StorageAnalyzerStage,
        in results: StorageAnalyzerResults
    ) -> Bool {
        switch stage {
        case .apfsVolume: return results.apfsStorage != nil
        case .userHomeStorage: return results.userHomeStorage != nil
        case .applications: return results.applications != nil
        case .applicationSupport: return results.applicationSupport != nil
        case .containers: return results.containers != nil
        case .groupContainers: return results.groupContainers != nil
        case .systemLibrary: return results.systemLibrary != nil
        case .privateStorage: return results.privateStorage != nil
        case .dataVolumeHiddenStorage: return results.dataVolumeHiddenStorage != nil
        case .developerSystemStorage: return results.developerSystemStorage != nil
        case .dockerStorage: return results.dockerStorage != nil
        case .coverageExpansion: return results.coverageExpansion != nil
        }
    }

    func mapState(_ state: StorageCanonicalRootState) -> StorageCoverageMapState {
        switch state {
        case .completed: return .measured
        case .partiallyCompleted: return .partiallyMeasured
        case .failed, .cancelled: return .unavailable
        case .missingOptional: return .missingOptional
        }
    }

    func rootExplanation(_ item: StorageCanonicalRootCoverage) -> String {
        switch item.state {
        case .completed: return "This configured root completed its measurement."
        case .partiallyCompleted: return "Measured bytes are a known lower bound because some descendants were incomplete."
        case .failed: return "This configured root did not produce a complete measurement."
        case .missingOptional: return "This optional configured root was not present."
        case .cancelled: return "This configured root was only measured up to cancellation."
        }
    }

    func rootTitle(_ root: StorageCanonicalRoot) -> String {
        switch root {
        case .userHomeVisibleStorage: return "Visible user-home roots"
        case .applications: return "Applications"
        case .applicationSupport: return "Application Support"
        case .containers: return "Containers"
        case .groupContainers: return "Group Containers"
        case .systemLibrary: return "System Library"
        case .privateStorage: return "Private / System State"
        case .dataVolumeHiddenStorage: return "Hidden Data-volume roots"
        case .opt: return "/opt"
        case .usrLocal: return "/usr/local"
        case .additionalCoverageGap: return "Additional Storage Coverage"
        }
    }

    func normalized(_ path: String) -> String {
        StoragePathNormalizer.normalize(path)
    }

    func contains(parent: String, child: String) -> Bool {
        StoragePathNormalizer.contains(parent: parent, child: child)
    }

    func parentPath(of path: String) -> String {
        StoragePathNormalizer.parentPath(of: path)
    }

    func analyzerIndex(_ stage: StorageAnalyzerStage) -> Int {
        StorageAnalyzerStage.allCases.firstIndex(of: stage) ?? Int.max
    }

    func rootIndex(_ root: StorageCanonicalRoot) -> Int {
        StorageCanonicalRoot.allCases.firstIndex(of: root) ?? Int.max
    }

    func groupSort(
        _ left: StorageCoverageDiagnosticIssueGroup,
        _ right: StorageCoverageDiagnosticIssueGroup
    ) -> Bool {
        if left.count != right.count { return left.count > right.count }
        if left.category != right.category { return left.category.rawValue < right.category.rawValue }
        if left.source.identifier != right.source.identifier {
            return left.source.identifier < right.source.identifier
        }
        if left.canonicalRoot != right.canonicalRoot {
            return (left.canonicalRoot?.rawValue ?? "") < (right.canonicalRoot?.rawValue ?? "")
        }
        return (left.posixErrorCode ?? 0) < (right.posixErrorCode ?? 0)
    }
}

private extension Array {
    func uniqued<Key: Hashable>(by keyPath: KeyPath<Element, Key>) -> [Element] {
        var seen: Set<Key> = []
        return filter { seen.insert($0[keyPath: keyPath]).inserted }
    }
}
