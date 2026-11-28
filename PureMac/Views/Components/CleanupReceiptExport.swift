import SwiftUI
import UniformTypeIdentifiers

struct CleanupReceiptExport: View {
    let receipt: CleanupReceipt
    @State private var saving = false
    @State private var document: CleanupReceiptDocument?
    @State private var errorMessage: String?

    var body: some View {
        Button {
            document = CleanupReceiptDocument(receipt: receipt)
            saving = true
        } label: {
            Label("Save receipt…", systemImage: "square.and.arrow.down")
        }
        .accessibilityIdentifier("cleanup.receipt.save")
        .fileExporter(isPresented: $saving, document: document, contentType: .plainText,
                      defaultFilename: "PureMac-" + Date.now.ISO8601Format(.iso8601.year().month().day())) { result in
            document = nil
            if case .failure(let error) = result {
                let failure = error as NSError
                if failure.domain != NSCocoaErrorDomain || failure.code != NSUserCancelledError {
                    errorMessage = failure.localizedDescription
                }
            }
        }
        .alert("Couldn’t save the receipt", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(verbatim: errorMessage ?? "")
        }
    }
}

struct CleanupReceiptDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.plainText]

    private enum Content {
        case receipt(CleanupReceipt)
        case saved(Data)
    }

    private let content: Content

    init(receipt: CleanupReceipt) {
        content = .receipt(receipt)
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        content = .saved(data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        switch content {
        case .saved(let data):
            return FileWrapper(regularFileWithContents: data)
        case .receipt(let receipt):
            return FileWrapper(regularFileWithContents: Data(receipt.reportText.utf8))
        }
    }
}

extension CleanupReceipt {
    private static let reportControls = CharacterSet.controlCharacters.union(.newlines)

    var reportText: String {
        let size = ByteCountFormatter()
        size.countStyle = .file
        var lines = [
            "PureMac · " + String(localized: "Cleanup receipt"),
            String(format: String(localized: "Items reviewed: %lld"), Int64(rows.count)),
            String(localized: "Estimated removed") + "   " + size.string(fromByteCount: removedBytes),
            String(localized: "Moved to Trash") + "   " + size.string(fromByteCount: trashedBytes)
        ]
        for row in rows {
            lines.append("")
            lines.append("[\(row.disposition.title)] " + Self.reportField(row.item.name))
            if !row.item.path.isEmpty { lines.append(Self.reportField(row.item.path)) }
            if row.bytes > 0 { lines.append(size.string(fromByteCount: row.bytes)) }
            if let detail = row.detail { lines.append(Self.reportField(detail)) }
            if row.disposition == .trashed, let path = row.trashPath {
                lines.append(String(localized: "Trash location") + "   " + Self.reportField(path))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func reportField(_ text: String) -> String {
        guard text.rangeOfCharacter(from: reportControls) != nil else { return text }
        var quoted = ""
        for scalar in text.debugDescription.unicodeScalars {
            if reportControls.contains(scalar) {
                quoted += "\\u{\(String(scalar.value, radix: 16))}"
            } else {
                quoted.unicodeScalars.append(scalar)
            }
        }
        return quoted
    }
}
