import SwiftUI

/// A short looping illustration of what the user is about to do in the real
/// System Settings pane. Built entirely in SwiftUI — no GIFs, no video, no
/// external assets. The point is to make the FDA step feel concrete so the
/// user knows exactly which toggle to flip before they even open Settings.
///
/// Frames cycle every ~5 seconds: idle → row highlights → toggle flips →
/// green check appears → hold → reset.
struct FDADemoView: View {
    enum Frame: Int, CaseIterable {
        case idle
        case highlight
        case toggleOn
        case granted
        case hold
    }

    @State private var frame: Frame = .idle
    @State private var isActive = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var rows: [DemoRow] {
        [
            DemoRow(name: "Finder", systemImage: "macwindow", granted: true),
            DemoRow(name: "PureMac", systemImage: "sparkles",
                    granted: frame == .toggleOn || frame == .granted || frame == .hold,
                    isPureMac: true),
            DemoRow(name: "Terminal", systemImage: "terminal", granted: true),
        ]
    }

    var body: some View {
        VStack(spacing: 14) {
            settingsCard

            HStack(spacing: 6) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 11, weight: .semibold))
                Text("Privacy & Security → Full Disk Access")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(.secondary)
        }
        .onAppear {
            // Reduce Motion: freeze on the end state — the user sees the
            // "toggled on, granted" frame as a static illustration instead
            // of an infinite loop.
            if reduceMotion {
                frame = .hold
                return
            }
            isActive = true
            cycle()
        }
        .onDisappear { isActive = false }
    }

    // MARK: - Settings card

    private var settingsCard: some View {
        VStack(spacing: 0) {
            // Faux titlebar
            HStack(spacing: 6) {
                Circle().fill(Color(red: 1.0, green: 0.36, blue: 0.34)).frame(width: 9, height: 9)
                Circle().fill(Color(red: 1.0, green: 0.78, blue: 0.27)).frame(width: 9, height: 9)
                Circle().fill(Color(red: 0.31, green: 0.78, blue: 0.36)).frame(width: 9, height: 9)
                Spacer()
                Text("Full Disk Access")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.04))

            Divider()

            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                    rowView(row)
                    if idx != rows.count - 1 {
                        Divider().padding(.leading, 46)
                    }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
    }

    private func rowView(_ row: DemoRow) -> some View {
        let highlight = row.isPureMac && (frame == .highlight)
        let succeeded = row.isPureMac && (frame == .granted || frame == .hold)

        return HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(row.isPureMac ? Tint.blue.opacity(0.16) : Color.primary.opacity(0.08))
                Image(systemName: row.systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(row.isPureMac ? Tint.blue : .secondary)
            }
            .frame(width: 26, height: 26)

            Text(row.name)
                .font(.system(size: 13, weight: row.isPureMac ? .semibold : .regular))

            Spacer()

            if succeeded {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Tint.green)
                    .transition(.scale.combined(with: .opacity))
            }

            ToggleSwitch(isOn: row.granted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(highlight ? Tint.blue.opacity(0.10) : .clear)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
        )
        .animation(.easeInOut(duration: 0.35), value: highlight)
        .animation(.easeInOut(duration: 0.35), value: succeeded)
    }

    // MARK: - Cycle

    private func cycle() {
        guard isActive, !reduceMotion else { return }

        let schedule: [(Frame, Double)] = [
            (.idle, 0.6),
            (.highlight, 0.9),
            (.toggleOn, 0.8),
            (.granted, 0.4),
            (.hold, 1.6),
        ]

        var accumulated: Double = 0
        for (target, hold) in schedule {
            DispatchQueue.main.asyncAfter(deadline: .now() + accumulated) {
                guard isActive else { return }
                withAnimation(.easeInOut(duration: 0.4)) {
                    frame = target
                }
            }
            accumulated += hold
        }
        // Re-arm. The isActive guard at the top of cycle() is what stops the
        // chain when the view disappears.
        DispatchQueue.main.asyncAfter(deadline: .now() + accumulated + 0.4) {
            guard isActive else { return }
            withAnimation(.easeInOut(duration: 0.3)) {
                frame = .idle
            }
            cycle()
        }
    }

    private struct DemoRow {
        let name: LocalizedStringKey
        let systemImage: String
        let granted: Bool
        var isPureMac: Bool = false
    }
}

/// Tiny stand-in for an OS-style toggle. NSSwitch via SwiftUI would also work
/// but rendering one ourselves gives us full control over the animation.
private struct ToggleSwitch: View {
    let isOn: Bool

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? Tint.green : Color.secondary.opacity(0.30))
            Circle()
                .fill(Color.white)
                .shadow(color: .black.opacity(0.15), radius: 1.5, y: 0.5)
                .padding(2)
        }
        .frame(width: 32, height: 19)
        .animation(.spring(response: 0.35, dampingFraction: 0.78), value: isOn)
    }
}
