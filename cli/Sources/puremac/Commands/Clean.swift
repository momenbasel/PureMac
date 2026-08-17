import ArgumentParser
import Foundation

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
        """
    )

    @Argument(help: "Category to clean: dev | junk | ai | trash. Omit to clean all.")
    var category: String?

    @Flag(name: .long, help: "Skip the confirmation prompt and remove immediately.")
    var force = false

    @Flag(name: .customLong("dry-run"), help: "Scan and report only; never delete.")
    var dryRun = false

    @Flag(name: .long, help: "Emit machine-readable JSON and exit (never deletes).")
    var json = false

    static let validIDs = ["dev", "junk", "ai", "trash"]

    func validate() throws {
        if let c = category, !Clean.validIDs.contains(c) {
            throw ValidationError("Unknown category '\(c)'. Use one of: \(Clean.validIDs.joined(separator: ", ")).")
        }
    }

    func run() throws {
        let ids = category.map { [$0] } ?? Clean.validIDs
        let ignore = IgnoreStore()
        let cats = ids.map { id in
            CategoryScanner.scan(categoryID: id, title: Clean.title(id), ignore: ignore)
        }.filter { !$0.groups.isEmpty }

        if json {
            print(JSONReport.string(cats))
            return
        }

        if cats.isEmpty {
            print(Term.green("Nothing to clean — you're already tidy."))
            return
        }

        Render.scanResults(cats)
        Render.selectionLine(cats)

        let selected = cats.flatMap { $0.selectedItems }
        if selected.isEmpty {
            print(Term.dim("No items selected by default. Nothing removed."))
            return
        }

        if dryRun {
            let out = Cleaner.remove(selected, ignore: ignore, dryRun: true)
            Render.cleanupSummary(out, dryRun: true)
            return
        }

        if !force {
            Render.deletionReview(cats)
            let total = ByteCount.human(selected.reduce(Int64(0)) { $0 + $1.sizeBytes })
            guard Term.confirm("Remove \(selected.count) items (\(total))?", default: false) else {
                print(Term.dim("Cancelled. Nothing removed."))
                return
            }
        }

        let out = Cleaner.remove(selected, ignore: ignore, dryRun: false)
        Render.cleanupSummary(out, dryRun: false)
        if !force {
            print(Term.dim("Tip: `puremac ignore add <path>` protects a path · `puremac clean --force` skips this prompt"))
        }
        if out.hadFailures { throw ExitCode.failure }
    }

    static func title(_ id: String) -> String {
        Catalog.categoryTitles.first { $0.id == id }?.title ?? id.capitalized
    }
}

enum JSONReport {
    static func string(_ cats: [CategoryScan]) -> String {
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
        return (try? enc.encode(out)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}
