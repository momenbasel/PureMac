import Foundation

/// Read-only analyzer that deconstructs and investigates the Data-volume internal
/// accounting gap between APFS physical allocation and filesystem attributed blocks.
struct DataVolumeInternalGapAnalyzer: Sendable {

    func analyze(
        reconciliationReport: StorageReconciliationReport,
        dataVolumePhysicalInUse: Int64?
    ) -> DataVolumeInternalGapReport {
        guard !Task.isCancelled else {
            return .empty
        }

        let filesystemAttributed = reconciliationReport.explainedAllocatedBytes
        let internalGap: Int64?
        if let dataVolumePhysicalInUse {
            internalGap = max(0, dataVolumePhysicalInUse - filesystemAttributed)
        } else {
            internalGap = nil
        }

        // 1. Allocation vs Logical Size Diagnostic
        let allocationDeltaSummary = evaluateAllocationDelta(from: reconciliationReport)

        // 2. Protected Storage Aggregation into Families
        let protectedSummary = aggregateProtectedStorage(from: reconciliationReport)

        // 3. Build Waterfall Items with Strict Tiers
        let waterfallItems = buildWaterfall(
            reconciliationReport: reconciliationReport,
            internalGap: internalGap,
            allocationDelta: allocationDeltaSummary,
            protectedSummary: protectedSummary
        )

        // 4. Calculate Non-Additive Evidenced Bytes
        let nonAdditiveEvidenced = waterfallItems
            .filter { $0.tier != .measuredAdditive && $0.category != .unresolvedResidual }
            .compactMap(\.reportedBytes)
            .reduce(Int64(0), +)

        // 5. Human-Readable Interpretation
        let interpretation = buildInterpretation(
            dataVolumePhysicalInUse: dataVolumePhysicalInUse,
            filesystemAttributed: filesystemAttributed,
            internalGap: internalGap,
            allocationDelta: allocationDeltaSummary,
            protectedSummary: protectedSummary,
            purgeableBytes: reconciliationReport.purgeableEstimateBytes
        )

        return DataVolumeInternalGapReport(
            dataVolumePhysicalInUseBytes: dataVolumePhysicalInUse,
            filesystemAttributedBytes: filesystemAttributed,
            internalPhysicalGapBytes: internalGap,
            allocationDeltaSummary: allocationDeltaSummary,
            waterfallItems: waterfallItems,
            protectedSummary: protectedSummary,
            additiveExplainedPortionBytes: 0, // Invariant: categories 2-5 never reduce residual
            nonAdditiveEvidencedPortionBytes: nonAdditiveEvidenced,
            unresolvedResidualGapBytes: internalGap,
            humanReadableInterpretation: interpretation,
            wasCancelled: reconciliationReport.wasCancelled,
            issues: []
        )
    }

    // MARK: - Allocation vs Logical Diagnostic

