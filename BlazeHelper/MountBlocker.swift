import Foundation
import DiskArbitration

/// The moment a flash writes a valid filesystem, diskarbitrationd probes and
/// mounts it mid-write — and macOS immediately scribbles fseventsd/Spotlight
/// metadata onto the card, corrupting what was just written. While a flash
/// runs, this dissents every mount attempt for the target disk and its
/// partitions; nothing else system-wide is affected.
final class MountBlocker {
    private var session: DASession?
    private var targetDisk = ""
    private let queue = DispatchQueue(label: "dev.derivation48.blaze.helper.mountblocker")

    private let approvalCallback: DADiskMountApprovalCallback = { disk, context in
        guard let context else { return nil }
        let blocker = Unmanaged<MountBlocker>.fromOpaque(context).takeUnretainedValue()
        guard let cName = DADiskGetBSDName(disk) else { return nil }
        let name = String(cString: cName)
        guard name == blocker.targetDisk || name.hasPrefix(blocker.targetDisk + "s") else {
            return nil  // not ours — allow
        }
        return Unmanaged.passRetained(DADissenterCreate(
            kCFAllocatorDefault, DAReturn(kDAReturnExclusiveAccess),
            "Blaze is writing this disk" as CFString))
    }

    func block(_ bsdName: String) {
        guard session == nil, let s = DASessionCreate(kCFAllocatorDefault) else { return }
        session = s
        targetDisk = bsdName
        DARegisterDiskMountApprovalCallback(s, nil, approvalCallback,
                                            Unmanaged.passUnretained(self).toOpaque())
        DASessionSetDispatchQueue(s, queue)
    }

    func unblock() {
        guard let s = session else { return }
        DAUnregisterCallback(s, unsafeBitCast(approvalCallback, to: UnsafeMutableRawPointer.self),
                             Unmanaged.passUnretained(self).toOpaque())
        DASessionSetDispatchQueue(s, nil)
        session = nil
    }
}
