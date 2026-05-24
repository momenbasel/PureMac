import SwiftUI

/// First-launch flow. Four scenes, large typography, plenty of breathing
/// room. Sequence is welcome → mission → permission (with live demo) →
/// ready. Skip is always available — we don't want to gate adoption on a
/// reluctant user, but we do want to make the FDA step concrete enough that
/// the people who *want* to grant it understand exactly what they're doing.
struct OnboardingView: View {
    @Binding var isComplete: Bool
    @State private var page: Page = .welcome
    @State private var appeared = false
    @State private var hasFda = false
    @State private var hasOpenedSettings = false
    @State private var autoAdvanceScheduled = false

    private let pollTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    enum Page: Int, CaseIterable {
        case welcome, mission, permission, ready

        var index: Int { rawValue }
        static var count: Int { allCases.count }
    }

    var body: some View {
        ZStack {
            backdrop
                .ignoresSafeArea()

            VStack(spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 36)
                    .padding(.top, 44)
                    .padding(.bottom, 12)
                    .id(page)
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .trailing)),
                            removal: .opacity.combined(with: .move(edge: .leading))
                        )
                    )

                bottomBar
            }
        }
        .frame(width: 680, height: 560)
        .onAppear {
            FullDiskAccessManager.shared.triggerRegistration()
            withAnimation(.easeOut(duration: 0.5)) { appeared = true }
            refreshFda()
        }
        .onReceive(pollTimer) { _ in
            if page == .permission { refreshFda() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case .welcome: WelcomeScene(appeared: appeared)
        case .mission: MissionScene()
        case .permission: PermissionScene(
            hasFda: hasFda,
            hasOpenedSettings: hasOpenedSettings,
            openSettings: openSettings,
            revealAppInFinder: { FullDiskAccessManager.shared.revealAppInFinder() }
        )
        case .ready: ReadyScene(hasFda: hasFda)
        }
    }

    // MARK: - Background

    private var backdrop: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            // Radial wash that shifts hue per page. Subtle enough to read
            // as ambient warmth rather than decoration.
            RadialGradient(
                colors: [pageTint.opacity(0.18), .clear],
                center: .topTrailing,
                startRadius: 60,
                endRadius: 520
            )
            .animation(.easeInOut(duration: 0.6), value: page)
        }
    }

    private var pageTint: Color {
        switch page {
        case .welcome: return Tint.blue
        case .mission: return Tint.purple
        case .permission: return Tint.orange
        case .ready: return Tint.green
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack {
            if page != .welcome {
                Button("Back") { advance(by: -1) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            } else {
                Button("Skip") { isComplete = true }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 6) {
                ForEach(Page.allCases, id: \.self) { p in
                    Capsule()
                        .fill(p == page ? Color.primary.opacity(0.75) : Color.primary.opacity(0.15))
                        .frame(width: p == page ? 18 : 6, height: 6)
                        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: page)
                }
            }

            Spacer()

            if page == .ready {
                Button("Start") { isComplete = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            } else {
                Button(page == .permission ? "Continue" : "Next") { advance(by: 1) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
        .background(
            VStack(spacing: 0) {
                Divider().opacity(0.5)
                Color.clear
            }
        )
    }

    // MARK: - Actions

    private func advance(by delta: Int) {
        let target = max(0, min(Page.count - 1, page.index + delta))
        guard target != page.index else { return }
        Haptics.tap()
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
            page = Page(rawValue: target) ?? page
        }
    }

    private func openSettings() {
        FullDiskAccessManager.shared.openFullDiskAccessSettings()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            FullDiskAccessManager.shared.revealAppInFinder()
        }
        withAnimation(.easeInOut(duration: 0.25)) {
            hasOpenedSettings = true
        }
    }

    private func refreshFda() {
        let granted = FullDiskAccessManager.shared.hasFullDiskAccess
        if granted != hasFda {
            withAnimation(.easeInOut(duration: 0.3)) {
                hasFda = granted
            }
            if granted { Haptics.success() }
        }
        // Auto-advance once they grant access while on the permission page.
        // The autoAdvanceScheduled latch prevents the 1-second poll from
        // queueing multiple .8s delays if grants are detected on back-to-back
        // ticks before the page actually flips.
        guard granted, page == .permission, !autoAdvanceScheduled else { return }
        autoAdvanceScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            // Re-check page in case the user manually advanced or backed up
            // during the delay window.
            guard page == .permission else {
                autoAdvanceScheduled = false
                return
            }
            advance(by: 1)
            autoAdvanceScheduled = false
        }
    }
}

// MARK: - Scenes

private struct WelcomeScene: View {
    let appeared: Bool
    @State private var bob = false

    var body: some View {
        VStack(spacing: 26) {
            Spacer(minLength: 0)

            ZStack {
                if let icon = NSImage(named: "AppIcon") {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 120, height: 120)
                        .shadow(color: .black.opacity(0.15), radius: 18, y: 8)
                        .offset(y: bob ? -4 : 4)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                                bob = true
                            }
                        }
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 88, weight: .semibold))
                        .foregroundStyle(Tint.blue)
                }
            }

            VStack(spacing: 12) {
                Text("Reclaim your Mac")
                    .font(.system(size: 38, weight: .semibold))
                    .multilineTextAlignment(.center)
                Text("Apple sells you small disks. We help you keep them clean.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 8)

            Text("Free. Open source. MIT licensed.")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.tertiary)
                .tracking(0.3)
                .padding(.top, 4)

            Spacer(minLength: 0)
        }
    }
}

