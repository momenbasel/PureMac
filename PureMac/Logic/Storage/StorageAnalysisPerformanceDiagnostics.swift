import Foundation

/// Read-only debug-only performance diagnostics for PureMac Storage Intelligence.
///
/// This utility measures wall-clock duration and aggregates filesystem traversal
/// metrics (entries, directories, files, bytes, permission issues, boundary skips)
/// directly from produced `StorageNode` trees with zero additional disk I/O.
struct StorageScanMetrics: Hashable, Codable, Sendable {
    var totalEntries: Int = 0
    var directoryCount: Int = 0
    var fileCount: Int = 0
    var otherCount: Int = 0
    var allocatedBytes: Int64 = 0
    var logicalBytes: Int64 = 0
    var permissionFailureCount: Int = 0
    var boundarySkipCount: Int = 0
    var packageAggregatesCount: Int = 0
    var packageDescendantsMeasured: Int = 0
    var packageNodesAvoided: Int = 0

    init(
        totalEntries: Int = 0,
        directoryCount: Int = 0,
        fileCount: Int = 0,
        otherCount: Int = 0,
        allocatedBytes: Int64 = 0,
        logicalBytes: Int64 = 0,
        permissionFailureCount: Int = 0,
        boundarySkipCount: Int = 0,
        packageAggregatesCount: Int = 0,
        packageDescendantsMeasured: Int = 0,
        packageNodesAvoided: Int = 0
    ) {
        self.totalEntries = totalEntries
        self.directoryCount = directoryCount
        self.fileCount = fileCount
        self.otherCount = otherCount
        self.allocatedBytes = allocatedBytes
        self.logicalBytes = logicalBytes
        self.permissionFailureCount = permissionFailureCount
        self.boundarySkipCount = boundarySkipCount
        self.packageAggregatesCount = packageAggregatesCount
        self.packageDescendantsMeasured = packageDescendantsMeasured
        self.packageNodesAvoided = packageNodesAvoided
    }

    static func compute(from node: StorageNode) -> StorageScanMetrics {
        var metrics = StorageScanMetrics()
        accumulate(node: node, into: &metrics)
        if let pkgs = node.metadata.attributes["fileTreeScanner.packagesAggregated"].flatMap(Int.init) ?? node.metadata.attributes[ApplicationsStorageAnalyzer.MetadataKey.packagesAggregated].flatMap(Int.init) {
            metrics.packageAggregatesCount = pkgs
            metrics.packageDescendantsMeasured = node.metadata.attributes["fileTreeScanner.descendantEntriesMeasured"].flatMap(Int.init) ?? node.metadata.attributes[ApplicationsStorageAnalyzer.MetadataKey.descendantEntriesMeasured].flatMap(Int.init) ?? 0
            metrics.packageNodesAvoided = node.metadata.attributes["fileTreeScanner.descendantNodesAvoided"].flatMap(Int.init) ?? node.metadata.attributes[ApplicationsStorageAnalyzer.MetadataKey.descendantNodesAvoided].flatMap(Int.init) ?? 0
        }
        return metrics
    }

    static func compute(from nodes: [StorageNode]) -> StorageScanMetrics {
        var metrics = StorageScanMetrics()
        for node in nodes {
            accumulate(node: node, into: &metrics)
            if let pkgs = node.metadata.attributes["fileTreeScanner.packagesAggregated"].flatMap(Int.init) ?? node.metadata.attributes[ApplicationsStorageAnalyzer.MetadataKey.packagesAggregated].flatMap(Int.init) {
                metrics.packageAggregatesCount += pkgs
                metrics.packageDescendantsMeasured += node.metadata.attributes["fileTreeScanner.descendantEntriesMeasured"].flatMap(Int.init) ?? node.metadata.attributes[ApplicationsStorageAnalyzer.MetadataKey.descendantEntriesMeasured].flatMap(Int.init) ?? 0
                metrics.packageNodesAvoided += node.metadata.attributes["fileTreeScanner.descendantNodesAvoided"].flatMap(Int.init) ?? node.metadata.attributes[ApplicationsStorageAnalyzer.MetadataKey.descendantNodesAvoided].flatMap(Int.init) ?? 0
            }
        }
        return metrics
    }

