import Foundation
import os.log

final class HelperService: NSObject, NSXPCListenerDelegate, BlazeHelperProtocol {
    private let log = Logger(subsystem: "dev.derivation48.blaze.helper", category: "service")
    private let flasher = Flasher()
    private let stateLock = NSLock()
    private var connectionCount = 0

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.setCodeSigningRequirement(PeerValidator.requirement)
        connection.exportedInterface = NSXPCInterface(with: BlazeHelperProtocol.self)
        connection.exportedObject = self
        connection.remoteObjectInterface = NSXPCInterface(with: BlazeHelperClientProtocol.self)
        stateLock.lock()
        connectionCount += 1
        stateLock.unlock()
        connection.invalidationHandler = { [weak self] in self?.connectionClosed() }
        connection.resume()
        log.info("accepted connection from pid \(connection.processIdentifier)")
        return true
    }

    /// Exit when idle so the next launch runs whatever binary is in the app
    /// bundle — helper updates deploy without re-registration or prompts.
    private func connectionClosed() {
        stateLock.lock()
        connectionCount -= 1
        let idle = connectionCount == 0
        stateLock.unlock()
        guard idle else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let stillIdle = self.connectionCount == 0
            self.stateLock.unlock()
            if stillIdle && !self.flasher.isRunning {
                // The app may have died holding a prepared card; put the
                // device node back before letting go.
                self.flasher.release()
                self.log.info("idle; exiting so launchd can respawn the current binary on demand")
                exit(0)
            }
        }
    }

    // MARK: - BlazeHelperProtocol

    func version(reply: @escaping @Sendable (String) -> Void) {
        reply(blazeHelperVersion)
    }

    func prepareDevice(bsdName: String, imageSize: Int64,
                       reply: @escaping @Sendable (String?, NSError?) -> Void) {
        // The card is handed to the user on the other end of this connection,
        // not to whoever asks — and the peer's code signature was already
        // checked when the connection was accepted.
        guard let uid = NSXPCConnection.current()?.effectiveUserIdentifier else {
            reply(nil, NSError(domain: blazeHelperErrorDomain,
                               code: BlazeHelperError.openFailed.rawValue,
                               userInfo: [NSLocalizedDescriptionKey: "No caller identity."]))
            return
        }
        do {
            let path = try flasher.prepare(bsdName: bsdName, imageSize: imageSize, uid: uid)
            reply(path, nil)
        } catch let error as NSError {
            log.error("prepareDevice(\(bsdName, privacy: .public)) refused: \(error.localizedDescription, privacy: .public)")
            reply(nil, error)
        }
    }

    func releaseDevice(reply: @escaping @Sendable () -> Void) {
        flasher.release()
        reply()
    }

    func flash(imageHandle: FileHandle,
               deviceHandle: FileHandle,
               imageSize: Int64,
               format: Int,
               payloadOffset: Int64,
               payloadSize: Int64,
               bsdName: String,
               verify: Bool,
               simulate: Bool,
               reply: @escaping @Sendable (NSError?) -> Void) {
        guard let imageFormat = ImageFormat(rawValue: format) else {
            reply(NSError(domain: blazeHelperErrorDomain,
                          code: BlazeHelperError.openFailed.rawValue,
                          userInfo: [NSLocalizedDescriptionKey: "Unknown image format."]))
            return
        }
        let client = NSXPCConnection.current()?.remoteObjectProxy as? BlazeHelperClientProtocol
        flasher.flash(imageHandle: imageHandle, deviceHandle: deviceHandle, imageSize: imageSize,
                      format: imageFormat, payloadOffset: payloadOffset, payloadSize: payloadSize,
                      bsdName: bsdName, verify: verify, simulate: simulate,
                      client: client, reply: reply)
    }

    func cancelFlash() {
        flasher.cancel()
    }
}
