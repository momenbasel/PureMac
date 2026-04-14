import SwiftUI

struct ContentView: View {
    @EnvironmentObject var vm: AppViewModel

    var body: some View {
        HStack(spacing: 0) {
            SidebarView()
                .frame(width: 220)

            Divider()
                .background(Color.pmSeparator)

            // Main content
            ZStack {
                Color.pmBackground
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    // Full Disk Access banner
                    if !vm.hasFullDiskAccess && !vm.fdaBannerDismissed {
                        FullDiskAccessBanner()
                            .padding(.horizontal, 24)
                            .padding(.top, 12)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    // Top bar with disk info
                    TopBarView()
                        .padding(.horizontal, 24)
                        .padding(.top, 16)
                        .padding(.bottom, 8)

                    // Content area
                    Group {
                        switch vm.selectedCategory {
                        case .smartScan:
                            SmartScanView()
                        default:
                            CategoryDetailView(category: vm.selectedCategory)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(Color.pmBackground)
        .onAppear {
            NSWindow.allowsAutomaticWindowTabbing = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            vm.checkFullDiskAccess()
        }
        .alert("Confirm Cleaning", isPresented: $vm.showCleanConfirmation) {
            Button("Cancel", role: .cancel) {
                vm.cancelClean()
            }
            Button("Delete Permanently", role: .destructive) {
                vm.confirmClean()
            }
        } message: {
            Text(vm.cleanConfirmationMessage)
        }
    }
}

// MARK: - Full Disk Access Banner

struct FullDiskAccessBanner: View {
    @EnvironmentObject var vm: AppViewModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 18))
                .foregroundColor(.pmWarning)

            VStack(alignment: .leading, spacing: 2) {
                Text("Full Disk Access Required")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.pmTextPrimary)

                Text("PureMac needs Full Disk Access to scan Trash, Mail, Desktop, Documents, and Homebrew cache.")
                    .font(.system(size: 11))
                    .foregroundColor(.pmTextSecondary)
                    .lineLimit(2)
            }

            Spacer()

            Button(action: { vm.openFullDiskAccessSettings() }) {
                Text("Open Settings")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(AppGradients.accent)
                    .cornerRadius(8)
            }
            .buttonStyle(.plain)

            Button(action: {
                withAnimation(.pmSmooth) {
                    vm.fdaBannerDismissed = true
                }
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.pmTextMuted)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.pmWarning.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.pmWarning.opacity(0.2), lineWidth: 1)
                )
        )
    }
}

// MARK: - Top Bar

struct TopBarView: View {
    @EnvironmentObject var vm: AppViewModel

    var body: some View {
        HStack(spacing: 16) {
            // Disk usage indicator
            HStack(spacing: 12) {
                Image(systemName: "internaldrive.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.pmAccentLight)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Macintosh HD")
                        .font(.pmCaption)
                        .foregroundColor(.pmTextPrimary)

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.pmCard)
                                .frame(height: 6)

                            RoundedRectangle(cornerRadius: 3)
                                .fill(
                                    vm.diskInfo.usedPercentage > 0.9 ? AppGradients.danger :
                                    vm.diskInfo.usedPercentage > 0.7 ? AppGradients.accent :
                                    AppGradients.success
                                )
                                .frame(width: geo.size.width * vm.diskInfo.usedPercentage, height: 6)
                        }
                    }
                    .frame(height: 6)
                }
                .frame(width: 160)

                Text("\(vm.diskInfo.formattedFree) free")
                    .font(.pmCaption)
                    .foregroundColor(.pmTextSecondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.pmCard.opacity(0.6))
            .cornerRadius(10)

            Spacer()

            // Schedule indicator
            if vm.scheduler.config.isEnabled {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.pmSuccess)
                        .frame(width: 6, height: 6)
                    Text("Auto-clean: ") + Text(LocalizedStringKey(vm.scheduler.config.interval.rawValue))
                        .font(.pmCaption)
                        .foregroundColor(.pmTextSecondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.pmCard.opacity(0.6))
                .cornerRadius(8)
            }

            // Settings button
            if #available(macOS 14.0, *) {
                SettingsLink {
                    iconGearView
                }
                .buttonStyle(.plain)
            } else {
                Button(action: {
                    NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                }) {
                    iconGearView
                }
                .buttonStyle(.plain)
            }
        }
    }
    
    var iconGearView: some View {
        Image(systemName: "gearshape.fill")
            .font(.system(size: 14))
            .foregroundColor(.pmTextSecondary)
            .frame(width: 32, height: 32)
            .background(Color.pmCard.opacity(0.6))
            .cornerRadius(8)
    }
}