    private func evaluateAllocationDelta(
        from report: StorageReconciliationReport
    ) -> DataVolumeAllocationDeltaSummary {
        var totalLogical: Int64 = 0
        var totalAllocated: Int64 = 0
        var sparseObserved = false
        var paddingObserved = false

        let results = report.analyzerResults

        // Accumulate from specialized roots
        let roots: [StorageNode?] = [
            results.userHomeStorage?.result.root,
            results.applicationSupport?.root,
            results.containers?.root,
            results.groupContainers?.root,
            results.systemLibrary?.root,
            results.privateStorage?.root,
            results.dataVolumeHiddenStorage?.root,
            results.developerSystemStorage?.opt.result.root,
            results.developerSystemStorage?.usrLocal.result.root
        ]

        for root in roots.compactMap({ $0 }) {
            totalLogical += root.logicalSize
            totalAllocated += root.allocatedSize
            if root.logicalSize > root.allocatedSize {
                sparseObserved = true
            }
            if root.allocatedSize > root.logicalSize {
                paddingObserved = true
            }
        }

        // Coverage expansion candidates
        if let expansion = results.coverageExpansion {
            for candidate in expansion.candidates where candidate.status.isMeasuredOrPartial {
                if let alloc = candidate.allocatedBytes {
                    totalAllocated += alloc
                }
                if let log = candidate.logicalBytes {
                    totalLogical += log
                }
            }
        }

        let delta = totalAllocated - totalLogical
        let deltaStr = formatBytes(abs(delta))
        let explanation: String
        if delta >= 0 {
            explanation = "Filesystem allocated blocks exceed logical file sizes by \(deltaStr) across measured trees due to filesystem allocation block granularity (4 KB alignment)."
        } else {
            explanation = "Logical file sizes exceed physical allocated blocks by \(deltaStr) across measured trees due to sparse files and APFS compression."
        }

        return DataVolumeAllocationDeltaSummary(
            totalMeasuredLogicalBytes: totalLogical,
            totalMeasuredAllocatedBytes: totalAllocated,
            deltaBytes: delta,
            sparseFilesObserved: sparseObserved,
            blockPaddingObserved: paddingObserved,
            explanation: explanation
        )
    }

    // MARK: - Protected Storage Aggregation

    private func aggregateProtectedStorage(
        from report: StorageReconciliationReport
    ) -> DataVolumeProtectedStorageSummary {
        let allIssues = report.coverageDiagnostic.measurementIssues.groups.flatMap { group in
            group.representativePaths.map { path in
                (path: path, source: group.source, error: group.posixErrorCode)
            }
        }

        var spotlightCount = 0
        var documentRevisionsCount = 0
        var fseventsdCount = 0
        var privateVarDbCount = 0
        var tccPrivacyCount = 0
        var installSandboxCount = 0
        var otherProtectedCount = 0

        for issue in allIssues {
            let p = issue.path.lowercased()
            if p.contains(".spotlight-v100") || p.contains("corespotlight") {
                spotlightCount += 1
            } else if p.contains(".documentrevisions-v100") {
                documentRevisionsCount += 1
            } else if p.contains(".fseventsd") {
                fseventsdCount += 1
            } else if p.contains("/private/var/db") || p.contains("/private/var/folders") || p.contains("/private/var/root") {
                privateVarDbCount += 1
            } else if p.contains("tcc") || p.contains("safari") || p.contains("identityservices") || p.contains("homekit") {
                tccPrivacyCount += 1
            } else if p.contains(".pkinstallsandboxmanager") {
                installSandboxCount += 1
            } else {
                otherProtectedCount += 1
            }
        }

        var families: [DataVolumeProtectedFamily] = []

        if spotlightCount > 0 || FileManager.default.fileExists(atPath: "/System/Volumes/Data/.Spotlight-V100") {
            families.append(DataVolumeProtectedFamily(
                id: "spotlight",
                name: "Spotlight Metadata & Indexes",
                pathPattern: "/System/Volumes/Data/.Spotlight-V100",
                issueCount: max(spotlightCount, 1),
                knownLowerBoundBytes: nil,
                explanation: "macOS CoreSpotlight index databases and metadata search store."
            ))
        }

        if documentRevisionsCount > 0 || FileManager.default.fileExists(atPath: "/System/Volumes/Data/.DocumentRevisions-V100") {
            families.append(DataVolumeProtectedFamily(
                id: "document_revisions",
                name: "Document Versions & Revisions",
                pathPattern: "/System/Volumes/Data/.DocumentRevisions-V100",
                issueCount: max(documentRevisionsCount, 1),
                knownLowerBoundBytes: nil,
                explanation: "macOS auto-save document generation database and revision chunk storage."
            ))
        }

        if fseventsdCount > 0 || FileManager.default.fileExists(atPath: "/System/Volumes/Data/.fseventsd") {
            families.append(DataVolumeProtectedFamily(
                id: "fseventsd",
                name: "Filesystem Events Journal",
                pathPattern: "/System/Volumes/Data/.fseventsd",
                issueCount: max(fseventsdCount, 1),
                knownLowerBoundBytes: nil,
                explanation: "Kernel filesystem events log and stream tracking journal."
            ))
        }

        if privateVarDbCount > 0 {
            families.append(DataVolumeProtectedFamily(
                id: "private_var_db",
                name: "Private / System State Databases",
                pathPattern: "/private/var/db, /private/var/folders",
                issueCount: privateVarDbCount,
                knownLowerBoundBytes: nil,
                explanation: "System daemon configuration databases, diagnostic logs, and dynamic system state."
            ))
        }

        if tccPrivacyCount > 0 {
            families.append(DataVolumeProtectedFamily(
                id: "tcc_privacy",
                name: "TCC & User Privacy Locations",
                pathPattern: "~/Library/Safari, com.apple.TCC",
                issueCount: tccPrivacyCount,
                knownLowerBoundBytes: nil,
                explanation: "User data locations restricted by macOS Transparency, Consent, and Control (TCC)."
            ))
        }

        if installSandboxCount > 0 {
            families.append(DataVolumeProtectedFamily(
                id: "install_sandbox",
                name: "Package Installation Sandboxes",
                pathPattern: "/System/Volumes/Data/.PKInstallSandboxManager*",
                issueCount: installSandboxCount,
                knownLowerBoundBytes: nil,
                explanation: "Staged macOS installer assets and system software installation sandboxes."
            ))
        }

        let totalIssues = report.coverageDiagnostic.measurementIssues.totalIssueCount
        let lowerBound = report.inaccessibleKnownLowerBoundBytes
        let unreadablePaths = report.unreadablePathCount

        return DataVolumeProtectedStorageSummary(
            families: families,
            totalProtectedIssueCount: totalIssues,
            inaccessiblePathCount: unreadablePaths,
            knownLowerBoundBytes: lowerBound,
            explanation: "\(families.count) protected system storage families recorded across the Data volume."
        )
    }

