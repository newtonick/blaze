import Foundation
import ServiceManagement
import os.log

/// Receives helper progress callbacks on an XPC queue and forwards them to
/// the main actor. Deliberately outside default MainActor isolation.
nonisolated final class ProgressReceiver: NSObject, BlazeHelperClientProtocol {
    let handler: @Sendable (FlashPhase, Int64, Int64) -> Void

    init(handler: @escaping @Sendable (FlashPhase, Int64, Int64) -> Void) {
        self.handler = handler
    }

    func flashProgress(phase: Int, bytesDone: Int64, bytesTotal: Int64) {
        handler(FlashPhase(rawValue: phase) ?? .writing, bytesDone, bytesTotal)
    }
}

/// Owns the SMAppService registration and the XPC connection to the root
/// helper. Registration triggers the one admin prompt Blaze ever shows;
/// approval persists across reboots and app updates.
@MainActor
@Observable
final class HelperManager {
    enum Status: Equatable {
        case unknown
        case notRegistered
        case requiresApproval   // user must flip the toggle in System Settings
        case enabled
        case notFound
    }

    var status: Status = .unknown

    private let log = Logger(subsystem: "dev.derivation48.blaze", category: "helper")
    private let service = SMAppService.daemon(plistName: "dev.derivation48.blaze.helper.plist")
    private var connection: NSXPCConnection?
    private var progressReceiver: ProgressReceiver?

    // MARK: - Registration

    func refreshStatus() {
        switch service.status {
        case .enabled: status = .enabled
        case .requiresApproval: status = .requiresApproval
        case .notRegistered: status = .notRegistered
        case .notFound: status = .notFound
        @unknown default: status = .unknown
        }
    }

    /// The single authorization Blaze asks for. Throws with a readable
    /// message if the user declines. Never opens System Settings on its own —
    /// the UI offers a button for that, so nothing appears unbidden.
    func install() throws {
        do {
            try service.register()
        } catch {
            refreshStatus()
            throw error
        }
        registeredBuild = Self.appBuild
        refreshStatus()
    }

    /// Rewrites launchd's registration record. Necessary whenever the app
    /// bundle changes: the record is tied to the bundle it was registered
    /// from, so an in-place update leaves it pointing at the old one and every
    /// spawn fails with EX_CONFIG (78) — the daemon never starts and XPC calls
    /// simply never get a reply. Background Items approval survives this, so
    /// there is no new prompt.
    private func reregister() async {
        log.info("re-registering the helper (build \(Self.appBuild, privacy: .public))")
        invalidate()
        do {
            try await service.unregister()
        } catch {
            // Worth knowing: a failed unregister is why a re-registration can
            // update the existing record in place instead of replacing it,
            // leaving launchd's stale launch constraint behind.
            log.error("unregister failed: \(error.localizedDescription, privacy: .public)")
        }
        // Registering again before the unregistration lands updates the old
        // record rather than creating one, so wait for the status to settle.
        for _ in 0..<15 where service.status != .notRegistered {
            try? await Task.sleep(for: .milliseconds(200))
        }
        if service.status != .notRegistered {
            log.error("helper still registered after unregister; registering over it")
        }
        do {
            try service.register()
            registeredBuild = Self.appBuild
            log.info("registered helper for build \(Self.appBuild, privacy: .public)")
        } catch {
            log.error("re-registration failed: \(error.localizedDescription, privacy: .public)")
        }
        refreshStatus()
    }

    /// User-driven repair for a helper that is registered but won't run —
    /// the state a stale launchd record leaves behind.
    func reinstall() async {
        await reregister()
    }

    /// The app build the current registration was made from.
    private var registeredBuild: String? {
        get { UserDefaults.standard.string(forKey: Self.registeredBuildKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.registeredBuildKey) }
    }

    private static let registeredBuildKey = "helperRegisteredForAppBuild"
    private static let appBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"

    func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Watches for the Login Items approval while onboarding's helper pane is
    /// up — flipping that toggle sends no notification. Cancelled with the
    /// pane.
    func watchApproval() async {
        while !Task.isCancelled, status != .enabled {
            try? await Task.sleep(for: .seconds(2))
            refreshStatus()
        }
    }

