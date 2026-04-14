import SwiftUI

struct SmartScanView: View {
    @EnvironmentObject var vm: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            switch vm.scanState {
            case .idle:
                idleView
            case .scanning:
                scanningView
            case .completed:
                completedView
            case .cleaning:
                cleaningView
            case .cleaned:
                cleanedView
            }

            Spacer()

            // Bottom action bar
            actionBar
                .padding(.bottom, 32)
        }
        .padding(.horizontal, 40)
    }

    // MARK: - Idle View

    private var idleView: some View {
        VStack(spacing: 24) {
            ZStack {
                // Outer glow ring
                Circle()
                    .stroke(Color.pmAccent.opacity(0.1), lineWidth: 2)
                    .frame(width: 220, height: 220)

                Circle()
                    .stroke(Color.pmAccent.opacity(0.05), lineWidth: 1)
                    .frame(width: 250, height: 250)

                // Main circle
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.pmAccent.opacity(0.15), Color.pmBackground],
                            center: .center,
                            startRadius: 20,
                            endRadius: 110
                        )
                    )
                    .frame(width: 200, height: 200)

                VStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 40))
                        .foregroundColor(.pmAccentLight)

                    Text("Smart Scan")
                        .font(.pmHeadline)
                        .foregroundColor(.pmTextPrimary)

                    Text("Click Scan to start")
                        .font(.pmCaption)
                        .foregroundColor(.pmTextMuted)
                }
            }
            .pmGlow(color: .pmAccent, radius: 40)

            // Disk overview
            diskOverview
        }
    }

    // MARK: - Scanning View

    private var scanningView: some View {
        VStack(spacing: 24) {
            ZStack {
                // Background ring
                Circle()
                    .stroke(Color.pmCard, lineWidth: 8)
                    .frame(width: 200, height: 200)

                // Progress ring
                Circle()
                    .trim(from: 0, to: vm.scanProgress)
                    .stroke(
                        AppGradients.scanRing,
                        style: StrokeStyle(lineWidth: 8, lineCap: .round)
                    )
                    .frame(width: 200, height: 200)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.3), value: vm.scanProgress)

                // Spinning outer ring
                Circle()
                    .trim(from: 0, to: 0.3)
                    .stroke(
                        Color.pmAccent.opacity(0.3),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round)
                    )
                    .frame(width: 230, height: 230)
                    .rotationEffect(.degrees(rotationAngle))

                VStack(spacing: 4) {
                    Text("\(Int(vm.scanProgress * 100))%")
                        .font(.pmLargeNumber)
                        .foregroundColor(.pmTextPrimary)
                        .contentTransition(.numericText())

                    Text(LocalizedStringKey(vm.currentScanCategory))
                        .font(.pmCaption)
                        .foregroundColor(.pmTextSecondary)
                        .lineLimit(1)
                }
            }

            // Live results
            if !vm.allResults.isEmpty {
                liveResults
            }
        }
        .onAppear { startRotation() }
    }

    // MARK: - Completed View

    private var completedView: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .stroke(Color.pmCard, lineWidth: 8)
                    .frame(width: 200, height: 200)

                Circle()
                    .trim(from: 0, to: 1)
                    .stroke(
                        AppGradients.primary,
                        style: StrokeStyle(lineWidth: 8, lineCap: .round)
                    )
                    .frame(width: 200, height: 200)
                    .rotationEffect(.degrees(-90))

                VStack(spacing: 4) {
                    Text(ByteCountFormatter.string(fromByteCount: vm.totalJunkSize, countStyle: .file))
                        .font(.pmLargeNumber)
                        .foregroundColor(.pmTextPrimary)

                    Text("junk found")
                        .font(.pmSubheadline)
                        .foregroundColor(.pmTextSecondary)
                }
            }
            .pmGlow(color: vm.totalJunkSize > 0 ? .pmWarning : .pmSuccess, radius: 30)

            // Results breakdown
            if !vm.allResults.isEmpty {
                resultsBreakdown
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 32))
                        .foregroundColor(.pmSuccess)
                    Text("Your Mac is clean!")
                        .font(.pmSubheadline)
                        .foregroundColor(.pmTextSecondary)
                }
            }
        }
    }

    // MARK: - Cleaning View

    private var cleaningView: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .stroke(Color.pmCard, lineWidth: 8)
                    .frame(width: 200, height: 200)

                Circle()
                    .trim(from: 0, to: vm.cleanProgress)
                    .stroke(
                        AppGradients.danger,
                        style: StrokeStyle(lineWidth: 8, lineCap: .round)
                    )
                    .frame(width: 200, height: 200)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.3), value: vm.cleanProgress)

                VStack(spacing: 4) {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 28))
                        .foregroundColor(.pmDanger)

                    Text("Cleaning...")
                        .font(.pmSubheadline)
                        .foregroundColor(.pmTextSecondary)

                    Text("\(Int(vm.cleanProgress * 100))%")
                        .font(.pmMediumNumber)
                        .foregroundColor(.pmTextPrimary)
                        .contentTransition(.numericText())
                }
            }
        }
    }

    // MARK: - Cleaned View

    private var cleanedView: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(Color.pmSuccess.opacity(0.1))
                    .frame(width: 200, height: 200)

                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.pmSuccess)

                    Text(ByteCountFormatter.string(fromByteCount: vm.totalFreedSpace, countStyle: .file))
                        .font(.pmLargeNumber)
                        .foregroundColor(.pmSuccess)

                    Text("freed up")
                        .font(.pmSubheadline)
                        .foregroundColor(.pmTextSecondary)
                }
            }
            .pmGlow(color: .pmSuccess, radius: 40)
        }
        .transition(.scale.combined(with: .opacity))
    }

    // MARK: - Sub Views

    private var diskOverview: some View {
        HStack(spacing: 24) {
            DiskStatCard(
                title: "Total",
                value: vm.diskInfo.formattedTotal,
                icon: "internaldrive.fill",
                color: .pmAccent
            )
            DiskStatCard(
                title: "Used",
                value: vm.diskInfo.formattedUsed,
                icon: "chart.pie.fill",
                color: .pmWarning
            )
            DiskStatCard(
                title: "Free",
                value: vm.diskInfo.formattedFree,
                icon: "checkmark.circle.fill",
                color: .pmSuccess
            )
            if vm.diskInfo.purgeableSpace > 0 {
                DiskStatCard(
                    title: "Purgeable",
                    value: vm.diskInfo.formattedPurgeable,
                    icon: "arrow.3.trianglepath",
                    color: .pmInfo
                )
            }
        }
    }

    private var liveResults: some View {
        VStack(spacing: 8) {
            ForEach(vm.allResults.prefix(6)) { result in
                HStack(spacing: 12) {
                    Image(systemName: result.category.icon)
                        .font(.system(size: 12))
                        .foregroundColor(result.category.color)
                        .frame(width: 20)

                    Text(LocalizedStringKey(result.category.rawValue))
                        .font(.pmCaption)
                        .foregroundColor(.pmTextSecondary)

                    Spacer()

                    Text(result.formattedSize)
                        .font(.pmCaption)
                        .foregroundColor(.pmTextPrimary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
        }
        .padding(.vertical, 12)
        .background(Color.pmCard.opacity(0.5))
        .cornerRadius(12)
        .frame(maxWidth: 400)
    }

    private var resultsBreakdown: some View {
        VStack(spacing: 8) {
            ForEach(vm.allResults) { result in
                ResultRow(result: result) {
                    withAnimation(.pmSpring) {
                        vm.selectedCategory = result.category
                    }
                }
            }
        }
        .frame(maxWidth: 450)
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        HStack(spacing: 16) {
            switch vm.scanState {
            case .idle:
                GradientActionButton(
                    title: "Scan",
                    icon: "magnifyingglass",
                    gradient: AppGradients.primary
                ) {
                    withAnimation(.pmSpring) {
                        vm.startSmartScan()
                    }
                }

            case .scanning:
                Button(action: {}) {
                    HStack(spacing: 8) {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .scaleEffect(0.7)
                            .tint(.white)
                        Text("Scanning...")
                            .font(.pmSubheadline)
                            .foregroundColor(.pmTextSecondary)
                    }
                    .frame(width: 200, height: 44)
                    .background(Color.pmCard)
                    .cornerRadius(12)
                }
                .buttonStyle(.plain)
                .disabled(true)

            case .completed:
                if vm.totalSelectedSize > 0 {
                    GradientActionButton(
                        title: "Clean (\(ByteCountFormatter.string(fromByteCount: vm.totalSelectedSize, countStyle: .file)))",
                        icon: "trash.fill",
                        gradient: AppGradients.accent
                    ) {
                        withAnimation(.pmSpring) {
                            vm.cleanAll()
                        }
                    }

                    Button(action: {
                        withAnimation(.pmSpring) {
                            vm.startSmartScan()
                        }
                    }) {
                        Text("Re-scan")
                            .font(.pmBody)
                            .foregroundColor(.pmTextSecondary)
                            .frame(height: 44)
                            .padding(.horizontal, 24)
                            .background(Color.pmCard)
                            .cornerRadius(12)
                    }
                    .buttonStyle(.plain)
                } else {
                    GradientActionButton(
                        title: "Scan Again",
                        icon: "arrow.clockwise",
                        gradient: AppGradients.success
                    ) {
                        withAnimation(.pmSpring) {
                            vm.startSmartScan()
                        }
                    }
                }

            case .cleaning:
                Button(action: {}) {
                    HStack(spacing: 8) {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .scaleEffect(0.7)
                            .tint(.white)
                        Text("Cleaning...")
                            .font(.pmSubheadline)
                            .foregroundColor(.pmTextSecondary)
                    }
                    .frame(width: 200, height: 44)
                    .background(Color.pmCard)
                    .cornerRadius(12)
                }
                .buttonStyle(.plain)
                .disabled(true)

            case .cleaned:
                GradientActionButton(
                    title: "Done",
                    icon: "checkmark",
                    gradient: AppGradients.success
                ) {
                    withAnimation(.pmSpring) {
                        vm.scanState = .idle
                    }
                }
            }
        }
    }

    // MARK: - Animation State

    @State private var rotationAngle: Double = 0
    @State private var rotationTimer: Timer?

    private func startRotation() {
        rotationTimer?.invalidate()
        rotationTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in
            DispatchQueue.main.async {
                rotationAngle += 1.5
                if rotationAngle >= 360 { rotationAngle = 0 }
            }
        }
    }
}

// MARK: - Disk Stat Card

struct DiskStatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(color)

            Text(value)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundColor(.pmTextPrimary)

            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.pmTextMuted)
        }
        .frame(width: 100, height: 80)
        .background(Color.pmCard.opacity(0.5))
        .cornerRadius(12)
    }
}

