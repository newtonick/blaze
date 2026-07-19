import Foundation
import DiskArbitration
import os.log

/// Writes a raw image to a whole disk. Runs as root: every fact about the
/// target is re-derived here — the app's UI filtering is convenience only,
/// and a UI bug must not be able to overwrite the boot drive.
final class Flasher {
    private let log = Logger(subsystem: "dev.derivation48.blaze.helper", category: "flasher")
    private let queue = DispatchQueue(label: "dev.derivation48.blaze.helper.flash")
    private let stateLock = NSLock()
    private var running = false
    private var cancelled = false

    private static let chunkSize = 8 * 1024 * 1024
    private static let progressInterval: TimeInterval = 0.25

    // MARK: - Public surface

    var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    func cancel() {
        stateLock.lock()
        if running { cancelled = true }
        stateLock.unlock()
    }

    func flash(imageHandle: FileHandle,
               imageSize: Int64,
               format: ImageFormat,
               payloadOffset: Int64,
               payloadSize: Int64,
               bsdName: String,
               verify: Bool,
               simulate: Bool,
               client: BlazeHelperClientProtocol?,
               reply: @escaping @Sendable (NSError?) -> Void) {
        stateLock.lock()
        if running {
            stateLock.unlock()
            reply(Self.error(.busy, "A flash is already in progress."))
            return
        }
        running = true
        cancelled = false
        stateLock.unlock()

        queue.async {
            let result: NSError?
            do {
                try self.run(imageHandle: imageHandle, imageSize: imageSize,
                             format: format, payloadOffset: payloadOffset,
                             payloadSize: payloadSize,
                             bsdName: bsdName, verify: verify, simulate: simulate,
                             client: client)
                result = nil
            } catch let e as NSError {
                self.log.error("flash failed: [\(e.code)] \(e.localizedDescription, privacy: .public)")
                result = e
            }
            self.stateLock.lock()
            self.running = false
            self.stateLock.unlock()
            reply(result)
        }
    }

    // MARK: - Safety gates

