import Darwin
import Foundation

/// Read-only diagnostic safety net checker that audits immediate children of
/// `/System/Volumes/Data` to ensure no measurable regions are omitted.
///
/// This checker performs shallow directory inspection only. It never modifies
/// any file, never follows symlinks, and reports ownership status deterministically.
struct DataVolumeTopLevelSafetyNetChecker: Sendable {
    private static let defaultDataVolumeURL = URL(fileURLWithPath: "/System/Volumes/Data", isDirectory: true)

    private static let canonicalAnalyzerOwners: [String: (StorageCanonicalRoot, StorageAnalyzerStage)] = [
        "Applications": (.applications, .applications),
        "/Applications": (.applications, .applications),
        "Users": (.userHomeVisibleStorage, .userHomeStorage),
        "/Users": (.userHomeVisibleStorage, .userHomeStorage),
        "Library": (.systemLibrary, .systemLibrary),
        "/Library": (.systemLibrary, .systemLibrary),
        "private": (.privateStorage, .privateStorage),
        "/private": (.privateStorage, .privateStorage),
        "opt": (.opt, .developerSystemStorage),
        "/opt": (.opt, .developerSystemStorage),
        "usr": (.usrLocal, .developerSystemStorage),
        "/usr": (.usrLocal, .developerSystemStorage),
    ]

    private static let firmlinkAliases: Set<String> = [
        "var",
        "/var",
        "etc",
        "/etc",
        "tmp",
        "/tmp",
        "bin",
        "/bin",
        "sbin",
        "/sbin",
        "home",
        "/home",
        "net",
        "/net",
        "dev",
        "/dev",
    ]

    private static let intentionallyNonAdditive: Set<String> = [
        "System",
        "/System",
        "Volumes",
        "/Volumes",
        ".Spotlight-V100",
        "/.Spotlight-V100",
        ".DocumentRevisions-V100",
        "/.DocumentRevisions-V100",
        ".fseventsd",
        "/.fseventsd",
        ".Trashes",
        "/.Trashes",
        ".PKInstallSandboxManager",
        "/.PKInstallSandboxManager",
        ".PKInstallSandboxManager-SystemSoftware",
        "/.PKInstallSandboxManager-SystemSoftware",
    ]

    private let dataVolumeURL: URL

    init(dataVolumeURL: URL = DataVolumeTopLevelSafetyNetChecker.defaultDataVolumeURL) {
        self.dataVolumeURL = dataVolumeURL
    }

