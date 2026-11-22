import Darwin
import Foundation

public enum DiskSpeedError: Error, Equatable, LocalizedError {
    case readOnly(String)
    case notEnoughSpace(needed: Int64, available: Int64)
    case cannotWrite(String)
    case ioFailed(String)
    case alreadyRunning
    case spaceUnknown(String)
    case cacheBypassUnavailable(String)
    case volumeChanged(String)
    case cleanupFailed(path: String)

    public var errorDescription: String? {
        switch self {
        case .readOnly(let name):
            coreLocalized("“\(name)” is read-only, so its speed can't be tested.")
        case .notEnoughSpace(let needed, let available):
            coreLocalized(
                "The test needs \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)) free, but only \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) is available."
            )
        case .cannotWrite(let name):
            coreLocalized("OpenToolbox can't write a test file on “\(name)”.")
        case .ioFailed(let message):
            coreLocalized("The test stopped: \(message)")
        case .alreadyRunning:
            coreLocalized("Another disk speed test is running. Wait for it to finish, then try again.")
        case .spaceUnknown(let name):
            coreLocalized("OpenToolbox can't tell how much space is free on “\(name)”, so it won't write a test file there.")
        case .cacheBypassUnavailable(let name):
            coreLocalized("“\(name)” doesn't let OpenToolbox bypass the file cache, so the result wouldn't measure the disk.")
        case .volumeChanged(let name):
            coreLocalized("“\(name)” is no longer the drive you chose. Refresh the volume list and choose it again.")
        case .cleanupFailed(let path):
            coreLocalized("OpenToolbox couldn't remove its test file. Delete it yourself: \(path)")
        }
    }
}

/// A mounted volume that can be speed-tested.
public struct SpeedTestVolume: Identifiable, Hashable, Sendable {
    public let name: String
    public let mountPoint: URL
    /// Where the test file is created: the volume's root, or the temporary folder on the startup disk.
    public let testDirectory: URL
    public let isReadOnly: Bool
    public let availableBytes: Int64?
    /// Identifies the volume, so a different drive mounted at the same path is not tested by mistake.
    public let volumeUUID: String?

    public var id: URL { mountPoint }

