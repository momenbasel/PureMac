import SwiftUI

struct CleanupReviewSheet: View {
    @EnvironmentObject private var appState: AppState
    let selection: CleanupSelection
    let cancel: () -> Void
    let confirm: () -> Void

    private var groups: [CleanupOperation: [CleanableItem]] {
        Dictionary(grouping: selection.items) { CleanupOperation($0, homeDirectory: appState.cleanupHomeDirectory) }
    }

    var body: some View {
        let operations = groups
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Review removal")
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("Selected: \(selection.items.count) · \(ByteCountFormatter.string(fromByteCount: selection.items.reduce(0) { $0 + $1.size }, countStyle: .file))")
                    .font(.body.monospacedDigit())
                explanation(for: operations)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)

            Divider()
            Group {
                if selection.items.count <= 3 {
                    ViewThatFits(in: .vertical) {
                        VStack(alignment: .leading, spacing: 0) { reviewRows(operations) }
                        scrollingRows(operations)
                    }
                } else {
                    scrollingRows(operations)
                }
            }
            .frame(maxHeight: 300)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("cleanup.review.cancel")
                Button(role: .destructive, action: confirm) {
                    if operations.count == 1, operations[.delete] != nil { Text("Delete Permanently") }
                    else if operations.count == 1, operations[.trash] != nil { Text("Move to Trash") }
                    else { Text("Remove Selected (\(selection.items.count))") }
                }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(selection.items.isEmpty || appState.scanState.isActive)
                    .accessibilityIdentifier("cleanup.review.confirm")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 560)
        .onAppear { appState.showCleanConfirmation = true }
        .onDisappear { appState.showCleanConfirmation = false }
    }

    @ViewBuilder private func explanation(for operations: [CleanupOperation: [CleanableItem]]) -> some View {
        if operations.count == 1, operations[.delete] != nil {
            Text("This will permanently delete the selected files. This cannot be undone.")
        } else if operations.count == 1, operations[.trash] != nil {
            Text("You can recover these items until the Trash is emptied.")
        } else {
            Text("Files and cleanup actions marked Permanent cannot be undone. Items marked Move to Trash can be recovered until the Trash is emptied.")
        }
    }

    private func scrollingRows(_ groups: [CleanupOperation: [CleanableItem]]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) { reviewRows(groups) }
        }
        .frame(minHeight: 120, idealHeight: 270, maxHeight: 300)
    }

    @ViewBuilder private func reviewRows(_ groups: [CleanupOperation: [CleanableItem]]) -> some View {
        ForEach(CleanupOperation.allCases, id: \.self) { operation in
            if let items = groups[operation] {
                Section {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(verbatim: item.name)
                                    .font(.body)
                                Spacer(minLength: 0)
                                Text(item.formattedSize)
                                    .font(.callout.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .fixedSize()
                            }
                            if !item.path.isEmpty { CleanupPath(path: item.path) }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        if item.id != items.last?.id { Divider().padding(.horizontal, 20) }
                    }
                } header: {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(operation.title)
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)
                        Spacer(minLength: 0)
                        Text("Items: \(items.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .overlay(alignment: .bottom) { Divider() }
                }
            }
        }
    }
}

struct CleanupReceiptView: View {
    @EnvironmentObject private var appState: AppState
    @State private var revealError = false
    @State private var needsAttentionOnly = false
    @State private var limit = 20
    let receipt: CleanupReceipt

    private var visibleRows: [CleanupReceipt.Row] {
        guard canFilter && needsAttentionOnly else { return receipt.rows }
        return receipt.rows.filter { [.failed, .protected, .skipped].contains($0.disposition) }
    }

    private var canFilter: Bool {
        receipt.rows.count > 8 && receipt.attentionCount > 0 && receipt.attentionCount < receipt.rows.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Cleanup receipt")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Text("Items reviewed: \(receipt.rows.count)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                CleanupReceiptExport(receipt: receipt)
                    .controlSize(.small)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 24) { metrics }
                VStack(alignment: .leading, spacing: 4) { metrics }
            }
            if canFilter {
                Toggle("Needs attention", isOn: $needsAttentionOnly)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .onChange(of: needsAttentionOnly) { _ in limit = 20 }
            }

            let rows = visibleRows
            LazyVStack(alignment: .leading, spacing: 0) {
                Divider()
                ForEach(rows.prefix(limit)) { row in
                    receiptRow(row)
                    Divider()
                }
                if rows.count > limit {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("\(min(rows.count, limit)) of \(rows.count) items shown")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button("Show more items") { limit += 20 }
                            .controlSize(.small)
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .onChange(of: receipt.rows.first?.id) { _ in
            needsAttentionOnly = false
            limit = 20
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cleanup.receipt")
        .alert("The item in Trash is missing or changed.", isPresented: $revealError) {
            Button("OK", role: .cancel) {}
        }
    }

    @ViewBuilder private var metrics: some View {
        metric("Estimated removed", bytes: receipt.removedBytes, identifier: "cleanup.receipt.removedBytes")
        metric("Moved to Trash", bytes: receipt.trashedBytes, identifier: "cleanup.receipt.trashedBytes")
    }

    private func metric(_ title: LocalizedStringKey, bytes: Int64, identifier: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(title).foregroundStyle(.secondary)
            Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                .monospacedDigit().accessibilityIdentifier(identifier)
        }
        .font(.callout)
    }

    private func receiptRow(_ row: CleanupReceipt.Row) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(verbatim: row.item.name).font(.body.weight(.medium))
                Spacer(minLength: 0)
                Text(row.disposition.title)
                    .font(.callout)
                    .foregroundStyle(row.disposition == .failed ? Color.red : Color.secondary)
                    .multilineTextAlignment(.trailing)
            }
            if !row.item.path.isEmpty { CleanupPath(path: row.item.path) }
            if let detail = row.detail {
                Text(detail)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if row.disposition == .trashed, let path = row.trashPath {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { recoveryActions(row, path: path) }
                    VStack(alignment: .leading, spacing: 5) { recoveryActions(row, path: path) }
                }
                .padding(.top, 3)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cleanup.receipt.\(row.disposition.rawValue).\(row.item.name)")
    }

    @ViewBuilder private func recoveryActions(_ row: CleanupReceipt.Row, path: String) -> some View {
        if row.recovery != nil {
            Button("Put Back") { appState.putBackCleanupItem(row.id, receiptID: receipt.id) }
                .disabled(row.recoveryUnavailable || appState.restoringCleanupItem != nil || appState.scanState.isActive
                    || appState.showCleanConfirmation || appState.deviceBackupRemovalInProgress
                    || appState.isRemovingAppFiles || appState.appRemovalReview != nil)
                .accessibilityIdentifier("cleanup.receipt.putBack.\(row.item.name)")
            if appState.restoringCleanupItem == row.id {
                ProgressView().controlSize(.small)
            }
        }
        Button(row.recovery == nil ? "Open Trash folder" : "Reveal in Trash") {
            if let recovery = row.recovery {
                guard let verified = recovery.verifiedTrashURL else { revealError = true; return }
                NSWorkspace.shared.activateFileViewerSelecting([verified])
            } else {
                let folder = URL(fileURLWithPath: path).deletingLastPathComponent()
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
            }
        }
        .buttonStyle(.link)
    }
}

private struct CleanupPath: View {
    let path: String

    var body: some View {
        Text(verbatim: path)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.layoutDirection, .leftToRight)
    }
}
