import Foundation
import Compression

/// Yields the decompressed image byte stream from the (seekable) image file
/// descriptor. Two passes per flash — write, then verify — each with a fresh
/// source; `reset()` seeks back and restarts the decoder.
protocol ImageSource: AnyObject {
    /// Fills `buffer` with up to `want` bytes; short only at end of stream.
    func read(into buffer: UnsafeMutablePointer<UInt8>, _ want: Int) throws -> Int
    func reset() throws
}

/// Pass-through for plain .img files.
final class RawImageSource: ImageSource {
    private let fd: Int32
    private let length: Int64
    private var remaining: Int64

    init(fd: Int32, length: Int64) {
        self.fd = fd
        self.length = length
        self.remaining = length
    }

    func reset() throws {
        lseek(fd, 0, SEEK_SET)
        remaining = length
    }

    func read(into buffer: UnsafeMutablePointer<UInt8>, _ want: Int) throws -> Int {
        let target = Int(min(Int64(want), remaining))
        var got = 0
        while got < target {
            let n = Darwin.read(fd, buffer + got, target - got)
            if n == 0 { break }
            guard n > 0 else {
                if errno == EINTR { continue }
                throw NSError(domain: blazeHelperErrorDomain,
                              code: BlazeHelperError.readBackFailed.rawValue,
                              userInfo: [NSLocalizedDescriptionKey:
                                "Image read failed: \(String(cString: strerror(errno)))"])
            }
            got += n
        }
        remaining -= Int64(got)
        return got
    }
}

/// Streams an xz (COMPRESSION_LZMA) or raw-DEFLATE (COMPRESSION_ZLIB)
/// payload through Apple's decoder. The helper is told the payload's byte
/// range by the app; it never parses container structure itself.
final class DecompressingImageSource: ImageSource {
    private let fd: Int32
    private let algorithm: compression_algorithm
    private let payloadOffset: Int64
    private let payloadSize: Int64

    private let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
    private var streamLive = false
    private let inBuffer: UnsafeMutablePointer<UInt8>
    private static let inChunk = 1024 * 1024
    private var inRemaining: Int64 = 0
    private var srcEOF = false
    private var streamDone = false

    init(fd: Int32, algorithm: compression_algorithm, payloadOffset: Int64, payloadSize: Int64) throws {
        self.fd = fd
        self.algorithm = algorithm
        self.payloadOffset = payloadOffset
        self.payloadSize = payloadSize
        inBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.inChunk)
        try reset()
    }

    deinit {
        if streamLive { compression_stream_destroy(stream) }
        stream.deallocate()
        inBuffer.deallocate()
    }

    func reset() throws {
        if streamLive { compression_stream_destroy(stream); streamLive = false }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, algorithm) == COMPRESSION_STATUS_OK else {
            throw Self.decodeError("cannot initialize the decoder")
        }
        streamLive = true
        stream.pointee.src_size = 0
        lseek(fd, payloadOffset, SEEK_SET)
        inRemaining = payloadSize
        srcEOF = false
        streamDone = false
    }

    func read(into buffer: UnsafeMutablePointer<UInt8>, _ want: Int) throws -> Int {
        if streamDone { return 0 }
        stream.pointee.dst_ptr = buffer
        stream.pointee.dst_size = want

        while stream.pointee.dst_size > 0 && !streamDone {
            if stream.pointee.src_size == 0 && !srcEOF {
                let target = Int(min(Int64(Self.inChunk), inRemaining))
                var got = 0
                while got < target {
                    let n = Darwin.read(fd, inBuffer + got, target - got)
                    if n == 0 { break }
                    guard n > 0 else {
                        if errno == EINTR { continue }
                        throw Self.decodeError("read failed: \(String(cString: strerror(errno)))")
                    }
                    got += n
                }
                inRemaining -= Int64(got)
                srcEOF = got == 0 || inRemaining == 0
                stream.pointee.src_ptr = UnsafePointer(inBuffer)
                stream.pointee.src_size = got
            }
            let flags = srcEOF && stream.pointee.src_size == 0
                ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            switch compression_stream_process(stream, flags) {
            case COMPRESSION_STATUS_OK:
                // Finalized with no progress possible → truncated input.
                if flags != 0 && stream.pointee.dst_size == want && stream.pointee.src_size == 0 {
                    throw Self.decodeError("unexpected end of compressed data")
                }
            case COMPRESSION_STATUS_END:
                streamDone = true
            default:
                throw Self.decodeError("the compressed image is corrupt")
            }
        }
        return want - stream.pointee.dst_size
    }

    private static func decodeError(_ message: String) -> NSError {
        NSError(domain: blazeHelperErrorDomain,
                code: BlazeHelperError.readBackFailed.rawValue,
                userInfo: [NSLocalizedDescriptionKey: "Decompression failed: \(message)"])
    }
}

enum ImageSourceFactory {
    static func make(fd: Int32, format: ImageFormat,
                     payloadOffset: Int64, payloadSize: Int64,
                     rawLength: Int64) throws -> ImageSource {
        switch format {
        case .raw:
            return RawImageSource(fd: fd, length: rawLength)
        case .xz:
            return try DecompressingImageSource(fd: fd, algorithm: COMPRESSION_LZMA,
                                                payloadOffset: payloadOffset, payloadSize: payloadSize)
        case .gzDeflate:
            return try DecompressingImageSource(fd: fd, algorithm: COMPRESSION_ZLIB,
                                                payloadOffset: payloadOffset, payloadSize: payloadSize)
        }
    }
}
