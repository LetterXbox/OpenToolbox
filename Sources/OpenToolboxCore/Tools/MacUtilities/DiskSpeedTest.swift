import Darwin
import Foundation

public enum DiskSpeedError: Error, Equatable, LocalizedError {
    case readOnly(String)
    case notEnoughSpace(needed: Int64, available: Int64)
    case cannotWrite(String)
    case ioFailed(String)

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

    public var id: URL { mountPoint }

    /// Local volumes, startup disk first. Hidden and network volumes are left out.
    public static func mounted() -> [SpeedTestVolume] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeLocalizedNameKey, .volumeIsReadOnlyKey, .volumeIsLocalKey, .volumeIsBrowsableKey,
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
                availableBytes: DiskSpeedTest.availableBytes(at: directory))
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
public enum DiskSpeedTest {
    public enum Phase: Sendable, Equatable {
        case writing
        case reading
    }

    public static let defaultBlockSize = 8 * 1024 * 1024
    /// Space left free on the volume beyond the test file.
    public static let reserveBytes: Int64 = 1024 * 1024 * 1024

    public static func availableBytes(at directory: URL) -> Int64? {
        let values = try? directory.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
        ])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }

    /// Throws when the volume can't hold the test file plus the reserve.
    public static func checkSpace(needed bytes: Int64, available: Int64?, reserve: Int64 = reserveBytes) throws {
        guard let available else { return }
        if available < bytes + reserve {
            throw DiskSpeedError.notEnoughSpace(needed: bytes + reserve, available: available)
        }
    }

    /// Runs the test in `directory`. Cancelling the calling task stops it with `CancellationError`.
    public static func run(
        in directory: URL, volumeName: String, bytes: Int64, blockSize: Int = defaultBlockSize,
        reserve: Int64 = reserveBytes, progress: @Sendable (Phase, Double) -> Void = { _, _ in }
    ) throws -> DiskSpeedResult {
        let values = try? directory.resourceValues(forKeys: [.volumeIsReadOnlyKey])
        if values?.volumeIsReadOnly == true { throw DiskSpeedError.readOnly(volumeName) }
        try checkSpace(needed: bytes, available: availableBytes(at: directory), reserve: reserve)

        let path = directory.appending(path: ".OpenToolbox-speed-test-\(UUID().uuidString)", directoryHint: .notDirectory).path
        let descriptor = open(path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw DiskSpeedError.cannotWrite(volumeName) }
        defer { close(descriptor) }
        unlink(path)
        _ = fcntl(descriptor, F_NOCACHE, 1)

        let size = max(blockSize, 4096)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16_384)
        defer { buffer.deallocate() }
        arc4random_buf(buffer, size)
        let total = max(bytes, Int64(size))

        let clock = ContinuousClock()
        let writeStart = clock.now
        try transfer(total, blockSize: size, phase: .writing, progress: progress) { offset, count in
            pwrite(descriptor, buffer, count, offset)
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
        _ io: (off_t, Int) -> Int
    ) throws {
        var offset: Int64 = 0
        progress(phase, 0)
        while offset < total {
            try Task.checkCancellation()
            let count = Int(min(Int64(blockSize), total - offset))
            let done = io(off_t(offset), count)
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
