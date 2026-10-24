import ArgumentParser
import Foundation
import TerminalUI

struct Config: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show or change CLI preferences.",
        discussion: """
          puremac config                       Show settings and storage locations
          puremac config set purge.older_than_days 14
        The age setting controls which project artifacts `puremac purge` preselects.
        PureMac CLI has no telemetry setting because it sends no telemetry.
        """
    )

    @Argument(help: "Use 'set' to change a value. Omit to show settings.")
    var action: String?

    @Argument(help: "Setting key.")
    var key: String?

    @Argument(help: "New value.")
    var value: String?

    func validate() throws {
        if action == nil, key == nil, value == nil { return }
        guard action == "set" else {
            throw ValidationError("Unknown action '\(action ?? "")'. Use 'set' or omit all arguments.")
        }
        guard let key, let value else {
            throw ValidationError("Usage: puremac config set <key> <value>")
        }
        do {
            _ = try ConfigStore.normalizedValue(value, for: key)
        } catch {
            throw ValidationError(error.localizedDescription)
        }
    }

    func run() throws {
        var store = try ConfigStore(fileURL: AppPaths.configFile)
        if action == "set" {
            guard let key, let value else {
                throw ValidationError("Usage: puremac config set <key> <value>")
            }
            try store.set(key, value)
            let saved = store.values[key] ?? value
            print(Term.green("✓ Saved \(key) = \(saved)"))
            print(Term.dim("  \(Render.shorten(AppPaths.configFile.path))"))
            return
        }

        let folders = try ProjectFoldersStore(fileURL: AppPaths.projectsFile).roots
        for line in Self.sheet(store: store, projectFolders: folders).plainLines() { print(line) }
    }

    static let sheetTitle = "PureMac CLI settings"

    static func sheet(store: ConfigStore, projectFolders: [String]) -> InfoSheet {
        let days = store.olderThanDays
        let note = days == ConfigStore.defaultDays ? Span("default", TextStyle(dim: true)) : Span("saved", TextStyle(color: .cyan))
        let keys = [InfoRow.metric(label: ConfigStore.daysKey, value: [Span("\(days) days")], note: note)]
        let files = [("Settings", AppPaths.configFile), ("Protected", AppPaths.ignoreFile), ("Projects", AppPaths.projectsFile)].map { label, url in
            InfoRow.metric(label: label, value: [Span(Render.shorten(url.path))], note: nil)
        }
        return InfoSheet(
            title: sheetTitle,
            subtitle: "Values used when a command-line option is omitted",
            sections: [
                InfoSection(title: nil, labelWidth: 26, rows: keys),
                InfoSection(title: "Files", labelWidth: 12, rows: files),
                InfoSection(title: "Project folders", rows: projectFolders.map { .path(Render.shorten($0)) }),
            ],
            footnote: nil
        )
    }
}