    /// Refuses anything that is not an external, non-boot whole disk big
    /// enough for the image (`imageSize` 0 = unknown; the fit gate then
    /// moves to write time). Returns the device's logical block size and
    /// capacity. Internal (not private) so `--validate` can exercise it.
    @discardableResult
    func validateTarget(bsdName: String, imageSize: Int64) throws -> (blockSize: Int, deviceSize: Int64) {
        guard bsdName.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil else {
            throw Self.error(.invalidDeviceName, "\(bsdName) is not a whole-disk device name.")
        }
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName),
              let desc = DADiskCopyDescription(disk) as? [String: Any] else {
            throw Self.error(.deviceNotFound, "No such device: \(bsdName).")
        }
        guard desc[kDADiskDescriptionMediaWholeKey as String] as? Bool == true else {
            throw Self.error(.notWholeDisk, "\(bsdName) is not a whole disk.")
        }
        if desc[kDADiskDescriptionDeviceInternalKey as String] as? Bool == true {
            throw Self.error(.internalDisk, "\(bsdName) is an internal disk.")
        }
        if try bootDisks().contains(bsdName) {
            throw Self.error(.bootDisk, "\(bsdName) backs the startup volume.")
        }
        guard let mediaSize = desc[kDADiskDescriptionMediaSizeKey as String] as? Int64 else {
            throw Self.error(.deviceNotFound, "Cannot determine the size of \(bsdName).")
        }
        guard imageSize <= mediaSize else {
            throw Self.error(.imageTooLarge,
                             "The image (\(imageSize) bytes) is larger than \(bsdName) (\(mediaSize) bytes).")
        }
        let blockSize = desc[kDADiskDescriptionMediaBlockSizeKey as String] as? Int ?? 512
        return (max(blockSize, 512), mediaSize)
    }

    /// Whole disks that must never be written: the disk mounted at "/" plus,
    /// when that is an APFS synthesized disk, its physical stores.
    private func bootDisks() throws -> Set<String> {
        var fs = statfs()
        guard statfs("/", &fs) == 0 else {
            throw Self.error(.bootDisk, "Cannot determine the startup disk; refusing to write.")
        }
        let mntFrom = withUnsafeBytes(of: fs.f_mntfromname) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        guard let rootWhole = Self.wholeDiskName(from: mntFrom) else {
            throw Self.error(.bootDisk, "Unrecognized startup device \(mntFrom); refusing to write.")
        }
        var forbidden: Set<String> = [rootWhole]
        if let info = try? diskutilPlist(["info", "-plist", rootWhole]),
           let stores = info["APFSPhysicalStores"] as? [[String: Any]] {
            for store in stores {
                if let dev = store["APFSPhysicalStore"] as? String,
                   let whole = Self.wholeDiskName(from: dev) {
                    forbidden.insert(whole)
                }
            }
        }
        return forbidden
    }

    /// "disk3s1s1" or "/dev/disk3s1s1" → "disk3"
    static func wholeDiskName(from device: String) -> String? {
        let name = device.hasPrefix("/dev/") ? String(device.dropFirst(5)) : device
        guard let match = name.range(of: #"^disk[0-9]+"#, options: .regularExpression) else { return nil }
        return String(name[match])
    }

    // MARK: - Pipeline

    private func run(imageHandle: FileHandle, imageSize: Int64,
                     format: ImageFormat, payloadOffset: Int64, payloadSize: Int64,
                     bsdName: String, verify: Bool, simulate: Bool,
                     client: BlazeHelperClientProtocol?) throws {
        let (blockSize, deviceSize) = try validateTarget(bsdName: bsdName, imageSize: imageSize)
        log.info("flash start: \(bsdName, privacy: .public) image=\(imageSize) format=\(format.rawValue) simulate=\(simulate) verify=\(verify)")

        // Block auto-mounts for the whole run (registered before the unmount
        // so no mount can slip in; released only after eject).
        let blocker = MountBlocker()
        if !simulate { blocker.block(bsdName) }
        defer { blocker.unblock() }
        let source = try ImageSourceFactory.make(fd: imageHandle.fileDescriptor, format: format,
                                                 payloadOffset: payloadOffset, payloadSize: payloadSize,
                                                 rawLength: imageSize)

        let progress = ProgressReporter(client: client, total: imageSize)

        // Unmount
        progress.phase(.unmounting)
        if simulate {
            Thread.sleep(forTimeInterval: 0.3)
        } else {
            try diskutil(["unmountDisk", "force", bsdName], failure: .unmountFailed)
        }

        // Open target: the raw node for real runs, /dev/null for simulate.
        let devicePath = simulate ? "/dev/null" : "/dev/rdisk" + bsdName.dropFirst(4)
        var devFD = try openDevice(devicePath, oflag: O_WRONLY)

        var ejected = false
        defer {
            if devFD >= 0 { close(devFD) }
            // Never leave a half-written card mounted: eject even on failure
            // or cancel (unless we already did, or never touched the disk).
            if !simulate && !ejected {
                _ = try? diskutil(["eject", bsdName], failure: .ejectFailed)
            }
        }

        // Write
        progress.phase(.writing)
        let written: Int64
        do {
            written = try pump(from: source, to: devFD, deviceSize: simulate ? Int64.max : deviceSize,
                               blockSize: blockSize, progress: progress)
        } catch {
            // flush what made it to the device before the deferred eject.
            if !simulate { try? syncDevice(devFD) }
            throw error
        }

        // Sync
        progress.phase(.syncing)
        if !simulate { try syncDevice(devFD) }
        close(devFD)
        devFD = -1

        // Verify
        if verify {
            progress.phase(.verifying)
            progress.reset()
            try source.reset()
            try runVerify(source: source, imageSize: written, bsdName: bsdName,
                          blockSize: blockSize, simulate: simulate, progress: progress)
        }

        // Eject
        progress.phase(.ejecting)
        if simulate {
            Thread.sleep(forTimeInterval: 0.3)
        } else {
            try diskutil(["eject", bsdName], failure: .ejectFailed)
        }
        ejected = true

        progress.phase(.done)
        log.info("flash done: \(bsdName, privacy: .public)")
    }

    /// Streams the (possibly decompressing) source to `dstFD` in aligned
    /// chunks, the final chunk zero-padded to the device block size (raw
    /// devices require block-multiple writes). The stream must fit within
    /// `deviceSize` — the only fit gate when the uncompressed size wasn't
    /// knowable up front. Returns the image bytes written.
    private func pump(from source: ImageSource, to dstFD: Int32, deviceSize: Int64,
                      blockSize: Int, progress: ProgressReporter) throws -> Int64 {
        let buffer = try Self.alignedBuffer(Self.chunkSize)
        defer { buffer.deallocate() }

        var done: Int64 = 0
        while true {
            try checkCancelled()
            let got = try source.read(into: buffer, Self.chunkSize)
            if got == 0 { break }
            guard done + Int64(got) <= deviceSize else {
                throw Self.error(.imageTooLarge,
                                 "The image is larger than the card — stopped after \(done) bytes.")
            }
            var writeLen = got
            if writeLen % blockSize != 0 {
                let padded = (writeLen / blockSize + 1) * blockSize
                memset(buffer + writeLen, 0, padded - writeLen)
                writeLen = padded
            }
            var written = 0
            while written < writeLen {
                let n = write(dstFD, buffer + written, writeLen - written)
                guard n > 0 else {
                    throw Self.error(.writeFailed,
                                     "Write failed at byte \(done + Int64(written)): \(String(cString: strerror(errno)))")
                }
                written += n
            }
            done += Int64(got)
            progress.update(done)
        }
        return done
    }

    /// Raw character devices don't implement F_FULLFSYNC (it fails ENOTTY),
    /// and raw writes bypass the buffer cache anyway — so on ENOTTY fall
    /// back to asking the driver to flush its own hardware cache, which is
    /// best-effort (USB readers commonly don't support it either). Any other
    /// errno is a real I/O failure.
    private func syncDevice(_ fd: Int32) throws {
        if fcntl(fd, F_FULLFSYNC) == 0 { return }
        if errno == ENOTTY || errno == EINVAL {
            let DKIOCSYNCHRONIZECACHE: UInt = 0x20006416  // _IO('d', 22), sys/disk.h
            _ = ioctl(fd, DKIOCSYNCHRONIZECACHE)
            return
        }
        throw Self.error(.writeFailed, "Sync failed: \(String(cString: strerror(errno)))")
    }

    /// Internal (not private) so the test harness can tamper a device and
    /// prove verify catches it.
    func runVerify(source: ImageSource, imageSize: Int64, bsdName: String,
                   blockSize: Int, simulate: Bool,
                   progress: ProgressReporter) throws {
        progress.setTotal(imageSize)
        let imageBuf = try Self.alignedBuffer(Self.chunkSize)
        defer { imageBuf.deallocate() }

        if simulate {
            // Exercise the decode/read path against the image alone.
            var done: Int64 = 0
            while true {
                try checkCancelled()
                let got = try source.read(into: imageBuf, Self.chunkSize)
                if got == 0 { break }
                done += Int64(got)
                progress.update(done)
            }
            return
        }

        let devicePath = "/dev/rdisk" + bsdName.dropFirst(4)
        let devFD = try openDevice(devicePath, oflag: O_RDONLY)
        defer { close(devFD) }

        let devBuf = try Self.alignedBuffer(Self.chunkSize)
        defer { devBuf.deallocate() }

        var done: Int64 = 0
        while done < imageSize {
            try checkCancelled()
            let got = try source.read(into: imageBuf, Self.chunkSize)
            guard got > 0 else {
                throw Self.error(.readBackFailed, "Image ended early during verify at byte \(done).")
            }
            // Device reads must be block-multiples; read the padded length
            // but compare only image bytes.
            let devWant = (got % blockSize == 0) ? got : (got / blockSize + 1) * blockSize
            let gotDev = try readFull(devFD, devBuf, devWant, code: .readBackFailed)
            guard gotDev >= got else {
                throw Self.error(.readBackFailed, "Short read during verify at byte \(done).")
            }
            if memcmp(imageBuf, devBuf, got) != 0 {
                var offset = done
                for i in 0..<got where imageBuf[i] != devBuf[i] {
                    offset = done + Int64(i)
                    break
                }
                throw NSError(domain: blazeHelperErrorDomain,
                              code: BlazeHelperError.verifyMismatch.rawValue,
                              userInfo: [
                                NSLocalizedDescriptionKey:
                                    "Verification failed: the card differs from the image at byte \(offset).",
                                blazeVerifyMismatchOffsetKey: NSNumber(value: offset),
                              ])
            }
            done += Int64(got)
            progress.update(done)
        }
    }

    // MARK: - Device opening

    /// TCC gates raw external-disk nodes with EPERM even for root (the same
    /// gate that makes `sudo dd` fail without Full Disk Access). authopen is
    /// the sanctioned path around it — an Apple setuid binary that opens the
    /// node and passes the descriptor back over a socket — and it authorizes
    /// silently for root, so the no-prompts promise holds.
    private func openDevice(_ path: String, oflag: Int32) throws -> Int32 {
        let fd = open(path, oflag)
        if fd >= 0 { return fd }
        if errno == EPERM || errno == EACCES {
            return try authopenFD(path: path, oflag: oflag)
        }
        throw Self.error(.openFailed, "Cannot open \(path): \(String(cString: strerror(errno)))")
    }

    private func authopenFD(path: String, oflag: Int32) throws -> Int32 {
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
            throw Self.error(.openFailed, "socketpair failed: \(String(cString: strerror(errno)))")
        }
        let parentSock = pair[0]
        let childSock = pair[1]
        defer { close(parentSock) }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/libexec/authopen")
        proc.arguments = ["-stdoutpipe", "-o", String(oflag), path]
        proc.standardOutput = FileHandle(fileDescriptor: childSock, closeOnDealloc: false)
        do {
            try proc.run()
        } catch {
            close(childSock)
            throw Self.error(.openFailed, "cannot launch authopen: \(error.localizedDescription)")
        }
        close(childSock)

        // authopen sends the descriptor as an SCM_RIGHTS control message.
        var data = [UInt8](repeating: 0, count: 16)
        var control = [UInt8](repeating: 0, count: 64)
        var receivedFD: Int32 = -1
        data.withUnsafeMutableBytes { dataPtr in
            control.withUnsafeMutableBytes { ctlPtr in
                var iov = iovec(iov_base: dataPtr.baseAddress, iov_len: dataPtr.count)
                withUnsafeMutablePointer(to: &iov) { iovPtr in
                    var msg = msghdr(msg_name: nil, msg_namelen: 0,
                                     msg_iov: iovPtr, msg_iovlen: 1,
                                     msg_control: ctlPtr.baseAddress,
                                     msg_controllen: socklen_t(ctlPtr.count), msg_flags: 0)
                    var n = 0
                    repeat { n = recvmsg(parentSock, &msg, 0) } while n < 0 && errno == EINTR
                    // cmsghdr on Darwin: len(4) level(4) type(4), data at 12.
                    if n > 0, msg.msg_controllen >= 16,
                       ctlPtr.load(fromByteOffset: 4, as: Int32.self) == SOL_SOCKET,
                       ctlPtr.load(fromByteOffset: 8, as: Int32.self) == SCM_RIGHTS {
                        receivedFD = ctlPtr.load(fromByteOffset: 12, as: Int32.self)
                    }
                }
            }
        }
        proc.waitUntilExit()
        guard receivedFD >= 0 else {
            throw Self.error(.openFailed,
                             "authopen did not return a descriptor for \(path) (status \(proc.terminationStatus)).")
        }
        return receivedFD
    }

    // MARK: - Small utilities

    private func checkCancelled() throws {
        stateLock.lock()
        let c = cancelled
        stateLock.unlock()
        if c { throw Self.error(.cancelled, "Cancelled.") }
    }

    private func readFull(_ fd: Int32, _ buf: UnsafeMutablePointer<UInt8>, _ want: Int,
                          code: BlazeHelperError = .readBackFailed) throws -> Int {
        var got = 0
        while got < want {
            let n = read(fd, buf + got, want - got)
            if n == 0 { break }
            guard n > 0 else {
                if errno == EINTR { continue }
                throw Self.error(code, "Read failed: \(String(cString: strerror(errno)))")
            }
            got += n
        }
        return got
    }

    private static func alignedBuffer(_ size: Int) throws -> UnsafeMutablePointer<UInt8> {
        var raw: UnsafeMutableRawPointer?
        guard posix_memalign(&raw, 4096, size) == 0, let raw else {
            throw error(.openFailed, "Out of memory.")
        }
        return raw.assumingMemoryBound(to: UInt8.self)
    }

    @discardableResult
    private func diskutil(_ args: [String], failure: BlazeHelperError) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        p.waitUntilExit()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard p.terminationStatus == 0 else {
            throw Self.error(failure, "diskutil \(args.joined(separator: " ")) failed: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return text
    }

    private func diskutilPlist(_ args: [String]) throws -> [String: Any] {
        let text = try diskutil(args, failure: .deviceNotFound)
        guard let data = text.data(using: .utf8),
              let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw Self.error(.deviceNotFound, "Unparseable diskutil output.")
        }
        return plist
    }

    private static func error(_ code: BlazeHelperError, _ message: String) -> NSError {
        NSError(domain: blazeHelperErrorDomain, code: code.rawValue,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// Rate-limits byte progress to ~4 Hz; phase changes always go through.
final class ProgressReporter {
    private let client: BlazeHelperClientProtocol?
    private var total: Int64
    private var currentPhase: FlashPhase = .unmounting
    private var lastSent = Date.distantPast

    init(client: BlazeHelperClientProtocol?, total: Int64) {
        self.client = client
        self.total = total
    }

    /// The write pass learns the true byte count when the container didn't
    /// declare one; verify then gets a determinate bar either way.
    func setTotal(_ newTotal: Int64) { total = newTotal }

    func phase(_ p: FlashPhase) {
        currentPhase = p
        lastSent = Date.distantPast
        client?.flashProgress(phase: p.rawValue, bytesDone: 0, bytesTotal: total)
    }

    func reset() { lastSent = .distantPast }

    func update(_ done: Int64) {
        let now = Date()
        guard now.timeIntervalSince(lastSent) >= 0.25 || done == total else { return }
        lastSent = now
        client?.flashProgress(phase: currentPhase.rawValue, bytesDone: done, bytesTotal: total)
    }
}
