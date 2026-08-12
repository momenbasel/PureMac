import SwiftUI

/// A semantic storage sculpture: its layers represent the checks PureMac
/// performs while the inspection light follows real scan and cleanup progress.
struct SmartCareCoreArtwork: View {
    enum Phase: Equatable {
        case idle
        case scanning(Double)
        case review
        case cleaning(Double)
        case success

        var tint: Color {
            switch self {
            case .idle: return Tint.cyan
            case .scanning: return Tint.blue
            case .review, .cleaning: return Tint.orange
            case .success: return Tint.green
            }
        }

        var progress: Double? {
            switch self {
            case .scanning(let value), .cleaning(let value):
                return max(0, min(1, value))
            case .idle, .review, .success:
                return nil
            }
        }

        var isWorking: Bool {
            switch self {
            case .scanning, .cleaning: return true
            case .idle, .review, .success: return false
            }
        }

    }

    let phase: Phase
    var size: CGFloat = 330

    @State private var hovering = false
    @State private var hoverLocation: CGPoint?
    @State private var tilt = CGSize.zero
    @State private var isDragging = false
    @State private var settleGeneration = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Image("SmartCareCore")
                .resizable()
                .scaledToFit()
                .contrast(1.02)
                .saturation(phase.isWorking ? 0.28 : (phase == .success ? 0.82 : 0.94))
                .brightness(phase == .success ? 0.045 : 0)
                .shadow(
                    color: phase.tint.opacity(phase.isWorking ? 0.22 : 0.12),
                    radius: phase.isWorking ? 22 : 14,
                    y: 5
                )
                .animation(reduceMotion ? nil : MotionTokens.gentle, value: phase)

            phaseLight

