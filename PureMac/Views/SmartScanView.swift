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
        VStack(spacing: 32) {
            // Logo-centered circle
            ZStack {
                // Outer decorative ring
                Circle()
                    .stroke(Color.pmSeparator.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                    .frame(width: 240, height: 240)

                // Main ring track
                Circle()
                    .stroke(Color.pmSeparator.opacity(0.2), lineWidth: 8)
                    .frame(width: 200, height: 200)

                // Accent arc hint
                Circle()
                    .trim(from: 0, to: 0.3)
                    .stroke(Color.pmAccent.opacity(0.15), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .frame(width: 200, height: 200)
                    .rotationEffect(.degrees(-90))

                // Inner fill
                Circle()
                    .fill(Color.pmAccent.opacity(0.04))
                    .frame(width: 188, height: 188)

                // App logo as centerpiece
                VStack(spacing: 12) {
                    Image("SidebarLogo")
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 56, height: 56)
                        .shadow(color: .black.opacity(0.08), radius: 6, y: 3)

                    Text("Smart Scan")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundColor(.pmTextPrimary)

                    Text("Analyze all categories")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.pmTextMuted)
                }
            }

            // Disk overview cards
            diskOverview
        }
    }

    // MARK: - Scanning View

    private var scanningView: some View {
        ZStack {
            // Circle — pinned above center, never moves
            ZStack {
                // Thick track
                Circle()
                    .stroke(Color.pmSeparator.opacity(0.15), lineWidth: 10)
                    .frame(width: 200, height: 200)

                // Progress ring
                Circle()
                    .trim(from: 0, to: vm.scanProgress)
                    .stroke(
                        AngularGradient(
                            colors: [.pmAccent, .pmAccentLight, .pmAccent],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 10, lineCap: .round)
                    )
                    .frame(width: 200, height: 200)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.3), value: vm.scanProgress)

                // Spinning outer indicator
                Circle()
                    .trim(from: 0, to: 0.2)
                    .stroke(
                        Color.pmAccent.opacity(0.15),
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
                    )
                    .frame(width: 226, height: 226)
                    .rotationEffect(.degrees(rotationAngle))

                // Center content
                VStack(spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text("\(Int(vm.scanProgress * 100))")
                            .font(.system(size: 48, weight: .bold, design: .rounded))
                            .foregroundColor(.pmTextPrimary)
                            .contentTransition(.numericText())

                        Text("%")
                            .font(.system(size: 20, weight: .medium, design: .rounded))
                            .foregroundColor(.pmTextMuted)
                    }

                    Text(LocalizedStringKey(vm.currentScanCategory))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.pmTextSecondary)
                        .lineLimit(1)
                        .padding(.top, 4)
                }
            }
            .offset(y: -80)

            // Results — pinned below center, staggered fade-in
            if !vm.allResults.isEmpty {
                liveResults
                    .offset(y: 140)
                    .transition(.opacity)
            }
        }
        .onAppear { startRotation() }
    }

    // MARK: - Completed View

    private var completedView: some View {
        VStack(spacing: 24) {
            ZStack {
                // Track
                Circle()
                    .stroke(Color.pmSeparator.opacity(0.15), lineWidth: 10)
                    .frame(width: 200, height: 200)

                // Full ring
                Circle()
                    .stroke(Color.pmAccent, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .frame(width: 200, height: 200)

                // Center content
                VStack(spacing: 4) {
                    if vm.totalJunkSize > 0 {
                        Text(ByteCountFormatter.string(fromByteCount: vm.totalJunkSize, countStyle: .file))
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .foregroundColor(.pmTextPrimary)

                        Text("junk found")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.pmTextSecondary)
                    } else {
                        Image(systemName: "checkmark")
                            .font(.system(size: 36, weight: .light))
                            .foregroundColor(.pmSuccess)

                        Text("All clean")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundColor(.pmTextPrimary)
                    }
                }
            }

            // Segmented breakdown bar
            if !vm.allResults.isEmpty {
                junkBreakdownBar
                    .padding(.top, 4)
            }

            // Results breakdown
            if !vm.allResults.isEmpty {
                resultsBreakdown
            }
        }
    }

    // MARK: - Cleaning View

    private var cleaningView: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .stroke(Color.pmSeparator.opacity(0.15), lineWidth: 10)
                    .frame(width: 200, height: 200)

                Circle()
                    .trim(from: 0, to: vm.cleanProgress)
                    .stroke(Color.pmDanger, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .frame(width: 200, height: 200)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.3), value: vm.cleanProgress)

                VStack(spacing: 4) {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 22, weight: .light))
                        .foregroundColor(.pmDanger)

                    Text("\(Int(vm.cleanProgress * 100))%")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundColor(.pmTextPrimary)
                        .contentTransition(.numericText())

                    Text("Cleaning...")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.pmTextSecondary)
                }
            }
        }
    }

    // MARK: - Cleaned View

    private var cleanedView: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .stroke(Color.pmSuccess.opacity(0.2), lineWidth: 10)
                    .frame(width: 200, height: 200)

                Circle()
                    .fill(Color.pmSuccess.opacity(0.04))
                    .frame(width: 190, height: 190)

                VStack(spacing: 8) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 32, weight: .light))
                        .foregroundColor(.pmSuccess)

                    Text(ByteCountFormatter.string(fromByteCount: vm.totalFreedSpace, countStyle: .file))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundColor(.pmSuccess)

                    Text("freed up")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.pmTextSecondary)
                }
            }
        }
        .transition(.scale.combined(with: .opacity))
    }

    // MARK: - Junk Breakdown Bar

    private var junkBreakdownBar: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                HStack(spacing: 1.5) {
                    ForEach(vm.allResults) { result in
                        let fraction = vm.totalJunkSize > 0
                            ? CGFloat(result.totalSize) / CGFloat(vm.totalJunkSize)
                            : 0

                        RoundedRectangle(cornerRadius: 3)
                            .fill(result.category.color)
                            .frame(width: max(4, geo.size.width * fraction))
                    }
                }
            }
            .frame(height: 8)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.pmSeparator.opacity(0.2))
            )
            .clipShape(RoundedRectangle(cornerRadius: 3))

            // Legend
            HStack(spacing: 12) {
                ForEach(vm.allResults.prefix(5)) { result in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(result.category.color)
                            .frame(width: 6, height: 6)

                        Text(LocalizedStringKey(result.category.rawValue))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.pmTextMuted)
                            .lineLimit(1)
                    }
                }

                if vm.allResults.count > 5 {
                    Text("+\(vm.allResults.count - 5) more")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.pmTextMuted)
                }
            }
        }
        .frame(maxWidth: 480)
    }

    // MARK: - Disk Overview

    private var diskOverview: some View {
        HStack(spacing: 16) {
            DiskStatCard(title: "Total", value: vm.diskInfo.formattedTotal, icon: "internaldrive.fill", color: .pmAccent)
            DiskStatCard(title: "Used", value: vm.diskInfo.formattedUsed, icon: "chart.pie.fill", color: .pmWarning)
            DiskStatCard(title: "Free", value: vm.diskInfo.formattedFree, icon: "checkmark.circle.fill", color: .pmSuccess)
            if vm.diskInfo.purgeableSpace > 0 {
                DiskStatCard(title: "Purgeable", value: vm.diskInfo.formattedPurgeable, icon: "arrow.3.trianglepath", color: .pmInfo)
            }
        }
    }

    // MARK: - Live Results

    private var liveResults: some View {
        VStack(spacing: 2) {
            ForEach(Array(vm.allResults.prefix(6).enumerated()), id: \.element.id) { index, result in
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(result.category.color.opacity(0.1))
                            .frame(width: 22, height: 22)

                        Image(systemName: result.category.icon)
                            .font(.system(size: 10))
                            .foregroundColor(result.category.color)
                    }

                    Text(LocalizedStringKey(result.category.rawValue))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.pmTextSecondary)

                    Spacer()

                    Text(result.formattedSize)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.pmTextPrimary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .opacity(appearingResults.contains(result.id) ? 1 : 0)
                .offset(y: appearingResults.contains(result.id) ? 0 : 6)
                .animation(.easeOut(duration: 0.3).delay(Double(index) * 0.05), value: appearingResults)
            }
        }
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.pmCard.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.pmSeparator.opacity(0.5), lineWidth: 0.5)
                )
        )
        .frame(maxWidth: 380)
        .onChange(of: vm.allResults.count) { _ in
            updateAppearingResults()
        }
        .onAppear {
            updateAppearingResults()
        }
    }

    @State private var appearingResults: Set<UUID> = []

    private func updateAppearingResults() {
        for result in vm.allResults.prefix(6) {
            if !appearingResults.contains(result.id) {
                withAnimation {
                    appearingResults.insert(result.id)
                }
            }
        }
    }

    // MARK: - Results Breakdown

    private var resultsBreakdown: some View {
        VStack(spacing: 6) {
            ForEach(vm.allResults) { result in
                ResultRow(result: result) {
                    withAnimation(.pmSpring) {
                        vm.selectedCategory = result.category
                    }
                }
            }
        }
        .frame(maxWidth: 480)
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        HStack(spacing: 12) {
            switch vm.scanState {
            case .idle:
                ActionButton(title: "Scan", icon: "magnifyingglass", color: .pmAccent) {
                    withAnimation(.pmSpring) { vm.startSmartScan() }
                }

            case .scanning:
                ActionButton(title: "Scanning...", icon: nil, color: .pmCard, isLoading: true, disabled: true) {}

            case .completed:
                if vm.totalSelectedSize > 0 {
                    ActionButton(
                        title: "Clean \(ByteCountFormatter.string(fromByteCount: vm.totalSelectedSize, countStyle: .file))",
                        icon: "trash.fill",
                        color: .pmAccent
                    ) {
                        withAnimation(.pmSpring) { vm.cleanAll() }
                    }

                    SecondaryButton(title: "Re-scan") {
                        withAnimation(.pmSpring) { vm.startSmartScan() }
                    }
                } else {
                    ActionButton(title: "Scan Again", icon: "arrow.clockwise", color: .pmSuccess) {
                        withAnimation(.pmSpring) { vm.startSmartScan() }
                    }
                }

            case .cleaning:
                ActionButton(title: "Cleaning...", icon: nil, color: .pmCard, isLoading: true, disabled: true) {}

            case .cleaned:
                ActionButton(title: "Done", icon: "checkmark", color: .pmSuccess) {
                    withAnimation(.pmSpring) { vm.scanState = .idle }
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
        VStack(spacing: 10) {
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
        .frame(width: 110, height: 90)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.pmCard.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.pmSeparator.opacity(0.4), lineWidth: 0.5)
                )
        )
    }
}

