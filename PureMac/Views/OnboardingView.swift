import SwiftUI

struct OnboardingView: View {
    @Binding var isComplete: Bool
    @State private var currentPage = 0
    @State private var hasFullDiskAccess = false

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            // Page content
            TabView(selection: $currentPage) {
                welcomePage.tag(0)
                fdaPage.tag(1)
                readyPage.tag(2)
            }
            .tabViewStyle(.automatic)

            // Navigation
            HStack {
                if currentPage > 0 {
                    Button("Back") { withAnimation { currentPage -= 1 } }
                }

                Spacer()

                // Page dots
                HStack(spacing: 8) {
                    ForEach(0..<3, id: \.self) { i in
                        Circle()
                            .fill(i == currentPage ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 8, height: 8)
                    }
                }

                Spacer()

                if currentPage < 2 {
                    Button("Next") { withAnimation { currentPage += 1 } }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Get Started") { isComplete = true }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }
        .frame(width: 520, height: 400)
        .onReceive(timer) { _ in
            if currentPage == 1 {
                checkFDA()
            }
        }
    }

    // MARK: - Welcome

    private var welcomePage: some View {
        VStack(spacing: 20) {
            Spacer()
            if let icon = NSImage(named: "AppIcon") {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 96, height: 96)
            }
            Text("Welcome to PureMac")
                .font(.largeTitle.bold())
            Text("Free, open-source macOS app manager and system cleaner.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 24) {
                featureCard(icon: "magnifyingglass", title: "Smart Scan", desc: "Find junk files across your system")
                featureCard(icon: "trash", title: "App Uninstaller", desc: "Remove apps and all their files")
                featureCard(icon: "doc.questionmark", title: "Orphan Finder", desc: "Find leftovers from deleted apps")
            }
            .padding(.top)
            Spacer()
        }
        .padding()
    }

    private func featureCard(icon: String, title: String, desc: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            Text(title)
                .font(.callout.bold())
            Text(desc)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(width: 130)
    }

    // MARK: - Full Disk Access

    private var fdaPage: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: hasFullDiskAccess ? "checkmark.shield.fill" : "lock.shield")
                .font(.system(size: 48))
                .foregroundStyle(hasFullDiskAccess ? .green : .orange)

            Text("Full Disk Access")
                .font(.title2.bold())

            if hasFullDiskAccess {
                Text("Full Disk Access is granted. You're all set!")
                    .foregroundStyle(.green)
            } else {
                Text("PureMac needs Full Disk Access to scan all caches, Trash, and app data.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Open System Settings > Privacy & Security", systemImage: "1.circle")
                        Label("Select Full Disk Access", systemImage: "2.circle")
                        Label("Enable PureMac", systemImage: "3.circle")
                    }
                    .font(.callout)
                }
                .frame(maxWidth: 380)

                Button("Open System Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                }
                .buttonStyle(.borderedProminent)
            }
            Spacer()
        }
        .padding()
    }

    // MARK: - Ready

    private var readyPage: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            Text("You're Ready")
                .font(.title.bold())

            HStack(spacing: 8) {
                Image(systemName: hasFullDiskAccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(hasFullDiskAccess ? .green : .red)
                Text("Full Disk Access: \(hasFullDiskAccess ? "Granted" : "Not Granted")")
                    .foregroundStyle(.secondary)
            }

            if !hasFullDiskAccess {
                Text("Some features may be limited without Full Disk Access.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Spacer()
        }
        .padding()
    }

    private func checkFDA() {
        hasFullDiskAccess = FullDiskAccessManager.shared.hasFullDiskAccess
    }
}
