import Foundation

/// One fat Mach-O file inside an app bundle, together with the slices that
/// can be stripped on this machine and the bytes doing so would reclaim.
/// `removableArchs` uses lipo's arch spelling ("x86_64", "arm64", ...) so it
/// can be passed straight to `lipo -remove` by BinaryThinner.
struct FatBinary: Sendable {
    let path: String
    let removableArchs: [String]
    let reclaimableBytes: Int64
}

/// A universal-binary discovery for one app bundle: the app's main
/// executable plus every fat framework/dylib found under Contents/Frameworks
/// (where most of the savings live for Electron apps). `appStore` marks apps
/// carrying a _MASReceipt — thinning those can break receipt validation, so
/// the caller should surface them unselected by default.
struct UniversalBinaryFinding: Identifiable, Sendable {
    let id = UUID()
    let appPath: String
    let appName: String
    let executablePath: String
    let nativeArch: String
    /// Union of removable arch names across all fat binaries in the bundle.
    let removableArchs: [String]
    /// Total bytes freed by stripping every foreign slice in the bundle.
    let reclaimableBytes: Int64
    let appStore: Bool
    /// Every fat Mach-O in the bundle with per-file removable archs — the
    /// exact work list BinaryThinner executes.
    let fatBinaries: [FatBinary]
}

/// Finds universal (fat) app binaries carrying a slice for the architecture
/// this Mac does not run natively, and computes how many bytes stripping the
/// foreign slice would reclaim. Pure logic — no mutation, no privileged
/// operations — so it stays a plain Sendable struct rather than an actor.
///
/// The FAT header is parsed by hand from the first 4 KB of each candidate
/// file instead of shelling out to `lipo -info` per file: an /Applications
/// walk touches thousands of framework binaries and process spawns would
/// dominate the scan time.
struct UniversalBinaryScanner: Sendable {

    // MARK: - Mach-O constants (values as they appear byte-swapped from disk)

    private static let fatMagic: UInt32 = 0xcafe_babe
    private static let fatMagic64: UInt32 = 0xcafe_babf
    private static let cpuTypeX86_64: UInt32 = 0x0100_0007
    private static let cpuTypeARM64: UInt32 = 0x0100_000c

    /// lipo arch spelling per (cputype, masked cpusubtype). arm64e and x86_64h
    /// are distinct lipo names, so the subtype matters for `-remove` to hit
    /// the right slice.
    private static func archName(cpuType: UInt32, cpuSubtype: UInt32) -> String? {
        // High byte of cpusubtype carries capability flags (e.g. LIB64,
        // PTRAUTH versioning) — mask them off before matching.
        let subtype = cpuSubtype & 0x00ff_ffff
        switch (cpuType, subtype) {
        case (0x0000_0007, _): return "i386"
        case (Self.cpuTypeX86_64, 8): return "x86_64h"
        case (Self.cpuTypeX86_64, _): return "x86_64"
        case (0x0000_000c, _): return "arm"
        case (Self.cpuTypeARM64, 2): return "arm64e"
        case (Self.cpuTypeARM64, _): return "arm64"
        default: return nil
        }
    }

