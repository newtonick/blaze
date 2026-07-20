import Foundation

/// Bump whenever the XPC contract or flash pipeline changes. The app compares
/// this against the installed helper's reported version on connect and
/// re-registers the daemon on mismatch.
public let blazeHelperVersion = "1.2.0"

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

    /// Writes the image from `imageHandle` to the whole disk `bsdName`
    /// (e.g. "disk8"). The image is passed as a file descriptor so the helper
    /// never opens user paths itself (root does not bypass TCC).
    ///
    /// `imageSize` is the expected UNCOMPRESSED size, or 0 when unknown
    /// (oversized gzip); the fit gate then falls to write time. The payload
    /// range delimits the compressed bytes within the file for `format`.
    /// With `simulate`, safety gates still run but the card is untouched:
    /// bytes go to /dev/null and verify re-decodes the image.
    func flash(imageHandle: FileHandle,
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
