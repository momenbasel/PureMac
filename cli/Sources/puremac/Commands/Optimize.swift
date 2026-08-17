import ArgumentParser
import Foundation

struct Optimize: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Free inactive RAM and release purgeable disk space.",
        discussion: """
          puremac optimize             Run both tasks
          puremac optimize ram         Ask macOS to release inactive memory
          puremac optimize purgeable   Release APFS purgeable disk space
        macOS manages memory on its own; these are best-effort nudges, not magic.
        """
    )

    @Argument(help: "Task to run: ram | purgeable. Omit to run both.")
    var task: String?

    func validate() throws {
        if let t = task, t != "ram", t != "purgeable" {
            throw ValidationError("Unknown task '\(t)'. Use 'ram' or 'purgeable'.")
        }
    }

    func run() throws {
        let all = task == nil
        var ok = true
        if all || task == "ram" { ok = optimizeRAM() && ok }
        if all || task == "purgeable" { ok = optimizePurgeable() && ok }
        if !ok { throw ExitCode.failure }
    }

    @discardableResult
    private func optimizeRAM() -> Bool {
        let before = SystemInfo.memory()
        print(Term.dim("Releasing inactive memory…"))
        let r = Shell.run("/usr/sbin/purge", [])
        let after = SystemInfo.memory()
        if r.status == 0 {
            let delta = after.free - before.free
            let avail = after.free + after.inactive
            print(Term.green("✓ RAM optimized") + "  ·  \(ByteCount.human(max(0, delta))) newly free  ·  \(ByteCount.human(avail)) available")
            return true
        }
        print(Term.yellow("• Could not run purge") + Term.dim(" — try: sudo puremac optimize ram"))
        print(Term.dim("  macOS already reclaims inactive memory automatically under pressure."))
        return false
    }

    @discardableResult
    private func optimizePurgeable() -> Bool {
        let before = SystemInfo.volume("/").available
        print(Term.dim("Releasing purgeable disk space…"))
        let r = Shell.run("/usr/sbin/diskutil", ["apfs", "purgePurgeable", "/"])
        let after = SystemInfo.volume("/").available
        if r.status == 0 {
            let freed = max(0, after - before)
            print(Term.green("✓ Purgeable space released") + "  ·  \(ByteCount.human(freed)) reclaimed")
            return true
        }
        print(Term.yellow("• Could not release purgeable space") + Term.dim(" — try: sudo puremac optimize purgeable"))
        return false
    }
}