    /// Local volumes, startup disk first. Hidden and network volumes are left out.
    public static func mounted() -> [SpeedTestVolume] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeLocalizedNameKey, .volumeIsReadOnlyKey, .volumeIsLocalKey, .volumeIsBrowsableKey,
            .volumeUUIDStringKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        let volumes = urls.compactMap { url -> SpeedTestVolume? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.volumeIsLocal != false,
                values.volumeIsBrowsable != false
            else { return nil }
            // The startup disk's root is the sealed, read-only system volume; its data volume holds the temporary folder.
            let isStartup = url.path == "/"
            let directory = isStartup ? FileManager.default.temporaryDirectory : url
            let isReadOnly = isStartup
                ? (try? directory.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
                : values.volumeIsReadOnly ?? false
            return SpeedTestVolume(
                name: values.volumeLocalizedName ?? values.volumeName ?? url.lastPathComponent,
                mountPoint: url, testDirectory: directory, isReadOnly: isReadOnly,
                availableBytes: DiskSpeedTest.availableBytes(at: directory),
                volumeUUID: DiskSpeedTest.volumeUUID(of: directory))
        }
        return volumes.sorted { lhs, rhs in
            if lhs.mountPoint.path == "/" { return true }
            if rhs.mountPoint.path == "/" { return false }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}

public struct DiskSpeedResult: Equatable, Sendable {
    public let bytes: Int64
    public let writeBytesPerSecond: Double
    public let readBytesPerSecond: Double
}

/// Sequential write then read of one test file, bypassing the file cache.
///
/// The test file is unlinked as soon as it is created, so it never shows up in the folder and
/// its space is returned when the test ends, even if OpenToolbox quits or crashes mid-test.
/// Only one test runs at a time, and free space is checked again while writing.
public enum DiskSpeedTest {
    public enum Phase: Sendable, Equatable {
        case writing
        case reading
    }

    public static let defaultBlockSize = 8 * 1024 * 1024
    /// Space left free on the volume beyond the test file.
    public static let reserveBytes: Int64 = 1024 * 1024 * 1024

    /// Space that can be written right now, not counting purgeable space.
    public static func availableBytes(at directory: URL) -> Int64? {
        var stats = statfs()
        guard statfs(directory.path, &stats) == 0 else { return nil }
        return Int64(stats.f_bavail) * Int64(stats.f_bsize)
    }

    static func volumeUUID(of directory: URL) -> String? {
        (try? directory.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
    }

    /// Throws when the volume can't hold the test file plus the reserve, or its free space is unknown.
    public static func checkSpace(
        needed bytes: Int64, available: Int64?, reserve: Int64 = reserveBytes, volumeName: String = ""
    ) throws {
        guard let available else { throw DiskSpeedError.spaceUnknown(volumeName) }
        if available < bytes + reserve {
            throw DiskSpeedError.notEnoughSpace(needed: bytes + reserve, available: available)
        }
    }

    private static let runLock = NSLock()
    nonisolated(unsafe) private static var isRunning = false

    /// Claims the single test slot. Returns `false` when another test holds it.
    static func claim() -> Bool {
        runLock.withLock {
            guard !isRunning else { return false }
            isRunning = true
            return true
        }
    }

    static func release() {
        runLock.withLock { isRunning = false }
    }

    /// Runs the test in `directory`. Cancelling the calling task stops it with `CancellationError`.
    /// `expectedVolumeUUID`, when given, must match the volume `directory` is on.
    public static func run(
        in directory: URL, volumeName: String, expectedVolumeUUID: String? = nil, bytes: Int64,
        blockSize: Int = defaultBlockSize, reserve: Int64 = reserveBytes,
        progress: @Sendable (Phase, Double) -> Void = { _, _ in }
    ) throws -> DiskSpeedResult {
        guard claim() else { throw DiskSpeedError.alreadyRunning }
        defer { release() }

        let values = try? directory.resourceValues(forKeys: [.volumeIsReadOnlyKey])
        if values?.volumeIsReadOnly == true { throw DiskSpeedError.readOnly(volumeName) }
        if let expectedVolumeUUID, volumeUUID(of: directory) != expectedVolumeUUID {
            throw DiskSpeedError.volumeChanged(volumeName)
        }
        var directoryStat = stat()
        guard stat(directory.path, &directoryStat) == 0 else { throw DiskSpeedError.cannotWrite(volumeName) }
        try checkSpace(needed: bytes, available: availableBytes(at: directory), reserve: reserve, volumeName: volumeName)

        let path = directory.appending(path: ".OpenToolbox-speed-test-\(UUID().uuidString)", directoryHint: .notDirectory).path
        let descriptor = open(path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw DiskSpeedError.cannotWrite(volumeName) }
        defer { close(descriptor) }
        guard unlink(path) == 0 else { throw DiskSpeedError.cleanupFailed(path: path) }
        var fileStat = stat()
        guard fstat(descriptor, &fileStat) == 0, fileStat.st_dev == directoryStat.st_dev else {
            throw DiskSpeedError.volumeChanged(volumeName)
        }
        guard fcntl(descriptor, F_NOCACHE, 1) == 0 else { throw DiskSpeedError.cacheBypassUnavailable(volumeName) }

        let size = max(blockSize, 4096)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16_384)
        defer { buffer.deallocate() }
        arc4random_buf(buffer, size)
        let total = max(bytes, Int64(size))

        let clock = ContinuousClock()
        let writeStart = clock.now
        let spaceCheckInterval = Int64(size) * 8
        try transfer(total, blockSize: size, phase: .writing, progress: progress) { offset, count in
            if offset % spaceCheckInterval == 0 {
                let remaining = total - offset
                if let available = availableBytes(at: directory), available - remaining < reserve {
                    throw DiskSpeedError.notEnoughSpace(needed: remaining + reserve, available: available)
                }
            }
            return pwrite(descriptor, buffer, count, offset)
        }
        guard fcntl(descriptor, F_FULLFSYNC) == 0 || fsync(descriptor) == 0 else {
            throw DiskSpeedError.ioFailed(String(cString: strerror(errno)))
        }
        let writeTime = writeStart.duration(to: clock.now)

        let readStart = clock.now
        try transfer(total, blockSize: size, phase: .reading, progress: progress) { offset, count in
            pread(descriptor, buffer, count, offset)
        }
        let readTime = readStart.duration(to: clock.now)

        return DiskSpeedResult(
            bytes: total, writeBytesPerSecond: rate(total, writeTime), readBytesPerSecond: rate(total, readTime))
    }

    private static func transfer(
        _ total: Int64, blockSize: Int, phase: Phase, progress: @Sendable (Phase, Double) -> Void,
        _ io: (off_t, Int) throws -> Int
    ) throws {
        var offset: Int64 = 0
        progress(phase, 0)
        while offset < total {
            try Task.checkCancellation()
            let count = Int(min(Int64(blockSize), total - offset))
            let done = try io(off_t(offset), count)
            if done < 0 {
                if errno == EINTR { continue }
                throw DiskSpeedError.ioFailed(String(cString: strerror(errno)))
            }
            guard done > 0 else { throw DiskSpeedError.ioFailed(coreLocalized("The disk stopped responding.")) }
            offset += Int64(done)
            progress(phase, Double(offset) / Double(total))
        }
    }

    static func rate(_ bytes: Int64, _ duration: Duration) -> Double {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        return Double(bytes) / max(seconds, 1e-6)
    }
}
