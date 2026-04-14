import SwiftUI

// PureMac uses system colors exclusively.
// The app respects the user's system appearance (light/dark/accent color).

extension View {
    func cardBackground() -> some View {
        self
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}
