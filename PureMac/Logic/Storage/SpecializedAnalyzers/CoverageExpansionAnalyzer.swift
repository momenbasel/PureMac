import Darwin
import Foundation

/// Discovers and measures meaningful filesystem regions currently omitted from
/// PureMac's specialized additive storage accounting without double-counting.
///
/// Stage A: Shallow Discovery enumerates immediate children cheaply and checks
/// ownership, symlink status, device boundaries, and system-protected classification.
/// Stage B: Targeted Recursive Measurement uses FileTreeScanner with bounded
/// concurrency to safely measure only eligible, unowned candidates.
struct CoverageExpansionAnalyzer: Sendable {
    private let homeDirectoryURL: URL
    private let dataVolumeURL: URL
    private let scanner: FileTreeScanner
    private let maxConcurrentDirectoryReads: Int
    private let extraExcludedCanonicalPaths: [String]

    private static let specializedLibraryNames: Set<String> = [
        "Application Support",
        "Containers",
        "Group Containers",
    ]

    private static let standardDataVolumeRootsToExclude: Set<String> = [
        "/Users",
        "/Library",
        "/private",
        "/Applications",
        "/opt",
        "/usr",
        "/usr/local",
        "/System",
        "/Volumes",
        "/dev",
        "/net",
        "/home",
        "/bin",
        "/sbin",
        "/etc",
        "/var",
        "/tmp",
        "/.DocumentRevisions-V100",
        "/.Spotlight-V100",
        "/.fseventsd",
        "/.Trashes",
        "/.PKInstallSandboxManager",
        "/.PKInstallSandboxManager-SystemSoftware",
    ]

    init(
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        dataVolumeURL: URL = URL(fileURLWithPath: "/System/Volumes/Data"),
        scanner: FileTreeScanner = FileTreeScanner(),
        maxConcurrentDirectoryReads: Int = 2,
        extraExcludedCanonicalPaths: [String] = []
    ) {
        self.homeDirectoryURL = homeDirectoryURL.standardizedFileURL
        self.dataVolumeURL = dataVolumeURL.standardizedFileURL
        self.scanner = scanner
        self.maxConcurrentDirectoryReads = max(1, min(maxConcurrentDirectoryReads, 4))
        self.extraExcludedCanonicalPaths = extraExcludedCanonicalPaths
    }

