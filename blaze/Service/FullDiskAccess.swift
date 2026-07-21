import Foundation
import AppKit

/// Full Disk Access detection + deep-link. Granted AFTER Removable Volumes in
/// onboarding — the order matters: FDA silently permits removable-volume file
/// reads, which would suppress the one-time Removable Volumes prompt if it
/// were granted first.
enum FullDiskAccess {
    /// Probes by reading the system TCC database. POSIX-world-readable, but
    /// TCC gates the open by responsible process, so a successful read is a
    /// reliable, side-effect-free signal that FDA is granted.
    static var isGranted: Bool {
        let fd = open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        if fd >= 0 { close(fd); return true }
        return false
    }

    static func openSettings() {
        openPrivacyPane("Privacy_AllFiles")
    }

    /// Privacy & Security → Files and Folders, where a declined Removable
    /// Volumes prompt can be reversed. An unknown anchor still lands the user
    /// in Privacy & Security, so a macOS rename degrades rather than breaks.
    static func openRemovableVolumesSettings() {
        openPrivacyPane("Privacy_RemovableVolume")
    }

    private static func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
