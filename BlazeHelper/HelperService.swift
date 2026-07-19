import Foundation
import os.log

final class HelperService: NSObject, NSXPCListenerDelegate, BlazeHelperProtocol {
    private let log = Logger(subsystem: "com.klockenga.blaze.helper", category: "service")
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
                self.log.info("idle; exiting so launchd can respawn the current binary on demand")
                exit(0)
            }
        }
    }

    // MARK: - BlazeHelperProtocol

    func version(reply: @escaping @Sendable (String) -> Void) {
        reply(blazeHelperVersion)
    }

    func flash(imageHandle: FileHandle,
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
        flasher.flash(imageHandle: imageHandle, imageSize: imageSize,
                      format: imageFormat, payloadOffset: payloadOffset, payloadSize: payloadSize,
                      bsdName: bsdName, verify: verify, simulate: simulate,
                      client: client, reply: reply)
    }

    func cancelFlash() {
        flasher.cancel()
    }
}