// MARK: - Result Row

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
        HStack(spacing: 10) {
            // Checkbox
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
                        .stroke(isCategorySelected ? result.category.color : Color.pmTextMuted.opacity(0.5), lineWidth: 1.5)
                        .frame(width: 16, height: 16)

                    if isFullySelected {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(result.category.color)
                            .frame(width: 16, height: 16)
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                    } else if isCategorySelected {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(result.category.color)
                            .frame(width: 16, height: 16)
                        Image(systemName: "minus")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Category row (clickable to navigate)
            Button(action: onTap) {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(result.category.color.opacity(isCategorySelected ? 0.12 : 0.06))
                            .frame(width: 28, height: 28)

                        Image(systemName: result.category.icon)
                            .font(.system(size: 12))
                            .foregroundColor(isCategorySelected ? result.category.color : .pmTextMuted)
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        Text(LocalizedStringKey(result.category.rawValue))
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundColor(isCategorySelected ? .pmTextPrimary : .pmTextMuted)

                        Text("\(vm.selectedCountInCategory(result.category))/\(result.itemCount) items")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.pmTextMuted)
                    }

                    Spacer()

                    Text(ByteCountFormatter.string(fromByteCount: selectedSize, countStyle: .file))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundColor(isCategorySelected ? result.category.color : .pmTextMuted)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(isHovering ? result.category.color : .pmTextMuted.opacity(0.5))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isHovering ? Color.pmCardHover : Color.pmCard.opacity(0.4))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(isHovering ? result.category.color.opacity(0.2) : Color.pmSeparator.opacity(0.3), lineWidth: 0.5)
                )
        )
        .onHover { h in
            withAnimation(.pmSmooth) { isHovering = h }
        }
    }
}

