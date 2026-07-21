import SwiftUI

/// One-time setup, four panes:
///   (1) install the helper — the single admin prompt Blaze shows,
///   (2) grant Removable Volumes access — REQUIRED for the raw write, and
///       requested FIRST so the prompt isn't masked,
///   (3) grant Full Disk Access — only after Removable Volumes is confirmed,
///   (4) learn the two shortcuts.
///
/// Nothing here reaches out on its own: System Settings opens only when the
/// user asks. Panes 2 and 3 poll while visible, so a permission granted in
/// System Settings (or on a prompt) is noticed without a click.
struct OnboardingSheet: View {
    @Environment(AppModel.self) private var model
    @Binding var done: Bool
    @State private var page = 0
    @State private var installError: String?

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch page {
                case 0: helperPage
                case 1: removableVolumesPage
                case 2: fullDiskAccessPage
                default: shortcutsPage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.smooth(duration: 0.25), value: page)

            HStack(spacing: 5) {
                ForEach(0..<4, id: \.self) { i in
                    Circle()
                        .fill(i == page ? Color.blaze : Color.secondary.opacity(0.3))
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.bottom, 16)
        }
        .frame(width: 420, height: 420)
        .interactiveDismissDisabled()
    }

    // MARK: 1 — helper

    private var helperPage: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "lock.shield")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Color.blaze)
            Text("One-time setup")
                .font(.title2.weight(.semibold))
            Text("Writing an SD card needs administrator access. Blaze installs a small helper once — you'll see a single password prompt, and never again.")
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
        // Approving the login item in System Settings doesn't call back, so
        // watch for it rather than making the user click "Check Again".
        .task { await model.helper.watchApproval() }
    }

    // MARK: 2 — Removable Volumes (required, first)

    private var removableVolumesPage: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: cardIcon)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(cardIconColor)
            Text("Card access")
                .font(.title2.weight(.semibold))

            Text(cardMessage)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
                .fixedSize(horizontal: false, vertical: true)

            switch model.cardAccess {
            case .granted:
                Button("Continue") { page = 2 }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)

            case .denied:
                HStack {
                    Button("Open System Settings") { FullDiskAccess.openRemovableVolumesSettings() }
                        .buttonStyle(.borderedProminent)
                    Button("Check Access") { Task { await model.probeCardAccess() } }
                }

            case .unmountable:
                // The only state where the permission cannot be settled here:
                // with nothing mounted, macOS has no reason to ask. Let the
                // user move on rather than trap them — the flash path asks
                // again, on a card it is about to write.
                VStack(spacing: 8) {
                    Button("Check Access") { Task { await model.probeCardAccess() } }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    Button("Continue Anyway") { page = 2 }
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                }

            case .checking, .noCard:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.cardAccess == .noCard ? "Waiting for a card…" : "Checking…")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                Button("Check Access") { Task { await model.probeCardAccess() } }
            }
            Spacer()
        }
        // Runs only while this pane is on screen: watches for the card to
        // arrive and for the grant to land, then stops.
        .task { await model.watchCardAccess() }
    }

    private var cardIcon: String {
        switch model.cardAccess {
        case .granted: "checkmark.circle.fill"
        case .denied, .unmountable: "exclamationmark.triangle"
        case .checking, .noCard: "sdcard"
        }
    }

    private var cardIconColor: Color {
        switch model.cardAccess {
        case .granted: .green
        case .denied, .unmountable: .orange
        case .checking, .noCard: .blaze
        }
    }

    /// LocalizedStringKey, not String: only the key overload of `Text` renders
    /// the **bold** markdown below.
    private var cardMessage: LocalizedStringKey {
        switch model.cardAccess {
        case .granted:
            "Granted. Blaze can read and write your cards."
        case .checking, .noCard:
            "Insert an SD card, then click **Allow** when macOS asks Blaze to access files on a removable volume. This one permission is what lets Blaze write cards."
        case .denied:
            // Reached both while the prompt is still up (the read that raised
            // it fails) and after a decline, so the copy has to fit both.
            "macOS hasn't allowed access to this card yet. If its prompt is on screen, click **Allow**. If you already declined, turn Blaze on under Privacy & Security → Files and Folders → Removable Volumes, then check again."
        case .unmountable:
            "A card is inserted, but macOS can't mount anything on it — a blank or Linux-formatted card — so it won't ask for permission. Insert a card macOS can read to settle this now, or continue and Blaze will ask the first time you flash."
        }
    }

    // MARK: 3 — Full Disk Access (required, after Removable Volumes)

    private var fullDiskAccessPage: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: model.hasFullDiskAccess ? "checkmark.shield.fill" : "externaldrive.badge.exclamationmark")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(model.hasFullDiskAccess ? Color.green : Color.blaze)
            Text("Full Disk Access")
                .font(.title2.weight(.semibold))

            if model.hasFullDiskAccess {
                Text("Granted. Setup is complete.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Button("Continue") { page = 3 }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            } else {
                Text("Turn on **Blaze** under System Settings → Privacy & Security → Full Disk Access, then return here. This lets Blaze detect cards reliably and remember your last image.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
                HStack {
                    Button("Open System Settings") { FullDiskAccess.openSettings() }
                        .buttonStyle(.borderedProminent)
                    Button("Check Access") { model.refreshFullDiskAccess() }
                }
            }
            Spacer()
        }
        // macOS usually wants the app relaunched after the toggle, but when it
        // takes effect live the pane should notice on its own.
        .task { await model.watchFullDiskAccess() }
    }

    // MARK: 4 — shortcuts

    private var shortcutsPage: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "keyboard")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Color.blaze)
            Text("Two keys to remember")
                .font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 10) {
                shortcutRow(keys: "⌘O", text: "choose an image")
                shortcutRow(keys: "⌘↩", text: "flash it")
                shortcutRow(keys: "⌥", text: "hold to simulate — full run, nothing written")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 40)

            Button("Get Started") {
                model.completeOnboarding()
                done = true
            }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
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
