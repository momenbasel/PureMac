import AppKit
import SwiftUI

struct ProtectionView: View {
    private enum Phase {
        case idle
        case running
        case complete(ProtectionSnapshot)
    }

    private let audit: ProtectionAudit
    @State private var phase: Phase = .idle
    @State private var auditTask: Task<Void, Never>?

    init(audit: ProtectionAudit = ProtectionAudit()) {
        self.audit = audit
    }

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    auditContent
                    permissionsCard
                    browserPrivacyCard
                }
                .frame(maxWidth: 920, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Protection")
        .onDisappear {
            auditTask?.cancel()
            auditTask = nil
            if case .running = phase {
                phase = .idle
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Protection")
                    .font(.system(size: 28, weight: .bold))
                Text("Review the macOS safeguards that protect apps, disks, network access, and system files.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 20)

            Button(action: runAudit) {
                HStack(spacing: 8) {
                    if case .running = phase {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Image(systemName: "checkmark.shield")
                    }
                    Text(auditButtonTitle)
                }
            }
            .buttonStyle(GlowProminentButtonStyle(tint: Tint.accent, gradient: TintGradient.of(Tint.accent)))
            .disabled(isRunning)
            .accessibilityLabel(auditButtonTitle)
        }
    }

    @ViewBuilder
    private var auditContent: some View {
        switch phase {
        case .idle:
            CardSurface(padding: 22, elevation: .standard, tint: Tint.accent) {
                HStack(spacing: 18) {
                    IconTile(systemName: "shield.checkered", tint: Tint.accent, size: 44, corner: 12)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Check built-in safeguards")
                            .font(.system(size: 17, weight: .semibold))
                        Text("The audit reads current settings and does not change your Mac. It is a configuration review, not a malware scan.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
            }
        case .running:
            CardSurface(padding: 0, elevation: .standard, tint: Tint.accent) {
                VStack(spacing: 0) {
                    ForEach(Array(ProtectionCheck.allCases.enumerated()), id: \.element.id) { index, check in
                        HStack(spacing: 12) {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 24)
                            Text(check.title)
                                .font(.system(size: 13, weight: .medium))
                            Spacer()
                            Text("Checking")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 13)

                        if index < ProtectionCheck.allCases.count - 1 {
                            Divider().padding(.leading, 54)
                        }
                    }
                }
            }
        case .complete(let snapshot):
            VStack(alignment: .leading, spacing: 8) {
                CardSurface(padding: 0, elevation: .standard) {
                    VStack(spacing: 0) {
                        ForEach(Array(snapshot.findings.enumerated()), id: \.element.id) { index, finding in
                            ProtectionFindingRow(finding: finding)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 13)

                            if index < snapshot.findings.count - 1 {
                                Divider().padding(.leading, 58)
                            }
                        }
                    }
                }

                Text("Checked \(snapshot.checkedAt.formatted(date: .abbreviated, time: .shortened)). Unknown means the setting could not be confirmed.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
        }
    }

    private var permissionsCard: some View {
        CardSurface(padding: 18, elevation: .flat) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    IconTile(systemName: "hand.raised.fill", tint: Tint.purple, size: 31, corner: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("App permissions")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Review which apps can access private data and hardware.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 8) {
                    SettingsButton(title: "Full Disk Access", icon: "externaldrive.badge.person.crop") {
                        ProtectionNavigation.openSettings("com.apple.preference.security?Privacy_AllFiles")
                    }
                    SettingsButton(title: "Location", icon: "location") {
                        ProtectionNavigation.openSettings("com.apple.preference.security?Privacy_LocationServices")
                    }
                    SettingsButton(title: "Camera", icon: "video") {
                        ProtectionNavigation.openSettings("com.apple.preference.security?Privacy_Camera")
                    }
                    SettingsButton(title: "Microphone", icon: "mic") {
                        ProtectionNavigation.openSettings("com.apple.preference.security?Privacy_Microphone")
                    }
                }
            }
        }
    }

    private var browserPrivacyCard: some View {
        CardSurface(padding: 18, elevation: .flat) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 10) {
                    IconTile(systemName: "safari", tint: Tint.blue, size: 31, corner: 8)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Browser privacy")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Browser controls must be reviewed inside each browser. PureMac does not change cookies, history, site permissions, or extensions.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(spacing: 10) {
                    Link(destination: URL(string: "https://support.apple.com/guide/safari/sfri35610/mac")!) {
                        Label("Safari privacy guide", systemImage: "arrow.up.right.square")
                    }
                    Link(destination: URL(string: "https://support.google.com/chrome/answer/17561599?hl=en")!) {
                        Label("Chrome privacy guide", systemImage: "arrow.up.right.square")
                    }
                    Spacer()
                    Text("Safari: Settings > Privacy")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.link)
            }
        }
    }

    private var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    private var auditButtonTitle: String {
        switch phase {
        case .idle:
            return String(localized: "Run audit")
        case .running:
            return String(localized: "Checking")
        case .complete:
            return String(localized: "Check again")
        }
    }

    private func runAudit() {
        guard !isRunning else { return }
        auditTask?.cancel()
        phase = .running
        auditTask = Task {
            let snapshot = await audit.run()
            guard !Task.isCancelled else { return }
            withAnimation(MotionTokens.gentle) {
                phase = .complete(snapshot)
            }
            auditTask = nil
        }
    }
}

