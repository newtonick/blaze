import SwiftUI

/// Shown when a real flash is requested without Full Disk Access. macOS has
/// no API to prompt for FDA, so this instructs the user and deep-links to the
/// exact Settings pane; a Recheck button confirms once granted.
struct FullDiskAccessSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield")
                .font(.system(size: 32))
                .foregroundStyle(Color.blaze)

            Text("Full Disk Access needed")
                .font(.title3.weight(.semibold))

            Text("Full Disk Access lets Blaze detect your SD cards. Grant it once; when you flash, macOS will also ask to access the card itself — just click Allow.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                step(1, "Open System Settings below.")
                step(2, "Turn on **Blaze** in the list.")
                step(3, "If macOS offers to quit and reopen Blaze, allow it.")
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(.quinary))

            HStack(spacing: 10) {
                Button("Later") { model.showFDAGate = false }
                    .keyboardShortcut(.cancelAction)
                Button("Open System Settings…") { FullDiskAccess.openSettings() }
                Button("Recheck") {
                    if model.refreshFullDiskAccess() { model.showFDAGate = false }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 400)
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.blaze))
            Text(text)
                .font(.system(size: 12))
        }
    }
}