    private static func accumulate(node: StorageNode, into metrics: inout StorageScanMetrics) {
        metrics.totalEntries += 1
        switch node.itemType {
        case .directory:
            metrics.directoryCount += 1
        case .regularFile:
            metrics.fileCount += 1
        default:
            metrics.otherCount += 1
        }
        if node.children.isEmpty {
            metrics.allocatedBytes += node.allocatedSize
            metrics.logicalBytes += node.logicalSize
        } else {
            metrics.allocatedBytes += node.ownAllocatedSize
            metrics.logicalBytes += node.ownLogicalSize
        }

        if node.accessibility == .inaccessible || node.accessibility == .partiallyAccessible {
            metrics.permissionFailureCount += node.scanIssues.filter {
                $0.kind == .permissionDenied || $0.kind == .unreadable
            }.count
        }
        if node.accessibility == .skippedDifferentVolume {
            metrics.boundarySkipCount += 1
        }

        for child in node.children {
            accumulate(node: child, into: &metrics)
        }
    }
}

struct SlowestSubtreeRecord: Hashable, Codable, Sendable {
    let path: String
    let totalEntries: Int
    let directoryCount: Int
    let fileCount: Int
    let allocatedBytes: Int64
    let isPackageOrApp: Bool
}

struct StagePerformanceRecord: Hashable, Codable, Sendable {
    let stageName: String
    let durationSeconds: Double
    let metrics: StorageScanMetrics?
    let customNote: String?

    init(
        stageName: String,
        durationSeconds: Double,
        metrics: StorageScanMetrics? = nil,
        customNote: String? = nil
    ) {
        self.stageName = stageName
        self.durationSeconds = durationSeconds
        self.metrics = metrics
        self.customNote = customNote
    }
}

struct DuplicateScanObservation: Hashable, Codable, Sendable {
    let path: String
    let primaryScanner: String
    let secondaryScanner: String
    let relationship: String

    init(
        path: String,
        primaryScanner: String,
        secondaryScanner: String,
        relationship: String
    ) {
        self.path = path
        self.primaryScanner = primaryScanner
        self.secondaryScanner = secondaryScanner
        self.relationship = relationship
    }
}

struct StorageAnalysisPerformanceReport: Hashable, Codable, Sendable {
    let totalDurationSeconds: Double
    let stageRecords: [StagePerformanceRecord]
    let duplicateObservations: [DuplicateScanObservation]
    let cacheMetrics: StorageAnalysisCacheMetrics?
    let heaviestSubtrees: [SlowestSubtreeRecord]

    init(
        totalDurationSeconds: Double,
        stageRecords: [StagePerformanceRecord],
        duplicateObservations: [DuplicateScanObservation],
        cacheMetrics: StorageAnalysisCacheMetrics? = nil,
        heaviestSubtrees: [SlowestSubtreeRecord] = []
    ) {
        self.totalDurationSeconds = totalDurationSeconds
        self.stageRecords = stageRecords
        self.duplicateObservations = duplicateObservations
        self.cacheMetrics = cacheMetrics
        self.heaviestSubtrees = heaviestSubtrees
    }

