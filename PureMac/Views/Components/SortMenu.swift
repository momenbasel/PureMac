import SwiftUI

/// The sort control shared by every file list.
///
/// It replaces the old icon-only toolbar toggle, which offered size order
/// only and read as no control at all because the macOS toolbar collapses
/// the button title.
struct SortMenu: View {
    @Binding var field: FileSortField
    @Binding var ascending: Bool

    /// Lists that render bare URLs have no modification date, so they pass
    /// `FileSortField.fieldsWithoutDate` rather than showing a field that
    /// cannot order anything.
    var fields: [FileSortField] = FileSortField.allCases

    var body: some View {
        Menu {
            Picker(selection: $field) {
                ForEach(fields) { option in
                    Label(LocalizedStringKey(option.label), systemImage: option.systemImage)
                        .tag(option)
                }
            } label: {
                Text("Sort By")
            }
            .pickerStyle(.inline)

            Divider()

            Picker(selection: $ascending) {
                Text(LocalizedStringKey(field.directionLabel(ascending: true))).tag(true)
                Text(LocalizedStringKey(field.directionLabel(ascending: false))).tag(false)
            } label: {
                Text("Order")
            }
            .pickerStyle(.inline)
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .help(helpText)
    }

    private var helpText: String {
        String(
            format: String(localized: "Sorted by %@"),
            String(localized: String.LocalizationValue(field.label))
        )
    }
}
