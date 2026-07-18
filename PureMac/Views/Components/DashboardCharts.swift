import SwiftUI
import Charts

// MARK: - Health Ring
//
// Premium animated radial gauge that replaces the flat StorageGauge. An
// angular-gradient sweep with a soft tinted glow, a rounded cap, and a
// spring-driven fill. The center number rolls via numericText. Honors
// Reduce Motion (no spring, no idle shimmer).

struct HealthRing: View {
    /// Primary fill, 0...1 (e.g. fraction of disk used).
    let percent: Double
    var tint: Color = Tint.blue
    var warnTint: Color = Tint.orange
    var stressThreshold: Double = 0.85
    var lineWidth: CGFloat = 14
    var subtitle: LocalizedStringKey = "USED"

    @State private var sweep: Double = 0
    @State private var displayPercent: Int = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var clamped: Double { max(0, min(1, percent)) }
    private var stress: Bool { clamped >= stressThreshold }
    private var arcColor: Color { stress ? warnTint : tint }
    private var trailColor: Color { stress ? Tint.red : Tint.purple }

    var body: some View {
        ZStack {
            // Orb body — a deep jewel fill that turns the flat ring into a
            // glowing sphere. Inset so it never bleeds across the track.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [arcColor.opacity(0.14), arcColor.opacity(0.05), .clear],
                        center: .center,
                        startRadius: 2,
                        endRadius: 160
                    )
                )
                .padding(lineWidth + 10)

            // Slow conic sheen sweeping the orb interior — the "alive" cue.
            // Removed entirely under Reduce Motion.
            if !reduceMotion {
                TimelineView(.animation) { timeline in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    let angle = (t.truncatingRemainder(dividingBy: 6.0) / 6.0) * 360.0
                    Circle()
                        .fill(
                            AngularGradient(
                                colors: [.clear, .clear, arcColor.opacity(0.10), .clear],
                                center: .center
                            )
                        )
                        .rotationEffect(.degrees(angle))
                }
                .padding(lineWidth + 10)
                .clipShape(Circle())
            }

            Circle()
                .stroke(Color.primary.opacity(0.06), lineWidth: lineWidth)

