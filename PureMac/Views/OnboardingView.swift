import SwiftUI

struct OnboardingView: View {
    @Binding var isComplete: Bool
    @State private var currentPage = 0
    @State private var hasFullDiskAccess = false
    @State private var appeared = false

    // Per-path access checks
    @State private var accessResults: [ProtectedPath] = ProtectedPath.allPaths

    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

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

    private func featureCard(icon: String, title: LocalizedStringKey, desc: LocalizedStringKey, delay: Double) -> some View {
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
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: hasFullDiskAccess ? "checkmark.shield.fill" : "lock.shield")
                .font(.system(size: 44))
                .foregroundStyle(hasFullDiskAccess ? .green : .orange)
                .animation(.easeInOut(duration: 0.3), value: hasFullDiskAccess)

            Text("Full Disk Access")
                .font(.title2.bold())

            if hasFullDiskAccess {
                Text("All permissions granted. You're all set!")
                    .foregroundStyle(.green)
                    .transition(.opacity.combined(with: .scale))
            } else {
                Text("PureMac needs Full Disk Access to scan protected locations.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }

            // Permission checklist
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(accessResults.enumerated()), id: \.element.id) { index, path in
                    HStack(spacing: 10) {
                        Image(systemName: path.accessible ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(path.accessible ? .green : .red.opacity(0.7))
                            .font(.system(size: 14))

                        Image(systemName: path.icon)
                            .foregroundStyle(.secondary)
                            .frame(width: 16)

                        Text(path.label)
                            .font(.callout)

                        Spacer()

                        Text(path.accessible ? "Accessible" : "Blocked")
                            .font(.caption)
                            .foregroundStyle(path.accessible ? .green : .orange)
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(path.accessible ? Color.green.opacity(0.06) : Color.orange.opacity(0.06))
                    )
                    .opacity(appeared ? 1 : 0)
                    .offset(x: appeared ? 0 : -20)
                    .animation(.easeOut(duration: 0.4).delay(Double(index) * 0.05), value: appeared)
                }
            }
            .frame(maxWidth: 400)
            .padding(.vertical, 4)

            if !hasFullDiskAccess {
                Button {
                    FullDiskAccessManager.shared.openFullDiskAccessSettings()
                } label: {
                    Label("Open System Settings", systemImage: "gear")
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)

                Text("Enable PureMac in Privacy & Security → Full Disk Access")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding()
        .transition(.asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        ))
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
