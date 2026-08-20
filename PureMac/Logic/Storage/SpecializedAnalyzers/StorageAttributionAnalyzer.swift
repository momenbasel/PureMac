import Darwin
import Foundation

/// Read-only analyzer that attributes the composition of the writable Data volume
/// and explains the remaining unexplained storage gap at the Data-volume / APFS level.
struct StorageAttributionAnalyzer: Sendable {
    static let defaultDataVolumeURL = URL(fileURLWithPath: "/System/Volumes/Data", isDirectory: true)
    static let defaultVMDirectoryURL = URL(fileURLWithPath: "/private/var/vm", isDirectory: true)

    private let dataVolumeURL: URL
    private let vmDirectoryURL: URL

    init(
        dataVolumeURL: URL = StorageAttributionAnalyzer.defaultDataVolumeURL,
        vmDirectoryURL: URL = StorageAttributionAnalyzer.defaultVMDirectoryURL
    ) {
        self.dataVolumeURL = dataVolumeURL.standardizedFileURL
        self.vmDirectoryURL = vmDirectoryURL.standardizedFileURL
    }

    func analyze(
        reconciliationReport: StorageReconciliationReport
    ) async -> StorageUnexplainedAttributionReport {
        guard !Task.isCancelled else {
            return .empty
        }

        let volumeUsed = reconciliationReport.usedCapacityBytes
        let explained = reconciliationReport.explainedAllocatedBytes
        let unexplained = reconciliationReport.unexplainedBytes

        // 1. Data-volume top-level root attribution
        let dataVolumeRoots = inspectDataVolumeRoots(reconciliationReport: reconciliationReport)

        // 2. System-managed storage inspection (VM, Swap, Sleep Image)
        let vmInspection = inspectVirtualMemory()

        // 3. APFS snapshots and purgeable info
        let snapshots = reconciliationReport.analyzerResults.apfsStorage?.snapshots ?? []
        let snapshotFootprint = snapshots.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        let purgeable = reconciliationReport.purgeableEstimateBytes

        // 4. Build attribution items
        let attributionItems = buildAttributionItems(
            reconciliationReport: reconciliationReport,
            vmInspection: vmInspection,
            dataVolumeRoots: dataVolumeRoots,
            snapshotFootprint: snapshotFootprint > 0 ? snapshotFootprint : nil,
            purgeableEstimate: purgeable,
            unexplained: unexplained
        )

        // 5. Calculate residual truly unattributed storage
        let residual = calculateResidual(
            unexplained: unexplained,
            attributionItems: attributionItems
        )

        return StorageUnexplainedAttributionReport(
            volumeUsedBytes: volumeUsed,
            explainedAllocatedBytes: explained,
            unexplainedBytes: unexplained,
            residualUnattributedBytes: residual,
            dataVolumeRoots: dataVolumeRoots,
            attributionItems: attributionItems,
            vmFootprintBytes: vmInspection.totalVMBytes,
            sleepImageBytes: vmInspection.sleepImageBytes,
            snapshotFootprintBytes: snapshotFootprint > 0 ? snapshotFootprint : nil,
            purgeableEstimateBytes: purgeable,
            wasCancelled: reconciliationReport.wasCancelled || Task.isCancelled,
            issues: []
        )
    }

    // MARK: - Data-Volume Root Inspection

    private func inspectDataVolumeRoots(
        reconciliationReport: StorageReconciliationReport
    ) -> [DataVolumeRootAttribution] {
        let fileManager = FileManager.default
        let dataVolumePath = dataVolumeURL.path

        var dataVolumeDeviceID: dev_t = 0
        var statBuf = stat()
        if stat(dataVolumePath, &statBuf) == 0 {
            dataVolumeDeviceID = statBuf.st_dev
        }

        guard let enumerator = try? fileManager.contentsOfDirectory(
            at: dataVolumeURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .totalFileAllocatedSizeKey],
            options: []
        ) else {
            return defaultStandardRoots(reconciliationReport: reconciliationReport)
        }

        var results: [DataVolumeRootAttribution] = []

