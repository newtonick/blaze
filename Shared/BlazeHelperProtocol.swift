import Foundation

/// Bump whenever the XPC contract or flash pipeline changes. The app compares
/// this against the installed helper's reported version on connect and
/// re-registers the daemon on mismatch.
public let blazeHelperVersion = "1.3.0"

public let blazeHelperMachServiceName = "dev.derivation48.blaze.helper"

/// Phases of a flash run, streamed to the client alongside byte progress.
@objc public enum FlashPhase: Int, Sendable {
    case unmounting
    case writing
    case syncing
    case verifying
    case ejecting
    case done

    public var label: String {
        switch self {
        case .unmounting: return "Unmounting"
        case .writing: return "Writing"
        case .syncing: return "Syncing"
        case .verifying: return "Verifying"
        case .ejecting: return "Ejecting"
        case .done: return "Done"
        }
    }
}

public let blazeHelperErrorDomain = "dev.derivation48.blaze.helper"

/// Error codes the helper reports. Raw values are NSError codes in
/// `blazeHelperErrorDomain`.
public enum BlazeHelperError: Int, Sendable {
    case invalidDeviceName = 1     // not a bare whole-disk name like "disk8"
    case notWholeDisk = 2
    case internalDisk = 3
    case bootDisk = 4              // backs "/", directly or as APFS physical store
    case deviceNotFound = 5
    case imageTooLarge = 6
    case unmountFailed = 7
    case openFailed = 8
    case writeFailed = 9
    case readBackFailed = 10
    case verifyMismatch = 11       // userInfo[blazeVerifyMismatchOffsetKey] = byte offset
    case cancelled = 12
    case ejectFailed = 13          // write succeeded; eject did not
    case busy = 14                 // a flash is already running
    case deviceMismatch = 15       // the passed descriptor isn't the named disk
}

public let blazeVerifyMismatchOffsetKey = "MismatchOffset"

/// How the image file's payload is encoded. The app inspects the container
/// (unprivileged) and tells the helper which Apple decoder to run; the
/// helper never parses archive structure itself.
@objc public enum ImageFormat: Int, Sendable {
    case raw = 0
    case xz = 1        // whole file is an xz stream (COMPRESSION_LZMA)
    case gzDeflate = 2 // raw DEFLATE at payloadOffset (gzip header pre-parsed)
}

/// Implemented by the app; the helper calls it back with progress.
/// Called on an arbitrary XPC queue — implementations must hop as needed.
@objc public protocol BlazeHelperClientProtocol {
    func flashProgress(phase: Int, bytesDone: Int64, bytesTotal: Int64)
}

/// The privileged helper's XPC surface.
@objc public protocol BlazeHelperProtocol {
    func version(reply: @escaping @Sendable (String) -> Void)

    /// Validates `bsdName` as a legal target, unmounts it, blocks re-mounts,
    /// and hands its raw device node to the calling user. Replies with the
    /// path for the app to open (or an error, having changed nothing).
    ///
    /// The app must be the process that opens the card, because TCC checks
    /// removable-media access against the app — the process the user actually
    /// granted it to. A root daemon has no such grant and cannot obtain one:
    /// it can't prompt, and `authopen` is no way out either (the
    /// `sys.openfile.` right is `allow-root: false`, and authopen's TCC check
    /// resolves to whoever is responsible for it, which is the daemon).
    /// Root gets the write; the app gets the descriptor.
    func prepareDevice(bsdName: String, imageSize: Int64,
                       reply: @escaping @Sendable (String?, NSError?) -> Void)

    /// Undoes `prepareDevice` — restores the node's ownership and stops
    /// blocking mounts. Called when the app gives up before flashing; a flash
    /// releases the device itself. Safe to call when nothing is prepared.
    func releaseDevice(reply: @escaping @Sendable () -> Void)

    /// Writes the image from `imageHandle` to `deviceHandle`, the descriptor
    /// the app opened at the path `prepareDevice` returned. Both arrive as
    /// file descriptors so the helper never opens a TCC-gated path itself
    /// (root does not bypass TCC). `bsdName` is re-validated here and
    /// `deviceHandle` must refer to that exact device — the app cannot
    /// substitute another. When simulating, pass a handle on /dev/null.
    ///
    /// `imageSize` is the expected UNCOMPRESSED size, or 0 when unknown
    /// (oversized gzip); the fit gate then falls to write time. The payload
    /// range delimits the compressed bytes within the file for `format`.
    /// With `simulate`, safety gates still run but the card is untouched:
    /// bytes go to /dev/null and verify re-decodes the image.
    func flash(imageHandle: FileHandle,
               deviceHandle: FileHandle,
               imageSize: Int64,
               format: Int,
               payloadOffset: Int64,
               payloadSize: Int64,
               bsdName: String,
               verify: Bool,
               simulate: Bool,
               reply: @escaping @Sendable (NSError?) -> Void)

    /// Cooperative cancel; checked between blocks. A cancelled write still
    /// syncs and ejects so the card is not left half-mounted.
    func cancelFlash()
}