    /// Converges the installed helper on this app build. `autoInstall` is off
    /// until onboarding has run, so a first launch registers nothing until the
    /// user asks for it.
    func handshake(autoInstall: Bool) async {
        refreshStatus()
        if status != .enabled {
            // Helper missing or awaiting approval (e.g. after an update's
            // re-registration was interrupted): converge to installed.
            if autoInstall { try? install() }
            return
        }
        // An app update invalidates the registration whether or not the helper
        // still answers, so refresh it before asking anything of the daemon.
        if registeredBuild != Self.appBuild {
            log.info("app build changed (\(self.registeredBuild ?? "none", privacy: .public) → \(Self.appBuild, privacy: .public))")
            await reregister()
        }
        let installed = await installedVersion()
        if installed == nil {
            // Unreachable: either launchd is refusing to spawn it (a stale
            // record we haven't repaired) or it is wedged. Either way the only
            // repair the app can make is a fresh registration — and doing it
            // here is what keeps a flash from waiting on a daemon that will
            // never arrive.
            log.error("helper did not answer; re-registering")
            await reregister()
        } else if installed != blazeHelperVersion {
            log.info("helper version \(installed ?? "?", privacy: .public) != \(blazeHelperVersion, privacy: .public); re-registering")
            await reregister()
        }
    }

    // MARK: - XPC

    private func makeConnection() -> NSXPCConnection {
        if let connection { return connection }
        let c = NSXPCConnection(machServiceName: blazeHelperMachServiceName, options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: BlazeHelperProtocol.self)
        c.exportedInterface = NSXPCInterface(with: BlazeHelperClientProtocol.self)
        // Trust is mutual: the helper validates us; we require the helper's
        // exact identity before sending it anything.
        c.setCodeSigningRequirement(
            #"anchor apple generic and identifier "dev.derivation48.blaze.helper" and certificate leaf[subject.OU] = "CNXH3K5L72""#)
        c.invalidationHandler = { [weak self] in
            Task { @MainActor [weak self] in self?.connection = nil }
        }
        connection = c
        c.resume()
        return c
    }

    private func invalidate() {
        connection?.invalidate()
        connection = nil
    }

    /// Sends one request and waits for its reply, with two escapes the bare
    /// continuation doesn't have. When launchd cannot spawn the daemon, the
    /// message waits for a peer that never arrives and XPC reports neither a
    /// reply nor an error — so a deadline is the only thing that ends the
    /// wait. Task cancellation ends it too, which is what makes Cancel work
    /// while the helper is unreachable.
    ///
    /// Deliberately not used for `flash`: abandoning a write that is actually
    /// under way would let the card be ejected from under the helper. That one
    /// waits for the helper's own cooperative cancel.
    private func send<T: Sendable>(
        timeout: Double,
        _ body: (BlazeHelperProtocol, @escaping @Sendable (Result<T, Error>) -> Void) -> Void
    ) async throws -> T {
        let c = makeConnection()
        let mailbox = ReplyMailbox<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
                mailbox.attach(cont)
                Task { [mailbox] in
                    do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                    mailbox.settle(.failure(Self.unresponsiveError))
                }
                let proxy = c.remoteObjectProxyWithErrorHandler { error in
                    mailbox.settle(.failure(error))
                } as? BlazeHelperProtocol
                guard let proxy else {
                    mailbox.settle(.failure(Self.unresponsiveError))
                    return
                }
                body(proxy) { mailbox.settle($0) }
            }
        } onCancel: {
            mailbox.settle(.failure(CancellationError()))
        }
    }

    private static var unresponsiveError: NSError {
        NSError(domain: blazeHelperErrorDomain,
                code: BlazeHelperError.openFailed.rawValue,
                userInfo: [NSLocalizedDescriptionKey:
                    "The privileged helper isn't responding. Quit and reopen Blaze — it reinstalls the helper on launch. If that doesn't help, reinstall it from Settings."])
    }

    func installedVersion() async -> String? {
        try? await send(timeout: 6) { proxy, reply in
            proxy.version { reply(.success($0)) }
        }
    }

    /// True when the helper answers at all. Checked before a flash so an
    /// unreachable daemon fails fast, with an explanation, instead of after
    /// the card has been unmounted and handed over.
    func isReachable() async -> Bool {
        await installedVersion() != nil
    }

    /// Asks the helper to validate, unmount and hand over the card. Returns
    /// the raw device path for the app to open — see `prepareDevice` in the
    /// protocol for why the app has to be the one to open it.
    func prepareDevice(bsdName: String, imageSize: Int64) async throws -> String {
        // Force-unmounting a busy card can take a few seconds; anything past
        // this is the helper not being there at all.
        try await send(timeout: 45) { proxy, reply in
            proxy.prepareDevice(bsdName: bsdName, imageSize: imageSize) { path, error in
                if let path {
                    reply(.success(path))
                } else {
                    reply(.failure(error ?? NSError(
                        domain: blazeHelperErrorDomain,
                        code: BlazeHelperError.openFailed.rawValue,
                        userInfo: [NSLocalizedDescriptionKey: "The helper did not hand over the card."])))
                }
            }
        }
    }

    /// Best-effort undo of `prepareDevice`; a failure here isn't worth
    /// reporting over the error that caused it — but it must not hang either,
    /// since it runs on the way out of a failed flash.
    func releaseDevice() async {
        _ = try? await send(timeout: 15) { (proxy, reply: @escaping @Sendable (Result<Bool, Error>) -> Void) in
            proxy.releaseDevice { reply(.success(true)) }
        }
    }

    /// Streams the image and the card to the helper as open file descriptors
    /// — the helper never opens a TCC-gated path itself (root does not bypass
    /// TCC).
    func flash(imageURL: URL, info: ImageInfo, deviceHandle: FileHandle, bsdName: String,
               verify: Bool, simulate: Bool,
               progress: @escaping @Sendable (FlashPhase, Int64, Int64) -> Void) async throws {
        let handle = try FileHandle(forReadingFrom: imageURL)
        defer { try? handle.close() }

        let receiver = ProgressReceiver(handler: progress)
        progressReceiver = receiver
        let c = makeConnection()
        c.exportedObject = receiver

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let box = ReplyOnce<NSError?>(nil) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
            let proxy = c.remoteObjectProxyWithErrorHandler { error in
                box.resume(error as NSError)
            } as? BlazeHelperProtocol
            guard let proxy else {
                box.resume(NSError(domain: blazeHelperErrorDomain,
                                   code: BlazeHelperError.openFailed.rawValue,
                                   userInfo: [NSLocalizedDescriptionKey: "Cannot reach the helper."]))
                return
            }
            proxy.flash(imageHandle: handle, deviceHandle: deviceHandle,
                        imageSize: info.uncompressedSize ?? 0,
                        format: info.format.rawValue,
                        payloadOffset: info.payloadOffset, payloadSize: info.payloadSize,
                        bsdName: bsdName,
                        verify: verify, simulate: simulate) { box.resume($0) }
        }
    }

    func cancelFlash() {
        (connection?.remoteObjectProxy as? BlazeHelperProtocol)?.cancelFlash()
    }
}