            // Bloom: a wide soft halo under a tighter, brighter one. The
            // glow comes from these blurred duplicates of the crisp arc.
            Circle()
                .trim(from: 0, to: sweep)
                .stroke(arcColor.opacity(0.35),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .blur(radius: 16)

            Circle()
                .trim(from: 0, to: sweep)
                .stroke(arcColor.opacity(0.55),
                        style: StrokeStyle(lineWidth: lineWidth * 0.7, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .blur(radius: 7)

            Circle()
                .trim(from: 0, to: sweep)
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: [arcColor.opacity(0.85), trailColor, arcColor]),
                        center: .center,
                        startAngle: .degrees(-90),
                        endAngle: .degrees(-90 + 360 * max(sweep, 0.0001))
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            // Endpoint highlight dot for a polished finish. The dot sits at the
            // top of the ring and the whole layer rotates about the ring
            // center so it orbits to the arc's end. Radius is derived from the
            // real frame so it tracks the stroke at any size.
            if sweep > 0.02 {
                GeometryReader { geo in
                    let radius = (min(geo.size.width, geo.size.height) - lineWidth) / 2
                    Circle()
                        .fill(.white)
                        .frame(width: lineWidth * 0.42, height: lineWidth * 0.42)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2 - radius)
                        .shadow(color: arcColor.opacity(0.7), radius: 4)
                }
                .rotationEffect(.degrees(360 * sweep))
            }

            VStack(spacing: 1) {
                Text("\(displayPercent)%")
                    .font(.system(size: 44, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(stress ? warnTint : Color.primary)
                Text(subtitle)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { animate(to: clamped) }
        .onChange(of: clamped) { animate(to: $0) }
    }

    private func animate(to value: Double) {
        if reduceMotion {
            sweep = value
            displayPercent = Int(round(value * 100))
            return
        }
        withAnimation(.spring(response: 1.0, dampingFraction: 0.82)) {
            sweep = value
        }
        withAnimation(.easeOut(duration: 0.9)) {
            displayPercent = Int(round(value * 100))
        }
    }
}

// MARK: - Storage Donut
//
// Custom multi-segment donut (Used / Junk / Purgeable / Free) drawn from
// trimmed arcs so it works on macOS 13 (SectorMark is 14+). Segments grow in
// with a spring on appear and animate when values change.

struct StorageDonut: View {
    struct Segment: Identifiable {
        /// Stable id (e.g. "used"/"junk") so legend rows keep identity across
        /// the many @Published refreshes that rebuild this array — otherwise a
        /// fresh UUID per render replays the staggered entrance animation.
        let id: String
        let value: Double      // raw byte fraction; normalized internally
        let color: Color
        let label: LocalizedStringKey
        let display: String
    }

    let segments: [Segment]
    var lineWidth: CGFloat = 16
    var gap: Double = 0.006    // angular gap between segments (fraction of circle)
    /// When set (legend hover), every other segment dims for cross-highlight.
    var highlightedID: String? = nil

    @State private var reveal: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var total: Double { max(segments.reduce(0) { $0 + $1.value }, 0.0001) }

    var body: some View {
        // A single segment is a full ring — no inter-segment hairline, so the
        // gap would otherwise carve a false missing slice.
        let effectiveGap = segments.count <= 1 ? 0 : gap
        let fractions = segments.map { $0.value / total }
        var cursor = 0.0
        var ranges: [(start: Double, end: Double)] = []
        for frac in fractions {
            let start = cursor
            cursor += frac
            // Trim back the trailing edge by `gap` for a hairline between
            // segments, clamped so a tiny slice never inverts.
            ranges.append((start, max(start, cursor - effectiveGap)))
        }

        return ZStack {
            Circle().stroke(Color.primary.opacity(0.05), lineWidth: lineWidth)
            ForEach(Array(segments.enumerated()), id: \.element.id) { idx, seg in
                Circle()
                    .trim(from: ranges[idx].start * reveal, to: ranges[idx].end * reveal)
                    .stroke(seg.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
                    .opacity(highlightedID == nil || highlightedID == seg.id ? 1 : 0.25)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: highlightedID)
        .onAppear {
            if reduceMotion { reveal = 1; return }
            withAnimation(.spring(response: 1.0, dampingFraction: 0.85)) { reveal = 1 }
        }
    }
}

// MARK: - Category Bar Chart
//
// Horizontal Swift Charts bar chart of junk size per category. BarMark is
// available on macOS 13. Used in the completed-scan state to give an
// at-a-glance "where the space is" graphic above the toggle list.

struct CategoryBarChart: View {
    struct Bar: Identifiable {
        // Category is unique per bar, so derive a stable id from it.
        var id: String { category.rawValue }
        let category: CleaningCategory
        let size: Int64
        var name: String { String(localized: String.LocalizationValue(category.rawValue)) }
    }

    let bars: [Bar]

    @State private var reveal: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Reserve ~28% trailing headroom so the byte-size annotation on the
        // longest bar renders fully instead of clipping at the chart edge
        // (the macOS 14+ annotation overflowResolution isn't available here).
        let maxSize = bars.map(\.size).max() ?? 0
        let upper = max(Int64(1), Int64(Double(maxSize) * 1.28))

        return Chart(bars) { bar in
            BarMark(
                x: .value("Size", Double(bar.size) * reveal),
                y: .value("Category", bar.name)
            )
            .foregroundStyle(bar.category.color.gradient)
            .cornerRadius(5)
            .annotation(position: .trailing, alignment: .leading) {
                Text(ByteCountFormatter.string(fromByteCount: bar.size, countStyle: .file))
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .opacity(reveal)
            }
        }
        .onAppear {
            if reduceMotion { reveal = 1; return }
            withAnimation(.spring(response: 0.8, dampingFraction: 0.85)) { reveal = 1 }
        }
        .chartXScale(domain: 0...upper)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(preset: .aligned, position: .leading) { _ in
                AxisValueLabel()
            }
        }
        .chartLegend(.hidden)
        .frame(height: max(120, CGFloat(bars.count) * 34))
    }
}

// MARK: - Legend chip

struct LegendChip: View {
    let color: Color
    let label: LocalizedStringKey
    let value: String
    /// Optional share readout ("72%") rendered after the value.
    var percent: String? = nil

    var body: some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                .fill(color)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 0) {
                Text(label)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(value)
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                    if let percent {
                        Text(percent)
                            .font(.system(size: 10, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
}

// MARK: - Stacked meter
//
// Full-width segmented storage bar (Used / Junk / Purgeable / Free). Segments
// sit flush inside one track with thin separators, grow in with a spring on
// appear, and cross-dim when a legend chip reports a hover. Honors Reduce
// Motion (instant reveal, instant cross-dim).

struct StackedMeter: View {
    struct Segment: Identifiable {
        /// Stable id so legend hover can cross-highlight the matching segment.
        let id: String
        let value: Double
        let color: Color
    }

    let segments: [Segment]
    var height: CGFloat = 14
    /// When set (legend hover), every other segment dims for cross-highlight.
    var highlightedID: String? = nil

    @State private var reveal: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var total: Double { max(segments.reduce(0) { $0 + $1.value }, 0.0001) }

    var body: some View {
        GeometryReader { geo in
            let separator: CGFloat = 2
            let available = geo.size.width - separator * CGFloat(max(0, segments.count - 1))
            HStack(spacing: separator) {
                ForEach(segments) { seg in
                    let frac = CGFloat(seg.value / total)
                    RoundedRectangle(cornerRadius: height * 0.3, style: .continuous)
                        .fill(seg.color)
                        .frame(width: max(frac > 0 ? 4 : 0, available * frac * reveal))
                        .opacity(highlightedID == nil || highlightedID == seg.id ? 1 : 0.28)
                }
            }
        }
        .frame(height: height)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: highlightedID)
        .onAppear {
            if reduceMotion { reveal = 1; return }
            withAnimation(.spring(response: 0.9, dampingFraction: 0.85)) { reveal = 1 }
        }
    }
}

// MARK: - Success medal
//
// Center checkmark with two concentric rings that expand and fade once on
// appear — a calm, premium "done" beat to pair with the freed-space number.

struct SuccessMedal: View {
    var tint: Color = Tint.green
    var size: CGFloat = 120

    @State private var pop = false
    @State private var ripple = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            ForEach(0..<2) { i in
                Circle()
                    .stroke(tint.opacity(ripple ? 0 : 0.45), lineWidth: 2)
                    .scaleEffect(ripple ? 1.5 + CGFloat(i) * 0.25 : 0.7)
            }
            Circle()
                .fill(tint.opacity(0.14))
                .scaleEffect(pop ? 1 : 0.6)

            Image(systemName: "checkmark")
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(tint)
                .scaleEffect(pop ? 1 : 0.3)
                .opacity(pop ? 1 : 0)
        }
        .frame(width: size, height: size)
        .onAppear {
            if reduceMotion { pop = true; return }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) { pop = true }
            withAnimation(.easeOut(duration: 1.1)) { ripple = true }
        }
    }
}

// MARK: - Staggered reveal
//
// Drop-in entrance animation: fades + lifts content with a per-index delay so
// grids and lists cascade in. Honors Reduce Motion.

struct StaggeredReveal: ViewModifier {
    let index: Int
    var baseDelay: Double = 0.04
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 10)
            .onAppear {
                if reduceMotion { shown = true; return }
                withAnimation(.spring(response: 0.5, dampingFraction: 0.85)
                    .delay(Double(index) * baseDelay)) {
                    shown = true
                }
            }
    }
}

