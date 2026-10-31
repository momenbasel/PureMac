import ArgumentParser
import Foundation
import TerminalUI

struct Clean: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Scan and remove developer caches, system junk, AI-tool junk, and Trash.",
        discussion: """
        With no category, scans all of: dev, junk, ai, trash.
          puremac clean            Scan everything, review, confirm
          puremac clean dev        Package-manager & build-tool caches only
          puremac clean junk        User logs & Xcode-generated junk only
          puremac clean ai          AI-tool caches & logs only
          puremac clean trash       Empty user + mounted-volume Trash

        Interactive review starts with every item unselected. \(Render.reviewHelp) --force removes the scanner's standard preselection without either prompt. --dry-run and --json never delete or open a selector.
        """
    )

    @Argument(help: "Category to clean: dev | junk | ai | trash. Omit to clean all.")
    var category: String?

    @Flag(name: .long, help: "Remove the scanner's standard preselection without review or confirmation.")
    var force = false

    @Flag(name: .customLong("dry-run"), help: "Scan and report only; never delete.")
    var dryRun = false

    @Flag(name: .long, help: "Emit machine-readable JSON and exit (never deletes).")
    var json = false

    @Flag(name: .long, help: "Use a numbered line-based selector instead of the fullscreen review.")
    var plain = false

    static let validIDs = ["dev", "junk", "ai", "trash"]

    func validate() throws {
        if let c = category, !Clean.validIDs.contains(c) {
            throw ValidationError("Unknown category '\(c)'. Use one of: \(Clean.validIDs.joined(separator: ", ")).")
        }
    }

    func run() throws {
        let mode = CleanupCommandPolicy.mode(
            force: force,
            dryRun: dryRun,
            json: json,
            plain: plain
        )
        guard mode != .unavailable else {
            throw ValidationError("Interactive review requires a terminal. Re-run with --force to remove the preselected items, or use --dry-run or --json for a read-only report.")
        }

        let ids = category.map { [$0] } ?? Clean.validIDs
        let ignore = try IgnoreStore(fileURL: AppPaths.ignoreFile)
        let scanning = "Scanning " + ids.map(Clean.title).joined(separator: ", ")
        let progress = ScanProgress.forMode(mode)
        if mode == .fullscreen {
            let labels = CleanupFlow.Labels(
                scanning: scanning,
                empty: Clean.emptyMessage,
                reviewTitle: "Choose items to clean",
                noun: "item"
            )
            let result = try CleanupFlow.run(labels: labels, ignore: ignore) { status, cancel in
                Clean.scan(ids: ids, ignore: ignore, progress: progress, status: status, cancel: cancel)
            }
            try CleanupFlow.finish(result, labels: labels)
            return
        }
        if !json {
            Term.err(Term.dim(scanning + " …"))
        }
        let cats = Clean.scan(ids: ids, ignore: ignore, progress: progress)

        if json {
            print(try JSONReport.string(cats))
            return
        }

        if cats.isEmpty {
            print(Term.green(Clean.emptyMessage))
            return
        }

        if dryRun {
            Render.scanResults(cats)
            Render.selectionLine(cats)
            let selected = cats.flatMap { $0.selectedItems }
            let out = Cleaner.remove(selected, ignore: ignore, dryRun: true)
            Render.cleanupSummary(out, dryRun: true)
            return
        }

        let reviewed: [CategoryScan]
        switch mode {
        case .forced:
            reviewed = cats
            Render.scanResults(cats)
            Render.selectionLine(cats)
        case .plain:
            guard let selection = try PlainSelectionReview.select(cats, title: "Choose items to clean") else {
                print(Term.dim("Cancelled. Nothing removed."))
                return
            }
            reviewed = selection
        case .fullscreen, .reportOnly, .unavailable:
            return
        }

        let selected = reviewed.flatMap { $0.selectedItems }
        if selected.isEmpty {
            print(Term.dim("No items selected. Nothing removed."))
            return
        }

        if mode != .forced {
            Render.deletionReview(reviewed)
            let total = ByteCount.human(selected.reduce(Int64(0)) { $0 + $1.sizeBytes })
            guard Term.confirm("Remove \(selected.count) items (\(total))?", default: false) else {
                print(Term.dim("Cancelled. Nothing removed."))
                return
            }
        }

        let out = Cleaner.remove(selected, ignore: ignore, dryRun: false)
        Render.cleanupSummary(out, dryRun: false)
        if out.hadFailures { throw ExitCode.failure }
    }

    static let emptyMessage = "No cleanup candidates found in readable locations."

    typealias CategoryScanFunction = (String, String, IgnoreStore, ScanProgress, () -> Bool) -> CategoryScan

    static func scan(
        ids: [String],
        ignore: IgnoreStore,
        progress: ScanProgress,
        status: WorkProgress<ScanStatus>? = nil,
        cancel: CancelFlag? = nil,
        scanCategory: CategoryScanFunction = CategoryScanner.scan
    ) -> [CategoryScan] {
        var scans: [CategoryScan] = []
        for (index, id) in ids.enumerated() {
            if cancel?.isCancelled == true { break }
            let title = Clean.title(id)
            status?.update { $0.beginCategory(title: title, position: index + 1, count: ids.count) }
            let scan = scanCategory(id, title, ignore, progress) { cancel?.isCancelled == true }
            status?.update { $0.addFound(in: scan) }
            scans.append(scan)
        }
        return scans.filter { !$0.groups.isEmpty }
    }

    static func title(_ id: String) -> String {
        Catalog.categoryTitles.first { $0.id == id }?.title ?? id.capitalized
    }
}

