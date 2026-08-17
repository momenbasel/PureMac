import Foundation

enum Render {
    static let rule = String(repeating: "─", count: 60)

    static func scanResults(_ cats: [CategoryScan]) {
        let grand = cats.reduce(Int64(0)) { $0 + $1.allBytes }
        print("")
        print(Term.bold("\(ByteCount.human(grand)) of removable items found"))
        for cat in cats where !cat.groups.isEmpty {
            print("")
            print("  \(Term.cyan(cat.title))  \(Term.dim(ByteCount.human(cat.allBytes)))")
            for group in cat.groups {
                for item in group.items {
                    let mark = item.selected ? Term.green("✓") : Term.dim("·")
                    print("    \(mark) \(sizeCol(item.sizeBytes)) \(pad(group.tool, 22)) \(Term.dim(shorten(item.path)))")
                }
            }
        }
    }

    static func selectionLine(_ cats: [CategoryScan]) {
        let items = cats.flatMap { $0.selectedItems }
        let total = items.reduce(Int64(0)) { $0 + $1.sizeBytes }
        print("")
        print(Term.bold("\(items.count) items selected (\(ByteCount.human(total)))"))
    }

    static func deletionReview(_ cats: [CategoryScan]) {
        let selected = cats.flatMap { $0.selectedItems }
        let total = selected.reduce(Int64(0)) { $0 + $1.sizeBytes }
        print("")
        print(Term.yellow(rule))
        print("  " + Term.bold("The following will be permanently deleted:"))
        print(Term.yellow(rule))
        for cat in cats {
            let catSelected = cat.selectedItems
            guard !catSelected.isEmpty else { continue }
            print("  " + Term.cyan(cat.title))
            for group in cat.groups {
                for item in group.items where item.selected {
                    print("    \(sizeCol(item.sizeBytes)) \(pad(group.tool, 20)) \(shorten(item.path))")
                }
            }
        }
        print(Term.yellow(rule))
        print("  " + Term.bold("Total: \(ByteCount.human(total))") + Term.dim("  ·  \(selected.count) items"))
        print(Term.yellow(rule))
    }

    static func cleanupSummary(_ out: CleanOutcome, dryRun: Bool) {
        print("")
        let freed = ByteCount.human(out.freedBytes)
        if dryRun {
            print(Term.bold("Dry run — nothing was deleted."))
            print("  " + Term.bold(freed) + " reclaimable across \(out.removed) items")
        } else {
            box(title: freed, subtitle: "cleaned!")
            print("  " + Term.bold("\(out.removed)") + " items removed")
        }
        if !out.skipped.isEmpty {
            print("  " + Term.yellow("\(out.skipped.count) skipped") + Term.dim(" (protected/ignored)"))
        }
        if !out.failed.isEmpty {
            print("  " + Term.red("\(out.failed.count) failed"))
            for f in out.failed.prefix(10) { Term.err("    ! \(shorten(f.path)) — \(f.error)") }
        }
        print("")
    }

    private static func box(title: String, subtitle: String) {
        let width = max(title.count, subtitle.count) + 6
        let top = "┌" + String(repeating: "─", count: width) + "┐"
        let bot = "└" + String(repeating: "─", count: width) + "┘"
        print("")
        print("   " + Term.green(top))
        print("   " + Term.green("│") + center(title, width) + Term.green("│"))
        print("   " + Term.green("│") + center(subtitle, width) + Term.green("│"))
        print("   " + Term.green(bot))
        print("")
    }

    private static func center(_ s: String, _ width: Int) -> String {
        let pad = max(0, width - s.count)
        let left = pad / 2, right = pad - left
        return String(repeating: " ", count: left) + Term.bold(s) + String(repeating: " ", count: right)
    }

    static func sizeCol(_ bytes: Int64) -> String { pad(ByteCount.human(bytes), 10) }
    static func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }

    static func shorten(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
