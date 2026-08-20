import Foundation

/// Capacity facts supplied by Foundation for one mounted volume.
///
/// `purgeableEstimate` is intentionally derived from Apple's important-usage
/// capacity rather than treated as guaranteed reclaimable storage.
struct VolumeCapacityStatistics: Hashable, Codable, Sendable {
    let totalCapacity: Int64?
    let availableCapacity: Int64?
    let usedCapacity: Int64?
    let availableCapacityForImportantUsage: Int64?
    let availableCapacityForOpportunisticUsage: Int64?
    let purgeableEstimate: Int64?
    let volumeName: String?
    let volumeIdentifier: String?
    let filesystemDescription: String?
    let mountPoint: String
}

enum VolumeStatisticsReadIssueKind: String, Codable, Sendable {
    case filesystemAttributesUnavailable
    case resourceValuesUnavailable
    case capacityUnavailable
}

struct VolumeStatisticsReadIssue: Hashable, Codable, Sendable {
    let kind: VolumeStatisticsReadIssueKind
    let message: String
}

struct VolumeStatisticsReadResult: Hashable, Codable, Sendable {
    let statistics: VolumeCapacityStatistics
    let issues: [VolumeStatisticsReadIssue]
}

/// Shared, read-only volume-capacity calculation used by the existing disk
/// summary and specialized storage analyzers.
struct VolumeStatisticsProvider {
    static func read(at volumeURL: URL) -> VolumeStatisticsReadResult {
        let standardizedURL = volumeURL.standardizedFileURL
        var issues: [VolumeStatisticsReadIssue] = []
        var attributeTotal: Int64?
        var attributeAvailable: Int64?

        do {
            let attributes = try FileManager.default.attributesOfFileSystem(
                forPath: standardizedURL.path
            )
            attributeTotal = int64(attributes[.systemSize])
            attributeAvailable = int64(attributes[.systemFreeSize])
        } catch {
            issues.append(.init(
                kind: .filesystemAttributesUnavailable,
                message: "Filesystem capacity attributes are unavailable for this volume."
            ))
        }

        var resourceTotal: Int64?
        var resourceAvailable: Int64?
        var importantAvailable: Int64?
        var opportunisticAvailable: Int64?
        var volumeName: String?
        var volumeIdentifier: String?
        var filesystemDescription: String?

        do {
            let values = try standardizedURL.resourceValues(forKeys: [
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeAvailableCapacityForOpportunisticUsageKey,
                .volumeNameKey,
                .volumeUUIDStringKey,
                .volumeLocalizedFormatDescriptionKey,
            ])
            resourceTotal = values.volumeTotalCapacity.map(Int64.init)
            resourceAvailable = values.volumeAvailableCapacity.map(Int64.init)
            importantAvailable = values.volumeAvailableCapacityForImportantUsage
            opportunisticAvailable = values.volumeAvailableCapacityForOpportunisticUsage
            volumeName = values.volumeName
            volumeIdentifier = values.volumeUUIDString
            filesystemDescription = values.volumeLocalizedFormatDescription
        } catch {
            issues.append(.init(
                kind: .resourceValuesUnavailable,
                message: "Foundation volume resource values are unavailable."
            ))
        }

        let total = nonnegative(resourceTotal) ?? nonnegative(attributeTotal)
        let available = nonnegative(resourceAvailable) ?? nonnegative(attributeAvailable)
        let statistics = calculate(
            totalCapacity: total,
            availableCapacity: available,
            availableCapacityForImportantUsage: nonnegative(importantAvailable),
            availableCapacityForOpportunisticUsage: nonnegative(opportunisticAvailable),
            volumeName: volumeName,
            volumeIdentifier: volumeIdentifier,
            filesystemDescription: filesystemDescription,
            mountPoint: standardizedURL.path
        )

        if statistics.totalCapacity == nil || statistics.availableCapacity == nil {
            issues.append(.init(
                kind: .capacityUnavailable,
                message: "Complete total and available capacity values are unavailable."
            ))
        }

        return VolumeStatisticsReadResult(statistics: statistics, issues: issues)
    }

    /// Pure calculation entry point used by synthetic tests and callers that
    /// already obtained capacity values from another stable API.
    static func calculate(
        totalCapacity: Int64?,
        availableCapacity: Int64?,
        availableCapacityForImportantUsage: Int64?,
        availableCapacityForOpportunisticUsage: Int64? = nil,
        volumeName: String? = nil,
        volumeIdentifier: String? = nil,
        filesystemDescription: String? = nil,
        mountPoint: String = "/"
    ) -> VolumeCapacityStatistics {
        let total = nonnegative(totalCapacity)
        let available = nonnegative(availableCapacity)
        let used: Int64?
        if let total, let available {
            used = max(0, total - min(total, available))
        } else {
            used = nil
        }

        let purgeable: Int64?
        if let important = nonnegative(availableCapacityForImportantUsage),
           let available {
            purgeable = max(0, important - available)
        } else {
            purgeable = nil
        }

        return VolumeCapacityStatistics(
            totalCapacity: total,
            availableCapacity: available,
            usedCapacity: used,
            availableCapacityForImportantUsage: nonnegative(
                availableCapacityForImportantUsage
            ),
            availableCapacityForOpportunisticUsage: nonnegative(
                availableCapacityForOpportunisticUsage
            ),
            purgeableEstimate: purgeable,
            volumeName: volumeName,
            volumeIdentifier: volumeIdentifier,
            filesystemDescription: filesystemDescription,
            mountPoint: mountPoint
        )
    }
}

private extension VolumeStatisticsProvider {
    static func nonnegative(_ value: Int64?) -> Int64? {
        guard let value, value >= 0 else { return nil }
        return value
    }

    static func int64(_ value: Any?) -> Int64? {
        if let value = value as? NSNumber { return value.int64Value }
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        return nil
    }
}
