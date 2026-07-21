import Foundation
import DiskArbitration

/// While Blaze runs (and the preference is on), dissents every mount of
/// removable physical media system-wide — cards (USB reader or built-in SD
/// slot) and USB sticks stay unmounted, so macOS never touches them. The
/// boot disk, external non-removable drives, and disk images are unaffected,
/// and everything returns to normal the moment Blaze quits.
///
/// Blaze itself has to mount a card in one situation: macOS only issues the
/// Removable Volumes permission prompt when the app reads a file on a mounted
/// removable volume. `whileMountingAllowed` covers that by tearing the
/// DiskArbitration session down for the duration rather than flagging it as
/// suspended — an unregistered callback cannot dissent, whereas a flag relies
/// on diskarbitrationd consulting us at exactly the right moment.
///
/// @unchecked Sendable: all mutable state is guarded by `lock`, and the DA
/// approval callback reads none of it.
nonisolated final class MountGuard: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "dev.derivation48.blaze.mountguard")
    private var session: DASession?
    /// The caller's intent (preference + lifecycle), independent of whether a
    /// session is registered right now.
    private var wanted = false
    /// Open `whileMountingAllowed` scopes.
    private var allowDepth = 0

    private let approvalCallback: DADiskMountApprovalCallback = { disk, _ in
        // Block any removable medium — USB reader/stick or a card in the
        // built-in SD slot (which is internal-bus but removable). The boot
        // disk and external SSD/HDD enclosures are non-removable so they
        // never match; disk images are excluded explicitly.
        guard let desc = DADiskCopyDescription(disk) as? [String: Any],
              desc[kDADiskDescriptionMediaRemovableKey as String] as? Bool == true,
              (desc[kDADiskDescriptionDeviceProtocolKey as String] as? String) != "Virtual Interface",
              (desc[kDADiskDescriptionDeviceModelKey as String] as? String) != "Disk Image"
        else { return nil }
        return Unmanaged.passRetained(DADissenterCreate(
            kCFAllocatorDefault, DAReturn(kDAReturnExclusiveAccess),
            "Blaze is blocking auto-mount of removable disks" as CFString))
    }

    func start() {
        lock.lock()
        wanted = true
        sync()
        lock.unlock()
    }

    func stop() {
        lock.lock()
        wanted = false
        sync()
        lock.unlock()
    }

    /// Runs `body` with auto-mount blocking fully off, restoring it after.
    /// Safe from any thread and safe to nest. Other removable media can
    /// auto-mount during the (brief) window — that is the price of being
    /// certain our own deliberate mount is never dissented.
    func whileMountingAllowed<T>(_ body: () -> T) -> T {
        lock.lock(); allowDepth += 1; sync(); lock.unlock()
        defer { lock.lock(); allowDepth -= 1; sync(); lock.unlock() }
        return body()
    }

    /// Brings the DA session in line with `wanted`/`allowDepth`; caller holds
    /// `lock`. The approval callback takes no locks, so tearing the session
    /// down here cannot deadlock against a callback already in flight.
    private func sync() {
        let shouldGuard = wanted && allowDepth == 0
        if shouldGuard, session == nil {
            guard let s = DASessionCreate(kCFAllocatorDefault) else { return }
            session = s
            DARegisterDiskMountApprovalCallback(s, nil, approvalCallback,
                                                Unmanaged.passUnretained(self).toOpaque())
            DASessionSetDispatchQueue(s, queue)
        } else if !shouldGuard, let s = session {
            DAUnregisterCallback(s, unsafeBitCast(approvalCallback, to: UnsafeMutableRawPointer.self),
                                 Unmanaged.passUnretained(self).toOpaque())
            DASessionSetDispatchQueue(s, nil)
            session = nil
        }
    }
}
