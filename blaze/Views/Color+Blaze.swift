import SwiftUI

extension Color {
    /// Blaze brand amber (#FF9F0A). Defined as a literal rather than the
    /// system accent so the app looks the same regardless of the user's
    /// macOS accent-color choice.
    static let blaze = Color(red: 1.0, green: 159.0 / 255.0, blue: 10.0 / 255.0)
}

extension ShapeStyle where Self == Color {
    /// Leading-dot access in `.tint(.blaze)`, `.foregroundStyle(.blaze)`, etc.
    static var blaze: Color { .blaze }
}