    func audit(reconciliationReport: StorageReconciliationReport) -> DataVolumeTopLevelSafetyNetReport {
        guard let directory = opendir(dataVolumeURL.path) else {
            return DataVolumeTopLevelSafetyNetReport(
                checkedDirectoryPath: dataVolumeURL.path,
                entries: [],
                totalEntriesCount: 0,
                unownedEntriesCount: 0,
                isFullyCovered: true
            )
        }
        defer { closedir(directory) }

        var entries: [DataVolumeTopLevelSafetyNetEntry] = []

        while true {
            Darwin.errno = 0
            guard let entry = readdir(directory) else { break }

            var nameBuffer = entry.pointee.d_name
            let capacity = MemoryLayout.size(ofValue: nameBuffer)
            let name = withUnsafePointer(to: &nameBuffer) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != ".." else { continue }

            let originalPath = (dataVolumeURL.path as NSString).appendingPathComponent(name)
            let normalized = StoragePathNormalizer.normalize(originalPath)

            // Determine allocated size if possible
            var statInfo = stat()
            let allocatedBytes: Int64?
            if lstat(originalPath, &statInfo) == 0 {
                allocatedBytes = Int64(statInfo.st_blocks) * 512
            } else {
                allocatedBytes = nil
            }

            let classifiedEntry = classify(
                name: name,
                originalPath: originalPath,
                normalizedPath: normalized,
                allocatedBytes: allocatedBytes,
                reconciliationReport: reconciliationReport
            )
            entries.append(classifiedEntry)
        }

        entries.sort { lhs, rhs in
            if (lhs.allocatedBytes ?? 0) != (rhs.allocatedBytes ?? 0) {
                return (lhs.allocatedBytes ?? 0) > (rhs.allocatedBytes ?? 0)
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        let unownedCount = entries.filter { $0.ownershipStatus == .unownedPotentialCoverageGap }.count

        return DataVolumeTopLevelSafetyNetReport(
            checkedDirectoryPath: dataVolumeURL.path,
            entries: entries,
            totalEntriesCount: entries.count,
            unownedEntriesCount: unownedCount,
            isFullyCovered: unownedCount == 0
        )
    }

    private func classify(
        name: String,
        originalPath: String,
        normalizedPath: String,
        allocatedBytes: Int64?,
        reconciliationReport: StorageReconciliationReport
    ) -> DataVolumeTopLevelSafetyNetEntry {
        // 1. Check canonical analyzers
        if let (root, stage) = Self.canonicalAnalyzerOwners[normalizedPath] ?? Self.canonicalAnalyzerOwners[name] {
            return DataVolumeTopLevelSafetyNetEntry(
                originalPath: originalPath,
                normalizedPath: normalizedPath,
                name: name,
                ownershipStatus: .ownedByCanonicalAnalyzer,
                owningAnalyzerStage: stage,
                canonicalOwner: root,
                allocatedBytes: allocatedBytes,
                isFilesystemAdditive: true,
                reason: "Owned and measured by canonical analyzer stage \(stage.rawValue)."
            )
        }

        // 2. Check intentionally non-additive system paths
        if Self.intentionallyNonAdditive.contains(name) || Self.intentionallyNonAdditive.contains(originalPath) || Self.intentionallyNonAdditive.contains(normalizedPath) {
            return DataVolumeTopLevelSafetyNetEntry(
                originalPath: originalPath,
                normalizedPath: normalizedPath,
                name: name,
                ownershipStatus: .intentionallyNonAdditive,
                owningAnalyzerStage: nil,
                canonicalOwner: nil,
                allocatedBytes: allocatedBytes,
                isFilesystemAdditive: false,
                reason: "Intentionally non-additive system-managed metadata or mount root."
            )
        }

        // 3. Check hidden data roots
        if name.hasPrefix(".") {
            return DataVolumeTopLevelSafetyNetEntry(
                originalPath: originalPath,
                normalizedPath: normalizedPath,
                name: name,
                ownershipStatus: .ownedByCanonicalAnalyzer,
                owningAnalyzerStage: .dataVolumeHiddenStorage,
                canonicalOwner: .dataVolumeHiddenStorage,
                allocatedBytes: allocatedBytes,
                isFilesystemAdditive: true,
                reason: "Owned by dataVolumeHiddenStorage analyzer."
            )
        }

        // 4. Check firmlink aliases
        if Self.firmlinkAliases.contains(normalizedPath) || Self.firmlinkAliases.contains(name) || Self.firmlinkAliases.contains("/" + name) {
            return DataVolumeTopLevelSafetyNetEntry(
                originalPath: originalPath,
                normalizedPath: normalizedPath,
                name: name,
                ownershipStatus: .firmlinkAlias,
                owningAnalyzerStage: .privateStorage,
                canonicalOwner: .privateStorage,
                allocatedBytes: allocatedBytes,
                isFilesystemAdditive: false,
                reason: "Firmlink alias normalizing to /private standard location."
            )
        }

        // 5. Check coverage expansion
        let candidateMatch = reconciliationReport.analyzerResults.coverageExpansion?.candidates.first {
            $0.originalPath == originalPath || $0.normalizedPath == normalizedPath || $0.name == name
        }

        if let candidate = candidateMatch, candidate.status.isMeasuredOrPartial {
            return DataVolumeTopLevelSafetyNetEntry(
                originalPath: originalPath,
                normalizedPath: normalizedPath,
                name: name,
                ownershipStatus: .ownedByCoverageExpansion,
                owningAnalyzerStage: .coverageExpansion,
                canonicalOwner: .additionalCoverageGap,
                allocatedBytes: candidate.allocatedBytes ?? allocatedBytes,
                isFilesystemAdditive: candidate.contributesToExplainedBytes,
                reason: "Discovered and measured by coverage expansion pass."
            )
        }

        // 6. Otherwise: unowned potential gap
        return DataVolumeTopLevelSafetyNetEntry(
            originalPath: originalPath,
            normalizedPath: normalizedPath,
            name: name,
            ownershipStatus: .unownedPotentialCoverageGap,
            owningAnalyzerStage: nil,
            canonicalOwner: nil,
            allocatedBytes: allocatedBytes,
            isFilesystemAdditive: false,
            reason: "Top-level Data volume entry not owned by canonical analyzers or coverage expansion."
        )
    }
}
