import ArgumentParser
import Foundation
import TerminalUI

struct Optimize: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Review memory, storage, and local snapshot status.",
        discussion: """
          puremac optimize             Show memory and storage status
          puremac optimize ram         Show memory details
          puremac optimize purgeable   Explain APFS managed capacity
          puremac optimize snapshots   List local Time Machine snapshots
        These checks are read-only. PureMac does not force memory purges or promise
        that APFS managed capacity can be reclaimed on demand.
        """
    )

    @Argument(help: "View to show: status | ram | purgeable | snapshots.")
    var task: String?

    func validate() throws {
        guard let task else { return }
        guard ["status", "ram", "purgeable", "snapshots"].contains(task) else {
            throw ValidationError(
                "Unknown view '\(task)'. Use 'status', 'ram', 'purgeable', or 'snapshots'."
            )
        }
    }

    func run() throws {
        switch task ?? "status" {
        case "ram":
            Self.printPlain(Self.memorySheet(try SystemInfo.memoryStatus(), pressure: SystemInfo.memoryPressure()), withHeader: false)
        case "purgeable":
            Self.printPlain(Self.storageSheet(try SystemInfo.volumeStatus("/")), withHeader: false)
        case "snapshots":
            try showSnapshots()
        default:
            Self.printPlain(try Self.currentStatusSheet())
        }
    }

    static let statusTitle = "Mac status"
    static let statusFootnote = "No maintenance ran. Use `puremac clean --dry-run` to review removable files."

    static func currentStatusSheet() throws -> InfoSheet {
        let memory = try SystemInfo.memoryStatus()
        let volume = try SystemInfo.volumeStatus("/")
        return statusSheet(
            memory: memory,
            pressure: SystemInfo.memoryPressure(),
            volume: volume,
            machine: SystemInfo.machine()
        )
    }

    static func statusSheet(
        memory: MemoryStatus,
        pressure: MemoryPressure?,
        volume: VolumeStatus,
        machine: MachineInfo
    ) -> InfoSheet {
        InfoSheet(
            title: statusTitle,
            subtitle: "Read-only measurements from macOS",
            sections: [
                thisMacSection(machine),
                memorySection(memory, pressure: pressure),
                storageSection(volume),
            ],
            footnote: statusFootnote
        )
    }

    static func memorySheet(_ status: MemoryStatus, pressure: MemoryPressure?) -> InfoSheet {
        InfoSheet(
            title: memoryTitle,
            sections: [memorySection(status, pressure: pressure)],
            footnote: "No memory was purged. macOS reclaims inactive memory when applications need it."
        )
    }

    static func storageSheet(_ status: VolumeStatus) -> InfoSheet {
        InfoSheet(
            title: storageTitle,
            sections: [storageSection(status)],
            footnote: "No storage was changed. APFS managed capacity is an estimate controlled by macOS."
        )
    }

    static let memoryTitle = "Memory"
    static let storageTitle = "Storage"

    static func thisMacSection(_ machine: MachineInfo) -> InfoSection {
        let facts: [(String, String?)] = [
            ("Chip", machine.chip),
            ("Cores", machine.cores),
            ("Memory", machine.memory.map(ByteCount.memory)),
            ("macOS", machine.macOS),
            ("Model", machine.model),
            ("Uptime", formatUptime(machine.uptime)),
        ]
        return InfoSection(title: "This Mac", rows: facts.compactMap { label, value in value.map { metric(label, $0) } })
    }

    static func memorySection(_ status: MemoryStatus, pressure: MemoryPressure?) -> InfoSection {
        let used = ByteCount.memory(status.total - status.free)
        var rows: [InfoRow] = [
            .gauge(
                fraction: status.usedFraction,
                color: pressure?.color,
                text: "\(used) in use of \(ByteCount.memory(status.total))"
            )
        ]
        if let pressure {
            rows.append(.metric(label: "Pressure", value: [Span(pressure.label, TextStyle(color: pressure.color))], note: nil))
        }
        rows += [
            metric("Installed", ByteCount.memory(status.total)),
            metric("Free now", ByteCount.memory(status.free)),
            metric("Active", ByteCount.memory(status.active)),
            metric("Inactive", ByteCount.memory(status.inactive)),
            metric("Compressed", ByteCount.memory(status.compressed)),
            metric("Wired", ByteCount.memory(status.wired)),
        ]
        return InfoSection(title: memoryTitle, rows: rows)
    }

    static func storageSection(_ status: VolumeStatus) -> InfoSection {
        let color = status.freeColor
        var rows: [InfoRow] = [
            .gauge(
                fraction: status.usedFraction,
                color: color,
                text: "\(ByteCount.human(status.availableNow)) free of \(ByteCount.human(status.total))"
            ),
            .metric(label: "Free now", value: [Span(ByteCount.human(status.availableNow), TextStyle(color: color))], note: nil),
            metric("Total", ByteCount.human(status.total)),
            metric("Managed by macOS", ByteCount.human(status.systemManagedCapacity)),
        ]
        if status.systemManagedCapacity > 0 {
            let note = "Managed capacity may include purgeable files and is not guaranteed free space."
            rows.append(.message([Span(note, TextStyle(dim: true))]))
        }
        return InfoSection(title: storageTitle, rows: rows)
    }

    private static func metric(_ label: String, _ value: String) -> InfoRow {
        .metric(label: label, value: [Span(value)], note: nil)
    }

    private static func printPlain(_ sheet: InfoSheet, withHeader: Bool = true) {
        for line in sheet.plainLines(withHeader: withHeader) { print(line) }
    }

    static func parseLocalSnapshots(_ output: String) -> [String] {
        let snapshots = output.split(whereSeparator: \Character.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter(isValidLocalSnapshot)
        return Array(Set(snapshots)).sorted(by: >)
    }

    static func isValidLocalSnapshot(_ value: String) -> Bool {
        let prefix = "com.apple.TimeMachine."
        let suffix = ".local"
        guard value.hasPrefix(prefix), value.hasSuffix(suffix) else { return false }
        let start = value.index(value.startIndex, offsetBy: prefix.count)
        let end = value.index(value.endIndex, offsetBy: -suffix.count)
        let timestamp = String(value[start..<end])
        guard timestamp.count == 17 else { return false }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.isLenient = false
        guard let date = formatter.date(from: timestamp) else { return false }
        return formatter.string(from: date) == timestamp
    }

    static func formatUptime(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h \(minutes)m" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    private func showSnapshots() throws {
        let result = Shell.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"])
        guard result.status == 0 else {
            let detail = result.err.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ValidationError(detail.isEmpty ? "Could not list local Time Machine snapshots." : detail)
        }
        let snapshots = Self.parseLocalSnapshots(result.out)
        print(Term.bold("Local Time Machine snapshots"))
        if snapshots.isEmpty {
            print(Term.dim("  None reported by macOS."))
            return
        }
        for snapshot in snapshots {
            print("  \(snapshot)  " + Term.dim("size unavailable"))
        }
        print("")
        print(Term.dim("Read-only list. Snapshot storage is managed by Time Machine and macOS."))
    }
}
