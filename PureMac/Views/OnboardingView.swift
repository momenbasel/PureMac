import SwiftUI

struct OnboardingView: View {
    @Binding var isComplete: Bool
    @State private var currentPage = 0
    @State private var hasFullDiskAccess = false
    @State private var appeared = false
    @State private var hasOpenedSettings = false
    @State private var showDiagnostics = false

    // Per-path access checks
    @State private var accessResults: [ProtectedPath] = ProtectedPath.allPaths

    private let timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            // Page content
            Group {
                switch currentPage {
                case 0: welcomePage
                case 1: fdaPage
                case 2: readyPage
                default: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Navigation
            HStack {
                if currentPage > 0 {
                    Button("Back") {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                            currentPage -= 1
                        }
                    }
                    .transition(.opacity)
                }

                Spacer()

                // Page dots
                HStack(spacing: 8) {
                    ForEach(0..<3, id: \.self) { i in
                        Circle()
                            .fill(i == currentPage ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 8, height: 8)
                            .scaleEffect(i == currentPage ? 1.2 : 1.0)
                            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: currentPage)
                    }
                }

                Spacer()

                if currentPage < 2 {
                    Button("Next") {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                            currentPage += 1
                        }
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Get Started") { isComplete = true }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }
        .frame(width: 560, height: 460)
        .onAppear {
            withAnimation(.easeOut(duration: 0.6).delay(0.1)) {
                appeared = true
            }
        }
        .onReceive(timer) { _ in
            if currentPage == 1 {
                refreshAccessChecks()
            }
        }
    }

    // MARK: - Welcome

    private var welcomePage: some View {
        VStack(spacing: 24) {
            Spacer()

            if let icon = NSImage(named: "AppIcon") {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .scaleEffect(appeared ? 1.0 : 0.5)
                    .opacity(appeared ? 1 : 0)
            }

            VStack(spacing: 8) {
                Text("Welcome to PureMac")
                    .font(.largeTitle.bold())
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 10)

                Text("Free, open-source macOS app manager and system cleaner.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 10)
            }

            HStack(spacing: 20) {
                featureCard(
                    icon: "magnifyingglass",
                    title: "Smart Scan",
                    desc: "Find junk files across your system",
                    delay: 0.15
                )
                featureCard(
                    icon: "trash",
                    title: "App Uninstaller",
                    desc: "Remove apps and all their files",
                    delay: 0.25
                )
                featureCard(
                    icon: "doc.questionmark",
                    title: "Orphan Finder",
                    desc: "Find leftovers from deleted apps",
                    delay: 0.35
                )
            }
            .padding(.top, 4)

            Spacer()
        }
        .padding()
        .transition(.asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        ))
    }

