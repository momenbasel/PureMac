import Foundation

struct CleanOutcome {
    var removed: Int = 0
    var freedBytes: Int64 = 0
    var skipped: [(path: String, reason: String)] = []
    var failed: [(path: String, error: String)] = []
    var hadFailures: Bool { !failed.isEmpty || !skipped.isEmpty }
}

enum Cleaner {
    static func remove(
        _ items: [ScanItem],
        ignore: IgnoreStore,
        dryRun: Bool,
        beforeItem: ((_ index: Int, _ count: Int, _ item: ScanItem) -> Void)? = nil
    ) -> CleanOutcome {
        var out = CleanOutcome()
        let fm = FileManager.default
        for (index, item) in items.enumerated() {
            beforeItem?(index, items.count, item)
            if Safety.hasSymlinkComponent(item.path) {
                out.skipped.append((item.path, "symlink"))
                continue
            }
            let verdict = Safety.canRemove(item.path, ignore: ignore)
            guard verdict.ok else {
                out.skipped.append((item.path, verdict.reason ?? "protected"))
                continue
            }
            guard let expectedIdentity = item.identity,
                  Safety.fileIdentity(at: item.path) == expectedIdentity else {
                out.skipped.append((item.path, "changed since scan"))
                continue
            }
            let measurement = DirSizer.measure(of: item.path)
            guard measurement.status == .complete else {
                out.skipped.append((item.path, "could not measure safely"))
                continue
            }
            if dryRun {
                out.removed += 1
                out.freedBytes = adding(measurement.bytes, to: out.freedBytes)
                continue
            }
            if Safety.hasSymlinkComponent(item.path) {
                out.skipped.append((item.path, "became a symlink"))
                continue
            }
            guard Safety.fileIdentity(at: item.path) == expectedIdentity else {
                out.skipped.append((item.path, "changed since scan"))
                continue
            }
            do {
                try fm.removeItem(atPath: item.path)
                let survivingIdentity = Safety.fileIdentity(at: item.path)
                if survivingIdentity == expectedIdentity {
                    out.failed.append((item.path, "item survived removal"))
                } else {
                    out.removed += 1
                    out.freedBytes = adding(measurement.bytes, to: out.freedBytes)
                }
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

    private static func adding(_ bytes: Int64, to total: Int64) -> Int64 {
        let (sum, overflow) = total.addingReportingOverflow(bytes)
        return overflow ? .max : sum
    }
}
