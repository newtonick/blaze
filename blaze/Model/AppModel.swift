import Foundation
import CryptoKit
import os.log

@MainActor
@Observable
final class AppModel {
    // MARK: - Image

    private(set) var imageURL: URL?
    private(set) var imageSize: Int64 = 0
    private(set) var imageModified: Date?
    private(set) var imageInfo: ImageInfo?
    /// Full SHA-256 hex digest; nil while computing (or no image).
    private(set) var imageSHA256: String?

    var imageCompactSHA256: String? {
        guard let h = imageSHA256 else { return nil }
        return h.prefix(7) + "…" + h.suffix(7)
    }

    // MARK: - Disks

    private(set) var disks: [Disk] = []
    var selectedDiskID: String?
    var selectedDisk: Disk? { disks.first { $0.bsdName == selectedDiskID } }

    // MARK: - Flash

    var flashState: FlashState = .idle
    var showConfirmSheet = false
    var showImporter = false
    var pendingSimulate = false

    let helper = HelperManager()

    private let log = Logger(subsystem: "dev.derivation48.blaze", category: "model")
    private let watcher = DiskWatcher()
    private let mountGuard = MountGuard()
    private var hashTask: Task<Void, Never>?

    var canFlash: Bool {
        imageURL != nil && selectedDisk != nil && !flashState.isFlashing && fitProblem == nil
    }

    /// Non-nil when the chosen image is known not to fit the chosen card.
    /// (Unknown sizes — oversized gzip — pass here; the helper enforces at
    /// write time instead.)
    var fitProblem: String? {
        guard let disk = selectedDisk, let info = imageInfo,
              let uncompressed = info.uncompressedSize, uncompressed > disk.size else { return nil }
        let need = ByteCountFormatter.string(fromByteCount: uncompressed, countStyle: .file)
        let have = ByteCountFormatter.string(fromByteCount: disk.size, countStyle: .file)
        return "Image (\(need)) is larger than \(disk.displayName) (\(have))"
    }

    // MARK: - Lifecycle

    func start() {
        if Prefs.blockRemovableMounts { mountGuard.start() }
        helper.refreshStatus()
        if let url = Prefs.restoreImage() { setImage(url, remember: false) }
        watcher.onChange = { [weak self] in
            Task { @MainActor [weak self] in await self?.rescanDisks() }
        }
        watcher.start()
        Task {
            await rescanDisks()
            await helper.handshake()
        }
    }

    // MARK: - Image selection