            interactionHighlight
        }
        .scaleEffect(interactionScale)
        .offset(y: isDragging && !reduceMotion ? -5 : 0)
        .rotation3DEffect(
            .degrees(Double(rotationAngle)),
            axis: rotationAxis,
            perspective: 0.42
        )
        .shadow(
            color: Color.black.opacity(isDragging ? 0.42 : 0.24),
            radius: isDragging ? 28 : 16,
            y: isDragging ? 18 : 9
        )
        .animation(
            reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.86),
            value: hoverLocation
        )
        .frame(width: size, height: size)
        .contentShape(RoundedRectangle(cornerRadius: size * 0.18, style: .continuous))
        .onContinuousHover { hoverPhase in
            switch hoverPhase {
            case .active(let location):
                hovering = true
                hoverLocation = location
            case .ended:
                hovering = false
                hoverLocation = nil
            }
        }
        .gesture(tiltGesture)
        .help("Drag to tilt")
        .onDisappear {
            settleGeneration += 1
        }
        .accessibilityHidden(true)
    }

    private var tiltGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .local)
            .onChanged { value in
                guard !reduceMotion else { return }

                settleGeneration += 1
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    isDragging = true
                    tilt = boundedTilt(for: value.translation)
                }
            }
            .onEnded { value in
                guard !reduceMotion else {
                    tilt = .zero
                    isDragging = false
                    return
                }

                settleGeneration += 1
                let generation = settleGeneration
                let current = boundedTilt(for: value.translation)
                let predicted = boundedTilt(for: value.predictedEndTranslation)
                let projected = boundedVector(
                    CGSize(
                        width: current.width + (predicted.width - current.width) * 0.22,
                        height: current.height + (predicted.height - current.height) * 0.22
                    ),
                    maximum: 10
                )

                withAnimation(.easeOut(duration: 0.1)) {
                    isDragging = false
                    tilt = projected
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    guard settleGeneration == generation else { return }
                    withAnimation(.spring(response: 0.46, dampingFraction: 0.78)) {
                        tilt = .zero
                    }
                }
            }
    }

    private var activeTilt: CGSize {
        guard !reduceMotion else { return .zero }
        if isDragging || tilt != .zero {
            return tilt
        }

        guard let hoverLocation else {
            return hovering ? CGSize(width: 1.8, height: -1.1) : .zero
        }
        return boundedVector(
            CGSize(
                width: (hoverLocation.x / size - 0.5) * 7,
                height: (hoverLocation.y / size - 0.5) * 6
            ),
            maximum: 3.5
        )
    }

    private var rotationAngle: CGFloat {
        hypot(activeTilt.width, activeTilt.height)
    }

    private var rotationAxis: (x: CGFloat, y: CGFloat, z: CGFloat) {
        let angle = rotationAngle
        guard angle > 0.001 else {
            return (x: 1, y: 0, z: 0)
        }
        return (
            x: -activeTilt.height / angle,
            y: activeTilt.width / angle,
            z: 0
        )
    }

    private var interactionScale: CGFloat {
        guard !reduceMotion else { return 1 }
        if isDragging { return 1.035 }
        return hovering ? 1.018 : 1
    }

    private var interactionHighlight: some View {
        LinearGradient(
            colors: [
                Color.white.opacity(isDragging ? 0.2 : 0.1),
                Color.clear,
                phase.tint.opacity(isDragging ? 0.08 : 0.035)
            ],
            startPoint: UnitPoint(
                x: clamped(0.28 + activeTilt.width / 36, to: 0.08...0.48),
                y: clamped(0.18 + activeTilt.height / 40, to: 0.06...0.42)
            ),
            endPoint: UnitPoint(
                x: clamped(0.72 + activeTilt.width / 36, to: 0.52...0.92),
                y: clamped(0.82 + activeTilt.height / 40, to: 0.58...0.94)
            )
        )
        .blendMode(.screen)
        .mask(
            Image("SmartCareCore")
                .resizable()
                .scaledToFit()
        )
        .opacity(hovering || isDragging || tilt != .zero ? 1 : 0)
    }

    private func boundedTilt(for translation: CGSize) -> CGSize {
        boundedVector(
            CGSize(
                width: translation.width / size * 30,
                height: translation.height / size * 30
            ),
            maximum: 10
        )
    }

    private func boundedVector(_ vector: CGSize, maximum: CGFloat) -> CGSize {
        let magnitude = hypot(vector.width, vector.height)
        guard magnitude > maximum, magnitude > 0 else { return vector }
        let scale = maximum / magnitude
        return CGSize(width: vector.width * scale, height: vector.height * scale)
    }

    private func clamped(_ value: CGFloat, to range: ClosedRange<CGFloat>) -> CGFloat {
        min(max(value, range.lowerBound), range.upperBound)
    }

    @ViewBuilder
    private var phaseLight: some View {
        if let progress = phase.progress {
            inspectionFill(progress: progress)
        } else if phase == .review {
            edgeGlow(color: Tint.orange, opacity: 0.14)
        } else if phase == .success {
            edgeGlow(color: Tint.green, opacity: 0.18)
        }
    }

    private func inspectionFill(progress: Double) -> some View {
        let clamped = max(0, min(1, progress))
        let fillHeight = size * CGFloat(clamped)
        let leadingEdgeOffset = size * (0.5 - CGFloat(clamped))

        return ZStack {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.34),
                        phase.tint.opacity(0.72),
                        phase.tint.opacity(0.3)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: fillHeight)
            }

            LinearGradient(
                colors: [
                    Color.clear,
                    phase.tint.opacity(0.72),
                    Color.white.opacity(0.38),
                    phase.tint.opacity(0.56),
                    Color.clear
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: size * 0.14)
            .offset(y: leadingEdgeOffset)
            .opacity(clamped > 0 ? 1 : 0)
        }
        .frame(width: size, height: size)
        .blendMode(.screen)
        .mask(
            Image("SmartCareCore")
                .resizable()
                .scaledToFit()
        )
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: clamped)
    }

    private func edgeGlow(color: Color, opacity: Double) -> some View {
        RadialGradient(
            colors: [color.opacity(opacity), .clear],
            center: UnitPoint(x: 0.53, y: 0.52),
            startRadius: 0,
            endRadius: size * 0.42
        )
        .blendMode(.screen)
        .mask(
            Image("SmartCareCore")
                .resizable()
                .scaledToFit()
        )
    }
}