    /// The machine's native architecture, asked of the kernel at runtime.
    /// A compile-time #if arch check would follow whichever slice PureMac
    /// itself runs as — under Rosetta the x86_64 slice would classify every
    /// app's native arm64/arm64e slices as removable, and thinning would
    /// strip them. hw.optional.arm64 is absent on Intel hardware.
    private static let hostIsARM64: Bool = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 else {
            return false
        }
        return value == 1
    }()
    private static var hostCPUType: UInt32 { hostIsARM64 ? cpuTypeARM64 : cpuTypeX86_64 }
    private static var hostArchName: String { hostIsARM64 ? "arm64" : "x86_64" }

    private var fileManager: FileManager { .default }

    // MARK: - Public API

    /// Walks the given application directories (top level plus one nested
    /// level, so apps grouped in subfolders like /Applications/Utilities are
    /// found) and returns one finding per app that has at least one foreign
    /// slice to strip.
    ///
    /// Skipped entirely: anything under /System, and PureMac itself (thinning
    /// the running binary out from under the process is asking for trouble).
    /// App Store apps (Contents/_MASReceipt present) are still reported but
    /// flagged `appStore = true`.
    func scan(
        applicationDirs: [String] = ["/Applications", "\(NSHomeDirectory())/Applications"]
    ) -> [UniversalBinaryFinding] {
        var findings: [UniversalBinaryFinding] = []
        let ownBundlePath = Bundle.main.bundleURL.resolvingSymlinksInPath().path

        for dir in applicationDirs {
            for appPath in appBundles(in: dir) {
                let resolved = URL(fileURLWithPath: appPath).resolvingSymlinksInPath().path
                guard !resolved.hasPrefix("/System"), resolved != ownBundlePath else { continue }
                if let finding = inspectApp(at: appPath) {
                    findings.append(finding)
                }
            }
        }

        return findings.sorted { $0.reclaimableBytes > $1.reclaimableBytes }
    }

    /// Rebuilds the finding for a single app bundle. Used by CleaningEngine
    /// to re-derive the lipo work list from a CleanableItem's bundle path
    /// right before thinning, so a stale scan can never strip slices the
    /// bundle no longer has. Same /System and self-bundle guards as scan().
    func finding(forAppAt appPath: String) -> UniversalBinaryFinding? {
        let resolved = URL(fileURLWithPath: appPath).resolvingSymlinksInPath().path
        let ownBundlePath = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        guard !resolved.hasPrefix("/System"), resolved != ownBundlePath else { return nil }
        return inspectApp(at: appPath)
    }

    // MARK: - Enumeration

    /// `.app` bundles at the top level of `dir`, plus one nested level for
    /// subfolders (e.g. /Applications/Utilities/*.app). No deeper recursion —
    /// helper .app bundles nested inside other apps (and PlugIns/XPCServices/
    /// Helpers) are intentionally not walked, so their fat slices are not
    /// counted; savings are under-reported for those, never over-reported.
    private func appBundles(in dir: String) -> [String] {
        guard let entries = try? fileManager.contentsOfDirectory(atPath: dir) else { return [] }
        var apps: [String] = []
        for entry in entries {
            let path = (dir as NSString).appendingPathComponent(entry)
            if entry.hasSuffix(".app") {
                apps.append(path)
                continue
            }
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
            if let nested = try? fileManager.contentsOfDirectory(atPath: path) {
                for sub in nested where sub.hasSuffix(".app") {
                    apps.append((path as NSString).appendingPathComponent(sub))
                }
            }
        }
        return apps
    }

    // MARK: - Per-app inspection

    private func inspectApp(at appPath: String) -> UniversalBinaryFinding? {
        let contents = (appPath as NSString).appendingPathComponent("Contents")
        let infoPlistPath = (contents as NSString).appendingPathComponent("Info.plist")

        guard let plist = NSDictionary(contentsOfFile: infoPlistPath),
              let executableName = plist["CFBundleExecutable"] as? String else {
            // Not a readable bundle (broken install, sandbox denial) — skip.
            Logger.shared.log("Universal binary scan: unreadable Info.plist at \(infoPlistPath)", level: .warning)
            return nil
        }

        let executablePath = (contents as NSString)
            .appendingPathComponent("MacOS/\(executableName)")

        var fatBinaries: [FatBinary] = []
        if let main = parseFatFile(at: executablePath) {
            fatBinaries.append(main)
        }
        fatBinaries.append(contentsOf: fatFrameworkBinaries(in: contents))

        guard !fatBinaries.isEmpty else { return nil }

        let totalBytes = fatBinaries.reduce(Int64(0)) { $0 + $1.reclaimableBytes }
        guard totalBytes > 0 else { return nil }

        let appName = (plist["CFBundleDisplayName"] as? String)
            ?? (plist["CFBundleName"] as? String)
            ?? ((appPath as NSString).lastPathComponent as NSString).deletingPathExtension

        let receiptPath = (contents as NSString).appendingPathComponent("_MASReceipt")
        let isAppStore = fileManager.fileExists(atPath: receiptPath)

        let archUnion = Array(Set(fatBinaries.flatMap { $0.removableArchs })).sorted()

        return UniversalBinaryFinding(
            appPath: appPath,
            appName: appName,
            executablePath: executablePath,
            nativeArch: Self.hostArchName,
            removableArchs: archUnion,
            reclaimableBytes: totalBytes,
            appStore: isAppStore,
            fatBinaries: fatBinaries
        )
    }

    /// Fat binaries under Contents/Frameworks: top-level *.dylib files plus
    /// each *.framework's Versions/*/<binary>. One nested level only —
    /// symlinks (Versions/Current, the framework-root binary link) are
    /// skipped so the same file is never counted twice.
    private func fatFrameworkBinaries(in contentsDir: String) -> [FatBinary] {
        let frameworksDir = (contentsDir as NSString).appendingPathComponent("Frameworks")
        guard let entries = try? fileManager.contentsOfDirectory(atPath: frameworksDir) else { return [] }

        var result: [FatBinary] = []
        for entry in entries {
            let entryPath = (frameworksDir as NSString).appendingPathComponent(entry)
            if entry.hasSuffix(".dylib") {
                if isRegularFile(entryPath), let fat = parseFatFile(at: entryPath) {
                    result.append(fat)
                }
            } else if entry.hasSuffix(".framework") {
                let versionsDir = (entryPath as NSString).appendingPathComponent("Versions")
                guard let versions = try? fileManager.contentsOfDirectory(atPath: versionsDir) else { continue }
                for version in versions {
                    let versionPath = (versionsDir as NSString).appendingPathComponent(version)
                    guard isRealDirectory(versionPath),
                          let files = try? fileManager.contentsOfDirectory(atPath: versionPath) else { continue }
                    for file in files {
                        let filePath = (versionPath as NSString).appendingPathComponent(file)
                        guard isRegularFile(filePath) else { continue }
                        if let fat = parseFatFile(at: filePath) {
                            result.append(fat)
                        }
                    }
                }
            }
        }
        return result
    }

    /// Regular file, not a symlink — framework layouts are full of symlinks
    /// back into Versions/ and following them would double-count slices.
    private func isRegularFile(_ path: String) -> Bool {
        guard let attrs = try? fileManager.attributesOfItem(atPath: path) else { return false }
        return (attrs[.type] as? FileAttributeType) == .typeRegular
    }

    /// Directory reached without following a symlink (filters Versions/Current).
    private func isRealDirectory(_ path: String) -> Bool {
        guard let attrs = try? fileManager.attributesOfItem(atPath: path) else { return false }
        return (attrs[.type] as? FileAttributeType) == .typeDirectory
    }

    // MARK: - FAT header parsing

    /// Reads the first 4 KB of the file and parses the Mach-O FAT header.
    /// Returns nil for thin (single-arch) binaries, non-Mach-O files, and
    /// anything unreadable or malformed (logged, never thrown). All header
    /// fields are big-endian on disk regardless of host, so every field is
    /// byte-swapped on read.
    private func parseFatFile(at path: String) -> FatBinary? {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            // Common for sandbox-restricted bundles; not worth an error.
            Logger.shared.log("Universal binary scan: cannot open \(path)", level: .warning)
            return nil
        }
        defer { try? handle.close() }

        guard let data = try? handle.read(upToCount: 4096), data.count >= 8 else {
            return nil
        }
        let bytes = [UInt8](data)

        func be32(_ offset: Int) -> UInt32? {
            guard offset + 4 <= bytes.count else { return nil }
            return (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16)
                | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
        }
        func be64(_ offset: Int) -> UInt64? {
            guard offset + 8 <= bytes.count,
                  let high = be32(offset), let low = be32(offset + 4) else { return nil }
            return (UInt64(high) << 32) | UInt64(low)
        }

        guard let magic = be32(0),
              magic == Self.fatMagic || magic == Self.fatMagic64 else {
            return nil // thin binary, script, or not Mach-O at all
        }
        let is64 = (magic == Self.fatMagic64)

        guard let nfat = be32(4), nfat > 0, nfat <= 16 else {
            // 0xcafebabe also opens Java .class files; an implausible arch
            // count is the tell. Treat as not-a-fat-binary.
            return nil
        }

        // fat_arch is 20 bytes (cputype, cpusubtype, offset, size, align);
        // fat_arch_64 is 32 (64-bit offset/size plus a reserved word).
        let entrySize = is64 ? 32 : 20
        let fileSize = (try? fileManager.attributesOfItem(atPath: path)[.size] as? Int64) ?? nil

        var removableArchs: [String] = []
        var reclaimable: Int64 = 0

        for index in 0..<Int(nfat) {
            let base = 8 + index * entrySize
            guard let cpuType = be32(base), let cpuSubtype = be32(base + 4) else {
                Logger.shared.log("Universal binary scan: truncated FAT header in \(path)", level: .warning)
                return nil
            }
            let sliceSize: Int64
            if is64 {
                guard let size = be64(base + 16) else {
                    Logger.shared.log("Universal binary scan: truncated fat_arch_64 in \(path)", level: .warning)
                    return nil
                }
                sliceSize = Int64(bitPattern: size)
            } else {
                guard let size = be32(base + 12) else {
                    Logger.shared.log("Universal binary scan: truncated fat_arch in \(path)", level: .warning)
                    return nil
                }
                sliceSize = Int64(size)
            }

            // Slice must lie inside the file, or the header is garbage
            // (e.g. a Java class file that slipped past the arch-count check).
            if let fileSize, sliceSize <= 0 || sliceSize > fileSize {
                return nil
            }

            guard cpuType != Self.hostCPUType else { continue }
            guard let name = Self.archName(cpuType: cpuType, cpuSubtype: cpuSubtype) else {
                // Foreign slice of an arch lipo can't name for us — leave it.
                Logger.shared.log("Universal binary scan: unknown cputype 0x\(String(cpuType, radix: 16)) in \(path)", level: .debug)
                continue
            }
            removableArchs.append(name)
            reclaimable += sliceSize
        }

        guard !removableArchs.isEmpty else { return nil }
        return FatBinary(path: path, removableArchs: removableArchs, reclaimableBytes: reclaimable)
    }
}