        for itemURL in enumerator {
            let originalPath = itemURL.path
            let name = itemURL.lastPathComponent
            let normalizedPath = StoragePathNormalizer.normalize(originalPath)

            var entryStat = stat()
            let statResult = lstat(originalPath, &entryStat)
            let isSymlink = statResult == 0 && ((entryStat.st_mode & S_IFMT) == S_IFLNK)
            let isDifferentVolume = statResult == 0 && dataVolumeDeviceID != 0 && entryStat.st_dev != dataVolumeDeviceID

            let isProtected = StoragePathNormalizer.isSystemProtectedLocation(originalPath)
                || StoragePathNormalizer.isSystemProtectedLocation(normalizedPath)
                || name == ".DocumentRevisions-V100"
                || name == ".Spotlight-V100"
                || name == ".fseventsd"
                || name == ".PKInstallSandboxManager"
                || name == ".PKInstallSandboxManager-SystemSoftware"

            let matchingContributions = reconciliationReport.filesystemContributions.filter {
                $0.normalizedPath == normalizedPath || StoragePathNormalizer.contains(parent: normalizedPath, child: $0.normalizedPath)
            }
            let uniqueBytes = matchingContributions
                .filter { $0.relationship == .canonicalUnique || $0.relationship == .externalSpecializedUnique }
                .reduce(Int64(0)) { $0 + $1.accountedAllocatedBytes }
            let observedBytes = matchingContributions.reduce(Int64(0)) { $0 + $1.observedAllocatedBytes }

            let (owner, stage) = identifyOwner(name: name, normalizedPath: normalizedPath)

            let classification: DataVolumeRegionClassification
            let explanation: String

            if isSymlink {
                classification = .intentionallyExcluded
                explanation = "Symbolic link pointing to a system location; contents are not traversed to avoid duplication."
            } else if isDifferentVolume {
                classification = .separateVolumeOrMount
                explanation = "Mount point or separate filesystem volume; isolated from Data-volume ledger."
            } else if isProtected && uniqueBytes == 0 && observedBytes == 0 {
                classification = .protectedUnreadable
                explanation = "Protected macOS system directory governed by System Integrity Protection (SIP) and privacy controls."
            } else if uniqueBytes > 0 {
                if owner == .additionalCoverageGap {
                    classification = .measuredByCoverageExpansion
                    explanation = "Discovered and measured during the storage coverage expansion pass."
                } else {
                    classification = .ownedByExistingAnalyzer
                    explanation = "Measured and accounted for by PureMac specialized storage analyzers."
                }
            } else if observedBytes > 0 {
                classification = .partiallyMeasured
                explanation = "Partially measured; some subpaths were excluded or owned by higher-level canonical roots."
            } else if isProtected {
                classification = .protectedUnreadable
                explanation = "Protected macOS location with restricted filesystem access."
            } else {
                classification = .unknown
                explanation = "Unattributed Data-volume root entry."
            }

            results.append(DataVolumeRootAttribution(
                originalPath: originalPath,
                normalizedPath: normalizedPath,
                name: name,
                classification: classification,
                canonicalOwner: owner,
                analyzerStage: stage,
                allocatedBytes: uniqueBytes > 0 ? uniqueBytes : (observedBytes > 0 ? observedBytes : nil),
                logicalBytes: nil,
                isFilesystemAdditive: classification == .ownedByExistingAnalyzer || classification == .measuredByCoverageExpansion,
                statusExplanation: explanation,
                isProtectedSystem: isProtected
            ))
        }

        // Add standard firmlinked top-level roots if they were not directly present in enumerator
        let existingNormalized = Set(results.map(\.normalizedPath))
        let standardEntries: [(name: String, path: String, owner: StorageCanonicalRoot, stage: StorageAnalyzerStage)] = [
            ("Users", "/Users", .userHomeVisibleStorage, .userHomeStorage),
            ("Library", "/Library", .systemLibrary, .systemLibrary),
            ("private", "/private", .privateStorage, .privateStorage),
            ("opt", "/opt", .opt, .developerSystemStorage),
            ("usr/local", "/usr/local", .usrLocal, .developerSystemStorage),
        ]

