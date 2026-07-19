import Foundation
import DiskArbitration

/// While Blaze runs (and the preference is on), dissents every mount of
/// removable physical media system-wide — cards and USB sticks stay
/// unmounted, so macOS never touches them. Internal disks, external
/// non-removable drives, and disk images are unaffected, and everything
/// returns to normal the moment Blaze quits.
///
/// @unchecked Sendable: `suspendCount` is lock-guarded and read from the DA
/// callback queue; `session` is only touched from start/stop on the main
/// actor.
nonisolated final class MountGuard: @unchecked Sendable {
    private var session: DASession?
    private let queue = DispatchQueue(label: "dev.derivation48.blaze.mountguard")
    private let suspendLock = NSLock()
    private var suspendCount = 0

    private let approvalCallback: DADiskMountApprovalCallback = { disk, context in
        guard let context else { return nil }
        let guardian = Unmanaged<MountGuard>.fromOpaque(context).takeUnretainedValue()
        guardian.suspendLock.lock()
        let suspended = guardian.suspendCount > 0
        guardian.suspendLock.unlock()
        if suspended { return nil }
        guard let desc = DADiskCopyDescription(disk) as? [String: Any],
              desc[kDADiskDescriptionMediaRemovableKey as String] as? Bool == true,
              desc[kDADiskDescriptionDeviceInternalKey as String] as? Bool != true,
              (desc[kDADiskDescriptionDeviceProtocolKey as String] as? String) != "Virtual Interface",
              (desc[kDADiskDescriptionDeviceModelKey as String] as? String) != "Disk Image"
        else { return nil }
        return Unmanaged.passRetained(DADissenterCreate(
            kCFAllocatorDefault, DAReturn(kDAReturnExclusiveAccess),
            "Blaze is blocking auto-mount of removable disks" as CFString))
    }

    func start() {
        guard session == nil, let s = DASessionCreate(kCFAllocatorDefault) else { return }
        session = s
        DARegisterDiskMountApprovalCallback(s, nil, approvalCallback,
                                            Unmanaged.passUnretained(self).toOpaque())
        DASessionSetDispatchQueue(s, queue)
    }

    func stop() {
        guard let s = session else { return }
        DAUnregisterCallback(s, unsafeBitCast(approvalCallback, to: UnsafeMutableRawPointer.self),
                             Unmanaged.passUnretained(self).toOpaque())
        DASessionSetDispatchQueue(s, nil)
        session = nil
    }

    /// The TCC permission probe mounts the card deliberately; it runs inside
    /// this scope so the guard doesn't dissent our own mount.
    func whileSuspended<T>(_ body: () -> T) -> T {
        suspendLock.lock(); suspendCount += 1; suspendLock.unlock()
        defer { suspendLock.lock(); suspendCount -= 1; suspendLock.unlock() }
        return body()
    }
}