    func analyze() async -> StorageCoverageExpansionReport {
        guard !Task.isCancelled else {
            return .empty
        }

        // STAGE A: Shallow Discovery
        var discoveredCandidates: [StorageCoverageCandidate] = []
        var shallowIssues: [StorageScanIssue] = []

        let homeDevice = rootDeviceIdentifier(for: homeDirectoryURL.path)
        let dataVolumeDevice = rootDeviceIdentifier(for: dataVolumeURL.path)

        // 1. Discover ~/Library immediate children outside Application Support, Containers, Group Containers
        let libraryURL = homeDirectoryURL.appendingPathComponent("Library", isDirectory: true)
        let libraryCandidates = discoverChildren(
            in: libraryURL.path,
            scope: .userLibrary,
            expectedDevice: homeDevice,
            nameFilter: { !Self.specializedLibraryNames.contains($0) },
            issues: &shallowIssues
        )
        discoveredCandidates.append(contentsOf: libraryCandidates)

        // 2. Discover immediate hidden home entries (~/.cache, ~/.npm, etc.)
        let hiddenHomeCandidates = discoverChildren(
            in: homeDirectoryURL.path,
            scope: .hiddenHome,
            expectedDevice: homeDevice,
            nameFilter: { name in
                (name.hasPrefix(".") && name != "." && name != "..") || name == "Library"
            },
            issues: &shallowIssues
        ).filter { candidate in
            // Exclude ~/Library itself here as its children are discovered independently above
            let norm = StoragePathNormalizer.normalize(candidate.originalPath)
            let libraryNorm = StoragePathNormalizer.normalize(libraryURL.path)
            return norm != libraryNorm
        }
        discoveredCandidates.append(contentsOf: hiddenHomeCandidates)

        // 3. Discover top-level Data-volume roots not already owned
        if FileManager.default.fileExists(atPath: dataVolumeURL.path) {
            let dataVolumeCandidates = discoverChildren(
                in: dataVolumeURL.path,
                scope: .dataVolumeRoot,
                expectedDevice: dataVolumeDevice,
                nameFilter: { name in
                    let childPath = self.dataVolumeURL.appendingPathComponent(name).path
                    let normalized = StoragePathNormalizer.normalize(childPath)
                    return !Self.standardDataVolumeRootsToExclude.contains(normalized)
                        && !Self.standardDataVolumeRootsToExclude.contains(childPath)
                },
                issues: &shallowIssues
            )
            discoveredCandidates.append(contentsOf: dataVolumeCandidates)
        }

        if Task.isCancelled {
            return StorageCoverageExpansionReport(
                totalNewlyMeasuredBytes: 0,
                measuredCandidateCount: 0,
                excludedOverlapCount: 0,
                inaccessibleCandidateCount: 0,
                differentVolumeBoundaryCount: 0,
                failedCandidateCount: 0,
                candidates: discoveredCandidates.sorted { $0.normalizedPath < $1.normalizedPath },
                largestDiscoveredRegions: [],
                treeResults: [],
                wasCancelled: true,
                issues: shallowIssues
            )
        }

        // STAGE B: Targeted Recursive Measurement of eligible candidates
        let eligibleIndices = discoveredCandidates.indices.filter {
            discoveredCandidates[$0].status == .eligible
        }

        var treeResults: [StorageAnalysisResult] = []
        var finalCandidates = discoveredCandidates

        await withTaskGroup(of: (Int, StorageAnalysisResult?).self) { group in
            var iterator = eligibleIndices.makeIterator()
            let initialBatch = min(maxConcurrentDirectoryReads, eligibleIndices.count)

            for _ in 0..<initialBatch {
                if let index = iterator.next() {
                    let path = finalCandidates[index].originalPath
                    group.addTask {
                        let result = await scanner.scan(root: URL(fileURLWithPath: path))
                        return (index, result)
                    }
                }
            }

            while let (index, result) = await group.next() {
                if Task.isCancelled {
                    finalCandidates[index] = updateCandidateStatus(finalCandidates[index], status: .cancelled)
                } else if let result {
                    if result.wasCancelled {
                        finalCandidates[index] = updateCandidateStatus(finalCandidates[index], status: .cancelled)
                    } else {
                        finalCandidates[index] = StorageCoverageCandidate(
                            originalPath: finalCandidates[index].originalPath,
                            normalizedPath: finalCandidates[index].normalizedPath,
                            name: finalCandidates[index].name,
                            scope: finalCandidates[index].scope,
                            status: .measured,
                            allocatedBytes: max(result.root.allocatedSize, 0),
                            logicalBytes: max(result.root.logicalSize, 0),
                            issue: result.issues.first,
                            exclusionReason: nil,
                            contributesToExplainedBytes: true
                        )
                        treeResults.append(result)
                    }
                } else {
                    finalCandidates[index] = updateCandidateStatus(finalCandidates[index], status: .failed)
                }

                if !Task.isCancelled, let nextIndex = iterator.next() {
                    let path = finalCandidates[nextIndex].originalPath
                    group.addTask {
                        let result = await scanner.scan(root: URL(fileURLWithPath: path))
                        return (nextIndex, result)
                    }
                }
            }
        }

        finalCandidates.sort { $0.normalizedPath < $1.normalizedPath }

        let measuredCandidates = finalCandidates.filter { $0.status == .measured }
        let totalNewlyMeasuredBytes = measuredCandidates.reduce(Int64(0)) {
            $0 + ($1.allocatedBytes ?? 0)
        }

        let largestRegions = measuredCandidates
            .sorted { ($0.allocatedBytes ?? 0) > ($1.allocatedBytes ?? 0) }

        return StorageCoverageExpansionReport(
            totalNewlyMeasuredBytes: totalNewlyMeasuredBytes,
            measuredCandidateCount: measuredCandidates.count,
            excludedOverlapCount: finalCandidates.filter { $0.status == .excludedAlreadyAccounted || $0.status == .excludedNested }.count,
            inaccessibleCandidateCount: finalCandidates.filter { $0.status == .inaccessible || $0.status == .excludedProtectedSystem }.count,
            differentVolumeBoundaryCount: finalCandidates.filter { $0.status == .excludedDifferentVolume }.count,
            failedCandidateCount: finalCandidates.filter { $0.status == .failed }.count,
            candidates: finalCandidates,
            largestDiscoveredRegions: largestRegions,
            treeResults: treeResults,
            wasCancelled: Task.isCancelled,
            issues: shallowIssues + treeResults.flatMap(\.issues)
        )
    }

    // MARK: - Shallow Discovery Helpers

