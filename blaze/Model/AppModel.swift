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

    /// What the last Removable Volumes probe found. macOS offers no way to
    /// query the permission, so the only signal is an actual read of a
    /// mounted card — see `probeCardAccess()`.
    enum CardAccess: Equatable {
        case checking
        /// Nothing removable is plugged in, so there is nothing to ask about.
        case noCard
        /// A card is present but macOS can mount nothing on it (blank, or
        /// ext4-only, or freshly flashed). No volume path exists, so macOS
        /// cannot be made to prompt — the permission is unverifiable here.
        case unmountable
        /// A volume is mounted and the read was refused: either the prompt is
        /// still on screen, or the user declined it.
        case denied
        case granted
    }

    /// True once Blaze has actually read a file on a mounted removable volume
    /// — i.e. macOS granted Removable Volumes access. Never needs FDA.
    private(set) var cardAccessConfirmed = false
    private(set) var cardAccess: CardAccess = .checking
    /// True while onboarding's Card-access pane is on screen. It is the one
    /// place where the removable-volume prompt is expected, so enumeration is
    /// allowed there before onboarding completes.
    private var cardAccessPaneActive = false
    private var probingCardAccess = false

    // MARK: - Flash

    var flashState: FlashState = .idle
    var showConfirmSheet = false
    var showImporter = false
    var pendingSimulate = false

    /// Full Disk Access — granted in onboarding AFTER Removable Volumes.
    var hasFullDiskAccess = false

    let helper = HelperManager()

    private let log = Logger(subsystem: "dev.derivation48.blaze", category: "model")
    private let watcher = DiskWatcher()
    private let mountGuard = MountGuard()
    private var hashTask: Task<Void, Never>?
    private var flashTask: Task<Void, Never>?

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

    var isOnboarded: Bool { UserDefaults.standard.bool(forKey: Prefs.onboardedKey) }

    func start() {
        // Not while onboarding: blocking auto-mount stops the card from ever
        // reaching /Volumes, and a mounted volume is the only thing that makes
        // macOS ask for Removable Volumes access. The guard starts in
        // `completeOnboarding()` instead.
        if Prefs.blockRemovableMounts, isOnboarded { mountGuard.start() }
        refreshFullDiskAccess()
        helper.refreshStatus()
        watcher.onChange = { [weak self] in
            Task { @MainActor [weak self] in await self?.rescanDisks() }
        }
        watcher.start()
        Task {
            // Before onboarding, installing the helper is the user's first
            // deliberate act — don't register (and so don't provoke the
            // Login Items approval) behind their back at launch.
            await helper.handshake(autoInstall: isOnboarded)
            if isOnboarded {
                if let url = Prefs.restoreImage() { setImage(url, remember: false) }
                await rescanDisks()
            }
        }
    }

    /// Onboarding is finished (granted or knowingly skipped): resume normal
    /// launch behaviour — mount blocking, remembered image, disk scan.
    func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: Prefs.onboardedKey)
        cardAccessPaneActive = false
        if Prefs.blockRemovableMounts { mountGuard.start() }
        if imageURL == nil, let url = Prefs.restoreImage() { setImage(url, remember: false) }
        Task { await rescanDisks() }
    }

    @discardableResult
    func refreshFullDiskAccess() -> Bool {
        hasFullDiskAccess = FullDiskAccess.isGranted
        return hasFullDiskAccess
    }

    /// Watches for an FDA grant while onboarding's pane is up — toggling it in
    /// System Settings sends no notification. Cancelled with the pane.
    func watchFullDiskAccess() async {
        while !Task.isCancelled, !refreshFullDiskAccess() {
            try? await Task.sleep(for: .seconds(2))
        }
    }

    /// Drives onboarding's Removable Volumes step for as long as its pane is
    /// on screen. Re-probes on a slow tick rather than once per click,
    /// because neither half of the grant is a single moment we can observe:
    /// the card may be inserted after the pane appears, and the read that
    /// raises the prompt can fail while the prompt is still up — the grant
    /// only shows in a *later* read. Cancelled when the pane goes away.
    func watchCardAccess() async {
        cardAccessPaneActive = true
        defer { cardAccessPaneActive = false }
        while !Task.isCancelled {
            await probeCardAccess()
            if cardAccessConfirmed { return }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    /// Enumerates, mounts a card if macOS hasn't, then reads its root. The
    /// read is what makes macOS show the one-time "access files on a
    /// removable volume" prompt (FDA isn't granted yet, so nothing masks it),
    /// and a successful read is the only true confirmation of the grant — a
    /// bare device listing is not. Sets `cardAccessConfirmed` on success.
    @discardableResult
    func probeCardAccess() async -> CardAccess {
        guard !probingCardAccess else { return cardAccess }
        probingCardAccess = true
        defer { probingCardAccess = false }
        // Deliberately not resetting to .checking here: the poll would flip
        // the pane's copy every two seconds. `.checking` is the initial state
        // only, and each probe publishes its own result below.
        await performEnumeration()   // bypass the onboarding gate
        guard !disks.isEmpty else {
            cardAccess = .noCard
            return cardAccess
        }
        // One unmountable card must not mask a mountable one, so probe them
        // all and keep the most informative answer.
        var sawMountedVolume = false
        for disk in disks {
            switch await Self.probeRead(disk, mountGuard: mountGuard) {
            case .granted:
                log.info("removable-volume access confirmed on \(disk.bsdName, privacy: .public)")
                cardAccessConfirmed = true
                cardAccess = .granted
                return cardAccess
            case .denied:
                sawMountedVolume = true
            case .unmountable:
                break
            }
        }
        cardAccess = sawMountedVolume ? .denied : .unmountable
        log.info("removable-volume access not confirmed: \(String(describing: self.cardAccess), privacy: .public)")
        return cardAccess
    }

    private enum ReadOutcome: Sendable { case granted, denied, unmountable }

    private nonisolated static func probeRead(_ disk: Disk, mountGuard: MountGuard) async -> ReadOutcome {
        let bsdName = disk.bsdName
        let known = disk.mountPoints
        return await Task.detached(priority: .userInitiated) {
            mountGuard.whileMountingAllowed {
                var mounts = known
                if mounts.isEmpty {
                    DiskEnumerator.mountDisk(bsdName)
                    mounts = DiskEnumerator.mountPoints(of: bsdName)
                }
                // Nothing macOS can mount — no volume path, so no prompt is
                // possible and the permission can't be settled from here.
                guard !mounts.isEmpty else { return .unmountable }
                // The read prompts on first access; success == access granted.
                for mount in mounts where (try? FileManager.default.contentsOfDirectory(atPath: mount)) != nil {
                    return .granted
                }
                return .denied
            }
        }.value
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
        // Before onboarding, enumerate only while its Card-access pane is up:
        // that pane needs to see cards arrive live, and it is the one place a
        // removable-volume prompt is expected (and must precede FDA).
        guard isOnboarded || cardAccessConfirmed || cardAccessPaneActive else { return }
        await performEnumeration()
    }

    private func performEnumeration() async {
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

        flashTask = Task {
            // Held outside the `do` so the failure path can close and hand
            // back whatever was already opened.
            var openedHandle: FileHandle?
            var handedOver = false
            do {
                // Ask the helper for a sign of life before touching the card.
                // If launchd can't spawn it, every later call would wait on a
                // peer that never arrives.
                guard await helper.isReachable() else {
                    throw NSError(domain: blazeHelperErrorDomain,
                                  code: BlazeHelperError.openFailed.rawValue,
                                  userInfo: [NSLocalizedDescriptionKey:
                                    "The privileged helper isn't running. Quit and reopen Blaze — it repairs the helper on launch. If that doesn't help, reinstall it from Settings."])
                }
                let deviceHandle: FileHandle
                if simulate {
                    deviceHandle = try Self.openDevice("/dev/null")
                } else {
                    // Settle the removable-volume grant first: this read is
                    // what makes macOS ask, and the open below needs it.
                    await requestRemovableVolumeAccess(disk)
                    let path = try await helper.prepareDevice(
                        bsdName: disk.bsdName, imageSize: info.uncompressedSize ?? 0)
                    handedOver = true
                    deviceHandle = try Self.openDevice(path)
                }
                openedHandle = deviceHandle

                try await helper.flash(
                    imageURL: url, info: info, deviceHandle: deviceHandle, bsdName: disk.bsdName,
                    verify: verify, simulate: simulate
                ) { [weak self] phase, done, total in
                    Task { @MainActor [weak self] in
                        self?.applyProgress(phase: phase, done: done, total: total)
                    }
                }
                // Close before releasing: the eject inside release() fails
                // while any descriptor on the raw node is still open.
                try? deviceHandle.close()
                openedHandle = nil
                if handedOver { await helper.releaseDevice() }
                flashState = .success(elapsed: Date().timeIntervalSince(started), simulated: simulate)
            } catch {
                try? openedHandle?.close()
                if handedOver { await helper.releaseDevice() }
                let ns = error as NSError
                log.error("flash failed: \(ns.domain, privacy: .public) [\(ns.code)] \(ns.localizedDescription, privacy: .public)")
                if error is CancellationError
                    || (ns.domain == blazeHelperErrorDomain && ns.code == BlazeHelperError.cancelled.rawValue) {
                    flashState = .idle
                } else {
                    // Report what the helper actually said. The old code
                    // pattern-matched the message and substituted advice that
                    // was often wrong for the failure at hand.
                    flashState = .failure(message: ns.localizedDescription)
                }
            }
        }
    }

    /// Opens the raw node the helper just handed over. This has to happen in
    /// the app: TCC checks removable-media access against the process the user
    /// granted it to, and that is Blaze, not the root daemon. The helper made
    /// the node openable (owner, 0600); a refusal here is TCC's, not POSIX's.
    private static func openDevice(_ path: String) throws -> FileHandle {
        let fd = open(path, O_RDWR)
        if fd >= 0 { return FileHandle(fileDescriptor: fd, closeOnDealloc: true) }
        let failure = errno
        let reason = String(cString: strerror(failure))
        let message = (failure == EPERM || failure == EACCES)
            ? "macOS blocked Blaze from opening the card (\(reason)). Turn Blaze on under System Settings → Privacy & Security → Files and Folders → Removable Volumes, then flash again."
            : "Cannot open \(path): \(reason)."
        throw NSError(domain: blazeHelperErrorDomain,
                      code: BlazeHelperError.openFailed.rawValue,
                      userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Opening a removable card's raw device is gated by the Removable Volumes
    /// TCC permission (checked on this app, the responsible process) — Full
    /// Disk Access does NOT cover it. macOS only shows the one-time prompt
    /// when the app actually touches files on a mounted removable volume, so
    /// mount the target card and read its root here, right before handing off
    /// to the helper. Runs with the mount guard lifted (so our own mount isn't
    /// dissented); the helper unmounts again before writing. Harmless once
    /// granted, or if the card has no mountable filesystem.
    private nonisolated func requestRemovableVolumeAccess(_ disk: Disk) async {
        let bsdName = disk.bsdName
        let known = disk.mountPoints
        let guardian = mountGuard
        await Task.detached(priority: .userInitiated) {
            guardian.whileMountingAllowed {
                var mounts = known
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

    /// Cancel has to reach two different places: a write already under way is
    /// stopped cooperatively by the helper, but before that the app is simply
    /// waiting on XPC — and if the helper never answers, only cancelling this
    /// task ends the wait.
    func cancelFlash() {
        helper.cancelFlash()
        flashTask?.cancel()
    }

    func setMountBlocking(_ enabled: Bool) {
        // Mid-onboarding the guard stays off whatever the preference says — a
        // blocked mount is exactly what stops macOS asking for card access.
        // `completeOnboarding()` applies the stored preference afterwards.
        guard isOnboarded else { return }
        enabled ? mountGuard.start() : mountGuard.stop()
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
