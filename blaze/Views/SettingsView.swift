import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Prefs.verifyKey) private var verifyAfterWrite = true
    @AppStorage(Prefs.blockMountsKey) private var blockMounts = true

    var body: some View {
        Form {
            Toggle("Verify after writing", isOn: $verifyAfterWrite)
            Text("Reads the card back after flashing and compares it byte-for-byte with the image.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Toggle("Block auto-mount of removable disks", isOn: $blockMounts)
                .onChange(of: blockMounts) { _, on in model.setMountBlocking(on) }
            Text("While Blaze is open, cards and USB sticks never mount — macOS can't touch them. Internal drives, external SSDs, and disk images mount normally. Quitting Blaze restores normal behavior.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Divider().padding(.vertical, 4)

            LabeledContent("Privileged helper") {
                switch model.helper.status {
                case .enabled:
                    Label("Installed", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .requiresApproval:
                    Button("Approve in System Settings…") { model.helper.openApprovalSettings() }
                default:
                    Button("Install…") {
                        try? model.helper.install()
                    }
                }
            }

            LabeledContent("Full Disk Access") {
                if model.hasFullDiskAccess {
                    Label("Granted", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Button("Grant in System Settings…") { FullDiskAccess.openSettings() }
                }
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            model.helper.refreshStatus()
            model.refreshFullDiskAccess()
        }
    }
}
