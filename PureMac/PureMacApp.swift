import SwiftUI

@main
struct PureMacApp: App {
    @StateObject private var appViewModel = AppViewModel()
    @AppStorage("PureMac.Appearance") private var appearance: AppAppearance = .system
    @AppStorage("PureMac.OnboardingComplete") private var onboardingComplete = false

    var body: some Scene {
        WindowGroup {
            Group {
                if onboardingComplete {
                    ContentView()
                } else {
                    OnboardingView(isComplete: $onboardingComplete)
                }
            }
            .environmentObject(appViewModel)
            .frame(minWidth: 900, minHeight: 600)
            .preferredColorScheme(appearance.colorScheme)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1000, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView()
                .environmentObject(appViewModel)
        }
    }
}
