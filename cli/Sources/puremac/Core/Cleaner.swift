import Foundation

struct CleanOutcome {
    var removed: Int = 0
    var freedBytes: Int64 = 0
    var skipped: [(path: String, reason: String)] = []
    var failed: [(path: String, error: String)] = []
    var hadFailures: Bool { !failed.isEmpty }
}

enum Cleaner {
    static func remove(_ items: [ScanItem], ignore: IgnoreStore, dryRun: Bool) -> CleanOutcome {
        var out = CleanOutcome()
        let fm = FileManager.default
        for item in items {
            if Safety.isSymlink(item.path) || parentHasSymlink(item.path) {
                out.skipped.append((item.path, "symlink"))
                continue
            }
            let verdict = Safety.canRemove(item.path, ignore: ignore)
            guard verdict.ok else {
                out.skipped.append((item.path, verdict.reason ?? "protected"))
                continue
            }
            if dryRun {
                out.removed += 1
                out.freedBytes += item.sizeBytes
                continue
            }
            if Safety.isSymlink(item.path) || parentHasSymlink(item.path) {
                out.skipped.append((item.path, "became a symlink"))
                continue
            }
            do {
                try fm.removeItem(atPath: item.path)
                out.removed += 1
                out.freedBytes += item.sizeBytes
            } catch {
                let ns = error as NSError
                let hint = (ns.code == NSFileWriteNoPermissionError || ns.code == NSFileReadNoPermissionError)
                    ? "locked or in use — close the owning app and retry" : ns.localizedDescription
                out.failed.append((item.path, hint))
            }
        }
        return out
    }

    static func parentHasSymlink(_ path: String) -> Bool {
        var url = URL(fileURLWithPath: path).deletingLastPathComponent()
        while url.path.count > 1 {
            if Safety.isSymlink(url.path) { return true }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        return false
    }
}
