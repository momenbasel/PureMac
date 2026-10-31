import Darwin
import Foundation
import TerminalUI

enum Render {
    static let rule = String(repeating: "─", count: 60)
    static let sizeColumnWidth = 10
    static let reviewHelp = "Return on the selection screen opens a confirmation with Cancel focused. --plain uses a numbered selector with ranges, all, and none, then prints the exact deletion review and asks (default No)."

    static func scanResults(_ categories: [CategoryScan], colors: Bool = Term.colorEnabled) {
        let total = categories.reduce(Int64(0)) { $0 + $1.allBytes }
        let itemCount = categories.flatMap(\.groups).flatMap(\.items).count
        print("")
        print(paint("Scan complete", TextStyle(bold: true), colors))
        print(
            paint(ByteCount.human(total), TextStyle(bold: true), colors)
                + paint(" across \(itemCount) item\(itemCount == 1 ? "" : "s")", TextStyle(dim: true), colors)
        )

        for category in categories where !category.groups.isEmpty {
            print("")
            print(
                paint(category.title, TextStyle(color: .cyan, bold: true), colors)
                    + paint("  \(ByteCount.human(category.allBytes))", TextStyle(dim: true), colors)
            )
            for group in category.groups {
                print(
                    "  " + paint(group.tool, TextStyle(bold: true), colors)
                        + paint("  \(group.items.count) item\(group.items.count == 1 ? "" : "s")", TextStyle(dim: true), colors)
                )
                for item in group.items {
                    let mark = item.selected ? paint("●", TextStyle(color: .cyan), colors) : paint("○", TextStyle(dim: true), colors)
                    let path = displayedPath(item.path, available: max(12, outputWidth - 18))
                    print("    \(mark) \(coloredSizeCol(item.sizeBytes, colors: colors)) \(path)")
                }
            }
        }
    }

    static func selectionLine(_ categories: [CategoryScan]) {
        let items = categories.flatMap { $0.selectedItems }
        let total = items.reduce(Int64(0)) { $0 + $1.sizeBytes }
        print("")
        print(
            Term.bold("\(items.count) selected")
                + Term.dim("  \(ByteCount.human(total))")
        )
    }

    static func deletionReview(_ categories: [CategoryScan], colors: Bool = Term.colorEnabled) {
        let selected = categories.flatMap { $0.selectedItems }
        let total = selected.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let rule = paint(String(repeating: "─", count: min(72, outputWidth)), TextStyle(dim: true), colors)
        print("")
        print(paint("Permanent deletion review", TextStyle(color: .yellow, bold: true), colors))
        print(rule)

        for category in categories {
            let selectedInCategory = category.selectedItems
            guard !selectedInCategory.isEmpty else { continue }
            print(
                paint(category.title, TextStyle(color: .cyan), colors)
                    + paint("  \(ByteCount.human(selectedInCategory.reduce(0) { $0 + $1.sizeBytes }))", TextStyle(dim: true), colors)
            )
            for group in category.groups {
                for item in group.items where item.selected {
                    print("  \(coloredSizeCol(item.sizeBytes, colors: colors)) \(Term.sanitize(group.tool))")
                    print("    \(Term.sanitize(item.path))")
                }
            }
        }

        print(rule)
        print(
            paint(ByteCount.human(total), TextStyle(bold: true), colors)
                + paint("  \(selected.count) item\(selected.count == 1 ? "" : "s")", TextStyle(dim: true), colors)
        )
    }

    static func cleanupSummary(_ outcome: CleanOutcome, dryRun: Bool) {
        print("")
        if dryRun {
            print(Term.bold("Dry run complete"))
            print(
                Term.cyan(ByteCount.human(outcome.freedBytes))
                    + Term.dim(" reclaimable across \(itemCount(outcome.removed))")
            )
            print(Term.dim("Nothing was deleted."))
        } else {
            print(Term.green(Term.bold(cleanupCompleteTitle)))
            print(
                Term.bold(ByteCount.human(outcome.freedBytes))
                    + Term.dim(removedDetail(outcome))
            )
        }

        if !outcome.skipped.isEmpty {
            print(Term.yellow(skippedLabel(outcome)) + Term.dim(skippedNote))
        }
        if !outcome.failed.isEmpty {
            print(Term.red(failedLabel(outcome)))
            for failure in outcome.failed.prefix(10) {
                Term.err("  ! \(Term.sanitize(failure.path))")
                Term.err("    \(Term.sanitize(failure.error))")
            }
        }
        print("")
    }

    static let cleanupCompleteTitle = "Cleanup complete"

    static func counted(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    static func itemCount(_ count: Int) -> String {
        counted(count, "item")
    }

    static func removedDetail(_ outcome: CleanOutcome) -> String {
        " removed across \(itemCount(outcome.removed))"
    }

    static func skippedLabel(_ outcome: CleanOutcome) -> String {
        "\(outcome.skipped.count) skipped"
    }

    static let skippedNote = "  protected or ignored"

    static func failedLabel(_ outcome: CleanOutcome) -> String {
        "\(outcome.failed.count) failed"
    }

    static func sizeCol(_ bytes: Int64) -> String {
        pad(ByteCount.human(bytes), sizeColumnWidth)
    }

    static func paint(_ text: String, _ style: TextStyle, _ colors: Bool) -> String {
        Term.styled([Span(text, style)], colors: colors)
    }

    static func coloredSizeCol(_ bytes: Int64, colors: Bool) -> String {
        paint(sizeCol(bytes), SizeLevel.style(bytes: bytes, focused: false), colors)
    }

    static func pad(_ string: String, _ width: Int) -> String {
        Term.pad(string, to: width)
    }

    static func shorten(_ path: String) -> String {
        let safePath = Term.sanitize(path)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if safePath == home { return "~" }
        return safePath.hasPrefix(home + "/")
            ? "~" + safePath.dropFirst(home.count)
            : safePath
    }

    private static var outputWidth: Int {
        guard isatty(STDOUT_FILENO) == 1 else { return 100 }
        var window = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &window) == 0 else { return 100 }
        return max(1, Int(window.ws_col))
    }

    private static func displayedPath(_ path: String, available: Int) -> String {
        return isatty(STDOUT_FILENO) == 1
            ? Term.truncate(shorten(path), to: available, middle: true)
            : Term.sanitize(path)
    }
}