    private func discoverChildren(
        in parentPath: String,
        scope: StorageCoverageCandidateScope,
        expectedDevice: dev_t?,
        nameFilter: (String) -> Bool,
        issues: inout [StorageScanIssue]
    ) -> [StorageCoverageCandidate] {
        guard let directory = opendir(parentPath) else {
            let errorCode = Darwin.errno
            if errorCode != 0 && errorCode != ENOENT {
                issues.append(StorageScanIssue(
                    path: parentPath,
                    kind: errorCode == EACCES || errorCode == EPERM ? .permissionDenied : .unreadable,
                    message: "Failed to open directory: \(parentPath)",
                    posixErrorCode: errorCode
                ))
            }
            return []
        }
        defer { closedir(directory) }

        var candidates: [StorageCoverageCandidate] = []

        while true {
            Darwin.errno = 0
            guard let entry = readdir(directory) else {
                let errorCode = Darwin.errno
                if errorCode != 0 {
                    issues.append(StorageScanIssue(
                        path: parentPath,
                        kind: errorCode == EACCES || errorCode == EPERM ? .permissionDenied : .unreadable,
                        message: "Failed reading directory entry in \(parentPath)",
                        posixErrorCode: errorCode
                    ))
                }
                break
            }

            var nameBuffer = entry.pointee.d_name
            let capacity = MemoryLayout.size(ofValue: nameBuffer)
            let name = withUnsafePointer(to: &nameBuffer) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != ".." else { continue }
            guard nameFilter(name) else { continue }

            let childPath = parentPath == "/" ? "/\(name)" : "\(parentPath)/\(name)"
            let normalized = StoragePathNormalizer.normalize(childPath)

            var statInfo = stat()
            guard lstat(childPath, &statInfo) == 0 else {
                let errorCode = Darwin.errno
                let isPerm = errorCode == EACCES || errorCode == EPERM
                let issue = StorageScanIssue(
                    path: childPath,
                    kind: isPerm ? .permissionDenied : .metadataUnavailable,
                    message: "Cannot inspect metadata for \(childPath)",
                    posixErrorCode: errorCode
                )
                issues.append(issue)
                candidates.append(StorageCoverageCandidate(
                    originalPath: childPath,
                    normalizedPath: normalized,
                    name: name,
                    scope: scope,
                    status: isPerm ? .inaccessible : .failed,
                    allocatedBytes: nil,
                    logicalBytes: nil,
                    issue: issue,
                    exclusionReason: isPerm ? "Permission denied." : "Metadata unavailable.",
                    contributesToExplainedBytes: false
                ))
                continue
            }

            let mode = statInfo.st_mode
            let isSymlink = (mode & S_IFMT) == S_IFLNK

            if isSymlink {
                candidates.append(StorageCoverageCandidate(
                    originalPath: childPath,
                    normalizedPath: normalized,
                    name: name,
                    scope: scope,
                    status: .excludedSymlink,
                    allocatedBytes: nil,
                    logicalBytes: nil,
                    issue: nil,
                    exclusionReason: "Symbolic links are not followed.",
                    contributesToExplainedBytes: false
                ))
                continue
            }

            if let expectedDevice, statInfo.st_dev != expectedDevice {
                candidates.append(StorageCoverageCandidate(
                    originalPath: childPath,
                    normalizedPath: normalized,
                    name: name,
                    scope: scope,
                    status: .excludedDifferentVolume,
                    allocatedBytes: nil,
                    logicalBytes: nil,
                    issue: nil,
                    exclusionReason: "Located on a different filesystem volume boundary.",
                    contributesToExplainedBytes: false
                ))
                continue
            }

            if StoragePathNormalizer.isSystemProtectedLocation(normalized) {
                candidates.append(StorageCoverageCandidate(
                    originalPath: childPath,
                    normalizedPath: normalized,
                    name: name,
                    scope: scope,
                    status: .excludedProtectedSystem,
                    allocatedBytes: nil,
                    logicalBytes: nil,
                    issue: nil,
                    exclusionReason: "Protected system state; not traversed.",
                    contributesToExplainedBytes: false
                ))
                continue
            }

            let isAlreadyAccounted = extraExcludedCanonicalPaths.contains { excluded in
                StoragePathNormalizer.pathsOverlap(excluded, normalized)
            }
            if isAlreadyAccounted {
                candidates.append(StorageCoverageCandidate(
                    originalPath: childPath,
                    normalizedPath: normalized,
                    name: name,
                    scope: scope,
                    status: .excludedAlreadyAccounted,
                    allocatedBytes: nil,
                    logicalBytes: nil,
                    issue: nil,
                    exclusionReason: "Already accounted by specialized canonical root.",
                    contributesToExplainedBytes: false
                ))
                continue
            }

            candidates.append(StorageCoverageCandidate(
                originalPath: childPath,
                normalizedPath: normalized,
                name: name,
                scope: scope,
                status: .eligible,
                allocatedBytes: nil,
                logicalBytes: nil,
                issue: nil,
                exclusionReason: nil,
                contributesToExplainedBytes: false
            ))
        }

        return candidates
    }

    private func rootDeviceIdentifier(for path: String) -> dev_t? {
        var statInfo = stat()
        guard stat(path, &statInfo) == 0 else { return nil }
        return statInfo.st_dev
    }

    private func updateCandidateStatus(
        _ candidate: StorageCoverageCandidate,
        status: StorageCoverageCandidateStatus
    ) -> StorageCoverageCandidate {
        StorageCoverageCandidate(
            originalPath: candidate.originalPath,
            normalizedPath: candidate.normalizedPath,
            name: candidate.name,
            scope: candidate.scope,
            status: status,
            allocatedBytes: candidate.allocatedBytes,
            logicalBytes: candidate.logicalBytes,
            issue: candidate.issue,
            exclusionReason: candidate.exclusionReason,
            contributesToExplainedBytes: candidate.contributesToExplainedBytes
        )
    }
}