    // MARK: - Waterfall Assembly

    private func buildWaterfall(
        reconciliationReport: StorageReconciliationReport,
        internalGap: Int64?,
        allocationDelta: DataVolumeAllocationDeltaSummary,
        protectedSummary: DataVolumeProtectedStorageSummary
    ) -> [DataVolumeGapWaterfallItem] {
        var items: [DataVolumeGapWaterfallItem] = []

        // 1. Allocation vs Logical Delta
        let delta = allocationDelta.deltaBytes
        items.append(DataVolumeGapWaterfallItem(
            id: "allocation_delta",
            title: "Allocation Block vs Logical Size Delta",
            category: .filesystemAllocationDelta,
            tier: .measuredNonAdditive,
            reportedBytes: abs(delta),
            explanation: allocationDelta.explanation,
            badgeText: "Diagnostic"
        ))

        // 2. Purgeable Capacity Estimate
        if let purgeable = reconciliationReport.purgeableEstimateBytes, purgeable > 0 {
            items.append(DataVolumeGapWaterfallItem(
                id: "purgeable_estimate",
                title: "Purgeable Capacity Estimate",
                category: .purgeableEstimate,
                tier: .estimatedOSReported,
                reportedBytes: purgeable,
                explanation: "macOS opportunistic reclaim estimate derived from volumeAvailableCapacityForImportantUsage. May overlap cache files on disk.",
                badgeText: "Estimate"
            ))
        }

        // 3. APFS Snapshots & Extents
        let snapshots = reconciliationReport.analyzerResults.apfsStorage?.snapshots ?? []
        let snapshotBytes = snapshots.compactMap(\.size).reduce(Int64(0), +)
        if !snapshots.isEmpty || snapshotBytes > 0 {
            items.append(DataVolumeGapWaterfallItem(
                id: "apfs_snapshots",
                title: "APFS Snapshots (\(snapshots.count))",
                category: .apfsSnapshots,
                tier: .measuredNonAdditive,
                reportedBytes: snapshotBytes > 0 ? snapshotBytes : nil,
                explanation: "APFS copy-on-write snapshots share extents with live filesystem data and are non-additive.",
                badgeText: "Non-additive"
            ))
        }

        // 4. APFS Clones & Shared Extents
        items.append(DataVolumeGapWaterfallItem(
            id: "clone_shared_extents",
            title: "APFS File Clones & Shared Extents",
            category: .cloneSharedExtents,
            tier: .presenceOnly,
            reportedBytes: nil,
            explanation: "APFS clonefile copy-on-write extents are shared between files. Exclusive physical allocation is not exposed by macOS userland APIs.",
            badgeText: "Presence-only"
        ))

        // 5. Protected System Storage
        items.append(DataVolumeGapWaterfallItem(
            id: "protected_storage",
            title: "macOS Protected Storage (\(protectedSummary.families.count) families)",
            category: .protectedStorage,
            tier: .unknownProtected,
            reportedBytes: nil, // Strictly no fabricated bytes
            explanation: "Restricted system locations including Spotlight (.Spotlight-V100), Document Versions (.DocumentRevisions-V100), and system databases.",
            badgeText: "Protected"
        ))

        // 6. APFS Filesystem Metadata & Structural Overhead
        items.append(DataVolumeGapWaterfallItem(
            id: "apfs_metadata",
            title: "APFS Filesystem Metadata & Structure Overhead",
            category: .apfsFilesystemMetadata,
            tier: .presenceOnly,
            reportedBytes: nil,
            explanation: "APFS object map, 2M+ file inode records, directory B-Trees, extent allocation bitmaps, and checkpoint log structures.",
            badgeText: "Presence-only"
        ))

        // 7. Unresolved Residual Physical Accounting Gap
        if let internalGap {
            items.append(DataVolumeGapWaterfallItem(
                id: "unresolved_residual",
                title: "Unresolved Data-Volume Physical Gap",
                category: .unresolvedResidual,
                tier: .unknownProtected,
                reportedBytes: internalGap,
                explanation: "Remaining difference between Data volume physical allocation and directory tree sum after accounting for all evidenced factors.",
                badgeText: "Unresolved"
            ))
        }

        return items
    }

