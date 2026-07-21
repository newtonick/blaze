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
        refreshStatus()
    }

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

    /// On connect, compare versions; if the installed helper is stale
    /// (e.g. the app was updated in place), re-register so launchd picks up
    /// the new binary. `autoInstall` is off until onboarding has run, so a
    /// first launch registers nothing until the user asks for it.
    func handshake(autoInstall: Bool) async {
        refreshStatus()
        if status != .enabled {
            // Helper missing or awaiting approval (e.g. after an update's
            // re-registration was interrupted): converge to installed.
            if autoInstall { try? install() }
            return
        }
        let installed = await installedVersion()
        if let installed, installed != blazeHelperVersion {
            log.info("helper version \(installed, privacy: .public) != \(blazeHelperVersion, privacy: .public); re-registering")
            invalidate()
            try? await service.unregister()
            try? service.register()
            refreshStatus()
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

    func installedVersion() async -> String? {
        let c = makeConnection()
        return await withCheckedContinuation { cont in
            let box = ReplyOnce<String?>(cont)
            let proxy = c.remoteObjectProxyWithErrorHandler { error in
                box.resume(nil)
            } as? BlazeHelperProtocol
            guard let proxy else { box.resume(nil); return }
            proxy.version { box.resume($0) }
        }
    }

    /// Asks the helper to validate, unmount and hand over the card. Returns
    /// the raw device path for the app to open — see `prepareDevice` in the
    /// protocol for why the app has to be the one to open it.
    func prepareDevice(bsdName: String, imageSize: Int64) async throws -> String {
        let c = makeConnection()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let box = ReplyOnce<Result<String, Error>>(nil) { cont.resume(with: $0) }
            let proxy = c.remoteObjectProxyWithErrorHandler { error in
                box.resume(.failure(error))
            } as? BlazeHelperProtocol
            guard let proxy else {
                box.resume(.failure(NSError(domain: blazeHelperErrorDomain,
                                            code: BlazeHelperError.openFailed.rawValue,
                                            userInfo: [NSLocalizedDescriptionKey: "Cannot reach the helper."])))
                return
            }
            proxy.prepareDevice(bsdName: bsdName, imageSize: imageSize) { path, error in
                if let path {
                    box.resume(.success(path))
                } else {
                    box.resume(.failure(error ?? NSError(
                        domain: blazeHelperErrorDomain,
                        code: BlazeHelperError.openFailed.rawValue,
                        userInfo: [NSLocalizedDescriptionKey: "The helper did not hand over the card."])))
                }
            }
        }
    }

    /// Best-effort undo of `prepareDevice`; failure here is not worth
    /// reporting over the error that caused it.
    func releaseDevice() async {
        guard let proxy = connection?.remoteObjectProxy as? BlazeHelperProtocol else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let box = ReplyOnce<Void>(nil) { cont.resume() }
            proxy.releaseDevice { box.resume(()) }
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

/// XPC can report both a reply and (later) a connection error; a checked
/// continuation must resume exactly once.
private final class ReplyOnce<T>: @unchecked Sendable {
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
