import SwiftUI

/// Premium Full Disk Access prompt that replaces the bare permission-denied
/// alert. Auto-polls FDA state, safely continues verified operations on grant,
/// and offers escape hatches for the "PureMac isn't in the list" case.
struct PermissionSheet: View {
    @ObservedObject private var coordinator = PermissionCoordinator.shared
    @State private var appeared = false
    @State private var pulse = false
    @State private var showAdvanced = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            body_
            Divider().opacity(0.4)
            footer
        }
        .frame(width: 540)
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.8),
                   value: coordinator.hasFullDiskAccess)
        .onAppear {
            if reduceMotion {
                appeared = true
                return
            }
            withAnimation(.easeOut(duration: 0.4)) { appeared = true }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                let tint = coordinator.hasFullDiskAccess ? Tint.green : Tint.blue
                Circle()
                    .fill(tint.opacity(0.14))
                    .frame(width: 40, height: 40)
                headerIcon
                    .foregroundStyle(tint)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(coordinator.context.headline)
                    .font(.system(size: 16, weight: .bold))
                Text(coordinator.hasFullDiskAccess
                     ? "Access granted. Checking items…"
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
            .font(.system(size: 18, weight: .semibold))
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
                .transition(
                    reduceMotion
                        ? .opacity
                        : .scale(scale: 0.9).combined(with: .opacity)
                )
        } else {
            requestBody
                .transition(.opacity)
        }
    }

    private var requestBody: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Two paths the user can choose between: drag the PureMac bundle
            // straight into the FDA list, OR have us reveal it in Finder so
            // they can drag from there. Drag-from-our-sheet is faster but
            // some users will still prefer the Finder flow they recognize.
            HStack(alignment: .center, spacing: 14) {
                AppBundleDragHandle()

                Divider().frame(maxHeight: 110)

                VStack(spacing: 8) {
                    Button {
                        Haptics.tap()
                        coordinator.openSettingsAndReveal()
                    } label: {
                        Label("Open Settings & reveal PureMac", systemImage: "gear")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)

                    Text("Or drag the icon on the left straight into Settings.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
            }

            // Step-by-step strip
            HStack(spacing: 0) {
                stepCell(number: 1, title: "Turn on PureMac",
                         caption: "Toggle the row that appears.")
                stepDivider
                stepCell(number: 2, title: "Authenticate",
                         caption: "Touch ID or password.")
                stepDivider
                stepCell(number: 3, title: "Done",
                         caption: "We'll continue safely; a re-scan may be required.")
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
            // SuccessMedal pops + ripples once on its own and already
            // honors Reduce Motion — no shared `pulse` state reuse.
            SuccessMedal(size: 72)
            Text("Access granted")
                .font(.system(size: 15, weight: .bold))
            Text("Checking whether the selected items can be retried safely.")
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
                Button("I granted it — continue") {
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
