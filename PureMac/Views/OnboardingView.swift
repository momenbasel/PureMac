import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var vm: AppViewModel
    @Binding var isComplete: Bool

    @State private var currentPage = 0
    @State private var fdaGranted = false
    @State private var fdaCheckTimer: Timer?
    @State private var logoScale: CGFloat = 0.5
    @State private var logoOpacity: Double = 0

    var body: some View {
        ZStack {
            Color.pmBackground
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Page content
                Group {
                    switch currentPage {
                    case 0:
                        welcomePage
                    case 1:
                        fdaPage
                    case 2:
                        readyPage
                    default:
                        EmptyView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Bottom bar
                bottomBar
                    .padding(.horizontal, 60)
                    .padding(.bottom, 40)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .focusable(false)
    }

    // MARK: - Welcome Page

    private var welcomePage: some View {
        VStack(spacing: 24) {
            Spacer()

            Image("SidebarLogo")
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.1), radius: 12, y: 6)
                .scaleEffect(logoScale)
                .opacity(logoOpacity)
                .onAppear {
                    withAnimation(.spring(response: 0.8, dampingFraction: 0.6)) {
                        logoScale = 1.0
                        logoOpacity = 1.0
                    }
                }

            VStack(spacing: 8) {
                Text("Welcome to PureMac")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(.pmTextPrimary)

                Text("Keep your Mac fast, clean, and optimized.")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.pmTextSecondary)
            }

            // Feature highlights
            HStack(spacing: 20) {
                FeatureCard(
                    icon: "magnifyingglass",
                    color: .pmAccent,
                    title: "Smart Scan",
                    subtitle: "Find junk in seconds"
                )
                FeatureCard(
                    icon: "trash.fill",
                    color: .pmDanger,
                    title: "One-Click Clean",
                    subtitle: "Remove files safely"
                )
                FeatureCard(
                    icon: "xmark.app.fill",
                    color: Color(hex: "e11d48"),
                    title: "App Uninstaller",
                    subtitle: "Delete apps completely"
                )
            }
            .padding(.top, 20)

            Spacer()
        }
    }

    // MARK: - Full Disk Access Page

    private var fdaPage: some View {
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                Circle()
                    .fill(fdaGranted ? Color.pmSuccess.opacity(0.08) : Color.pmWarning.opacity(0.08))
                    .frame(width: 120, height: 120)

                Image(systemName: fdaGranted ? "checkmark.shield.fill" : "lock.shield.fill")
                    .font(.system(size: 48, weight: .light))
                    .foregroundColor(fdaGranted ? .pmSuccess : .pmWarning)
            }

            VStack(spacing: 8) {
                Text(fdaGranted ? LocalizedStringKey("Access Granted") : LocalizedStringKey("Full Disk Access"))
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(.pmTextPrimary)

                Text(fdaGranted
                     ? LocalizedStringKey("PureMac can now scan all areas of your Mac.")
                     : LocalizedStringKey("PureMac needs Full Disk Access to scan Trash, Mail, Desktop, Documents, and Homebrew cache."))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.pmTextSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !fdaGranted {
                VStack(spacing: 12) {
                    // Steps
                    VStack(alignment: .leading, spacing: 10) {
                        StepRow(number: 1, text: "Click \"Open System Settings\" below")
                        StepRow(number: 2, text: "Find PureMac in the list")
                        StepRow(number: 3, text: "Toggle the switch to enable access")
                    }
                    .padding(20)
                    .frame(maxWidth: 380)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.pmCard.opacity(0.6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.pmSeparator.opacity(0.4), lineWidth: 0.5)
                            )
                    )

                    Button(action: {
                        vm.openFullDiskAccessSettings()
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "gear")
                                .font(.system(size: 13, weight: .semibold))
                            Text("Open System Settings")
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                        }
                        .foregroundColor(.white)
                        .frame(height: 42)
                        .padding(.horizontal, 28)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.pmWarning)
                        )
                        .shadow(color: Color.pmWarning.opacity(0.2), radius: 6, y: 3)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 8)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.pmSuccess)
                    .padding(.top, 8)
                    .transition(.scale.combined(with: .opacity))
            }

            Spacer()
        }
        .onAppear { startFDACheck() }
        .onDisappear { fdaCheckTimer?.invalidate() }
    }

    // MARK: - Ready Page

    private var readyPage: some View {
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.pmSuccess.opacity(0.06))
                    .frame(width: 140, height: 140)

                Circle()
                    .stroke(Color.pmSuccess.opacity(0.15), lineWidth: 2)
                    .frame(width: 140, height: 140)

                Image("SidebarLogo")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 72, height: 72)
                    .shadow(color: .black.opacity(0.08), radius: 8, y: 4)
            }

            VStack(spacing: 8) {
                Text("You're All Set")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(.pmTextPrimary)

                Text("PureMac is ready to keep your Mac clean.")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.pmTextSecondary)
            }

            // Summary
            HStack(spacing: 20) {
                StatusPill(
                    icon: fdaGranted ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
                    text: fdaGranted ? "Full Disk Access" : "Limited Access",
                    color: fdaGranted ? .pmSuccess : .pmWarning
                )
            }
            .padding(.top, 8)

            Spacer()
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack {
            // Page dots
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule()
                        .fill(currentPage == index ? Color.pmAccent : Color.pmSeparator)
                        .frame(width: currentPage == index ? 20 : 8, height: 8)
                        .animation(.pmSmooth, value: currentPage)
                }
            }

            Spacer()

            HStack(spacing: 12) {
                // Skip button (pages 0-1)
                if currentPage < 2 {
                    Button(action: {
                        withAnimation(.pmSmooth) {
                            currentPage = 2
                        }
                    }) {
                        Text("Skip")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundColor(.pmTextMuted)
                    }
                    .buttonStyle(.plain)
                }

                // Next / Get Started button
                Button(action: {
                    if currentPage < 2 {
                        withAnimation(.pmSmooth) {
                            currentPage += 1
                        }
                    } else {
                        withAnimation(.pmSmooth) {
                            isComplete = true
                        }
                    }
                }) {
                    HStack(spacing: 6) {
                        Text(currentPage == 2 ? LocalizedStringKey("Start Scanning") : LocalizedStringKey("Continue"))
                            .font(.system(size: 14, weight: .semibold, design: .rounded))

                        if currentPage < 2 {
                            Image(systemName: "arrow.right")
                                .font(.system(size: 11, weight: .semibold))
                        }
                    }
                    .foregroundColor(.white)
                    .frame(height: 38)
                    .padding(.horizontal, 24)
                    .background(
                        RoundedRectangle(cornerRadius: 9)
                            .fill(Color.pmAccent)
                    )
                    .shadow(color: Color.pmAccent.opacity(0.15), radius: 4, y: 2)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - FDA Check

    private func startFDACheck() {
        fdaGranted = vm.hasFullDiskAccess
        fdaCheckTimer?.invalidate()
        fdaCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                let granted = FullDiskAccessManager.shared.hasFullDiskAccess
                if granted != fdaGranted {
                    withAnimation(.pmSmooth) {
                        fdaGranted = granted
                        vm.hasFullDiskAccess = granted
                    }
                }
            }
        }
    }
}

// MARK: - Feature Card

struct FeatureCard: View {
    let icon: String
    let color: Color
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(color.opacity(0.08))
                    .frame(width: 48, height: 48)

                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundColor(color)
            }

            VStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.pmTextPrimary)

                Text(subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.pmTextMuted)
            }
        }
        .frame(width: 160)
        .padding(.vertical, 20)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.pmCard.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.pmSeparator.opacity(0.4), lineWidth: 0.5)
                )
        )
    }
}

// MARK: - Step Row

struct StepRow: View {
    let number: Int
    let text: LocalizedStringKey

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.pmAccent.opacity(0.1))
                    .frame(width: 24, height: 24)

                Text("\(number)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(.pmAccent)
            }

            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.pmTextSecondary)
        }
    }
}

// MARK: - Status Pill

struct StatusPill: View {
    let icon: String
    let text: LocalizedStringKey
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(color)

            Text(text)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.pmTextPrimary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(color.opacity(0.08))
                .overlay(
                    Capsule()
                        .stroke(color.opacity(0.15), lineWidth: 0.5)
                )
        )
    }
}