    private func featureCard(icon: String, title: String, desc: String, delay: Double) -> some View {
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
        .frame(width: 140)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 20)
        .animation(.easeOut(duration: 0.5).delay(delay), value: appeared)
    }

    // MARK: - Full Disk Access

    private var fdaPage: some View {
        VStack(spacing: 14) {
            Image(systemName: hasFullDiskAccess ? "checkmark.shield.fill" : "lock.shield")
                .font(.system(size: 40))
                .foregroundStyle(hasFullDiskAccess ? .green : .orange)
                .animation(.easeInOut(duration: 0.3), value: hasFullDiskAccess)
                .padding(.top, 8)

            Text("Full Disk Access")
                .font(.title2.bold())

            if hasFullDiskAccess {
                grantedView
            } else if hasOpenedSettings {
                instructionsView
            } else {
                introView
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
        .onAppear {
            FullDiskAccessManager.shared.triggerRegistration()
            refreshAccessChecks()
        }
        .onChange(of: hasFullDiskAccess) { granted in
            if granted, currentPage == 1 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                        currentPage = 2
                    }
                }
            }
        }
        .transition(.asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        ))
    }

    private var introView: some View {
        VStack(spacing: 12) {
            Text("PureMac needs Full Disk Access to uninstall apps, find leftover files, and clean protected caches.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            Button {
                openSettingsAndAdvance()
            } label: {
                Label("Open System Settings", systemImage: "gear")
                    .frame(minWidth: 200)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .padding(.top, 4)

            Text("We'll guide you through the next steps.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var instructionsView: some View {
        VStack(spacing: 10) {
            Text("In System Settings, do this:")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                stepRow(number: 1, text: "Privacy & Security → Full Disk Access")
                stepRow(number: 2, text: "Find **PureMac** and turn the toggle on")
                stepRow(number: 3, text: "Authenticate with Touch ID or your password")
            }
            .frame(maxWidth: 420, alignment: .leading)

            HStack(spacing: 8) {
                Button {
                    FullDiskAccessManager.shared.openFullDiskAccessSettings()
                } label: {
                    Label("Reopen Settings", systemImage: "gear")
                }

                Menu {
                    Button("PureMac isn't in the list — reveal it") {
                        FullDiskAccessManager.shared.revealAppInFinder()
                    }
                    Button("Reset permissions and re-prompt") {
                        _ = FullDiskAccessManager.shared.resetFullDiskAccess()
                        FullDiskAccessManager.shared.triggerRegistration()
                        refreshAccessChecks()
                    }
                    Divider()
                    Button(showDiagnostics ? "Hide diagnostics" : "Show diagnostics") {
                        showDiagnostics.toggle()
                    }
                } label: {
                    Label("Trouble?", systemImage: "questionmark.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.top, 4)

            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Waiting for permission…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 2)

            if showDiagnostics {
                diagnosticsList
            }
        }
    }

    private var grantedView: some View {
        VStack(spacing: 8) {
            Text("Permission granted.")
                .foregroundStyle(.green)
                .font(.callout.weight(.semibold))
            Text("PureMac can now manage protected files.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .transition(.opacity.combined(with: .scale))
    }

    private func stepRow(number: Int, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.callout.bold())
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentColor))
            Text(.init(text))
                .font(.callout)
            Spacer()
        }
    }

    private var diagnosticsList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(accessResults) { path in
                HStack(spacing: 8) {
                    Image(systemName: path.accessible ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(path.accessible ? .green : .red.opacity(0.7))
                        .font(.system(size: 11))
                    Image(systemName: path.icon)
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                    Text(path.label)
                        .font(.caption)
                    Spacer()
                    Text(path.accessible ? "OK" : "Blocked")
                        .font(.caption2)
                        .foregroundStyle(path.accessible ? .green : .orange)
                }
            }
        }
        .frame(maxWidth: 360)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
    }

    private func openSettingsAndAdvance() {
        FullDiskAccessManager.shared.openFullDiskAccessSettings()
        withAnimation(.easeInOut(duration: 0.25)) {
            hasOpenedSettings = true
        }
    }

    // MARK: - Ready

    private var readyPage: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
                .scaleEffect(appeared ? 1.0 : 0.3)
                .animation(.spring(response: 0.5, dampingFraction: 0.6), value: currentPage)

            Text("You're Ready")
                .font(.title.bold())

            // Summary of access
            let granted = accessResults.filter(\.accessible).count
            let total = accessResults.count

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: hasFullDiskAccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(hasFullDiskAccess ? .green : .orange)
                    Text("\(granted)/\(total) protected locations accessible")
                        .foregroundStyle(.secondary)
                }

                if !hasFullDiskAccess {
                    Text("Some features will be limited. You can grant Full Disk Access later in System Settings.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }
            }

            Spacer()
        }
        .padding()
        .transition(.asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        ))
    }

    // MARK: - Permission Checking

    private func refreshAccessChecks() {
        for i in accessResults.indices {
            let path = accessResults[i].path
            let canAccess: Bool
            if FileManager.default.fileExists(atPath: path) {
                canAccess = FileManager.default.isReadableFile(atPath: path)
            } else {
                // Path doesn't exist on this system — not blocked, just absent
                canAccess = true
            }
            if accessResults[i].accessible != canAccess {
                withAnimation(.easeInOut(duration: 0.3)) {
                    accessResults[i].accessible = canAccess
                }
            }
        }
        hasFullDiskAccess = accessResults.allSatisfy(\.accessible)
    }
}

// MARK: - Protected Path Model

struct ProtectedPath: Identifiable {
    let id = UUID()
    let label: String
    let path: String
    let icon: String
    var accessible: Bool = false

    static var allPaths: [ProtectedPath] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            ProtectedPath(label: "Trash", path: "\(home)/.Trash", icon: "trash"),
            ProtectedPath(label: "Mail Data", path: "\(home)/Library/Mail", icon: "envelope"),
            ProtectedPath(label: "Safari Data", path: "\(home)/Library/Safari/Bookmarks.plist", icon: "safari"),
            ProtectedPath(label: "Desktop", path: "\(home)/Desktop", icon: "menubar.dock.rectangle"),
            ProtectedPath(label: "Documents", path: "\(home)/Documents", icon: "folder"),
            ProtectedPath(label: "TCC Database", path: "/Library/Application Support/com.apple.TCC/TCC.db", icon: "lock.shield"),
        ]
    }
}