private struct ProtectionFindingRow: View {
    let finding: ProtectionFinding

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: finding.status.icon)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(finding.status.tint)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(finding.check.title)
                        .font(.system(size: 13, weight: .semibold))
                    StatusChip(
                        label: finding.status.label(for: finding.check),
                        systemImage: finding.status.chipIcon,
                        tint: finding.status.tint
                    )
                    if let version = finding.version {
                        Text(version)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(finding.detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Button(finding.check.actionTitle) {
                ProtectionNavigation.openAction(for: finding.check)
            }
            .controlSize(.small)
        }
    }
}

private struct SettingsButton: View {
    let title: LocalizedStringKey
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 11.5, weight: .medium))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

private enum ProtectionNavigation {
    static func openAction(for check: ProtectionCheck) {
        switch check {
        case .gatekeeper:
            openSettings("com.apple.preference.security")
        case .fileVault:
            openSettings("com.apple.preference.security?FileVault")
        case .firewall:
            openSettings("com.apple.Network-Settings.extension?Firewall")
        case .systemIntegrityProtection:
            openWeb("https://support.apple.com/guide/security/secb7ea06b49/web")
        case .xProtect:
            openSettings("com.apple.Software-Update-Settings.extension")
        }
    }

    static func openSettings(_ destination: String) {
        openWeb("x-apple.systempreferences:\(destination)")
    }

    private static func openWeb(_ address: String) {
        guard let url = URL(string: address) else { return }
        NSWorkspace.shared.open(url)
    }
}

private extension ProtectionCheck {
    var title: String {
        switch self {
        case .gatekeeper:
            return String(localized: "Gatekeeper")
        case .fileVault:
            return String(localized: "FileVault")
        case .firewall:
            return String(localized: "Application Firewall")
        case .systemIntegrityProtection:
            return String(localized: "System Integrity Protection")
        case .xProtect:
            return String(localized: "XProtect")
        }
    }

    var actionTitle: String {
        switch self {
        case .gatekeeper:
            return String(localized: "Security Settings")
        case .fileVault:
            return String(localized: "FileVault Settings")
        case .firewall:
            return String(localized: "Firewall Settings")
        case .systemIntegrityProtection:
            return String(localized: "Apple Guide")
        case .xProtect:
            return String(localized: "Software Update")
        }
    }
}

private extension ProtectionStatus {
    var icon: String {
        switch self {
        case .enabled:
            return "checkmark.circle.fill"
        case .disabled:
            return "exclamationmark.circle.fill"
        case .unknown:
            return "questionmark.circle.fill"
        }
    }

    var chipIcon: String {
        switch self {
        case .enabled:
            return "checkmark"
        case .disabled:
            return "exclamationmark"
        case .unknown:
            return "questionmark"
        }
    }

    var tint: Color {
        switch self {
        case .enabled:
            return Tint.green
        case .disabled:
            return Tint.orange
        case .unknown:
            return .secondary
        }
    }

    func label(for check: ProtectionCheck) -> String {
        switch (self, check) {
        case (.enabled, .xProtect):
            return String(localized: "Installed")
        case (.enabled, _):
            return String(localized: "On")
        case (.disabled, _):
            return String(localized: "Off")
        case (.unknown, _):
            return String(localized: "Unknown")
        }
    }
}
