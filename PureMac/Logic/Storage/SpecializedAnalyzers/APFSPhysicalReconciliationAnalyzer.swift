import Darwin
import Foundation

/// Read-only analyzer that physically reconciles APFS container-level storage,
/// sibling APFS volumes, target Data-volume physical allocation, snapshots,
/// and filesystem-attributed allocated bytes.
struct APFSPhysicalReconciliationAnalyzer: Sendable {
    typealias CommandRunner = @Sendable (APFSCommandRequest) async -> APFSCommandResult

    static let diskutilURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
    static let defaultDataVolumeURL = URL(fileURLWithPath: "/System/Volumes/Data", isDirectory: true)

    private let dataVolumeURL: URL
    private let commandRunner: CommandRunner

    init(
        dataVolumeURL: URL = APFSPhysicalReconciliationAnalyzer.defaultDataVolumeURL,
        commandRunner: @escaping CommandRunner = {
            await APFSStorageAnalyzer.runReadOnlyCommand($0)
        }
    ) {
        self.dataVolumeURL = dataVolumeURL.standardizedFileURL
        self.commandRunner = commandRunner
    }

    func analyze(
        reconciliationReport: StorageReconciliationReport
    ) async -> APFSPhysicalReconciliationReport {
        guard !Task.isCancelled else {
            return .empty
        }

        var issues: [APFSStorageIssue] = []
        var evidenceSources: [String] = ["VolumeStatisticsProvider", "FileTreeScanner"]

        // 1. Query diskutil apfs list -plist for complete container architecture
        let apfsListResult = await commandRunner(Self.apfsListRequest())
        evidenceSources.append("diskutil apfs list -plist")

        var containerEvidence: APFSContainerEvidence?
        var targetVolumeEvidence: APFSVolumeEvidence?

        if let commandIssue = Self.commandIssue(apfsListResult, source: "diskutil-apfs-list") {
            issues.append(commandIssue)
        } else if let parsedContainers = Self.parseAPFSContainers(apfsListResult.stdout) {
            // Find container containing the Data volume or root
            let (matchedContainer, matchedVolume) = Self.resolveTargetContainerAndVolume(
                from: parsedContainers,
                dataVolumePath: dataVolumeURL.path
            )
            containerEvidence = matchedContainer
            targetVolumeEvidence = matchedVolume
        } else {
            issues.append(APFSStorageIssue(
                kind: .malformedPlist,
                message: "Disk Utility returned malformed APFS container list.",
                source: "diskutil-apfs-list"
            ))
        }

        // 2. Query diskutil info -plist for the Data volume specifically if missing
        if targetVolumeEvidence == nil || targetVolumeEvidence?.capacityInUseBytes == nil {
            let infoResult = await commandRunner(Self.diskInfoRequest(for: dataVolumeURL))
            evidenceSources.append("diskutil info -plist \(dataVolumeURL.path)")

            if let commandIssue = Self.commandIssue(infoResult, source: "diskutil-info-data") {
                issues.append(commandIssue)
            } else if let parsed = APFSStorageAnalyzer.parseDiskInfo(infoResult.stdout) {
                targetVolumeEvidence = APFSVolumeEvidence(
                    name: parsed.metadata.name ?? "mac - Data",
                    mountPoint: parsed.metadata.mountPoint ?? dataVolumeURL.path,
                    deviceIdentifier: parsed.metadata.volumeIdentifier ?? "disk3s1",
                    volumeUUID: parsed.metadata.volumeUUID,
                    volumeGroupUUID: parsed.metadata.volumeGroupIdentifier,
                    roles: ["Data"],
                    capacityInUseBytes: parsed.metadata.totalCapacity,
                    isEncrypted: true,
                    isSealed: false,
                    isWritable: true
                )
            }
        }

        // 3. Collect Snapshot Evidence
        let existingSnapshots = reconciliationReport.analyzerResults.apfsStorage?.snapshots ?? []
        let snapshotBytes = existingSnapshots.compactMap(\.size).reduce(Int64(0), +)
        let snapshotEvidence = APFSSnapshotEvidence(
            snapshotCount: existingSnapshots.count,
            totalReportedSnapshotBytes: snapshotBytes > 0 ? snapshotBytes : nil,
            snapshots: existingSnapshots
        )
        if !existingSnapshots.isEmpty {
            evidenceSources.append("diskutil apfs listSnapshots")
        }

        // 4. Collect System-Managed Storage Evidence
        let attribution = reconciliationReport.attributionReport
        let vmVolumeBytes = containerEvidence?.volumes.first { $0.role.lowercased() == "vm" }?.capacityInUseBytes
        let systemManaged = APFSSystemManagedEvidence(
            vmFootprintBytes: attribution?.vmFootprintBytes,
            swapFileBytes: attribution?.attributionItems.first { $0.id == "vm.swap" }?.allocatedBytes,
            sleepImageBytes: attribution?.sleepImageBytes,
            vmVolumeBytes: vmVolumeBytes,
            hasSystemIndexingDatabases: true,
            explanation: "System-managed virtual memory, sleep image, APFS VM volume, and Spotlight indexing databases."
        )

        // 5. Collect Protected System Storage Evidence
        let protectedItems = attribution?.attributionItems.filter { $0.category == .protectedSystemStorage } ?? []
        let protectedStorage = APFSProtectedStorageEvidence(
            protectedRegionCount: protectedItems.count,
            inaccessibleKnownLowerBoundBytes: reconciliationReport.inaccessibleKnownLowerBoundBytes,
            unreadablePathCount: reconciliationReport.unreadablePathCount,
            explanation: "macOS System Integrity Protection and TCC protected locations."
        )

        // 6. Calculate Physical Accounting Metrics
        let physicalVolumeUsed = reconciliationReport.usedCapacityBytes
            ?? containerEvidence?.totalCapacityBytes.flatMap { total in
                containerEvidence?.freeCapacityBytes.map { free in max(0, total - free) }
            }
        let dataVolumeInUse = targetVolumeEvidence?.capacityInUseBytes
        let filesystemAttributed = reconciliationReport.explainedAllocatedBytes
        let siblingVolumesBytes = containerEvidence?.totalSiblingVolumeBytesOutsideData ?? 0

        let physicalGap: Int64?
        if let physicalVolumeUsed {
            physicalGap = max(0, physicalVolumeUsed - filesystemAttributed)
        } else {
            physicalGap = nil
        }

        let dataVolumeInternalGap: Int64?
        if let dataVolumeInUse {
            dataVolumeInternalGap = max(0, dataVolumeInUse - filesystemAttributed)
        } else {
            dataVolumeInternalGap = nil
        }

        let purgeable = reconciliationReport.purgeableEstimateBytes

        let containerDiscrepancy: Int64?
        if let physicalVolumeUsed, let dataVolumeInUse {
            containerDiscrepancy = max(0, physicalVolumeUsed - (dataVolumeInUse + siblingVolumesBytes))
        } else {
            containerDiscrepancy = nil
        }

        let metrics = APFSPhysicalAccountingMetrics(
            physicalVolumeUsedBytes: physicalVolumeUsed,
            dataVolumePhysicalInUseBytes: dataVolumeInUse,
            filesystemAttributedBytes: filesystemAttributed,
            containerSiblingVolumesBytes: siblingVolumesBytes,
            physicalAccountingGapBytes: physicalGap,
            dataVolumeInternalGapBytes: dataVolumeInternalGap,
            purgeableEstimateBytes: purgeable,
            containerAccountingDiscrepancyBytes: containerDiscrepancy
        )

        // 7. Data Volume Internal Gap Investigation
        let dataVolumeInternalGapReport = DataVolumeInternalGapAnalyzer().analyze(
            reconciliationReport: reconciliationReport,
            dataVolumePhysicalInUse: dataVolumeInUse
        )

        // 8. Deterministic Status Classification
        let status = Self.classifyStatus(
            metrics: metrics,
            snapshotCount: existingSnapshots.count,
            purgeableBytes: purgeable ?? 0,
            protectedCount: protectedItems.count,
            unreadableCount: reconciliationReport.unreadablePathCount
        )

        // 9. Human-Readable Interpretation
        let interpretation = Self.buildInterpretation(
            metrics: metrics,
            targetVolume: targetVolumeEvidence,
            container: containerEvidence,
            snapshotCount: existingSnapshots.count,
            purgeableBytes: purgeable
        )

        var warnings: [String] = []
        if let discrepancy = containerDiscrepancy, discrepancy > 500_000_000 {
            warnings.append("APFS container reports \(Self.formatBytes(discrepancy)) in container metadata or unallocated extents.")
        }
        if existingSnapshots.count > 0 {
            warnings.append("APFS snapshots share extents with the active filesystem; reported snapshot sizes are non-additive.")
        }

        return APFSPhysicalReconciliationReport(
            status: status,
            metrics: metrics,
            targetVolume: targetVolumeEvidence,
            container: containerEvidence,
            snapshots: snapshotEvidence,
            systemManaged: systemManaged,
            protectedStorage: protectedStorage,
            dataVolumeInternalGap: dataVolumeInternalGapReport,
            humanReadableInterpretation: interpretation,
            warnings: warnings,
            evidenceSources: evidenceSources.uniqued(),
            wasCancelled: reconciliationReport.wasCancelled || Task.isCancelled,
            issues: issues
        )
    }

