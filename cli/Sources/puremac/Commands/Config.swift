import ArgumentParser
import Foundation

struct Config: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show or change CLI preferences.",
        discussion: """
          puremac config                       Show all settings and file locations
          puremac config set purge.older_than_days 14
        PureMac CLI sends no telemetry — there is nothing to opt out of.
        """
    )

    @Argument(help: "'set' to change a value, omit to show all.") var action: String?
    @Argument(help: "Key to set.") var key: String?
    @Argument(help: "Value to set.") var value: String?

    func run() throws {
        var store = ConfigStore()
        if action == "set" {
            guard let key, let value else { throw ValidationError("Usage: puremac config set <key> <value>") }
            guard ConfigStore.knownKeys.contains(key) else {
                throw ValidationError("Unknown key '\(key)'. Known: \(ConfigStore.knownKeys.joined(separator: ", "))")
            }
            store.set(key, value)
            print(Term.green("✓ \(key) = \(value)"))
            return
        }
        print(Term.bold("PureMac CLI configuration"))
        print(Term.dim("  config: ") + Render.shorten(AppPaths.configFile.path))
        print(Term.dim("  ignore: ") + Render.shorten(AppPaths.ignoreFile.path))
        print("")
        for key in ConfigStore.knownKeys {
            print("  \(key) = \(store.values[key] ?? Term.dim("(default)"))")
        }
    }
}
