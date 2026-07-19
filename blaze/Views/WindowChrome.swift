import SwiftUI

/// The top drag region: traffic lights live inline at its leading edge, so
/// it stays uncluttered — just the app name, centered.
struct WindowChrome: View {
    var body: some View {
        ZStack {
            Text("Blaze")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
    }
}
