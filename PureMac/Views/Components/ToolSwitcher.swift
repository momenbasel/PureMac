import AppKit
import SwiftUI

extension AppSection {
    var tool: (name: String, symbol: String, id: String) {
        switch self {
        case .cleaning(.smartScan): return ("Overview", "internaldrive", "cleaning.\(CleaningCategory.smartScan.id)")
        case .protection: return ("Protection", "shield", "protection")
        case .performance: return ("Performance", "gauge.with.dots.needle.67percent", "performance")
        case .appleFeatures: return ("Apple Features", "switch.2", "appleFeatures")
        case .apps: return ("Uninstaller", "square.grid.2x2", "uninstaller")
        case .appUpdates: return ("App Updates", "arrow.triangle.2.circlepath", "appUpdates")
        case .orphans: return ("Leftovers", "doc.questionmark", "leftovers")
        case .spaceExplorer: return ("Space Explorer", "folder", "spaceExplorer")
        case .duplicates: return ("Duplicate Finder", "doc.on.doc", "duplicates")
        case .similarPhotos: return ("Similar Photos", "photo.on.rectangle", "similarPhotos")
        case .settings: return ("Settings", "gearshape", "settings")
        case .cleaning(let category): return (category.rawValue, category.icon, "cleaning.\(category.id)")
        }
    }

    var localizedToolName: String {
        Bundle.main.localizedString(forKey: tool.name, value: tool.name, table: nil)
    }

    func matchesToolName(_ term: String) -> Bool {
        if localizedToolName.localizedStandardContains(term) { return true }
        switch self {
        case .cleaning(.smartScan): return String(localized: "Smart Scan").localizedStandardContains(term)
        case .apps: return String(localized: "Installed Apps").localizedStandardContains(term)
        default: return false
        }
    }
}

struct ToolSwitcher: View {
    let sections: [AppSection]
    let choose: (AppSection) -> Void
    let cancel: () -> Void
    @State private var query = ""
    @State private var highlighted: AppSection?

    init(sections: [AppSection], current: AppSection?, choose: @escaping (AppSection) -> Void, cancel: @escaping () -> Void) {
        self.sections = sections
        self.choose = choose
        self.cancel = cancel
        _highlighted = State(initialValue: current)
    }

    private var matches: [AppSection] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return sections }
        return sections.filter { $0.matchesToolName(term) }
    }

    private var selection: AppSection? {
        if let highlighted, matches.contains(highlighted) { return highlighted }
        return matches.first
    }

    var body: some View {
        let results = matches
        let selected = selection
        VStack(alignment: .leading, spacing: 0) {
            Text("Find a Tool")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 16)
                .padding(.top, 16)
            ToolSearchField(query: $query, move: move, submit: openSelection, cancel: cancel)
                .frame(height: 28)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Divider()
            if results.isEmpty {
                Text("No matching tools")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("toolSwitcher.empty")
            } else {
                ScrollViewReader { proxy in
                    List(selection: Binding(
                        get: { selected },
                        set: { if let section = $0 { highlighted = section } }
                    )) {
                        ForEach(results, id: \.self) { section in
                            resultRow(section, selected: section == selected)
                                .tag(section)
                                .id(section)
                        }
                    }
                    .listStyle(.plain)
                    .onAppear {
                        if let selected { proxy.scrollTo(selected) }
                    }
                    .onChange(of: selected) { row in
                        if let row { proxy.scrollTo(row) }
                    }
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Open", action: openSelection)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected == nil)
            }
            .padding(12)
            .background(.bar)
        }
        .frame(width: 420, height: 364)
        .onChange(of: query) { _ in highlighted = matches.first }
    }

    private func resultRow(_ section: AppSection, selected: Bool) -> some View {
        Button {
            choose(section)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: section.tool.symbol)
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(verbatim: section.localizedToolName)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("toolSwitcher.result.\(section.tool.id)")
    }

    private func move(_ offset: Int) {
        let results = matches
        guard !results.isEmpty else { return }
        let index = selection.flatMap(results.firstIndex(of:)) ?? 0
        let next = results[min(max(0, index + offset), results.count - 1)]
        guard next != selection else { return }
        highlighted = next
        if let window = NSApp.keyWindow {
            NSAccessibility.post(element: window, notification: .announcementRequested,
                                 userInfo: [.announcement: next.localizedToolName, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }
    }

    private func openSelection() {
        if let selection { choose(selection) }
    }
}

private struct ToolSearchField: NSViewRepresentable {
    @Binding var query: String
    let move: (Int) -> Void
    let submit: () -> Void
    let cancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = SearchField()
        field.delegate = context.coordinator
        field.placeholderString = String(localized: "Search tools")
        field.setAccessibilityLabel(String(localized: "Search tools"))
        field.setAccessibilityHelp(String(localized: "Use the arrow keys to choose a tool, then press Return to open it."))
        field.setAccessibilityIdentifier("toolSwitcher.search")
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != query { field.stringValue = query }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: ToolSearchField
        init(_ parent: ToolSearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSSearchField { parent.query = field.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            switch selector {
            case #selector(NSResponder.moveUp(_:)): parent.move(-1)
            case #selector(NSResponder.moveDown(_:)): parent.move(1)
            case #selector(NSResponder.insertNewline(_:)): parent.submit()
            case #selector(NSResponder.cancelOperation(_:)): parent.cancel()
            default: return false
            }
            return true
        }
    }

    private final class SearchField: NSSearchField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.initialFirstResponder = self
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window else { return }
                window.makeFirstResponder(self)
            }
        }
    }
}