    // MARK: - Status Classification

    static func classifyStatus(
        metrics: APFSPhysicalAccountingMetrics,
        snapshotCount: Int,
        purgeableBytes: Int64,
        protectedCount: Int,
        unreadableCount: Int
    ) -> APFSPhysicalReconciliationStatus {
        guard let physicalGap = metrics.physicalAccountingGapBytes else {
            return .insufficientEvidence
        }

        // Trivial discrepancy tolerance: <= 50 MB
        if physicalGap <= 50_000_000 {
            return .fullyReconciled
        }

        // Mostly reconciled: <= 1 GB, or Data volume internal gap <= 500 MB
        if physicalGap <= 1_073_741_824 || (metrics.dataVolumeInternalGapBytes ?? Int64.max) <= 500_000_000 {
            return .mostlyReconciled
        }

        // APFS non-additive factors (snapshots, purgeable, clones)
        if snapshotCount > 0 || purgeableBytes > 1_000_000_000 || metrics.containerSiblingVolumesBytes > 0 {
            return .apfsNonAdditiveFactorsPresent
        }

        // Protected system storage barriers
        if protectedCount > 0 || unreadableCount > 0 {
            return .protectedSystemStoragePresent
        }

        return .physicalAccountingGapRemaining
    }

    // MARK: - Interpretation Builder