    func setImage(_ url: URL, remember: Bool = true) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else {
            flashState = .failure(message: "Cannot read \(url.lastPathComponent).")
            return
        }
        guard let info = ImageInspector.inspect(url) else {
            flashState = .failure(message: "\(url.lastPathComponent) is not a valid disk image or compressed image.")
            return
        }
        imageURL = url
        imageSize = size
        imageInfo = info
        imageModified = attrs[.modificationDate] as? Date
        if remember { Prefs.rememberImage(url) }
        if case .success = flashState { flashState = .idle }
        if case .failure = flashState { flashState = .idle }
        computeHash(of: url, size: size)
    }

    private func computeHash(of url: URL, size: Int64) {
        imageSHA256 = nil
        hashTask?.cancel()
        hashTask = Task.detached(priority: .utility) { [weak self] in
            guard let handle = try? FileHandle(forReadingFrom: url) else { return }
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try? handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
                if Task.isCancelled { return }
                hasher.update(data: chunk)
            }
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            await MainActor.run { [weak self] in
                guard let self, self.imageURL == url else { return }
                self.imageSHA256 = digest
            }
        }
    }

    // MARK: - Disks

    func rescanDisks() async {
        let found = await Task.detached(priority: .userInitiated) { DiskEnumerator.enumerate() }.value
        disks = found

        if let selected = selectedDiskID, found.contains(where: { $0.bsdName == selected }) {
            return  // keep the user's choice
        }
        // Selection fell away (or first scan): preselect the best candidate,
        // preferring the remembered card. Never auto-select an implausible
        // disk (score <= 0) — an empty selection beats pointing at an NVMe.
        selectedDiskID = nil
        let remembered = Prefs.restoreCardIdentity()
        if let match = found.first(where: { $0.identity == remembered }), match.score > 0 {
            selectedDiskID = match.bsdName
        } else if let best = found.first, best.score > 0 {
            selectedDiskID = best.bsdName
        }
        log.info("selection now \(self.selectedDiskID ?? "none", privacy: .public)")
    }

    // MARK: - Flash pipeline

    func requestFlash(simulate: Bool) {
        guard canFlash else { return }
        pendingSimulate = simulate
        showConfirmSheet = true
    }

    func confirmFlash(verify: Bool) {
        guard let url = imageURL, let disk = selectedDisk, let info = imageInfo else { return }
        showConfirmSheet = false
        Prefs.rememberCard(disk.identity)
        let simulate = pendingSimulate
        var progress = FlashProgress()
        progress.bytesTotal = info.uncompressedSize ?? 0
        flashState = .flashing(progress, simulated: simulate)
        let started = Date()

        Task {
            do {
                await requestRemovableVolumeAccess(disk)
                try await helper.flash(
                    imageURL: url, info: info, bsdName: disk.bsdName,
                    verify: verify, simulate: simulate
                ) { [weak self] phase, done, total in
                    Task { @MainActor [weak self] in
                        self?.applyProgress(phase: phase, done: done, total: total)
                    }
                }
                flashState = .success(elapsed: Date().timeIntervalSince(started), simulated: simulate)
            } catch {
                let ns = error as NSError
                if ns.domain == blazeHelperErrorDomain, ns.code == BlazeHelperError.cancelled.rawValue {
                    flashState = .idle
                } else if ns.localizedDescription.contains("authopen") {
                    flashState = .failure(message:
                        "macOS blocked access to the card. Grant it once in System Settings → Privacy & Security → Files & Folders → Blaze → Removable Volumes, then flash again.")
                } else {
                    flashState = .failure(message: ns.localizedDescription)
                }
            }
        }
    }

    func cancelFlash() {
        helper.cancelFlash()
    }

    /// Raw-device access is TCC-gated by the Removable Volumes permission,
    /// and the grant is recorded against this app's identity — which the
    /// helper shares via AssociatedBundleIdentifiers. Only a foreground app
    /// can make TCC show the one-time prompt, so touch the card's mounted
    /// volume here before handing off to the helper. Blocks until the user
    /// answers; harmless once granted (or if nothing is mounted).
    func setMountBlocking(_ enabled: Bool) {
        enabled ? mountGuard.start() : mountGuard.stop()
    }

    private nonisolated func requestRemovableVolumeAccess(_ disk: Disk) async {
        let bsdName = disk.bsdName
        var mounts = disk.mountPoints
        let guardian = mountGuard
        await Task.detached(priority: .userInitiated) {
            // The card is usually unmounted (the guard keeps it that way),
            // and TCC can only be asked through a real file access — so this
            // deliberate mount runs with the guard suspended (the helper
            // unmounts again before writing anyway).
            guardian.whileSuspended {
                if mounts.isEmpty {
                    DiskEnumerator.mountDisk(bsdName)
                    mounts = DiskEnumerator.mountPoints(of: bsdName)
                }
                for mount in mounts {
                    _ = try? FileManager.default.contentsOfDirectory(atPath: mount)
                }
            }
        }.value
    }

    func dismissResult() {
        flashState = .idle
    }

    private func applyProgress(phase: FlashPhase, done: Int64, total: Int64) {
        guard case .flashing(var p, let simulated) = flashState else { return }
        if phase != p.phase {
            p.phase = phase
            p.phaseStartedAt = Date()
            p.bytesPerSecond = 0
        }
        p.bytesDone = done
        p.bytesTotal = max(total, 1)
        let elapsed = Date().timeIntervalSince(p.phaseStartedAt)
        if elapsed > 0.5, done > 0 {
            p.bytesPerSecond = Double(done) / elapsed
        }
        flashState = .flashing(p, simulated: simulated)
    }
}