enum CleanupCommandMode: Equatable {
    case reportOnly
    case forced
    case fullscreen
    case plain
    case unavailable
}

enum CleanupCommandPolicy {
    static func mode(
        force: Bool,
        dryRun: Bool,
        json: Bool,
        plain: Bool,
        terminalSupported: Bool = TerminalSession.isSupported,
        inputIsTTY: Bool = isatty(fileno(stdin)) == 1 && isatty(fileno(stdout)) == 1
    ) -> CleanupCommandMode {
        if dryRun || json { return .reportOnly }
        if force { return .forced }
        guard inputIsTTY else { return .unavailable }
        return plain || !terminalSupported ? .plain : .fullscreen
    }
}

enum PlainSelectionReview {
    static func select(_ categories: [CategoryScan], title: String) throws -> [CategoryScan]? {
        print("")
        print(Term.bold(Term.sanitize(title)))
        print(Term.dim("All items start unselected. Enter numbers, ranges, all, none, or q to cancel."))
        var number = 1
        for category in categories {
            print("")
            print("  " + Term.cyan(Term.sanitize(category.title)))
            for group in category.groups {
                for item in group.items {
                    print("  \(number). \(Render.sizeCol(item.sizeBytes)) \(Render.pad(Term.sanitize(group.tool), 20)) \(Term.sanitize(item.path))")
                    number += 1
                }
            }
        }

        while true {
            print("\nSelect items: ", terminator: "")
            guard let line = readLine() else { return nil }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if ["q", "quit", "cancel"].contains(trimmed.lowercased()) { return nil }
            do {
                let indices = try parseSelection(trimmed, itemCount: number - 1)
                return applyingSelection(indices, to: categories)
            } catch {
                Term.err(Term.red(Term.sanitize(error.localizedDescription)))
            }
        }
    }

    static func parseSelection(_ input: String, itemCount: Int) throws -> Set<Int> {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty || trimmed == "none" { return [] }
        if trimmed == "all" { return itemCount > 0 ? Set(1...itemCount) : [] }

        let parts = trimmed.replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
        var selected = Set<Int>()
        for partValue in parts {
            let part = String(partValue)
            if part.contains("-") {
                let bounds = part.split(separator: "-", omittingEmptySubsequences: false)
                guard bounds.count == 2,
                      let lower = Int(bounds[0]),
                      let upper = Int(bounds[1]),
                      lower <= upper,
                      lower >= 1,
                      upper <= itemCount
                else { throw ValidationError("Invalid selection '\(part)'.") }
                selected.formUnion(lower...upper)
            } else {
                guard let index = Int(part), index >= 1, index <= itemCount else {
                    throw ValidationError("Invalid selection '\(part)'.")
                }
                selected.insert(index)
            }
        }
        return selected
    }

    static func applyingSelection(_ selected: Set<Int>, to categories: [CategoryScan]) -> [CategoryScan] {
        var result = categories
        var number = 1
        for categoryIndex in result.indices {
            for groupIndex in result[categoryIndex].groups.indices {
                for itemIndex in result[categoryIndex].groups[groupIndex].items.indices {
                    result[categoryIndex].groups[groupIndex].items[itemIndex].selected = selected.contains(number)
                    number += 1
                }
            }
        }
        return result
    }
}

enum JSONReport {
    static func string(_ cats: [CategoryScan]) throws -> String {
        struct Out: Encodable {
            struct Cat: Encodable { let id, title: String; let totalBytes, selectedBytes: Int64; let groups: [ToolGroup] }
            let totalBytes: Int64
            let categories: [Cat]
        }
        let out = Out(
            totalBytes: cats.reduce(0) { $0 + $1.allBytes },
            categories: cats.map { Out.Cat(id: $0.id, title: $0.title, totalBytes: $0.allBytes, selectedBytes: $0.totalBytes, groups: $0.groups) }
        )
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        return String(decoding: try enc.encode(out), as: UTF8.self)
    }
}
