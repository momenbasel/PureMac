import ArgumentParser
import Foundation

struct Purge: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Find removable build artifacts inside project folders (node_modules, target, .venv, …).",
        discussion: """
        With no path, scans ~/Projects, ~/Code, ~/dev, ~/GitHub, ~/Workspace.
        Artifacts older than the age threshold are preselected; newer ones are shown unchecked.
          puremac purge                 Scan the default project folders
          puremac purge ~/Work/app      Scan a specific folder
        """
    )

    @Argument(help: "Folder(s) to scan. Omit to scan the default project locations.")
    var paths: [String] = []

    @Option(name: .customLong("older-than"), help: "Preselect artifacts older than N days (default 7, or config).")
    var olderThanDays: Int = -1

    @Flag(name: .long, help: "Skip the confirmation prompt and remove immediately.")
    var force = false

    @Flag(name: .customLong("dry-run"), help: "Scan and report only; never delete.")
    var dryRun = false

    @Flag(name: .long, help: "Emit machine-readable JSON and exit (never deletes).")
    var json = false

    func validate() throws {
        if olderThanDays != -1 && !(0...3650).contains(olderThanDays) {
            throw ValidationError("--older-than must be between 0 and 3650 days.")
        }
        for p in paths {
            let v = Safety.isValidScanRoot(p)
            if !v.ok { throw ValidationError(v.reason ?? "invalid path") }
        }
    }

    func run() throws {
        let ignore = IgnoreStore()
        let days = resolvedDays()
        let roots = paths.isEmpty
            ? Purger.defaultRoots
            : paths.map { (($0 as NSString).expandingTildeInPath as NSString).standardizingPath }

        if !json { Term.err(Term.dim("Scanning " + roots.map { Render.shorten($0) }.joined(separator: ", ") + " …")) }
        let cat = Purger.scan(roots: roots, olderThanDays: days, ignore: ignore)

        if json { print(JSONReport.string([cat])); return }

        if cat.groups.isEmpty {
            print(Term.green("No project artifacts found."))
            return
        }

        let projectCount = cat.groups.count
        print("")
        print(Term.bold("Found \(ByteCount.human(cat.allBytes)) across \(projectCount) project\(projectCount == 1 ? "" : "s")"))
        for group in cat.groups {
            print("")
            print("  \(Term.cyan(group.tool))  \(Term.dim(ByteCount.human(group.allBytes)))")
            for item in group.items {
                let mark = item.selected ? Term.green("✓") : Term.dim("·")
                let recent = item.selected ? "" : Term.dim("  recent")
                print("    \(mark) \(Render.sizeCol(item.sizeBytes)) \(Render.shorten(item.path))\(recent)")
            }
        }
        print("")
        print(Term.dim("Artifacts newer than \(days) days are shown but left unchecked."))

        let selected = cat.selectedItems
        if selected.isEmpty { print(Term.dim("\nNothing preselected. Nothing removed.")); return }

        if dryRun {
            let out = Cleaner.remove(selected, ignore: ignore, dryRun: true)
            Render.cleanupSummary(out, dryRun: true)
            return
        }
        if !force {
            Render.deletionReview([cat])
            let total = ByteCount.human(selected.reduce(Int64(0)) { $0 + $1.sizeBytes })
            guard Term.confirm("Remove \(selected.count) artifacts (\(total))?", default: false) else {
                print(Term.dim("Cancelled. Nothing removed."))
                return
            }
        }
        let out = Cleaner.remove(selected, ignore: ignore, dryRun: false)
        Render.cleanupSummary(out, dryRun: false)
        if out.hadFailures { throw ExitCode.failure }
    }

    private func resolvedDays() -> Int {
        if olderThanDays >= 0 { return olderThanDays }
        if let v = ConfigStore().values["purge.older_than_days"], let n = Int(v), (0...3650).contains(n) { return n }
        return 7
    }
}
