import Foundation

/// What the app learned about an image file by reading container headers —
/// milliseconds of I/O, no decompression. The helper is handed these facts
/// and never parses container structure itself.
nonisolated struct ImageInfo: Equatable, Sendable {
    var format: ImageFormat
    var fileSize: Int64
    /// Exact for raw and xz; exact for gzip under 4 GB, nil when the gzip
    /// size counter may have wrapped (stored mod 2^32).
    var uncompressedSize: Int64?
    var payloadOffset: Int64
    var payloadSize: Int64

    var isCompressed: Bool { format != .raw }
}

nonisolated enum ImageInspector {
    static func inspect(_ url: URL) -> ImageInfo? {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let fileSize = try? handle.seekToEnd(), fileSize > 0 else { return nil }
        defer { try? handle.close() }
        let size = Int64(fileSize)

        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".xz") {
            return inspectXZ(handle, fileSize: size)
        }
        if name.hasSuffix(".gz") {
            return inspectGzip(handle, fileSize: size)
        }
        return ImageInfo(format: .raw, fileSize: size, uncompressedSize: size,
                         payloadOffset: 0, payloadSize: size)
    }

    // MARK: - xz

    /// The 12-byte xz stream footer records the size of the index, and the
    /// index records every block's uncompressed size — so the exact image
    /// size is available without decompressing anything.
    private static func inspectXZ(_ handle: FileHandle, fileSize: Int64) -> ImageInfo? {
        guard fileSize > 32,
              let header = read(handle, at: 0, count: 6), header == Data([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]),
              let footer = read(handle, at: fileSize - 12, count: 12),
              footer[10] == 0x59, footer[11] == 0x5A  // "YZ"
        else { return nil }

        var info = ImageInfo(format: .xz, fileSize: fileSize, uncompressedSize: nil,
                             payloadOffset: 0, payloadSize: fileSize)

        // backward size: (stored + 1) * 4 = real index size
        let storedBackward = UInt32(littleEndian: footer.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: UInt32.self) })
        let indexSize = (Int64(storedBackward) + 1) * 4
        guard indexSize < fileSize - 12,
              let index = read(handle, at: fileSize - 12 - indexSize, count: Int(indexSize)),
              index.first == 0x00
        else { return info }  // still flashable; size just stays unknown

        var pos = 1
        guard let recordCount = readVarint(index, &pos) else { return info }
        var total: UInt64 = 0
        for _ in 0..<recordCount {
            guard readVarint(index, &pos) != nil,               // unpadded size
                  let uncompressed = readVarint(index, &pos) else { return info }
            total &+= uncompressed
        }
        info.uncompressedSize = Int64(clamping: total)
        return info
    }

    /// xz variable-length integers: 7 bits per byte, high bit = continue.
    private static func readVarint(_ data: Data, _ pos: inout Int) -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while pos < data.count && shift < 63 {
            let byte = data[data.startIndex + pos]
            pos += 1
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        return nil
    }

    // MARK: - gzip

    /// RFC 1952: fixed 10-byte header plus optional extra/name/comment/CRC
    /// fields, then the raw DEFLATE stream, then CRC32 + ISIZE (mod 2^32).
    private static func inspectGzip(_ handle: FileHandle, fileSize: Int64) -> ImageInfo? {
        guard fileSize > 20,
              let head = read(handle, at: 0, count: min(Int(fileSize), 64 * 1024)),
              head.count >= 10, head[0] == 0x1F, head[1] == 0x8B, head[2] == 0x08
        else { return nil }

        let flags = head[3]
        var offset = 10
        if flags & 0x04 != 0 {  // FEXTRA
            guard head.count >= offset + 2 else { return nil }
            let xlen = Int(head[offset]) | (Int(head[offset + 1]) << 8)
            offset += 2 + xlen
        }
        for bit in [UInt8(0x08), UInt8(0x10)] where flags & bit != 0 {  // FNAME, FCOMMENT
            while offset < head.count && head[offset] != 0 { offset += 1 }
            guard offset < head.count else { return nil }
            offset += 1
        }
        if flags & 0x02 != 0 { offset += 2 }  // FHCRC
        guard Int64(offset) < fileSize - 8 else { return nil }

        var info = ImageInfo(format: .gzDeflate, fileSize: fileSize, uncompressedSize: nil,
                             payloadOffset: Int64(offset),
                             payloadSize: fileSize - Int64(offset) - 8)

        if let trailer = read(handle, at: fileSize - 4, count: 4) {
            let isize = UInt32(littleEndian: trailer.withUnsafeBytes { $0.load(as: UInt32.self) })
            // ISIZE is the true size mod 2^32. A wrapped (>4 GB) image shows
            // a claimed size far below its compressed payload; incompressible
            // data legitimately shows slightly below (ratio ≈ 1). Accept the
            // near-or-above range, treat anything far below as unknown.
            if Double(isize) >= Double(info.payloadSize) * 0.9 {
                info.uncompressedSize = Int64(isize)
            }
        }
        return info
    }

    private static func read(_ handle: FileHandle, at offset: Int64, count: Int) -> Data? {
        guard (try? handle.seek(toOffset: UInt64(offset))) != nil,
              let data = try? handle.read(upToCount: count), data.count == count || offset == 0
        else { return nil }
        return data
    }
}