// MARK: - Result Row (Clickable)

struct ResultRow: View {
    @EnvironmentObject var vm: AppViewModel
    let result: CategoryResult
    let onTap: () -> Void

    @State private var isHovering = false

    var isCategorySelected: Bool {
        vm.selectedCountInCategory(result.category) > 0
    }

    var isFullySelected: Bool {
        vm.selectedCountInCategory(result.category) == result.itemCount
    }

    var selectedSize: Int64 {
        vm.selectedSizeInCategory(result.category)
    }

    var body: some View {
        HStack(spacing: 12) {
            // Category checkbox
            Button(action: {
                withAnimation(.pmSmooth) {
                    if isFullySelected {
                        vm.deselectAllInCategory(result.category)
                    } else {
                        vm.selectAllInCategory(result.category)
                    }
                }
            }) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isCategorySelected ? result.category.color : Color.pmTextMuted, lineWidth: 1.5)
                        .frame(width: 18, height: 18)

                    if isFullySelected {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(result.category.color)
                            .frame(width: 18, height: 18)

                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                    } else if isCategorySelected {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(result.category.color)
                            .frame(width: 18, height: 18)

                        Image(systemName: "minus")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Category icon + info (clickable to navigate)
            Button(action: onTap) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(result.category.color.opacity(isCategorySelected ? 0.15 : 0.05))
                            .frame(width: 28, height: 28)

                        Image(systemName: result.category.icon)
                            .font(.system(size: 12))
                            .foregroundColor(isCategorySelected ? result.category.color : .pmTextMuted)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(LocalizedStringKey(result.category.rawValue))
                            .font(.pmBody)
                            .foregroundColor(isCategorySelected ? .pmTextPrimary : .pmTextMuted)

                        Text("\(vm.selectedCountInCategory(result.category))/\(result.itemCount) items")
                            .font(.system(size: 10))
                            .foregroundColor(.pmTextMuted)
                    }

                    Spacer()

                    Text(ByteCountFormatter.string(fromByteCount: selectedSize, countStyle: .file))
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundColor(isCategorySelected ? result.category.color : .pmTextMuted)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(isHovering ? result.category.color : .pmTextMuted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isHovering ? Color.pmCardHover : Color.pmCard.opacity(0.4))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isHovering ? result.category.color.opacity(0.3) : Color.clear, lineWidth: 1)
        )
        .onHover { h in
            withAnimation(.pmSmooth) { isHovering = h }
        }
    }
}

// MARK: - Gradient Action Button

struct GradientActionButton: View {
    let title: LocalizedStringKey
    let icon: String
    let gradient: LinearGradient
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                Text(title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
            }
            .foregroundColor(.white)
            .frame(height: 44)
            .padding(.horizontal, 32)
            .background(gradient)
            .cornerRadius(12)
            .scaleEffect(isHovering ? 1.03 : 1.0)
            .pmShadow(radius: isHovering ? 15 : 8, y: isHovering ? 6 : 4)
        }
        .buttonStyle(.plain)
        .onHover { h in
            withAnimation(.pmSmooth) { isHovering = h }
        }
    }
}
