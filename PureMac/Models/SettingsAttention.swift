import Foundation

/// Only actionable, observed conditions belong here. An unchecked updater or
/// an intentionally disabled preference is not a settings problem.
enum SettingsAttention {
    enum Issue: String, Identifiable {
        case diskAccess, startup, restart, updateFailed, updateAvailable
        var id: Self { self }
        var opensUpdates: Bool { self == .updateFailed || self == .updateAvailable }
        var title: String {
            switch self {
            case .diskAccess: return String(localized: "Review Full Disk Access")
            case .startup: return String(localized: "Review launch at login")
            case .restart: return String(localized: "Restart to apply your language")
            case .updateFailed: return String(localized: "Try checking for updates again")
            case .updateAvailable: return String(localized: "A PureMac update is available")
            }
        }
        var icon: String {
            switch self {
            case .diskAccess: return "lock.shield"
            case .startup: return "power"
            case .restart: return "arrow.clockwise"
            case .updateFailed: return "arrow.triangle.2.circlepath"
            case .updateAvailable: return "arrow.down.circle"
            }
        }
    }

    static func issues(hasFullDiskAccess: Bool, updateState: UpdateService.State,
                       needsRestart: Bool = false, startupError: String? = nil) -> [Issue] {
        var issues: [Issue] = []
        if !hasFullDiskAccess { issues.append(.diskAccess) }
        if startupError != nil { issues.append(.startup) }
        if needsRestart { issues.append(.restart) }
        switch updateState {
        case .failed: issues.append(.updateFailed)
        case .available: issues.append(.updateAvailable)
        case .idle, .checking, .upToDate: break
        }
        return issues
    }
}
