import Foundation
import DiskArbitration

/// Fires `onChange` (on a private queue) when disks appear or disappear,
/// debounced ~400 ms so a card insertion's burst of partition events causes
/// one re-enumeration. No polling.
nonisolated final class DiskWatcher {
    var onChange: @Sendable () -> Void = {}

    private var session: DASession?
    private let queue = DispatchQueue(label: "com.klockenga.blaze.diskwatcher")
    private var pending: DispatchWorkItem?

    func start() {
        guard session == nil, let s = DASessionCreate(kCFAllocatorDefault) else { return }
        session = s
        let context = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskAppearedCallback(s, nil, { _, context in
            guard let context else { return }
            Unmanaged<DiskWatcher>.fromOpaque(context).takeUnretainedValue().bump()
        }, context)
        DARegisterDiskDisappearedCallback(s, nil, { _, context in
            guard let context else { return }
            Unmanaged<DiskWatcher>.fromOpaque(context).takeUnretainedValue().bump()
        }, context)
        DASessionSetDispatchQueue(s, queue)
    }

    private func bump() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = item
        queue.asyncAfter(deadline: .now() + 0.4, execute: item)
    }
}