private struct MissionScene: View {
    var body: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 0)

            VStack(spacing: 12) {
                Text("What's inside")
                    .font(.system(size: 30, weight: .semibold))
                    .multilineTextAlignment(.center)
                Text("Three things, done well.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 12) {
                FeatureRow(
                    systemImage: "sparkles",
                    tint: Tint.blue,
                    title: "Smart Scan",
                    body: "Find caches, logs, broken installs, and the AI-app history hiding in your library."
                )
                FeatureRow(
                    systemImage: "square.grid.2x2.fill",
                    tint: Tint.purple,
                    title: "App Uninstaller",
                    body: "Drag an app, see every file it dropped, remove all of it. No leftovers."
                )
                FeatureRow(
                    systemImage: "doc.questionmark.fill",
                    tint: Tint.pink,
                    title: "Orphan Finder",
                    body: "Surfaces files that outlived the apps that created them."
                )
            }
            .frame(maxWidth: 460)

            Spacer(minLength: 0)
        }
    }
}

private struct FeatureRow: View {
    let systemImage: String
    let tint: Color
    let title: String
    let body_: String

    init(systemImage: String, tint: Color, title: String, body: String) {
        self.systemImage = systemImage
        self.tint = tint
        self.title = title
        self.body_ = body
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            IconTile(systemName: systemImage, tint: tint, size: 36, corner: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(body_)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }
}

private struct PermissionScene: View {
    let hasFda: Bool
    let hasOpenedSettings: Bool
    let openSettings: () -> Void
    let revealAppInFinder: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 8) {
                Text(hasFda ? "Permission granted" : "One permission, then we're done")
                    .font(.system(size: 26, weight: .semibold))
                    .multilineTextAlignment(.center)
                Text(hasFda
                     ? "PureMac can now reach the locations macOS protects by default."
                     : "macOS hides certain folders from every app until you say otherwise. We need them to find caches and uninstall cleanly.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }

            FDADemoView()
                .frame(maxWidth: 420)

            if hasFda {
                Label("All set — moving you to the next step.", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Tint.green)
                    .transition(.opacity.combined(with: .scale))
            } else {
                // Two equally legitimate paths: open Settings and have it
                // reveal PureMac in Finder, OR grab the draggable icon on the
                // left and drop it directly into the FDA list. Showing both
                // side by side lets users pick the path their mental model
                // prefers without a 3-step decision tree.
                HStack(alignment: .top, spacing: 18) {
                    AppBundleDragHandle()
                    Divider().frame(maxHeight: 90)
                    VStack(spacing: 8) {
                        Button {
                            openSettings()
                        } label: {
                            Label(hasOpenedSettings ? "Reopen Settings" : "Open Settings & reveal PureMac",
                                  systemImage: "gear")
                                .font(.system(size: 13, weight: .semibold))
                                .frame(minWidth: 240)
                                .padding(.vertical, 2)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)

                        if hasOpenedSettings {
                            HStack(spacing: 12) {
                                Button("Reveal app again") { revealAppInFinder() }
                                    .buttonStyle(.link)
                                    .font(.system(size: 11.5))
                                Button("Reset permissions") {
                                    _ = FullDiskAccessManager.shared.resetFullDiskAccess()
                                    FullDiskAccessManager.shared.triggerRegistration()
                                }
                                .buttonStyle(.link)
                                .font(.system(size: 11.5))
                            }
                            .transition(.opacity)
                        } else {
                            Text("Tip: drag the icon on the left straight into the list.")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .frame(maxWidth: 260)
                }
                .padding(.top, 4)
            }
        }
    }
}

private struct ReadyScene: View {
    let hasFda: Bool
    @State private var bounce = false
    @State private var fireConfetti = false
    @State private var confettiWork: DispatchWorkItem?
    @AppStorage("PureMac.HasSeenWelcomeConfetti") private var hasSeenConfetti = false

    var body: some View {
        ZStack {
            // Confetti sits above the content but behind any touch targets;
            // disabling hit-testing keeps the Start button clickable through
            // falling particles.
            if !hasSeenConfetti {
                ConfettiView(trigger: fireConfetti)
                    .allowsHitTesting(false)
            }

            VStack(spacing: 22) {
                Spacer(minLength: 0)

                ZStack {
                    Circle()
                        .fill((hasFda ? Tint.green : Tint.orange).opacity(0.12))
                        .frame(width: 110, height: 110)
                    Image(systemName: hasFda ? "checkmark" : "hand.wave.fill")
                        .font(.system(size: 50, weight: .semibold))
                        .foregroundStyle(hasFda ? Tint.green : Tint.orange)
                        .scaleEffect(bounce ? 1.05 : 1.0)
                }
                .onAppear {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.55)) {
                        bounce = true
                    }
                    // Fire the welcome confetti exactly once per install.
                    // The work item is cancelled in onDisappear so a fast
                    // user who clicks Start within the 0.35s delay doesn't
                    // burn the once-per-install flag without ever seeing the
                    // celebration.
                    guard !hasSeenConfetti else { return }
                    let work = DispatchWorkItem {
                        fireConfetti = true
                        hasSeenConfetti = true
                        Haptics.success()
                    }
                    confettiWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
                }
                .onDisappear {
                    confettiWork?.cancel()
                    confettiWork = nil
                }

                VStack(spacing: 10) {
                    Text(hasFda ? "You're ready" : "Ready when you are")
                        .font(.system(size: 30, weight: .semibold))
                    Text(hasFda
                         ? "Hit Start to run your first Smart Scan."
                         : "Some features will be limited without Full Disk Access. You can grant it later in Settings.")
                        .font(.system(size: 13.5))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }

                Spacer(minLength: 0)
            }
        }
    }
}