    func formattedDebugString() -> String {
        var output = "\n=== PureMac Storage Analysis Performance ===\n"
        let totalDurationStr = String(format: "%.2f", totalDurationSeconds)
        output += "Total Duration: \(totalDurationStr)s\n\n"
        output += "Stage Breakdown:\n"

        let maxNameWidth = stageRecords.map(\.stageName.count).max() ?? 25
        for record in stageRecords {
            let paddedName = record.stageName.padding(toLength: max(maxNameWidth + 2, 28), withPad: " ", startingAt: 0)
            let durationStr = (String(format: "%.2f", record.durationSeconds) + "s").leftPadded(toLength: 7)

            if let metrics = record.metrics, metrics.totalEntries > 0 {
                let bytesStr = ByteCountFormatter.string(fromByteCount: max(metrics.allocatedBytes, 0), countStyle: .file)
                let rate = record.durationSeconds > 0 ? Double(metrics.totalEntries) / record.durationSeconds : 0
                let rateStr = String(format: "%.0f entries/s", rate)
                let note = record.customNote.map { " (\($0))" } ?? ""
                if metrics.packageAggregatesCount > 0 {
                    let pkgNote = " (\(metrics.packageAggregatesCount) apps aggregated, \(metrics.packageDescendantsMeasured) descendants measured, \(metrics.packageNodesAvoided) nodes avoided)"
                    output += "\(paddedName) \(durationStr)   \(metrics.totalEntries) materialized entries (\(metrics.directoryCount) dirs, \(metrics.fileCount) files)  [\(bytesStr)] [\(rateStr)]\(pkgNote)\(note)\n"
                } else {
                    output += "\(paddedName) \(durationStr)   \(metrics.totalEntries) entries (\(metrics.directoryCount) dirs, \(metrics.fileCount) files)  [\(bytesStr)] [\(rateStr)]\(note)\n"
                }
            } else if let note = record.customNote {
                output += "\(paddedName) \(durationStr)   [\(note)]\n"
            } else {
                output += "\(paddedName) \(durationStr)\n"
            }
        }

        if let cache = cacheMetrics {
            output += "\nScan Cache & Subtree Reuse:\n"
            output += "  Physical Traversals:    \(cache.physicalTraversalsCount)\n"
            output += "  Cache Hits:             \(cache.cacheHitCount)\n"
            output += "  Cache Misses:           \(cache.cacheMissCount)\n"
            output += "  Reused Subtrees:        \(cache.reusedSubtreeCount)\n"
            output += "  Avoided Traversals:     \(cache.avoidedTraversalsCount)\n"
        }

        if !heaviestSubtrees.isEmpty {
            output += "\nTop High-Density Subtrees & Application Bundles:\n"
            for (index, subtree) in heaviestSubtrees.prefix(20).enumerated() {
                let bytesStr = ByteCountFormatter.string(fromByteCount: max(subtree.allocatedBytes, 0), countStyle: .file)
                let tag = subtree.isPackageOrApp ? "[App Bundle]" : "[Directory]"
                let indexStr = "\(index + 1)".leftPadded(toLength: 2)
                let tagStr = tag.padding(toLength: 12, withPad: " ", startingAt: 0)
                let entriesStr = "\(subtree.totalEntries)".leftPadded(toLength: 6)
                let dirsStr = "\(subtree.directoryCount)".leftPadded(toLength: 5)
                let filesStr = "\(subtree.fileCount)".leftPadded(toLength: 5)
                let bytesPadded = bytesStr.leftPadded(toLength: 8)
                output += "  \(indexStr). \(tagStr) \(entriesStr) entries (\(dirsStr) dirs, \(filesStr) files) [\(bytesPadded)] \(subtree.path)\n"
            }
        }

        if !duplicateObservations.isEmpty {
            output += "\nPotential Duplicate / Overlapping Recursive Coverage:\n"
            for obs in duplicateObservations {
                output += "- \(obs.path)\n"
                output += "  Primary:   \(obs.primaryScanner)\n"
                output += "  Secondary: \(obs.secondaryScanner) (\(obs.relationship))\n"
            }
        }

        output += "=============================================\n"
        return output
    }
}

