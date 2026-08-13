import Foundation

/// Strips foreign-architecture slices from the fat binaries of one app
/// bundle (a UniversalBinaryFinding from UniversalBinaryScanner) and ad-hoc
/// re-signs the resealed copy so it still passes `codesign --verify`. Also
/// removes .lproj localization folders through the same flow, because
/// deleting sealed resources with a plain unlink breaks the bundle's
/// signature.
///
/// Only unsigned or already ad-hoc bundles are ever modified. A bundle
/// carrying a real Developer ID / notarized signature is refused up front:
/// stripping a slice rewrites the Mach-O and destroys that signature, and an
/// ad-hoc re-sign — though it satisfies `codesign --verify` — is rejected by
/// Gatekeeper (`spctl`), which treats an ad-hoc identity as un-notarized. It
/// also breaks Sparkle-style auto-updaters and makes apps that verify their
/// own Developer ID at launch (MacUpdater is the canonical example) refuse to
/// run and report themselves "damaged". The original authority cannot be
/// restored without the vendor's private key, so such bundles are left alone.
///
/// Safety model — the original bundle is never modified in place:
///   1. Signature gate: bundles carrying a real (Developer ID / Apple / Mac
///      App Store) signature are refused, because ad-hoc re-signing cannot
///      preserve their notarized trust. Apps claiming provisioning-backed
///      entitlements (com.apple.developer.*, com.apple.application-identifier)
///      are refused with a more specific error for the same underlying
///      reason — those entitlements are only honored under an Apple-issued
///      certificate, and an ad-hoc signature carrying them is killed by AMFI
///      at spawn.
///   2. Preflight: the bundle and its parent directory must be writable by
///      the current user (the swap below is two renames in the parent).
///      Otherwise fail with `needsAdmin` before touching anything; there
///      is no admin escalation here.
///   3. Stage: clone the whole bundle to a hidden sibling directory (APFS
///      makes the copy cheap) and apply every modification — lipo or lproj
///      removal — to the copy only.
///   4. Sign the staged copy ad-hoc, then verify it with
///      `codesign --verify --deep --strict`. Any failure discards the copy
///      and leaves the original untouched; nothing to roll back, so a
///      failed sign can never leave a mixed Developer ID / ad-hoc bundle.
///   5. Strip com.apple.quarantine from the verified copy. The re-sign
///      changes the cdhash, so a still-quarantined app would otherwise be
///      re-assessed by Gatekeeper and refused as not notarized.
///   6. Swap: rename the original aside, rename the staged copy into place,
///      delete the original. If the delete fails (root-owned contents) the
///      swap is undone and `needsAdmin` is returned, so "success" always
///      means the space was actually freed.
actor BinaryThinner {

    enum ThinningError: LocalizedError {
        /// Bundle, its parent directory, or its contents not writable by
        /// this user. Caller decides what to do; this actor never escalates
        /// privileges.
        case needsAdmin(String)
        /// App claims provisioning-backed entitlements that only work under
        /// its original developer signature; re-signing would stop it
        /// launching, so it is refused before anything is staged.
        case restrictedEntitlements(String)
        /// Bundle carries a real Developer ID / notarized signature that lipo
        /// would invalidate. Ad-hoc re-signing cannot restore notarized trust,
        /// so the bundle is refused before anything is staged.
        case signatureProtected(String)
        case lipoFailed(String, String)
        case swapFailed(String, String)
        case codesignFailed(String, String)
        case verificationFailed(String, String)
        case nothingToThin(String)

        var errorDescription: String? {
            switch self {
            case .needsAdmin(let path):
                return "Not writable by current user: \(path)"
            case .restrictedEntitlements(let app):
                return "Cannot modify \(app): its entitlements require the original developer signature"
            case .signatureProtected(let app):
                return "Cannot thin \(app): it is signed and notarized, and stripping a slice would break its signature"
            case .lipoFailed(let path, let detail):
                return "lipo failed for \(path): \(detail)"
            case .swapFailed(let path, let detail):
                return "Could not swap modified bundle into place at \(path): \(detail)"
            case .codesignFailed(let app, let detail):
                return "Re-signing failed for \(app): \(detail)"
            case .verificationFailed(let app, let detail):
                return "Signature verification failed for \(app): \(detail)"
            case .nothingToThin(let app):
                return "No removable slices in \(app)"
            }
        }
    }

    private let fileManager = FileManager.default

    // MARK: - Public API

    /// Thins every fat binary in the finding and re-signs the bundle.
    /// Success value is the number of bytes actually freed (sum of
    /// before-minus-after file sizes, which can differ slightly from the
    /// scanner's estimate because lipo rewrites the FAT header padding).
    func thin(_ finding: UniversalBinaryFinding) async -> Result<Int64, Error> {
        let binaries = finding.fatBinaries.filter { !$0.removableArchs.isEmpty }
        guard !binaries.isEmpty else {
            return .failure(ThinningError.nothingToThin(finding.appPath))
        }

        let appPath = (finding.appPath as NSString).standardizingPath
        let result = stagedModify(appPath: appPath, appName: finding.appName) { stagedPath in
            var freedBytes: Int64 = 0
            for binary in binaries {
                freedBytes += try self.thinBinary(binary, appPath: appPath, stagedPath: stagedPath)
            }
            return freedBytes
        }

        if case .success(let freed) = result {
            Logger.shared.log("Thinned \(finding.appName): freed \(freed) bytes across \(binaries.count) binaries", level: .info)
        }
        return result
    }

    /// Removes one localization folder from an app bundle through the same
    /// staged clone / re-sign / verify / swap flow as `thin`, so the
    /// bundle's signature seal stays valid after the folder is gone.
    /// `lprojPath` must sit inside `appPath`; the caller is responsible for
    /// validating the .lproj shape and keep-set.
    func removeLproj(at lprojPath: String, fromAppAt appPath: String) async -> Result<Void, Error> {
        let app = (appPath as NSString).standardizingPath
        let lproj = (lprojPath as NSString).standardizingPath
        guard lproj.hasPrefix(app + "/") else {
            return .failure(ThinningError.swapFailed(lprojPath, "localization is outside the app bundle"))
        }

        let appName = ((app as NSString).lastPathComponent as NSString).deletingPathExtension
        let result = stagedModify(appPath: app, appName: appName) { stagedPath in
            let stagedLproj = stagedPath + String(lproj.dropFirst(app.count))
            do {
                try self.fileManager.removeItem(atPath: stagedLproj)
            } catch {
                throw ThinningError.swapFailed(lprojPath, error.localizedDescription)
            }
            return 0
        }
        return result.map { _ in () }
    }

    // MARK: - Staged modification

    /// Clones the bundle, runs `modify` against the clone, re-signs and
    /// verifies the clone, strips quarantine, then atomically swaps it over
    /// the original. Every failure path discards the clone and leaves the
    /// original bundle byte-identical — there is deliberately no in-place
    /// rollback and no re-sign of the original, ever.
    private func stagedModify(
        appPath: String,
        appName: String,
        modify: (String) throws -> Int64
    ) -> Result<Int64, Error> {
        // WITHDRAWN in 2.9.5 (issues #135, #144). Every caller of this method
        // ad-hoc re-signs a third-party bundle, and no signature gate can make
        // that safe: `codesign --deep` skips Contents/Resources, so a Mach-O
        // there keeps its vendor Developer ID while the outer bundle turns
        // ad-hoc, and dyld kills the process for the Team-ID mismatch.
        //
        // `CleaningCategory.scannable` already excludes both app-modifying
        // categories, so nothing should reach here. This refusal is the second
        // layer: a persisted scan result decoded from an older build, or a
        // replayed item list, must also be inert. Remove it only together with
        // a re-signing strategy that preserves the vendor's authority.
        Logger.shared.log(
            "Refusing to modify app bundle at \(appPath): bundle modification is withdrawn (issues #135, #144)",
            level: .warning
        )
        return .failure(ThinningError.signatureProtected(appName))
    }

    /// Retained for the eventual safe implementation; see `stagedModify`.
    private func stagedModifyUnsafe_disabled(
        appPath: String,
        appName: String,
        modify: (String) throws -> Int64
    ) -> Result<Int64, Error> {
        if hasRestrictedEntitlements(appPath) {
            return .failure(ThinningError.restrictedEntitlements(appName))
        }
        if hasProtectedSignature(appPath) {
            return .failure(ThinningError.signatureProtected(appName))
        }

        let parentDir = (appPath as NSString).deletingLastPathComponent
        let bundleName = (appPath as NSString).lastPathComponent
        guard fileManager.isWritableFile(atPath: appPath),
              fileManager.isWritableFile(atPath: parentDir) else {
            return .failure(ThinningError.needsAdmin(appPath))
        }

        // Hidden sibling so the rename into place stays on the same volume
        // (atomic) and Finder never shows the work-in-progress copy.
        let stagingPath = (parentDir as NSString)
            .appendingPathComponent(".\(bundleName).puremac-staging-\(UUID().uuidString)")
        do {
            try fileManager.copyItem(atPath: appPath, toPath: stagingPath)
        } catch {
            try? fileManager.removeItem(atPath: stagingPath)
            return .failure(ThinningError.swapFailed(appPath, "could not stage a working copy: \(error.localizedDescription)"))
        }

        let freedBytes: Int64
        do {
            freedBytes = try modify(stagingPath)
        } catch {
            try? fileManager.removeItem(atPath: stagingPath)
            return .failure(error)
        }

        // Ad-hoc deep re-sign of the staged copy. --preserve-metadata keeps
        // entitlements/flags/identifier so sandboxed and hardened apps keep
        // behaving; "requirements" is deliberately NOT preserved — the old
        // designated requirement names the original Developer ID authority,
        // which an ad-hoc identity can never satisfy.
        let sign = runProcess("/usr/bin/codesign", [
            "--force", "--deep", "--sign", "-",
            "--preserve-metadata=entitlements,flags,identifier",
            stagingPath,
        ])
        guard sign.status == 0 else {
            try? fileManager.removeItem(atPath: stagingPath)
            return .failure(ThinningError.codesignFailed(appPath, sign.stderr))
        }

        let verify = runProcess("/usr/bin/codesign", ["--verify", "--deep", "--strict", stagingPath])
        guard verify.status == 0 else {
            // Common for Electron-style bundles whose nested helper apps
            // break the outer resource seal. The original is untouched, so
            // the app simply stays un-thinned.
            try? fileManager.removeItem(atPath: stagingPath)
            return .failure(ThinningError.verificationFailed(appPath, verify.stderr))
        }

        // The new signature has a new cdhash, so syspolicyd's stored
        // approval no longer applies. Strip quarantine so Gatekeeper does
        // not re-assess the non-notarized ad-hoc signature and refuse the
        // app as damaged. Exit status is ignored — the attribute is usually
        // absent already.
        let xattr = runProcess("/usr/bin/xattr", ["-rd", "com.apple.quarantine", stagingPath])
        if xattr.status != 0 && !xattr.stderr.isEmpty {
            Logger.shared.log("Quarantine strip note for \(bundleName): \(xattr.stderr)", level: .debug)
        }

        // Swap: park the original, move the verified copy into place, then
        // delete the original. Both renames stay inside parentDir.
        let oldPath = (parentDir as NSString)
            .appendingPathComponent(".\(bundleName).puremac-old-\(UUID().uuidString)")
        do {
            try fileManager.moveItem(atPath: appPath, toPath: oldPath)
        } catch {
            try? fileManager.removeItem(atPath: stagingPath)
            return .failure(ThinningError.swapFailed(appPath, error.localizedDescription))
        }
        do {
            try fileManager.moveItem(atPath: stagingPath, toPath: appPath)
        } catch {
            // Put the original back before reporting; it was only renamed.
            try? fileManager.moveItem(atPath: oldPath, toPath: appPath)
            try? fileManager.removeItem(atPath: stagingPath)
            return .failure(ThinningError.swapFailed(appPath, error.localizedDescription))
        }

        do {
            try fileManager.removeItem(atPath: oldPath)
        } catch {
            // Root-owned contents survive a user-level delete. Undo the
            // swap — keeping both copies frees nothing and would leave a
            // hidden orphan bundle next to the app.
            Logger.shared.log("Could not delete replaced bundle at \(oldPath): \(error.localizedDescription)", level: .warning)
            do {
                try fileManager.removeItem(atPath: appPath)
                try fileManager.moveItem(atPath: oldPath, toPath: appPath)
            } catch {
                Logger.shared.log("Could not undo bundle swap for \(appPath); original remains at \(oldPath): \(error.localizedDescription)", level: .error)
                return .failure(ThinningError.swapFailed(appPath, "original bundle left at \(oldPath)"))
            }
            return .failure(ThinningError.needsAdmin(appPath))
        }

        return .success(freedBytes)
    }

    /// Runs lipo for one fat binary against its counterpart inside the
    /// staged copy. Returns the bytes freed for that file.
    private func thinBinary(_ binary: FatBinary, appPath: String, stagedPath: String) throws -> Int64 {
        let binaryPath = (binary.path as NSString).standardizingPath
        guard binaryPath.hasPrefix(appPath + "/") else {
            throw ThinningError.lipoFailed(binary.path, "binary is outside the app bundle")
        }
        let stagedBinary = stagedPath + String(binaryPath.dropFirst(appPath.count))

        let sizeBefore = fileSize(at: stagedBinary)
        let tmpPath = stagedBinary + ".thin"
        var args = [stagedBinary]
        for arch in binary.removableArchs {
            args += ["-remove", arch]
        }
        args += ["-output", tmpPath]

        let lipo = runProcess("/usr/bin/lipo", args)
        guard lipo.status == 0 else {
            try? fileManager.removeItem(atPath: tmpPath)
            throw ThinningError.lipoFailed(binary.path, lipo.stderr)
        }

        // lipo writes the output with default umask permissions; carry the
        // original mode over so executables stay executable.
        if let attrs = try? fileManager.attributesOfItem(atPath: stagedBinary),
           let mode = attrs[.posixPermissions] {
            try? fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: tmpPath)
        }

        do {
            try fileManager.removeItem(atPath: stagedBinary)
            try fileManager.moveItem(atPath: tmpPath, toPath: stagedBinary)
        } catch {
            try? fileManager.removeItem(atPath: tmpPath)
            throw ThinningError.swapFailed(binary.path, error.localizedDescription)
        }

        return sizeBefore - fileSize(at: stagedBinary)
    }

    // MARK: - Helpers

    /// True when the app's main executable claims restricted entitlements
    /// (com.apple.developer.*, com.apple.application-identifier). macOS
    /// only honors those when backed by a provisioning profile and an
    /// Apple-issued certificate; preserved into an ad-hoc signature they
    /// get the process killed at spawn, and `codesign --verify` cannot
    /// detect that, so such apps are refused up front.
    private func hasRestrictedEntitlements(_ appPath: String) -> Bool {
        let result = runProcess("/usr/bin/codesign", ["-d", "--entitlements", "-", "--xml", appPath])
        // Unsigned bundle: nothing to preserve, nothing restricted.
        guard result.status == 0 else { return false }
        return result.stdout.contains("com.apple.developer.")
            || result.stdout.contains("com.apple.application-identifier")
    }

    /// True when the bundle carries a real (Developer ID, Apple, or Mac App
    /// Store) code signature. Stripping an arch slice rewrites the Mach-O and
    /// destroys that signature; an ad-hoc re-sign lets the copy pass
    /// `codesign --verify` but not Gatekeeper (`spctl`), which rejects ad-hoc
    /// identities as un-notarized — so auto-updaters break and apps that check
    /// their own Developer ID at launch (e.g. MacUpdater) refuse to run and
    /// report themselves "damaged". The original authority cannot be restored
    /// without the vendor's private key, so these bundles are never thinned.
    /// Only unsigned or already ad-hoc bundles — which carry no notarized
    /// trust to lose — return false here.
    private func hasProtectedSignature(_ appPath: String) -> Bool {
        // `codesign -d` prints the signature summary to stderr.
        let result = runProcess("/usr/bin/codesign", ["-dvv", appPath])
        // FAIL CLOSED. A non-zero exit is not proof the bundle is unsigned —
        // it also covers a spawn failure (runProcess returns status -1), a
        // read error, or a bundle format codesign cannot parse. Treating any
        // of those as "unsigned, safe to mutate" is how a Developer ID app
        // gets ad-hoc re-signed. If we cannot prove it is unsigned, protect it.
        guard result.status == 0 else { return true }
        let info = result.stdout + result.stderr
        // An already ad-hoc bundle has nothing Gatekeeper would have trusted,
        // so re-thinning + re-ad-hoc-signing leaves it no worse off.
        return !info.contains("Signature=adhoc")
    }

    private func fileSize(at path: String) -> Int64 {
        (try? fileManager.attributesOfItem(atPath: path)[.size] as? Int64).flatMap { $0 } ?? 0
    }

    private func runProcess(_ executable: String, _ args: [String]) -> (status: Int32, stdout: String, stderr: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = args
        let outPipe = Pipe()
        task.standardOutput = outPipe
        let errPipe = Pipe()
        task.standardError = errPipe
        do {
            try task.run()
        } catch {
            return (-1, "", error.localizedDescription)
        }
        // Drain both pipes before waiting so a chatty child can't dead-lock
        // on a full pipe buffer.
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let stdout = String(data: outData, encoding: .utf8) ?? ""
        let stderr = String(data: errData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (task.terminationStatus, stdout, stderr)
    }
}
