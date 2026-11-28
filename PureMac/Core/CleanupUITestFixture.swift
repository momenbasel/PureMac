#if DEBUG
import AppKit

enum CleanupUITestFixture {
    static let home: URL? = {
        guard let token = ProcessInfo.processInfo.environment["PUREMAC_UI_TEST_RUN"] else { return nil }
        guard let id = UUID(uuidString: token) else { fatalError("Invalid UI test run ID") }
        let root = URL(fileURLWithPath: "/private/tmp/PureMacUITest-\(id.uuidString)", isDirectory: true)
        for directory in [root, root.appendingPathComponent("Library"),
                          root.appendingPathComponent("Library/Caches"), root.appendingPathComponent("Library/HTTPStorages")] {
            let attributes = try? FileManager.default.attributesOfItem(atPath: directory.path)
            guard attributes?[.type] as? FileAttributeType == .typeDirectory,
                  attributes?[.ownerAccountID] as? UInt32 == getuid() else {
                fatalError("UI test fixture directory is unavailable")
            }
        }
        return root
    }()

    @MainActor
    static func makeState(home: URL) -> AppState {
        let token = ProcessInfo.processInfo.environment["PUREMAC_UI_TEST_APP_RECOVERY"]
        let recoveryRun = token.flatMap(UUID.init(uuidString:)).flatMap { id in
            home.lastPathComponent == "PureMacUITest-\(id.uuidString)" ? id : nil
        }
        let bundle = home.appendingPathComponent("Fixture.app", isDirectory: true)
        let sessionName = recoveryRun.map { "Recovery-\($0.uuidString).session" } ?? "Fixture.session"
        let session = home.appendingPathComponent("Library/HTTPStorages/\(sessionName)")
        let state = AppState(performStartupTasks: false, homeDirectory: home, scanCategories: [.userCache, .aiApps, .mailAttachments],
                             appFileScanner: { _, _, completion in completion([]) },
                             appFileTrasher: { requested in
            guard let recoveryRun, requested.path == session.path, let physical = realpath(requested.path, nil)
            else { throw CocoaError(.userCancelled) }
            defer { free(physical) }
            guard String(cString: physical) == session.path else { throw CocoaError(.userCancelled) }
            let attributes = try FileManager.default.attributesOfItem(atPath: requested.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  attributes[.ownerAccountID] as? UInt32 == getuid() else { throw CocoaError(.userCancelled) }
            let moved = home.appendingPathComponent("Trashed-\(recoveryRun.uuidString).session")
            try FileManager.default.moveItem(at: requested, to: moved)
            return moved
        })
        state.fdaBannerDismissed = true
        if FileManager.default.fileExists(atPath: bundle.path) {
            let attrs = try? FileManager.default.attributesOfItem(atPath: bundle.path)
            let sessionAttrs = try? FileManager.default.attributesOfItem(atPath: session.path)
            guard attrs?[.type] as? FileAttributeType == .typeDirectory,
                  sessionAttrs?[.type] as? FileAttributeType == .typeRegular else {
                fatalError("Invalid disposable app fixture")
            }
            let app = InstalledApp(id: UUID(), appName: "Fixture", bundleIdentifier: "test.puremac.fixture",
                                   path: bundle, icon: NSWorkspace.shared.icon(forFile: bundle.path), size: 0)
            state.installedApps = [app]
            state.selectedApp = app
            state.discoveredFiles = [bundle, session]
            state.selectedFiles = [bundle]
        }
        return state
    }
}
#endif
