import Foundation
import AppKit

/// Full Disk Access is what actually lets the (root) helper open raw
/// external-disk nodes — TCC gates those even for root, and the helper shares
/// the app's TCC identity via AssociatedBundleIdentifiers, so the app's grant
/// covers it. macOS provides no API to *prompt* for FDA; an app can only
/// detect whether it has it and deep-link the user to the right Settings pane.
enum FullDiskAccess {
    /// Probes by reading the system TCC database. The file is POSIX
    /// world-readable, but TCC intercepts the open based on the responsible
    /// process and only lets an FDA-granted app through — so a successful
    /// read is a reliable, side-effect-free signal that FDA is granted.
    static var isGranted: Bool {
        let fd = open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        if fd >= 0 { close(fd); return true }
        return false
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
