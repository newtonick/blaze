import SwiftUI

/// One-time, two panes: (1) install the helper — the single admin prompt
/// Blaze ever shows, explained before it appears; (2) learn the two
/// shortcuts that matter by using them.
struct OnboardingSheet: View {
    @Environment(AppModel.self) private var model
    @Binding var done: Bool
    @State private var page = 0
    @State private var installError: String?

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if page == 0 { helperPage } else { shortcutsPage }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.smooth(duration: 0.25), value: page)

            HStack(spacing: 5) {
                ForEach(0..<2, id: \.self) { i in
                    Circle()
                        .fill(i == page ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.bottom, 16)
        }
        .frame(width: 420, height: 400)
        .interactiveDismissDisabled()
    }

    private var helperPage: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "lock.shield")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Color.accentColor)
            Text("One-time setup")
                .font(.title2.weight(.semibold))
            Text("Writing an SD card needs administrator access. Blaze installs a small helper once — you'll see a single password prompt, and never again. No prompts per flash, no prompts after reboot.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)

            switch model.helper.status {
            case .enabled:
                Label("Helper installed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button("Continue") { page = 1 }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            case .requiresApproval:
                Text("Approve Blaze in System Settings → Login Items to finish.")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                HStack {
                    Button("Open System Settings") { model.helper.openApprovalSettings() }
                    Button("Check Again") { model.helper.refreshStatus() }
                }
            default:
                Button("Install Helper…") {
                    installError = nil
                    do { try model.helper.install() } catch {
                        installError = error.localizedDescription
                        model.helper.refreshStatus()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                if let installError {
                    Text(installError)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                }
            }
            Spacer()
        }
    }

    private var shortcutsPage: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "keyboard")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Color.accentColor)
            Text("Two keys to remember")
                .font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 10) {
                shortcutRow(keys: "⌘O", text: "choose an image")
                shortcutRow(keys: "⌘↩", text: "flash it")
                shortcutRow(keys: "⌥", text: "hold to simulate — full run, nothing written")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 40)

            Button("Try it — press ⌘O") {
                done = true
                model.showImporter = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut("o", modifiers: .command)

            Button("Skip") { done = true }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer()
        }
    }

    private func shortcutRow(keys: String, text: String) -> some View {
        HStack(spacing: 12) {
            Text(keys)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
                .frame(minWidth: 46)
            Text(text)
                .font(.system(size: 13))
        }
    }
}
