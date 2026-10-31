import ArgumentParser
import Foundation
import TerminalUI

struct Purge: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Find removable build artifacts inside project folders (node_modules, target, .venv, …).",
        discussion: """
        With no path, scans the project folders from Preferences, by default ~/Projects, ~/Code, ~/dev, ~/GitHub, ~/Workspace.
        Interactive review starts empty so recent and older artifacts are both selectable.
          puremac purge                 Scan the configured project folders
          puremac purge ~/Work/app      Scan a specific folder

        \(Render.reviewHelp) --force removes only artifacts older than the configured threshold without either prompt. --dry-run and --json never delete or open a selector.
        """
    )

    @Argument(help: "Folder(s) to scan. Omit to scan the configured project folders.")
    var paths: [String] = []

    @Option(name: .customLong("older-than"), help: "Age threshold used by --force and read-only reports (default 7, or config).")
    var olderThanDays: Int = -1

    @Flag(name: .long, help: "Remove age-selected artifacts without review or confirmation.")
    var force = false

    @Flag(name: .customLong("dry-run"), help: "Scan and report only; never delete.")
    var dryRun = false

    @Flag(name: .long, help: "Emit machine-readable JSON and exit (never deletes).")
    var json = false

    @Flag(name: .long, help: "Use a numbered line-based selector instead of the fullscreen review.")
    var plain = false

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
        let mode = CleanupCommandPolicy.mode(
            force: force,
            dryRun: dryRun,
            json: json,
            plain: plain
        )
        guard mode != .unavailable else {
            throw ValidationError("Interactive review requires a terminal. Re-run with --force to remove the age-selected artifacts, or use --dry-run or --json for a read-only report.")
        }

        let ignore = try IgnoreStore(fileURL: AppPaths.ignoreFile)
        let days = try resolvedDays()
        let roots = try resolvedRoots()
        guard !roots.isEmpty || json else {
            print(Term.dim(Purge.noFoldersMessage))
            return
        }

        let scanning = "Scanning " + roots.map { Render.shorten($0) }.joined(separator: ", ")
        if mode == .fullscreen {
            let labels = CleanupFlow.Labels(
                scanning: scanning,
                empty: Purge.emptyMessage,
                reviewTitle: "Choose project artifacts",
                noun: "artifact"
            )
            let result = try CleanupFlow.run(labels: labels, ignore: ignore) { status, cancel in
                let cat = Purger.scan(
                    roots: roots, olderThanDays: days, ignore: ignore,
                    progress: { event in status.update { $0.apply(event) } },
                    isCancelled: { cancel.isCancelled }
                )
                return cat.groups.isEmpty ? [] : [cat]
            }
            try CleanupFlow.finish(result, labels: labels)
            return
        }
        if !json { Term.err(Term.dim(scanning + " …")) }
        let cat = Purger.scan(roots: roots, olderThanDays: days, ignore: ignore)

        if json { print(try JSONReport.string([cat])); return }

        if cat.groups.isEmpty {
            print(Term.green(Purge.emptyMessage))
            return
        }

        if dryRun {
            renderScan(cat, days: days)
            let selected = cat.selectedItems
            let out = Cleaner.remove(selected, ignore: ignore, dryRun: true)
            Render.cleanupSummary(out, dryRun: true)
            return
        }

        let reviewed: [CategoryScan]
        switch mode {
        case .forced:
            reviewed = [cat]
            renderScan(cat, days: days)
        case .plain:
            guard let selection = try PlainSelectionReview.select([cat], title: "Choose project artifacts") else {
                print(Term.dim("Cancelled. Nothing removed."))
                return
            }
            reviewed = selection
        case .fullscreen, .reportOnly, .unavailable:
            return
        }

        let selected = reviewed.flatMap { $0.selectedItems }
        if selected.isEmpty { print(Term.dim("\nNo artifacts selected. Nothing removed.")); return }

        if mode != .forced {
            Render.deletionReview(reviewed)
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

    static let noFoldersMessage = "No project folders configured. Add one in Preferences."
    static let emptyMessage = "No project artifacts found in readable locations."

    private func resolvedDays() throws -> Int {
        if olderThanDays >= 0 { return olderThanDays }
        return try ConfigStore(fileURL: AppPaths.configFile).olderThanDays
    }

    func resolvedRoots() throws -> [String] {
        guard paths.isEmpty else { return paths.map { Safety.absolutePath($0) } }
        return try ProjectFoldersStore(fileURL: AppPaths.projectsFile).roots
    }

    func renderScan(_ cat: CategoryScan, days: Int, colors: Bool = Term.colorEnabled) {
        let projectCount = cat.groups.count
        print("")
        print(Render.paint("Found \(ByteCount.human(cat.allBytes)) across \(projectCount) project\(projectCount == 1 ? "" : "s")", TextStyle(bold: true), colors))
        for group in cat.groups {
            print("")
            print("  \(Render.paint(group.tool, TextStyle(color: .cyan), colors))  \(Render.paint(ByteCount.human(group.allBytes), TextStyle(dim: true), colors))")
            for item in group.items {
                let mark = item.selected ? Render.paint("✓", TextStyle(color: .green), colors) : Render.paint("·", TextStyle(dim: true), colors)
                let recent = item.selected ? "" : Render.paint("  recent", TextStyle(dim: true), colors)
                print("    \(mark) \(Render.coloredSizeCol(item.sizeBytes, colors: colors)) \(Render.shorten(item.path))\(recent)")
            }
        }
        print("")
        print(Render.paint("Artifacts newer than \(days) days are shown but left unchecked.", TextStyle(dim: true), colors))
    }
}