/// One-shot mailbox for a helper reply: whichever of reply, connection error,
/// deadline, or cancellation happens first wins and the rest are ignored.
/// Settling before `attach` is expected — cancellation can land before the
/// continuation exists — so the result is held until there's somewhere to put
/// it. Nonisolated because XPC reply blocks, the timer, and the cancellation
/// handler all arrive on different threads.
private nonisolated final class ReplyMailbox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var settled: Result<T, Error>?
    private var resumed = false

    func attach(_ cont: CheckedContinuation<T, Error>) {
        lock.lock()
        if let settled, !resumed {
            resumed = true
            lock.unlock()
            cont.resume(with: settled)
            return
        }
        continuation = cont
        lock.unlock()
    }

    func settle(_ result: Result<T, Error>) {
        lock.lock()
        guard !resumed else { lock.unlock(); return }
        if settled == nil { settled = result }
        guard let cont = continuation else { lock.unlock(); return }
        resumed = true
        continuation = nil
        let outcome = settled!
        lock.unlock()
        cont.resume(with: outcome)
    }
}

/// XPC can report both a reply and (later) a connection error; a checked
/// continuation must resume exactly once.
private nonisolated final class ReplyOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let onResume: (T) -> Void

    init(_ cont: CheckedContinuation<T, Never>) {
        onResume = { cont.resume(returning: $0) }
    }

    init(_ marker: T?, handler: @escaping (T) -> Void) {
        onResume = handler
    }

    func resume(_ value: T) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { onResume(value) }
    }
}
