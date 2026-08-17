import ArgumentParser
import Foundation

let puremacVersion = "1.0.0"

@main
struct PureMac: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "puremac",
        abstract: "Clean developer caches, project artifacts, and disk clutter — from the terminal.",
        discussion: """
        PureMac scans first and removes only what you approve. Cache/junk removal is
        permanent; cloud (iCloud/Dropbox/…) state and your config dotfiles are never touched.
        """,
        version: puremacVersion,
        subcommands: [Clean.self, Purge.self, Analyze.self, Optimize.self, Ignore.self, Config.self],
        defaultSubcommand: Clean.self
    )
}
