import Charts
import SwiftUI

struct HealthRing: View {
    let percent: Double
    var size: CGFloat = 190
    var lineWidth: CGFloat = 13
    var tint: Color = Tint.accent
    var warnTint: Color = Tint.orange
    var stressThreshold: Double = 0.9
    var subtitle: LocalizedStringKey = "USED"

    @State private var reveal: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var clamped: Double {
        max(0, min(1, percent))
    }

    private var ringTint: Color {
        clamped >= stressThreshold ? warnTint : tint
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.075), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: reveal)
                .stroke(ringTint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 2) {
                Text("\(Int((clamped * 100).rounded()))%")
                    .font(.system(size: 38, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(subtitle)
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .onAppear { animate() }
        .onChange(of: clamped) { _ in animate() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(subtitle))
        .accessibilityValue("\(Int((clamped * 100).rounded())) percent")
    }

    private func animate() {
        if reduceMotion {
            reveal = clamped
        } else {
            withAnimation(.easeOut(duration: 0.65)) {
                reveal = clamped
            }
        }
    }
}

struct StorageDonut: View {
    struct Segment: Identifiable {
        let id: String
        let value: Double
        let color: Color
        let label: LocalizedStringKey
        let display: String
    }

    let segments: [Segment]
    var lineWidth: CGFloat = 16
    var gap: Double = 0.008
    var highlightedID: String? = nil

    @State private var reveal: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var total: Double {
        max(segments.reduce(0) { $0 + $1.value }, 0.0001)
    }

    var body: some View {
        let effectiveGap = segments.count <= 1 ? 0 : gap
        let fractions = segments.map { $0.value / total }
        var cursor = 0.0
        var ranges: [(start: Double, end: Double)] = []

        for fraction in fractions {
            let start = cursor
            cursor += fraction
            ranges.append((start, max(start, cursor - effectiveGap)))
        }

        return ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.065), lineWidth: lineWidth)
            ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                Circle()
                    .trim(
                        from: ranges[index].start * reveal,
                        to: ranges[index].end * reveal
                    )
                    .stroke(
                        segment.color,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt)
                    )
                    .rotationEffect(.degrees(-90))
                    .opacity(highlightedID == nil || highlightedID == segment.id ? 1 : 0.22)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: highlightedID)
        .onAppear {
            if reduceMotion {
                reveal = 1
            } else {
                withAnimation(.easeOut(duration: 0.7)) {
                    reveal = 1
                }
            }
        }
    }
}

struct CategoryBarChart: View {
    struct Bar: Identifiable {
        var id: String { category.rawValue }
        let category: CleaningCategory
        let size: Int64
        var name: String { String(localized: String.LocalizationValue(category.rawValue)) }
    }

    let bars: [Bar]
    @State private var reveal = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let maxSize = bars.map(\.size).max() ?? 0
        let upper = max(Int64(1), Int64(Double(maxSize) * 1.25))

        Chart(bars) { bar in
            BarMark(
                x: .value("Size", Double(bar.size) * reveal),
                y: .value(String(localized: "Category"), bar.name)
            )
            .foregroundStyle(bar.category.color)
            .cornerRadius(4)
            .annotation(position: .trailing, alignment: .leading) {
                Text(ByteCountFormatter.string(fromByteCount: bar.size, countStyle: .file))
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .opacity(reveal)
            }
        }
        .chartXScale(domain: 0...upper)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(preset: .aligned, position: .leading) { _ in
                AxisValueLabel()
            }
        }
        .chartLegend(.hidden)
        .frame(height: max(120, CGFloat(bars.count) * 32))
        .onAppear {
            if reduceMotion {
                reveal = 1
            } else {
                withAnimation(.easeOut(duration: 0.6)) {
                    reveal = 1
                }
            }
        }
    }
}

struct LegendChip: View {
    let color: Color
    let label: LocalizedStringKey
    let value: String
    var percent: String? = nil

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(value)
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                    if let percent {
                        Text(percent)
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
}

struct StackedMeter: View {
    struct Segment: Identifiable {
        let id: String
        let value: Double
        let color: Color
    }