    static func buildInterpretation(
        metrics: APFSPhysicalAccountingMetrics,
        targetVolume: APFSVolumeEvidence?,
        container: APFSContainerEvidence?,
        snapshotCount: Int,
        purgeableBytes: Int64?
    ) -> String {
        guard let physicalUsed = metrics.physicalVolumeUsedBytes,
              let gap = metrics.physicalAccountingGapBytes else {
            return "Physical APFS container capacity information is currently unavailable."
        }

        let attributedStr = formatBytes(metrics.filesystemAttributedBytes)
        let usedStr = formatBytes(physicalUsed)
        let gapStr = formatBytes(gap)

        var parts: [String] = [
            "PureMac attributes \(attributedStr) to live filesystem objects, while macOS reports \(usedStr) physical usage across the shared APFS container pool."
        ]

        if metrics.containerSiblingVolumesBytes > 0 {
            let siblingStr = formatBytes(metrics.containerSiblingVolumesBytes)
            parts.append("Sibling APFS volumes in this container (including the sealed System volume, Preboot, Recovery, and VM) physically occupy \(siblingStr).")
        }

        if let internalGap = metrics.dataVolumeInternalGapBytes, internalGap > 0 {
            let internalStr = formatBytes(internalGap)
            parts.append("The remaining \(internalStr) on the Data volume consists of APFS allocation metadata, purgeable capacity, system databases, and protected locations.")
        }

        parts.append("The physical accounting gap of \(gapStr) is a structural filesystem characteristic and must not be treated as junk or automatically reclaimable.")
        return parts.joined(separator: " ")
    }

    private static func formatBytes(_ bytes: Int64?) -> String {
        guard let bytes else { return "Unknown" }
        return ByteCountFormatter.string(fromByteCount: max(bytes, 0), countStyle: .file)
    }

    // MARK: - Requests

    static func apfsListRequest() -> APFSCommandRequest {
        APFSCommandRequest(
            executableURL: diskutilURL,
            arguments: ["apfs", "list", "-plist"]
        )
    }

    static func diskInfoRequest(for url: URL) -> APFSCommandRequest {
        APFSCommandRequest(
            executableURL: diskutilURL,
            arguments: ["info", "-plist", url.path]
        )
    }

