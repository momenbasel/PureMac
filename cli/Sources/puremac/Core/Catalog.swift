import Foundation

struct Target {
    let tool: String
    let paths: [String]
    var selectedByDefault: Bool = true

    var contents: Bool = false
}

enum Catalog {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path
    private static func h(_ rel: String) -> String { "\(home)/\(rel)" }

    static var dev: [Target] {
        [

            Target(tool: "Homebrew", paths: [h("Library/Caches/Homebrew")]),
            Target(tool: "npm", paths: [h(".npm/_cacache")]),
            Target(tool: "Yarn", paths: [h("Library/Caches/Yarn"), h(".cache/yarn"), h(".yarn/berry/cache")]),
            Target(tool: "pnpm", paths: [h("Library/pnpm/store"), h(".pnpm-store"), h(".cache/pnpm")]),
            Target(tool: "pip", paths: [h("Library/Caches/pip"), h(".cache/pip")]),

            Target(tool: "Cargo (Rust)", paths: [h(".cargo/registry/cache"), h(".cargo/registry/index"), h(".cargo/git/db"), h(".cargo/git/checkouts")]),
            Target(tool: "Go", paths: [h("Library/Caches/go-build"), h("go/pkg/mod/cache")]),
            Target(tool: "CocoaPods", paths: [h("Library/Caches/CocoaPods")]),
            Target(tool: "VS Code", paths: [h("Library/Application Support/Code/Cache"), h("Library/Application Support/Code/CachedData"), h("Library/Application Support/Code/CachedExtensionVSIXs"), h("Library/Application Support/Code/logs")]),
            Target(tool: "JetBrains", paths: [h("Library/Caches/JetBrains"), h("Library/Logs/JetBrains")]),

            Target(tool: "Maven (~/.m2 — may hold local installs)", paths: [h(".m2/repository")], selectedByDefault: false),
            Target(tool: "Gradle", paths: [h(".gradle/caches"), h(".gradle/daemon"), h(".gradle/wrapper/dists")]),
            Target(tool: "Poetry", paths: [h("Library/Caches/pypoetry"), h(".cache/pypoetry")]),
            Target(tool: "uv", paths: [h(".cache/uv"), h("Library/Caches/uv")]),
            Target(tool: "Bun", paths: [h(".bun/install/cache")]),
            Target(tool: "Deno", paths: [h("Library/Caches/deno"), h(".cache/deno")]),
            Target(tool: "mise", paths: [h(".cache/mise")]),
            Target(tool: "Flutter / Dart pub", paths: [h(".pub-cache")]),
            Target(tool: "NuGet / .NET (~/.nuget — may hold local packages)", paths: [h(".nuget/packages"), h(".local/share/NuGet/http-cache")], selectedByDefault: false),

            Target(tool: "Swift Package Manager", paths: [h("Library/Caches/org.swift.swiftpm")]),

            Target(tool: "Docker Desktop", paths: [h("Library/Containers/com.docker.docker/Data/cache"), h("Library/Containers/com.docker.docker/Data/log"), h("Library/Containers/com.docker.docker/Data/tmp"), h("Library/Group Containers/group.com.docker/Caches"), h(".docker/cli-plugins/.cache"), h(".docker/buildx/cache")]),
            Target(tool: "OrbStack", paths: [h(".orbstack/log"), h("Library/Caches/dev.kdrag0n.MacVirt"), h("Library/Logs/OrbStack")]),
        ]
    }

    static var junk: [Target] {
        [

            Target(tool: "User logs", paths: [h("Library/Logs")], contents: true),
            Target(tool: "Saved application state", paths: [h("Library/Saved Application State")], selectedByDefault: false),
            Target(tool: "Xcode DerivedData", paths: [h("Library/Developer/Xcode/DerivedData")]),
            Target(tool: "Xcode Archives", paths: [h("Library/Developer/Xcode/Archives")], selectedByDefault: false),
            Target(tool: "iOS DeviceSupport", paths: [h("Library/Developer/Xcode/iOS DeviceSupport")]),
            Target(tool: "watchOS DeviceSupport", paths: [h("Library/Developer/Xcode/watchOS DeviceSupport")]),
            Target(tool: "tvOS DeviceSupport", paths: [h("Library/Developer/Xcode/tvOS DeviceSupport")]),
            Target(tool: "CoreSimulator caches", paths: [h("Library/Developer/CoreSimulator/Caches")]),
            Target(tool: "Xcode app cache", paths: [h("Library/Caches/com.apple.dt.Xcode")]),
            Target(tool: "XCTestDevices", paths: [h("Library/Developer/XCTestDevices")]),
            Target(tool: "SwiftUI Previews", paths: [h("Library/Developer/Xcode/UserData/Previews")]),
        ]
    }

    static var ai: [Target] {
        [

            Target(tool: "Ollama (logs/cache)", paths: [h(".ollama/logs"), h("Library/Caches/ollama"), h("Library/Caches/com.electron.ollama")]),
            Target(tool: "LM Studio (logs)", paths: [h(".lmstudio/server-logs")]),
            Target(tool: "Cursor (cache)", paths: [h("Library/Application Support/Cursor/Cache"), h("Library/Application Support/Cursor/CachedData"), h("Library/Application Support/Cursor/logs")]),
        ]
    }

    static func targets(for id: String) -> [Target] {
        switch id {
        case "dev": return dev
        case "junk": return junk
        case "ai": return ai
        default: return []
        }
    }

    static let categoryTitles: [(id: String, title: String)] = [
        ("dev", "Dev Tools"),
        ("junk", "System Junk"),
        ("ai", "AI Junk"),
        ("trash", "Trash"),
    ]
}