    let segments: [Segment]
    var height: CGFloat = 12
    var highlightedID: String? = nil

    @State private var reveal: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var total: Double {
        max(segments.reduce(0) { $0 + $1.value }, 0.0001)
    }

    var body: some View {
        GeometryReader { geometry in
            let spacing: CGFloat = 2
            let available = geometry.size.width - spacing * CGFloat(max(0, segments.count - 1))
            HStack(spacing: spacing) {
                ForEach(segments) { segment in
                    let fraction = CGFloat(segment.value / total)
                    RoundedRectangle(cornerRadius: height * 0.28, style: .continuous)
                        .fill(segment.color)
                        .frame(width: max(fraction > 0 ? 3 : 0, available * fraction * reveal))
                        .opacity(highlightedID == nil || highlightedID == segment.id ? 1 : 0.24)
                }
            }
        }
        .frame(height: height)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: highlightedID)
        .onAppear {
            if reduceMotion {
                reveal = 1
            } else {
                withAnimation(.easeOut(duration: 0.65)) {
                    reveal = 1
                }
            }
        }
    }
}

struct SuccessMedal: View {
    var tint: Color = Tint.green
    var size: CGFloat = 120
    @State private var visible = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.11))
            Circle()
                .strokeBorder(tint.opacity(0.18), lineWidth: 1)
            Image(systemName: "checkmark")
                .font(.system(size: size * 0.34, weight: .semibold))
                .foregroundStyle(tint)
        }
        .frame(width: size, height: size)
        .scaleEffect(visible ? 1 : 0.92)
        .opacity(visible ? 1 : 0)
        .onAppear {
            if reduceMotion {
                visible = true
            } else {
                withAnimation(MotionTokens.gentle) {
                    visible = true
                }
            }
        }
    }
}

struct StaggeredReveal: ViewModifier {
    let index: Int
    var baseDelay = 0.035
    @State private var shown = false
    @Environment(\.interfaceMotionEnabled) private var motion

    func body(content: Content) -> some View {
        content
            .opacity(shown || !motion ? 1 : 0)
            .offset(y: shown || !motion ? 0 : 6)
            .onAppear {
                if !motion {
                    shown = true
                } else {
                    withAnimation(.easeOut(duration: 0.28).delay(Double(min(index, 5)) * baseDelay)) {
                        shown = true
                    }
                }
            }
    }
}

extension View {
    func staggered(_ index: Int, baseDelay: Double = 0.035) -> some View {
        modifier(StaggeredReveal(index: index, baseDelay: baseDelay))
    }
}

struct CountUpBytes: View {
    let bytes: Int64
    @State private var shown = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .modifier(ByteRollEffect(value: shown))
            .onAppear { animate(to: bytes) }
            .onChange(of: bytes) { animate(to: $0) }
    }

    private func animate(to target: Int64) {
        if reduceMotion {
            shown = Double(target)
        } else {
            withAnimation(.easeOut(duration: 0.55)) {
                shown = Double(target)
            }
        }
    }
}

private struct ByteRollEffect: AnimatableModifier {
    var value: Double

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    func body(content: Content) -> some View {
        Text(ByteCountFormatter.string(fromByteCount: Int64(max(0, value)), countStyle: .file))
            .monospacedDigit()
    }
}

struct ScanningGauge: View {
    let progress: Double
    var tint: Color = Tint.accent
    var label: LocalizedStringKey = "SCANNING"

    @State private var rotation = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var clamped: Double {
        max(0, min(1, progress))
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.07), lineWidth: 10)
            Circle()
                .trim(from: 0, to: max(0.035, clamped))
                .stroke(tint, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90 + rotation))
            VStack(spacing: 2) {
                Text("\(Int((clamped * 100).rounded()))%")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(label)
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.9)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 5).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue("\(Int((clamped * 100).rounded())) percent")
    }
}