    static func commandIssue(_ result: APFSCommandResult, source: String) -> APFSStorageIssue? {
        if result.wasCancelled {
            return APFSStorageIssue(kind: .cancelled, message: "APFS query was cancelled.", source: source)
        }
        if result.terminationStatus != 0 {
            let msg = String(data: result.stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return APFSStorageIssue(
                kind: .commandFailed,
                message: msg?.isEmpty == false ? msg! : "Command failed with code \(result.terminationStatus)",
                source: source
            )
        }
        return nil
    }

    // MARK: - Plist Parsing

    struct ParsedContainerInfo: Sendable {
        let containerReference: String
        let containerUUID: String?
        let capacityCeiling: Int64?
        let capacityFree: Int64?
        let physicalStore: String?
        let volumes: [ParsedVolumeInfo]
    }

    struct ParsedVolumeInfo: Sendable {
        let name: String
        let deviceIdentifier: String
        let volumeUUID: String?
        let roles: [String]
        let capacityInUse: Int64?
        let isEncrypted: Bool
        let isFileVault: Bool
    }

    static func parseAPFSContainers(_ data: Data) -> [ParsedContainerInfo]? {
        guard let plist = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any] else {
            return nil
        }

        guard let rawContainers = plist["Containers"] as? [[String: Any]] else {
            return nil
        }

        return rawContainers.compactMap { dict -> ParsedContainerInfo? in
            guard let ref = dict["ContainerReference"] as? String else { return nil }
            let uuid = dict["APFSContainerUUID"] as? String
            let ceiling = (dict["CapacityCeiling"] as? NSNumber)?.int64Value
            let free = (dict["CapacityFree"] as? NSNumber)?.int64Value

            var physStore: String?
            if let stores = dict["PhysicalStores"] as? [[String: Any]], let first = stores.first {
                physStore = first["DeviceIdentifier"] as? String
            }

            let rawVolumes = (dict["Volumes"] as? [[String: Any]]) ?? []
            let volumes = rawVolumes.compactMap { vDict -> ParsedVolumeInfo? in
                let name = (vDict["Name"] as? String) ?? "Untitled"
                guard let devID = vDict["DeviceIdentifier"] as? String else { return nil }
                let vUUID = vDict["APFSVolumeUUID"] as? String
                let roles = (vDict["Roles"] as? [String]) ?? []
                let inUse = (vDict["CapacityInUse"] as? NSNumber)?.int64Value
                let enc = (vDict["Encryption"] as? Bool) ?? false
                let fv = (vDict["FileVault"] as? Bool) ?? false
                return ParsedVolumeInfo(
                    name: name,
                    deviceIdentifier: devID,
                    volumeUUID: vUUID,
                    roles: roles,
                    capacityInUse: inUse,
                    isEncrypted: enc,
                    isFileVault: fv
                )
            }

            return ParsedContainerInfo(
                containerReference: ref,
                containerUUID: uuid,
                capacityCeiling: ceiling,
                capacityFree: free,
                physicalStore: physStore,
                volumes: volumes
            )
        }
    }

    static func resolveTargetContainerAndVolume(
        from containers: [ParsedContainerInfo],
        dataVolumePath: String
    ) -> (APFSContainerEvidence?, APFSVolumeEvidence?) {
        for container in containers {
            // Find Data volume inside this container
            if let dataVol = container.volumes.first(where: {
                $0.roles.contains(where: { $0.caseInsensitiveCompare("Data") == .orderedSame })
                    || $0.name.localizedCaseInsensitiveContains("Data")
            }) {
                let siblingVolumes = container.volumes.map {
                    APFSSiblingVolumeEvidence(
                        name: $0.name,
                        role: $0.roles.joined(separator: ", "),
                        deviceIdentifier: $0.deviceIdentifier,
                        capacityInUseBytes: $0.capacityInUse
                    )
                }

                let siblingBytesOutsideData = container.volumes
                    .filter { $0.deviceIdentifier != dataVol.deviceIdentifier }
                    .compactMap(\.capacityInUse)
                    .reduce(Int64(0), +)

                let containerEv = APFSContainerEvidence(
                    containerReference: container.containerReference,
                    containerUUID: container.containerUUID,
                    totalCapacityBytes: container.capacityCeiling,
                    freeCapacityBytes: container.capacityFree,
                    physicalStoreIdentifier: container.physicalStore,
                    volumes: siblingVolumes,
                    totalSiblingVolumeBytesOutsideData: siblingBytesOutsideData
                )

                let volumeEv = APFSVolumeEvidence(
                    name: dataVol.name,
                    mountPoint: dataVolumePath,
                    deviceIdentifier: dataVol.deviceIdentifier,
                    volumeUUID: dataVol.volumeUUID,
                    volumeGroupUUID: nil,
                    roles: dataVol.roles,
                    capacityInUseBytes: dataVol.capacityInUse,
                    isEncrypted: dataVol.isEncrypted,
                    isSealed: false,
                    isWritable: true
                )

                return (containerEv, volumeEv)
            }
        }

        // Fallback: pick the largest container
        if let largest = containers.max(by: { ($0.capacityCeiling ?? 0) < ($1.capacityCeiling ?? 0) }) {
            let siblingVolumes = largest.volumes.map {
                APFSSiblingVolumeEvidence(
                    name: $0.name,
                    role: $0.roles.joined(separator: ", "),
                    deviceIdentifier: $0.deviceIdentifier,
                    capacityInUseBytes: $0.capacityInUse
                )
            }
            let containerEv = APFSContainerEvidence(
                containerReference: largest.containerReference,
                containerUUID: largest.containerUUID,
                totalCapacityBytes: largest.capacityCeiling,
                freeCapacityBytes: largest.capacityFree,
                physicalStoreIdentifier: largest.physicalStore,
                volumes: siblingVolumes,
                totalSiblingVolumeBytesOutsideData: 0
            )
            return (containerEv, nil)
        }

        return (nil, nil)
    }
}

private extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var set: Set<Element> = []
        return filter { set.insert($0).inserted }
    }
}