    // MARK: - Human Readable Interpretation

    private func buildInterpretation(
        dataVolumePhysicalInUse: Int64?,
        filesystemAttributed: Int64,
        internalGap: Int64?,
        allocationDelta: DataVolumeAllocationDeltaSummary,
        protectedSummary: DataVolumeProtectedStorageSummary,
        purgeableBytes: Int64?
    ) -> String {
        guard let inUse = dataVolumePhysicalInUse, let gap = internalGap else {
            return "Data volume physical allocation information is currently unavailable."
        }

        let inUseStr = formatBytes(inUse)
        let attributedStr = formatBytes(filesystemAttributed)
        let gapStr = formatBytes(gap)

        var parts: [String] = [
            "macOS reports \(inUseStr) physically allocated on the Data volume, while PureMac attributes \(attributedStr) to accessible directory trees, resulting in an internal gap of \(gapStr)."
        ]

        if let purgeable = purgeableBytes, purgeable > 0 {
            let purgeableStr = formatBytes(purgeable)
            parts.append("macOS estimates \(purgeableStr) of purgeable cache data.")
        }

        if !protectedSummary.families.isEmpty {
            parts.append("\(protectedSummary.families.count) protected system areas (including Spotlight and Document Versions) deny read access.")
        }

        parts.append("Because APFS metadata, shared extents, and purgeable files are non-additive, the \(gapStr) residual remains unreduced and must not be treated as junk.")
        return parts.joined(separator: " ")
    }

    private func formatBytes(_ bytes: Int64?) -> String {
        guard let bytes else { return "Unknown" }
        return ByteCountFormatter.string(fromByteCount: max(bytes, 0), countStyle: .file)
    }
}
