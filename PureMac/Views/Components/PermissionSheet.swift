import SwiftUI

/// Premium Full Disk Access prompt that replaces the bare permission-denied
/// alert. Auto-polls FDA state, auto-retries the failed operation on grant,
/// and offers escape hatches for the "PureMac isn't in the list" case.
struct PermissionSheet: View {
    @ObservedObject private var coordinator = PermissionCoordinator.shared
    @State private var appeared = false
    @State private var pulse = false
    @State private var showAdvanced = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            body_
            Divider().opacity(0.4)
            footer
        }
        .frame(width: 560)
        .background(
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                LinearGradient(
                    colors: [Tint.blue.opacity(0.06), Tint.purple.opacity(0.04), .clear],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            }
        )
        .onAppear {
            withAnimation(.easeOut(duration: 0.5)) { appeared = true }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: coordinator.hasFullDiskAccess
                                ? [Tint.green, Color(red: 0.10, green: 0.65, blue: 0.40)]
                                : [Tint.blue, Tint.purple],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 44, height: 44)
                    .shadow(
                        color: (coordinator.hasFullDiskAccess ? Tint.green : Tint.blue)
                            .opacity(pulse ? 0.45 : 0.15),
                        radius: pulse ? 14 : 6
                    )
                headerIcon
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(coordinator.context.headline)
                    .font(.system(size: 16, weight: .bold))
                Text(coordinator.hasFullDiskAccess
                     ? "Access granted. Retrying…"
                     : "1-tap setup. We'll detect the change automatically.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : -6)
    }

    @ViewBuilder
    private var headerIcon: some View {
        let name = coordinator.hasFullDiskAccess ? "checkmark.shield.fill" : "lock.shield.fill"
        let base = Image(systemName: name)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(.white)
        if #available(macOS 14.0, *) {
            base.contentTransition(.symbolEffect(.replace))
        } else {
            base
        }
    }

    // MARK: - Body

    @ViewBuilder
    private var body_: some View {
        if coordinator.hasFullDiskAccess {
            grantedBody
        } else {
            requestBody
        }
    }

    private var requestBody: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Primary action row
            Button {
                coordinator.openSettingsAndReveal()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "gear.badge")
                        .font(.system(size: 18, weight: .semibold))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Open Settings & reveal PureMac")
                            .font(.system(size: 13.5, weight: .semibold))
                        Text("We'll open both windows side-by-side.")
                            .font(.system(size: 11))
                            .opacity(0.85)
                    }
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11, weight: .bold))
                        .opacity(0.7)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(
                    LinearGradient(
                        colors: [Tint.blue, Tint.purple],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: Tint.blue.opacity(0.35), radius: 10, y: 4)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)

            // Step-by-step strip
            HStack(spacing: 0) {
                stepCell(number: 1, title: "Turn on PureMac",
                         caption: "Toggle the row that appears.")
                stepDivider
                stepCell(number: 2, title: "Authenticate",
                         caption: "Touch ID or password.")
                stepDivider
                stepCell(number: 3, title: "Done",
                         caption: "We auto-retry — no need to come back.")
            }
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )

            // Listening indicator
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .stroke(Tint.blue.opacity(0.3), lineWidth: 1.5)
                        .frame(width: 10, height: 10)
                    Circle()
                        .fill(Tint.blue)
                        .frame(width: 6, height: 6)
                        .scaleEffect(pulse ? 1.4 : 0.8)
                        .opacity(pulse ? 0.4 : 1)
                }
                Text("Watching for permission change…")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(showAdvanced ? "Hide help" : "PureMac not in the list?") {
                    withAnimation(.easeInOut(duration: 0.25)) { showAdvanced.toggle() }
                }
                .buttonStyle(.link)
                .font(.system(size: 11.5))
            }

            if showAdvanced {
                advancedPanel
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if !coordinator.failedItemPaths.isEmpty {
                blockedList
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .opacity(appeared ? 1 : 0)
    }

    private var advancedPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Try this if PureMac doesn't appear:")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                advancedButton(
                    icon: "folder.badge.gearshape",
                    title: "Reveal app",
                    subtitle: "Drag PureMac.app into the list"
                ) {
                    FullDiskAccessManager.shared.revealAppInFinder()
                }
                advancedButton(
                    icon: "arrow.clockwise.circle",
                    title: "Reset + reprompt",
                    subtitle: "Clear stale TCC entry"
                ) {
                    coordinator.resetAndReprime()
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
    }

    private func advancedButton(icon: String, title: LocalizedStringKey,
                                subtitle: LocalizedStringKey,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                IconTile(systemName: icon, tint: Tint.orange, size: 30, corner: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    private var blockedList: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(coordinator.failedItemPaths.prefix(6), id: \.self) { path in
                    Text(path)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if coordinator.failedItemPaths.count > 6 {
                    Text(remainingText(coordinator.failedItemPaths.count - 6))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.top, 4)
        } label: {
            Text(blockedHeaderText(coordinator.failedItemPaths.count))
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    private func remainingText(_ count: Int) -> String {
        String(format: String(localized: "+ %lld more"), Int64(count))
    }

    private func blockedHeaderText(_ count: Int) -> String {
        String(
            format: String(localized: "%lld blocked path(s)"),
            Int64(count)
        )
    }

    private func stepCell(number: Int, title: LocalizedStringKey,
                          caption: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Tint.blue))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                Text(caption)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var stepDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(width: 0.5)
            .padding(.vertical, 6)
    }

    private var grantedBody: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Tint.green.opacity(0.15))
                    .frame(width: 72, height: 72)
                    .scaleEffect(pulse ? 1.05 : 0.95)
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(Tint.green)
            }
            Text("Access granted")
                .font(.system(size: 15, weight: .bold))
            Text("Retrying the operation now.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Skip for now") {
                coordinator.dismiss(callRetry: false)
            }
            .buttonStyle(.link)
            .foregroundStyle(.secondary)

            Spacer()

            if !coordinator.hasFullDiskAccess {
                Button("I granted it — retry") {
                    coordinator.refreshStatus()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        if coordinator.hasFullDiskAccess {
                            coordinator.dismiss(callRetry: true)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }
}