// MARK: - Action Button

struct ActionButton: View {
    let title: LocalizedStringKey
    let icon: String?
    let color: Color
    var isLoading: Bool = false
    var disabled: Bool = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.6)
                        .tint(.white)
                }
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
            }
            .foregroundColor(.white)
            .frame(height: 42)
            .padding(.horizontal, 28)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(color)
            )
            .scaleEffect(isHovering && !disabled ? 1.02 : 1.0)
            .shadow(color: color.opacity(isHovering ? 0.25 : 0.12), radius: isHovering ? 10 : 5, y: isHovering ? 4 : 2)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.7 : 1)
        .onHover { h in
            withAnimation(.pmSmooth) { isHovering = h }
        }
    }
}

// MARK: - Secondary Button

struct SecondaryButton: View {
    let title: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundColor(.pmTextSecondary)
                .frame(height: 42)
                .padding(.horizontal, 20)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.pmCard)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.pmSeparator.opacity(0.5), lineWidth: 0.5)
                        )
                )
        }
        .buttonStyle(.plain)
        .onHover { h in
            withAnimation(.pmSmooth) { isHovering = h }
        }
    }
}

// MARK: - Legacy Gradient Button (kept for CategoryDetailView compatibility)

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
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
            }
            .foregroundColor(.white)
            .frame(height: 42)
            .padding(.horizontal, 28)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(gradient)
            )
            .scaleEffect(isHovering ? 1.02 : 1.0)
            .pmShadow(radius: isHovering ? 10 : 5, y: isHovering ? 4 : 2)
        }
        .buttonStyle(.plain)
        .onHover { h in
            withAnimation(.pmSmooth) { isHovering = h }
        }
    }
}
