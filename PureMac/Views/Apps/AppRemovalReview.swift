import SwiftUI
import UniformTypeIdentifiers

extension View {
    func appRemovalReviewPresentation() -> some View {
        modifier(AppRemovalReviewPresentation())
    }
}

private struct AppRemovalReviewPresentation: ViewModifier {
    @EnvironmentObject private var state: AppState

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(
            get: { state.appRemovalReview != nil },
            set: { if !$0 { state.closeAppRemovalReview() } }
        )) {
            if let review = state.appRemovalReview {
                AppRemovalSheet(review: review)
            }
        }
    }
}

private struct AppRemovalSheet: View {
    let review: AppRemovalReview
    @EnvironmentObject private var state: AppState
    @Environment(\.interfaceMotionEnabled) private var motionEnabled

    private var groups: [(outcome: AppRemovalOutcome, files: [AppRemovalFile])] {
        let buckets = Dictionary(grouping: review.visibleFiles, by: \.outcome)
        let order: [AppRemovalOutcome] = [.ready, .needsAdmin, .needsAccess, .failed, .restoreUnverified, .blocked, .changed, .missing, .trashed, .restored, .deleted]
        return order.compactMap {
            guard let files = buckets[$0] else { return nil }
            return ($0, files)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            let sections = groups
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(sections, id: \.outcome) { section in
                        if showsHeader(for: section.outcome, sectionCount: sections.count) {
                            sectionHeader(section.outcome, count: section.files.count)
                        }
                        ForEach(section.files) { file in
                            fileRow(file)
                            Divider()
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 3)
                .id(ListRevision(stage: review.stage, generation: review.contentGeneration))
                .transition(motionEnabled ? .opacity.combined(with: .offset(y: 4)) : .identity)
            }
            .animation(motionEnabled ? .easeOut(duration: 0.18) : nil, value: review.stage)
            .frame(height: listHeight(sectionCount: sections.count))
            Divider()
            HStack {
                if state.isRemovingAppFiles { ProgressView().controlSize(.small) }
                Spacer()
                if review.stage == .receipt {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { receiptActions }
                        VStack(alignment: .trailing, spacing: 7) { receiptActions }
                    }
                } else {
                    Button("Cancel", role: .cancel) { state.closeAppRemovalReview() }
                        .accessibilityIdentifier("appRemoval.cancel")
                        .keyboardShortcut(.cancelAction)
                    Button(role: review.stage == .permanent ? .destructive : nil) {
                        Task { await state.performAppRemovalReview() }
                    } label: {
                        Text(review.stage == .permanent ? LocalizedStringKey("Delete Permanently") : LocalizedStringKey("Move to Trash"))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(review.stage == .permanent ? Color.red : Color.accentColor)
                    .accessibilityIdentifier("appRemoval.confirm")
                    .disabled(!review.visibleFiles.contains { $0.outcome == .ready || $0.outcome == .needsAdmin })
                }
            }
            .controlSize(.regular)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .disabled(state.isRemovingAppFiles)
        .interactiveDismissDisabled(state.isRemovingAppFiles)
        .frame(width: 560)
    }

    private struct ListRevision: Hashable {
        let stage: AppRemovalReview.Stage
        let generation: UUID
    }

    private func listHeight(sectionCount: Int) -> CGFloat {
        let recoveredRows = review.stage == .receipt ? review.files.filter { $0.outcome == .trashed && $0.trashDestination != nil }.count : 0
        let count = review.visibleFiles.count
        let headers = groups.filter { showsHeader(for: $0.outcome, sectionCount: sectionCount) }.count
        let contentHeight = headers * 24 + count * 54 + recoveredRows * 50 + 8
        return min(318, CGFloat(contentHeight))
    }

    private func fileRow(_ file: AppRemovalFile) -> some View {
        let type = UTType(filenameExtension: file.url.pathExtension) ?? (file.url.hasDirectoryPath ? .folder : .item)
        return HStack(alignment: .top, spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(for: type))
                .resizable().frame(width: 20, height: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(file.url.lastPathComponent)
                    .font(.body.weight(.medium))
                    .textSelection(.enabled)
                    .accessibilityIdentifier("appRemoval.\(file.outcome == .restored ? "restored" : "name").\(file.url.lastPathComponent)")
                Text(file.url.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("appRemoval.path.\(file.url.lastPathComponent)")
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if review.stage == .receipt {
                    if file.outcome == .trashed { recoveryActions(file) }
                    if let error = file.recoveryError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func recoveryActions(_ file: AppRemovalFile) -> some View {
        if let destination = file.trashDestination {
            Label {
                Text(destination.path)
                    .font(.caption)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "trash")
            }
            .foregroundStyle(.secondary)
            .accessibilityLabel(Text("Trash location"))
            .accessibilityValue(Text(verbatim: destination.path))
        }
        if file.recovery != nil {
            HStack(spacing: 12) {
                Button("Reveal in Finder") { Task { await state.revealTrashedAppFile(reviewID: review.id, url: file.url) } }
                    .accessibilityIdentifier("appRemoval.reveal.\(file.url.lastPathComponent)")
                Button("Put Back") { Task { await state.putBackAppFile(reviewID: review.id, url: file.url) } }
                    .accessibilityIdentifier("appRemoval.putBack.\(file.url.lastPathComponent)")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                if review.stage == .permanent {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .accessibilityHidden(true)
                }
                Text(title).font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("appRemoval.title")
            }
            switch review.source {
            case .app(let name): Text(name).foregroundStyle(.secondary)
            case .leftovers: Text("Leftovers").foregroundStyle(.secondary)
            }
            if review.stage == .permanent {
                Text("These items could not be moved to the Trash. Deleting them with administrator access cannot be undone.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .animation(motionEnabled ? .easeOut(duration: 0.18) : nil, value: review.stage)
    }

    private func showsHeader(for outcome: AppRemovalOutcome, sectionCount: Int) -> Bool {
        if review.stage == .permanent { return false }
        return review.stage == .receipt || sectionCount > 1 || outcome != .ready
    }

    private func sectionHeader(_ outcome: AppRemovalOutcome, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(LocalizedStringKey(outcome.rawValue)).font(.subheadline.weight(.semibold))
            if count > 1 {
                Text(count.formatted()).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private var receiptActions: some View {
        if review.files.contains(where: { $0.outcome == .needsAccess }) {
            Button("Grant Access and Retry") { state.requestReviewedAppFileAccess() }
        }
        if review.files.contains(where: { $0.outcome == .needsAdmin }) {
            Button("Review Protected Items") { state.reviewProtectedAppFiles() }
        }
        Button("Done") { state.closeAppRemovalReview() }
            .keyboardShortcut(.defaultAction)
    }

    private var title: LocalizedStringKey {
        switch review.stage {
        case .trash: return "Review removal"
        case .permanent: return "Review permanent deletion"
        case .receipt: return "Removal results"
        }
    }
}
