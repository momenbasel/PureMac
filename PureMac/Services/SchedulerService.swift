import Foundation
import Combine

enum ScheduledScanOutcome {
    case completed
    case deferred
    case cancelled
}

@MainActor
class SchedulerService: ObservableObject {
    @Published var config: ScheduleConfig {
        didSet { saveConfig() }
    }
    @Published private(set) var isRunning = false
    @Published private(set) var isDeferred = false

    private var timer: Timer?
    private let configKey = "PureMac.ScheduleConfig"
    private let consentKey = "PureMac.ScheduleEnabledByUser"
    private let defaults: UserDefaults
    private let now: () -> Date
    private var onTrigger: (() async -> ScheduledScanOutcome)?

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
        var saved = defaults.data(forKey: configKey)
            .flatMap { try? JSONDecoder().decode(ScheduleConfig.self, from: $0) } ?? ScheduleConfig()
        let consent = defaults.object(forKey: consentKey) as? Bool
        if !(consent ?? defaults.bool(forKey: "PureMac.OnboardingComplete")) {
            saved.isEnabled = false
            saved.autoClean = false
        }
        if !saved.isEnabled || (saved.nextRunDate?.timeIntervalSince(now()) ?? 0) < 60 {
            saved.nextRunDate = nil
        }
        self.config = saved
    }

    func setTrigger(_ handler: @escaping () async -> ScheduledScanOutcome) {
        onTrigger = handler
    }

    func start() {
        stop()
        guard config.isEnabled else { return }
        if config.nextRunDate == nil {
            config.nextRunDate = now().addingTimeInterval(config.interval.seconds)
        }

        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.checkAndRun()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func updateSchedule(interval: ScheduleInterval) {
        config.interval = interval
        isDeferred = false
        config.nextRunDate = config.isEnabled ? now().addingTimeInterval(interval.seconds) : nil
    }

    func toggleEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: consentKey)
        config.isEnabled = enabled
        config.nextRunDate = nil
        isDeferred = false
        start()
    }

    func checkAndRun() async {
        guard !isRunning, config.isEnabled, let deadline = config.nextRunDate,
              deadline <= now(), let onTrigger else { return }

        isRunning = true
        let outcome = await onTrigger()
        isRunning = false
        let finishedAt = now()
        if outcome == .completed {
            config.lastRunDate = finishedAt
        }
        guard config.isEnabled, config.nextRunDate == deadline else { return }
        isDeferred = outcome == .deferred
        if !isDeferred {
            config.nextRunDate = finishedAt.addingTimeInterval(config.interval.seconds)
        }
    }

    deinit { timer?.invalidate() }

    private func saveConfig() {
        if let data = try? JSONEncoder().encode(config) {
            defaults.set(data, forKey: configKey)
        }
    }

    // MARK: - LaunchAgent Management

    func installLaunchAgent() {
        let plistName = "com.puremac.scheduler"
        let plistPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(plistName).plist")

        guard let appPath = Bundle.main.executablePath else { return }

        let intervalSeconds = Int(config.interval.seconds)
        let plistContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(plistName)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(appPath)</string>
                <string>--scheduled-clean</string>
            </array>
            <key>StartInterval</key>
            <integer>\(intervalSeconds)</integer>
            <key>RunAtLoad</key>
            <false/>
        </dict>
        </plist>
        """

        try? plistContent.write(to: plistPath, atomically: true, encoding: .utf8)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["load", plistPath.path]
        try? task.run()
        task.waitUntilExit()
    }

    func uninstallLaunchAgent() {
        let plistName = "com.puremac.scheduler"
        let plistPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(plistName).plist")

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["unload", plistPath.path]
        try? task.run()
        task.waitUntilExit()

        try? FileManager.default.removeItem(at: plistPath)
    }
}