enum StorageAnalysisPerformanceDiagnostics {
    static func analyzeDuplicates(
        results: StorageAnalyzerResults,
        expansionReport: StorageCoverageExpansionReport?
    ) -> [DuplicateScanObservation] {
        var observations: [DuplicateScanObservation] = []

        // 1. Docker host locations overlapping specialized analyzers
        if let docker = results.dockerStorage {
            for location in docker.hostFootprint.locations {
                let path = location.root.absolutePath
                if path.contains("/Library/Containers/") {
                    observations.append(DuplicateScanObservation(
                        path: path,
                        primaryScanner: "ContainersAnalyzer (scans ~/Library/Containers)",
                        secondaryScanner: "DockerStorageAnalyzer",
                        relationship: "Nested inside Containers hierarchy"
                    ))
                } else if path.contains("/Library/Group Containers/") {
                    observations.append(DuplicateScanObservation(
                        path: path,
                        primaryScanner: "GroupContainersAnalyzer (scans ~/Library/Group Containers)",
                        secondaryScanner: "DockerStorageAnalyzer",
                        relationship: "Nested inside Group Containers hierarchy"
                    ))
                } else if path.contains("/Library/Application Support/") {
                    observations.append(DuplicateScanObservation(
                        path: path,
                        primaryScanner: "ApplicationSupportAnalyzer (scans ~/Library/Application Support)",
                        secondaryScanner: "DockerStorageAnalyzer",
                        relationship: "Nested inside Application Support hierarchy"
                    ))
                } else if path.hasSuffix("/.docker") {
                    observations.append(DuplicateScanObservation(
                        path: path,
                        primaryScanner: "CoverageExpansionAnalyzer (discovers ~/.docker as hidden home root)",
                        secondaryScanner: "DockerStorageAnalyzer",
                        relationship: "Duplicate scan of ~/.docker"
                    ))
                }
            }
        }

        // 2. Coverage Expansion candidates overlapping with other roots
        if let expansion = expansionReport {
            for candidate in expansion.candidates where candidate.status == .excludedAlreadyAccounted || candidate.status == .excludedNested || candidate.status == .skippedAlreadyOwned || candidate.status == .skippedUnsafeOverlap {
                observations.append(DuplicateScanObservation(
                    path: candidate.originalPath,
                    primaryScanner: candidate.exclusionReason ?? "Canonical Root Analyzer",
                    secondaryScanner: "CoverageExpansionAnalyzer",
                    relationship: "Identified and excluded during Stage A discovery"
                ))
            }
        }

        // 3. Firmlink canonical roots
        observations.append(DuplicateScanObservation(
            path: "/Applications vs /System/Volumes/Data/Applications",
            primaryScanner: "ApplicationsStorageAnalyzer (/Applications)",
            secondaryScanner: "StoragePathNormalizer",
            relationship: "Firmlink alias normalized to /Applications"
        ))

        return observations
    }

    /// Finds high-density subtrees and application packages across scanned trees.
    static func findHeaviestSubtrees(
        from rootNodes: [StorageNode],
        limit: Int = 20
    ) -> [SlowestSubtreeRecord] {
        var records: [SlowestSubtreeRecord] = []

        for root in rootNodes {
            inspectNode(root, isRoot: true, records: &records)
        }

        return records.sorted { $0.totalEntries > $1.totalEntries }.prefix(limit).map { $0 }
    }

    private static func inspectNode(
        _ node: StorageNode,
        isRoot: Bool,
        records: inout [SlowestSubtreeRecord]
    ) {
        let isApp = node.name.hasSuffix(".app") || node.name.hasSuffix(".framework") || node.name.hasSuffix(".bundle")
        let isHighDensityFolder = !isRoot && (node.name == "node_modules" || node.name == ".git" || node.name == "Pods" || node.name == "DerivedData" || node.name == "venv" || node.name == ".venv" || node.name == "target")

        if !isRoot && (isApp || isHighDensityFolder || node.children.count > 50) {
            let metrics = StorageScanMetrics.compute(from: node)
            if metrics.totalEntries >= 100 {
                records.append(SlowestSubtreeRecord(
                    path: node.absolutePath,
                    totalEntries: metrics.totalEntries,
                    directoryCount: metrics.directoryCount,
                    fileCount: metrics.fileCount,
                    allocatedBytes: metrics.allocatedBytes,
                    isPackageOrApp: isApp
                ))
            }
        }

        if !isRoot && isApp {
            // Do not recurse deeper into apps for candidate ranking
            return
        }

        for child in node.children where child.itemType == .directory {
            inspectNode(child, isRoot: false, records: &records)
        }
    }

    static func printDebugReport(_ report: StorageAnalysisPerformanceReport) {
        #if DEBUG
        print(report.formattedDebugString())
        #endif
    }
}

extension String {
    func leftPadded(toLength length: Int, withPad pad: Character = " ") -> String {
        guard count < length else { return self }
        return String(repeating: pad, count: length - count) + self
    }
}