extension View {
    func staggered(_ index: Int, baseDelay: Double = 0.04) -> some View {
        modifier(StaggeredReveal(index: index, baseDelay: baseDelay))
    }
}

// MARK: - Count-up bytes
//
// Animatable byte counter. `.contentTransition(.numericText())` only rolls
// when the change happens inside an animation transaction — values assigned
// during a plain data refresh snap instead. Driving the formatter through
// `animatableData` makes the roll-up play every time the target changes.
// Styling (font/color) flows in from the environment of the call site.

struct CountUpBytes: View {
    let bytes: Int64

    @State private var shown: Double = 0
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
            return
        }
        withAnimation(.easeOut(duration: 0.8)) {
            shown = Double(target)
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

// MARK: - Scanning gauge
//
// Active-scan focal element: a rotating trimmed arc over a radar wedge sweep
// with two expanding halo rings. Reduce Motion freezes every loop and falls
// back to the static arc + rolling percent.

struct ScanningGauge: View {
    let progress: Double
    var tint: Color = Tint.blue
    var label: LocalizedStringKey = "SCANNING"

    @State private var rotate = false
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            // Expanding halo rings, SuccessMedal-style but repeating.
            if !reduceMotion {
                ForEach(0..<2, id: \.self) { i in
                    Circle()
                        .stroke(tint.opacity(0.35), lineWidth: 1.5)
                        .scaleEffect(pulse ? 1.22 : 0.9)
                        .opacity(pulse ? 0 : 0.6)
                        .animation(
                            .easeOut(duration: 1.6)
                                .repeatForever(autoreverses: false)
                                .delay(Double(i) * 0.8),
                            value: pulse
                        )
                }
            }

            // Radar wedge sweeping the ring interior. TimelineView keeps the
            // angle deterministic; the branch above removes it entirely under
            // Reduce Motion.
            if !reduceMotion {
                TimelineView(.animation) { timeline in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    let angle = (t.truncatingRemainder(dividingBy: 3.0) / 3.0) * 360.0
                    Circle()
                        .fill(
                            AngularGradient(
                                colors: [tint.opacity(0), tint.opacity(0), tint.opacity(0.22)],
                                center: .center
                            )
                        )
                        .rotationEffect(.degrees(angle))
                }
                .padding(14)
                .clipShape(Circle())
            }

            Circle()
                .stroke(Color.primary.opacity(0.07), lineWidth: 10)

            Circle()
                .trim(from: 0, to: CGFloat(max(0.05, min(0.95, progress))))
                .stroke(tint, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(rotate ? 360 : 0))
                .animation(
                    reduceMotion ? nil : .linear(duration: 4).repeatForever(autoreverses: false),
                    value: rotate
                )

            VStack(spacing: 2) {
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 36, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(reduceMotion ? .identity : .numericText())
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: Int(progress * 100))
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            rotate = true
            pulse = true
        }
    }
}
