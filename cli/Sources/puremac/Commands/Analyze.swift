import ArgumentParser
import Foundation

struct Analyze: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show what is taking up disk space, largest first.",
        discussion: """
        Sizes the immediate children of a folder and ranks them, like `du -d1 | sort`.
          puremac analyze              Explore your home folder
          puremac analyze ~/Library    Explore a specific folder
        Browsing never modifies files.
        """
    )

    @Argument(help: "Folder to analyze. Omit for your home folder.")
    var path: String?

    @Option(name: .shortAndLong, help: "How many levels deep to break down (default 1).")
    var depth: Int = 1

    @Flag(name: .long, help: "Emit machine-readable JSON and exit.")
    var json = false

    func run() throws {
        let target = ((path ?? Safety.home) as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target, isDirectory: &isDir), isDir.boolValue else {
            throw ValidationError("Not a folder: \(target)")
        }

        let children = sizedChildren(of: target)
        let total = children.reduce(Int64(0)) { $0 + $1.size }

        if json {
            struct Row: Encodable { let path: String; let bytes: Int64 }
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            let data = try enc.encode(children.map { Row(path: $0.path, bytes: $0.size) })
            print(String(decoding: data, as: UTF8.self))
            return
        }

        let vol = SystemInfo.volume(target)
        if vol.total > 0 {
            print("")
            print(Term.bold("\(ByteCount.human(vol.available)) free of \(ByteCount.human(vol.total))"))
        }
        print(Term.dim("\(Render.shorten(target)) — \(ByteCount.human(total))"))
        print("")
        printLevel(children, total: total, indent: "  ", depthLeft: max(1, depth) - 1)
    }

    struct Child { let path: String; let size: Int64; let isDir: Bool }

    func sizedChildren(of dir: String) -> [Child] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        return names.compactMap { name -> Child? in
            let full = "\(dir)/\(name)"
            if let type = (try? fm.attributesOfItem(atPath: full)[.type]) as? FileAttributeType, type == .typeSymbolicLink {
                return nil
            }
            var isDir: ObjCBool = false
            fm.fileExists(atPath: full, isDirectory: &isDir)
            return Child(path: full, size: DirSizer.size(of: full), isDir: isDir.boolValue)
        }.sorted { $0.size > $1.size }
    }

    func printLevel(_ children: [Child], total: Int64, indent: String, depthLeft: Int) {
        for child in children where child.size > 0 {
            let frac = total > 0 ? Double(child.size) / Double(total) : 0
            let pct = String(format: "%5.1f%%", frac * 100)
            let size = ByteCount.human(child.size).padding(toLength: 10, withPad: " ", startingAt: 0)
            let name = URL(fileURLWithPath: child.path).lastPathComponent + (child.isDir ? "/" : "")
            print("\(indent)\(size) \(Term.dim(pct)) \(Term.bar(fraction: frac, width: 20)) \(name)")
            if depthLeft > 0 && child.isDir {
                let sub = sizedChildren(of: child.path)
                printLevel(Array(sub.prefix(10)), total: child.size, indent: indent + "  ", depthLeft: depthLeft - 1)
            }
        }
    }
}
