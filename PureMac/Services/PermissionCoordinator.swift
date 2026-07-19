import AppKit
import Combine
import Foundation

/// Centralized coordinator for Full Disk Access (FDA) prompts and continuation flow.
///
/// Replaces the bare "Open System Settings" alert with a sheet-driven flow that:
/// - Auto-opens the Settings pane and reveals PureMac.app in Finder so users can
///   drag the bundle into the FDA list when macOS hasn't auto-registered it
///   (common with Homebrew installs that strip the quarantine attribute).
/// - Polls `FullDiskAccessManager.hasFullDiskAccess` once per second while the
///   sheet is on-screen and auto-dismisses + invokes the continuation callback the
///   moment the user toggles permission on.
/// - Carries the failed-item batch across the prompt so the caller can retry
///   identity-verified items or require a safe rescan for unverified paths.
@MainActor
final class PermissionCoordinator: ObservableObject {
    static let shared = PermissionCoordinator()

    @Published private(set) var isRequesting: Bool = false
    @Published private(set) var hasFullDiskAccess: Bool = false
    @Published private(set) var failedItemPaths: [String] = []
    @Published private(set) var context: PromptContext = .general

    enum PromptContext {
        case general
        case cleanup(failedCount: Int)
        case uninstall(appName: String, failedCount: Int)

        var headline: String {
            switch self {
            case .general:
                return String(localized: "Grant Full Disk Access")
            case .cleanup(let n):
                return String(
                    format: String(localized: "%lld item(s) need Full Disk Access"),
                    Int64(n)
                )
            case .uninstall(let app, let n):
                return String(
                    format: String(localized: "Uninstalling %@: %lld file(s) need Full Disk Access"),
                    app,
                    Int64(n)
                )
            }
        }
    }

    private var pollTimer: Timer?
    private var onGrantCallback: (() -> Void)?
    private var pendingGrantWork: DispatchWorkItem?

    private init() {
        hasFullDiskAccess = FullDiskAccessManager.shared.hasFullDiskAccess
    }

    /// Begin the request flow. `onGranted` fires exactly once when permission
    /// is detected, regardless of whether the sheet was open or already closed.
    ///
    /// Re-entrant: if a request is already in flight, the new context and
    /// callback replace the previous ones (last writer wins) but the polling
    /// timer is not duplicated. Prevents a rapid double-tap from spinning up
    /// two Timers or leaking the first callback's captured state.
    func requestAccess(
        context: PromptContext = .general,
        failedPaths: [String] = [],
        onGranted: @escaping () -> Void
    ) {
        // Drop the previous callback AND cancel any pending grant work
        // before installing the new one. Without the cancel, a second
        // requestAccess() during the 1-second post-grant delay would fire
        // both callbacks — the queued one for the prior batch plus the
        // new one we're installing here.
        onGrantCallback = nil
        pendingGrantWork?.cancel()
        pendingGrantWork = nil

        self.context = context
        self.failedItemPaths = failedPaths
        self.onGrantCallback = onGranted
        self.hasFullDiskAccess = FullDiskAccessManager.shared.hasFullDiskAccess

        if hasFullDiskAccess {
            // Already granted. Fire immediately and skip the sheet — useful for
            // retry-button paths where the user may have granted access in
            // another window between the original failure and the retry tap.
            onGranted()
            onGrantCallback = nil
            return
        }

        isRequesting = true
        // startPolling stops any existing timer first, so re-entry is safe.
        startPolling()
    }

    /// Open System Settings AND reveal PureMac.app in Finder so the user can
    /// drag the bundle directly into the FDA list. Side-by-side windows are
    /// the fastest path when macOS hasn't auto-registered the app.
    func openSettingsAndReveal() {
        FullDiskAccessManager.shared.openFullDiskAccessSettings()
        // Delay the reveal slightly so Settings is the frontmost window first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            FullDiskAccessManager.shared.revealAppInFinder()
        }
    }

    /// Reset PureMac's TCC entry and re-prime registration. Use when the user
    /// reports PureMac doesn't appear in the FDA list (typical after Homebrew
    /// reinstall replaces the bundle with a different code signature).
    func resetAndReprime() {
        _ = FullDiskAccessManager.shared.resetFullDiskAccess()
        FullDiskAccessManager.shared.triggerRegistration()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            FullDiskAccessManager.shared.openFullDiskAccessSettings()
        }
    }

    func dismiss(callRetry: Bool = false) {
        stopPolling()
        // Cancel any pending 1-second post-grant retry — without this, a user
        // who skips the sheet during the success-display delay would still
        // see the retry execute, which contradicts their explicit dismiss.
        pendingGrantWork?.cancel()
        pendingGrantWork = nil
        let callback = onGrantCallback
        onGrantCallback = nil
        isRequesting = false
        failedItemPaths = []
        context = .general
        if callRetry { callback?() }
    }

    /// Refresh permission status without armed polling. Cheap to call on
    /// app-becomes-active.
    ///
    /// If a request is in flight and we just observed the grant, route
    /// through `handleGrant` so the sheet dismisses and the callback fires.
    /// Without this, refreshStatus would flip `hasFullDiskAccess` to true
    /// and the next poll tick's `granted && !hasFullDiskAccess` guard
    /// would skip `handleGrant` — the sheet would sit open in a granted
    /// state and never fire the retry.
    func refreshStatus() {
        Task.detached(priority: .userInitiated) {
            let granted = FullDiskAccessManager.shared.hasFullDiskAccess
            await MainActor.run { [weak self] in
                guard let self else { return }
                let wasGranted = self.hasFullDiskAccess
                self.hasFullDiskAccess = granted
                if granted && !wasGranted && self.isRequesting {
                    self.handleGrant()
                }
            }
        }
    }

    // MARK: - Polling

    private func startPolling() {
        stopPolling()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let granted = FullDiskAccessManager.shared.hasFullDiskAccess
                if granted && !self.hasFullDiskAccess {
                    self.hasFullDiskAccess = true
                    self.handleGrant()
                } else {
                    self.hasFullDiskAccess = granted
                }
            }
        }
        // Run once immediately so a user who granted before opening the sheet
        // doesn't wait a full poll cycle.
        Task { @MainActor [weak self] in
            guard let self else { return }
            if FullDiskAccessManager.shared.hasFullDiskAccess {
                self.hasFullDiskAccess = true
                self.handleGrant()
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func handleGrant() {
        let callback = onGrantCallback
        onGrantCallback = nil
        stopPolling()
        Haptics.success()
        // Cancel any prior pending grant work — guarantees the callback fires
        // at most once even if grant is detected twice in rapid succession
        // (e.g. immediate-read + first poll tick both fire).
        pendingGrantWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.isRequesting = false
            self.failedItemPaths = []
            self.context = .general
            self.pendingGrantWork = nil
            callback?()
        }
        pendingGrantWork = work
        // Give the success state ~1s on screen so the user sees the
        // confirmation tick before the sheet snaps closed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }
}