        for entry in standardEntries where !existingNormalized.contains(entry.path) {
            let matchingContributions = reconciliationReport.filesystemContributions.filter {
                $0.normalizedPath == entry.path || StoragePathNormalizer.contains(parent: entry.path, child: $0.normalizedPath)
            }
            let uniqueBytes = matchingContributions
                .filter { $0.relationship == .canonicalUnique || $0.relationship == .externalSpecializedUnique }
                .reduce(Int64(0)) { $0 + $1.accountedAllocatedBytes }

            results.append(DataVolumeRootAttribution(
                originalPath: entry.path,
                normalizedPath: entry.path,
                name: entry.name,
                classification: uniqueBytes > 0 ? .ownedByExistingAnalyzer : .unknown,
                canonicalOwner: entry.owner,
                analyzerStage: entry.stage,
                allocatedBytes: uniqueBytes > 0 ? uniqueBytes : nil,
                logicalBytes: nil,
                isFilesystemAdditive: true,
                statusExplanation: "Canonical macOS firmlink root on the writable Data volume.",
                isProtectedSystem: false
            ))
        }

        return results.sorted { ($0.allocatedBytes ?? 0) > ($1.allocatedBytes ?? 0) }
    }

    private func identifyOwner(
        name: String,
        normalizedPath: String
    ) -> (StorageCanonicalRoot?, StorageAnalyzerStage?) {
        switch normalizedPath {
        case "/Users":
            return (.userHomeVisibleStorage, .userHomeStorage)
        case "/Library":
            return (.systemLibrary, .systemLibrary)
        case "/Library/Application Support":
            return (.applicationSupport, .applicationSupport)
        case "/private":
            return (.privateStorage, .privateStorage)
        case "/opt":
            return (.opt, .developerSystemStorage)
        case "/usr/local":
            return (.usrLocal, .developerSystemStorage)
        default:
            break
        }

        if normalizedPath.hasPrefix("/System/Volumes/Data/.") || normalizedPath.hasPrefix("/.") {
            return (.dataVolumeHiddenStorage, .dataVolumeHiddenStorage)
        }
        if normalizedPath.hasPrefix("/private") {
            return (.privateStorage, .privateStorage)
        }
        if normalizedPath.hasPrefix("/Library") {
            return (.systemLibrary, .systemLibrary)
        }
        if normalizedPath.hasPrefix("/Users") {
            return (.userHomeVisibleStorage, .userHomeStorage)
        }
        return (.additionalCoverageGap, .coverageExpansion)
    }

    private func defaultStandardRoots(
        reconciliationReport: StorageReconciliationReport
    ) -> [DataVolumeRootAttribution] {
        let standardEntries: [(name: String, path: String, owner: StorageCanonicalRoot, stage: StorageAnalyzerStage)] = [
            ("Users", "/Users", .userHomeVisibleStorage, .userHomeStorage),
            ("Library", "/Library", .systemLibrary, .systemLibrary),
            ("private", "/private", .privateStorage, .privateStorage),
            ("opt", "/opt", .opt, .developerSystemStorage),
            ("usr/local", "/usr/local", .usrLocal, .developerSystemStorage),
            ("Hidden Data Roots", "/System/Volumes/Data", .dataVolumeHiddenStorage, .dataVolumeHiddenStorage)
        ]

        return standardEntries.map { entry in
            let matchingContributions = reconciliationReport.filesystemContributions.filter {
                $0.normalizedPath == entry.path || StoragePathNormalizer.contains(parent: entry.path, child: $0.normalizedPath)
            }
            let uniqueBytes = matchingContributions
                .filter { $0.relationship == .canonicalUnique || $0.relationship == .externalSpecializedUnique }
                .reduce(Int64(0)) { $0 + $1.accountedAllocatedBytes }

            return DataVolumeRootAttribution(
                originalPath: entry.path,
                normalizedPath: entry.path,
                name: entry.name,
                classification: uniqueBytes > 0 ? .ownedByExistingAnalyzer : .unknown,
                canonicalOwner: entry.owner,
                analyzerStage: entry.stage,
                allocatedBytes: uniqueBytes > 0 ? uniqueBytes : nil,
                logicalBytes: nil,
                isFilesystemAdditive: true,
                statusExplanation: "Canonical macOS root on Data volume.",
                isProtectedSystem: false
            )
        }
    }

    // MARK: - System-Managed Storage Inspection (VM / Swap / Sleep Image)

    private struct VMInspectionResult {
        let totalVMBytes: Int64?
        let swapBytes: Int64?
        let sleepImageBytes: Int64?
        let hasVMDirectory: Bool
    }

    private func inspectVirtualMemory() -> VMInspectionResult {
        let vmPath = vmDirectoryURL.path
        var totalBytes: Int64 = 0
        var swapBytes: Int64 = 0
        var sleepImageBytes: Int64 = 0
        var foundEntries = false

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: vmDirectoryURL,
            includingPropertiesForKeys: [.fileSizeKey, .totalFileAllocatedSizeKey],
            options: []
        ) else {
            // Check direct stat of /private/var/vm/sleepimage if directory enumeration is restricted
            let sleepImageURL = vmDirectoryURL.appendingPathComponent("sleepimage")
            var sleepStat = stat()
            if stat(sleepImageURL.path, &sleepStat) == 0 {
                let bytes = Int64(sleepStat.st_blocks) * 512
                return VMInspectionResult(
                    totalVMBytes: bytes,
                    swapBytes: nil,
                    sleepImageBytes: bytes,
                    hasVMDirectory: true
                )
            }
            return VMInspectionResult(totalVMBytes: nil, swapBytes: nil, sleepImageBytes: nil, hasVMDirectory: false)
        }

        for item in entries {
            foundEntries = true
            let name = item.lastPathComponent
            var itemStat = stat()
            if lstat(item.path, &itemStat) == 0 {
                let allocated = Int64(itemStat.st_blocks) * 512
                totalBytes += allocated
                if name.hasPrefix("swapfile") {
                    swapBytes += allocated
                } else if name == "sleepimage" {
                    sleepImageBytes += allocated
                }
            }
        }

        return VMInspectionResult(
            totalVMBytes: foundEntries ? totalBytes : nil,
            swapBytes: swapBytes > 0 ? swapBytes : nil,
            sleepImageBytes: sleepImageBytes > 0 ? sleepImageBytes : nil,
            hasVMDirectory: true
        )
    }

    // MARK: - Attribution Items Builder

    private func buildAttributionItems(
        reconciliationReport: StorageReconciliationReport,
        vmInspection: VMInspectionResult,
        dataVolumeRoots: [DataVolumeRootAttribution],
        snapshotFootprint: Int64?,
        purgeableEstimate: Int64?,
        unexplained: Int64?
    ) -> [StorageAttributionItem] {
        var items: [StorageAttributionItem] = []

        // Category 1: Measured Gaps (from Coverage Expansion)
        if let coverageReport = reconciliationReport.analyzerResults.coverageExpansion {
            for candidate in coverageReport.largestDiscoveredRegions where candidate.status == .measured {
                items.append(StorageAttributionItem(
                    id: "gap:\(candidate.normalizedPath)",
                    category: .measuredGaps,
                    name: candidate.name,
                    path: candidate.normalizedPath,
                    status: .measured,
                    allocatedBytes: candidate.allocatedBytes,
                    explanation: "Discovered and measured by storage coverage expansion (\(candidate.scope.rawValue)).",
                    isFilesystemAdditive: true
                ))
            }
        }

        // Category 2: Protected System Storage
        let protectedRoots = dataVolumeRoots.filter { $0.isProtectedSystem }
        for root in protectedRoots {
            items.append(StorageAttributionItem(
                id: "protected:\(root.normalizedPath)",
                category: .protectedSystemStorage,
                name: root.name,
                path: root.normalizedPath,
                status: root.allocatedBytes != nil ? .partial : .protectedUnreadable,
                allocatedBytes: root.allocatedBytes,
                explanation: root.statusExplanation,
                isFilesystemAdditive: root.isFilesystemAdditive
            ))
        }

        // Add prominent protected system subdirectories if known
        let protectedSubpaths: [(name: String, path: String, reason: String)] = [
            ("Audit Logs", "/private/var/audit", "Protected macOS security audit logs (EACCES/SIP)."),
            ("System Administrator State", "/private/var/root", "Protected root user state (EACCES/SIP)."),
            ("System Databases", "/private/var/db", "Protected macOS system databases and metadata."),
            ("Document Versions", "/System/Volumes/Data/.DocumentRevisions-V100", "macOS document revision history database."),
            ("Spotlight Index", "/System/Volumes/Data/.Spotlight-V100", "System-wide search and indexing database."),
            ("Filesystem Events", "/System/Volumes/Data/.fseventsd", "macOS filesystem change logs.")
        ]
        let existingItemPaths = Set(items.compactMap(\.path))
        for subpath in protectedSubpaths where !existingItemPaths.contains(subpath.path) {
            let matchingContributions = reconciliationReport.filesystemContributions.filter {
                $0.normalizedPath == subpath.path || StoragePathNormalizer.contains(parent: subpath.path, child: $0.normalizedPath)
            }
            let uniqueBytes = matchingContributions
                .filter { $0.relationship == .canonicalUnique || $0.relationship == .externalSpecializedUnique }
                .reduce(Int64(0)) { $0 + $1.accountedAllocatedBytes }
            let observedBytes = matchingContributions.reduce(Int64(0)) { $0 + $1.observedAllocatedBytes }

            items.append(StorageAttributionItem(
                id: "protected:\(subpath.path)",
                category: .protectedSystemStorage,
                name: subpath.name,
                path: subpath.path,
                status: uniqueBytes > 0 ? .partial : .protectedUnreadable,
                allocatedBytes: uniqueBytes > 0 ? uniqueBytes : (observedBytes > 0 ? observedBytes : nil),
                explanation: subpath.reason,
                isFilesystemAdditive: uniqueBytes > 0
            ))
        }

        // Category 3: System-Managed Storage (Virtual Memory, Sleep Image, Caches)
        if let swapBytes = vmInspection.swapBytes {
            items.append(StorageAttributionItem(
                id: "system:var-vm-swap",
                category: .systemManagedStorage,
                name: "Virtual Memory Swap",
                path: "/private/var/vm/swapfile*",
                status: .measured,
                allocatedBytes: swapBytes,
                explanation: "Active macOS virtual memory swap files allocated on disk.",
                isFilesystemAdditive: false
            ))
        }
        if let sleepBytes = vmInspection.sleepImageBytes {
            items.append(StorageAttributionItem(
                id: "system:var-vm-sleepimage",
                category: .systemManagedStorage,
                name: "Sleep Image",
                path: "/private/var/vm/sleepimage",
                status: .measured,
                allocatedBytes: sleepBytes,
                explanation: "Hibernation image written by macOS when the Mac goes to sleep.",
                isFilesystemAdditive: false
            ))
        }
        if let totalVM = vmInspection.totalVMBytes, vmInspection.swapBytes == nil && vmInspection.sleepImageBytes == nil {
            items.append(StorageAttributionItem(
                id: "system:var-vm",
                category: .systemManagedStorage,
                name: "Virtual Memory (/private/var/vm)",
                path: "/private/var/vm",
                status: .measured,
                allocatedBytes: totalVM,
                explanation: "macOS virtual memory swap and sleep image directory.",
                isFilesystemAdditive: false
            ))
        }

        // Category 4: APFS & Non-Additive Factors
        if let snapshotFootprint {
            items.append(StorageAttributionItem(
                id: "apfs:snapshots",
                category: .apfsAndNonAdditive,
                name: "APFS Local Snapshots",
                path: nil,
                status: .nonAdditive,
                allocatedBytes: snapshotFootprint,
                explanation: "Time Machine and OS update snapshots; copy-on-write data shares blocks with the live volume.",
                isFilesystemAdditive: false
            ))
        }
        if let purgeableEstimate {
            items.append(StorageAttributionItem(
                id: "apfs:purgeable",
                category: .apfsAndNonAdditive,
                name: "Purgeable Capacity",
                path: nil,
                status: .estimate,
                allocatedBytes: purgeableEstimate,
                explanation: "Estimated disk capacity that macOS can reclaim automatically when space is needed.",
                isFilesystemAdditive: false
            ))
        }
        items.append(StorageAttributionItem(
            id: "apfs:shared-extents",
            category: .apfsAndNonAdditive,
            name: "APFS Shared Extents & Metadata",
            path: nil,
            status: .nonAdditive,
            allocatedBytes: nil,
            explanation: "APFS block cloning, extent sharing, and container filesystem metadata overhead.",
            isFilesystemAdditive: false
        ))

        // Category 5: Still Unattributed
        let residual = calculateResidual(unexplained: unexplained, attributionItems: items)
        if let residual, residual > 0 {
            items.append(StorageAttributionItem(
                id: "unexplained:residual",
                category: .stillUnattributed,
                name: "Unattributed Residual",
                path: nil,
                status: .unknown,
                allocatedBytes: residual,
                explanation: "Remaining volume storage not yet attributed by measured or evidenced categories.",
                isFilesystemAdditive: false
            ))
        }

        return items
    }

    private func calculateResidual(
        unexplained: Int64?,
        attributionItems: [StorageAttributionItem]
    ) -> Int64? {
        guard let unexplained else { return nil }
        return max(unexplained, 0)
    }
}
