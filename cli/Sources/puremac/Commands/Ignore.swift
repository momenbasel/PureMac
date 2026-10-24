import ArgumentParser
import Foundation
import TerminalUI

struct Ignore: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Protect paths so clean/purge/analyze never touch them.",
        subcommands: [Add.self, Remove.self, List.self],
        defaultSubcommand: List.self
    )

    struct Add: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Add a path to the ignore list.")
        @Argument(help: "Path to protect.") var path: String
        func run() throws {
            var store = try IgnoreStore(fileURL: AppPaths.ignoreFile)
            let added = try store.add(path)
            let shown = Render.shorten(((path as NSString).expandingTildeInPath as NSString).standardizingPath)
            print(added ? Term.green("✓ Protected ") + shown : Term.dim("Already protected: \(shown)"))
        }
    }

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove a path from the ignore list.")
        @Argument(help: "Path to stop protecting.") var path: String
        func run() throws {
            var store = try IgnoreStore(fileURL: AppPaths.ignoreFile)
            let removed = try store.remove(path)
            let shown = Render.shorten(((path as NSString).expandingTildeInPath as NSString).standardizingPath)
            print(removed ? Term.green("✓ Removed ") + shown : Term.yellow("Not in ignore list: \(shown)"))
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show protected paths.")

        func run() throws {
            let store = try IgnoreStore(fileURL: AppPaths.ignoreFile)
            guard !store.roots.isEmpty else {
                print(Term.styled(Self.emptyHint()))
                return
            }
            print(Term.bold("Protected paths:"))
            for root in store.roots.sorted() { print("  " + Render.shorten(root)) }
        }

        static func emptyHint() -> [Span] {
            [
                Span("No protected paths. Add one with `", TextStyle(dim: true)),
                Span("puremac ignore add <path>", TextStyle(color: .cyan)),
                Span("`.", TextStyle(dim: true)),
            ]
        }
    }
}
