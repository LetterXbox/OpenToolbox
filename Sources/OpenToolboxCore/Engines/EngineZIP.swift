import Compression
import Darwin
import Foundation

/// Extracts regular files and directories from pinned, single-volume ZIP archives.
/// Layout and limits are checked before writes. Only this code creates filesystem entries;
/// neither ZIP metadata nor a separate extractor can create links or special files.
enum EngineZIP {
    private static let maxEntries = 4_096
    private static let maxExpandedBytes = 2 * 1_024 * 1_024 * 1_024
    private static let chunkSize = 64 * 1_024
    // Allow DEFLATE options and UTF-8. Data descriptors are unsupported.
    private static let allowedFlags = UInt16(0x0806)

    private struct Member {
        let components: [String]
        let isDirectory: Bool
        let method: UInt16
        let size: Int
        let compressedSize: Int
        let offset: Int
        let crc32: UInt32
    }

    private struct CRC32 {
        // ZIP uses the reflected IEEE CRC-32 polynomial.
        private static let table = (0..<256).map { index in
            var remainder = UInt32(index)
            for _ in 0..<8 {
                let polynomial: UInt32 = remainder & 1 == 0 ? 0 : 0xedb8_8320
                remainder = (remainder >> 1) ^ polynomial
            }
            return remainder
        }

        private var state = UInt32.max

        var checksum: UInt32 { self.state ^ UInt32.max }

        mutating func update(_ bytes: UnsafeRawBufferPointer) {
            for byte in bytes {
                let index = Int((self.state ^ UInt32(byte)) & 0xff)
                self.state = Self.table[index] ^ (self.state >> 8)
            }
        }
    }

    static func extract(_ archive: FileHandle, size: Int64, into directory: EngineDirectory,
                        didExtractChunk: () throws -> Void) throws {
        let members = try Self.readDirectory(archive, size: size)
        for member in members {
            try Task.checkCancellation()
            let parts = member.components
            let parent = try directory.parent(of: parts, create: true)
            let name = parts[parts.count - 1]
            if member.isDirectory {
                _ = try parent.directory(name, create: true)
                continue
            }
            let output = try parent.createFile(name)
            try archive.seek(toOffset: UInt64(member.offset))
            var crc = CRC32()
            if member.method == 0 {
                var remaining = member.size
                while remaining > 0 {
                    let bytes = try Self.read(archive, min(remaining, Self.chunkSize))
                    try output.write(contentsOf: bytes)
                    bytes.withUnsafeBytes { crc.update($0) }
                    remaining -= bytes.count
                    try didExtractChunk()
                }
            } else {
                try Self.inflate(member, from: archive, into: output, crc: &crc, didExtractChunk: didExtractChunk)
            }
            try output.close()
            guard crc.checksum == member.crc32 else { throw EngineStoreError.invalidArchive }
        }
        let device = try directory.metadata().st_dev
        var entries = 0
        var bytes: Int64 = 0
        try Self.verify(directory, device: device, depth: 0, entries: &entries, bytes: &bytes)
    }

    private static func readDirectory(_ archive: FileHandle, size: Int64) throws -> [Member] {
        // ZIP64 and multi-disk archives are outside the supported limits.
        guard size >= 22, size < Int64(UInt32.max) else { throw EngineStoreError.invalidArchive }
        let tailSize = min(Int(size), 22 + Int(UInt16.max))
        let tailOffset = Int(size) - tailSize
        try archive.seek(toOffset: UInt64(tailOffset))
        let tail = try Self.read(archive, tailSize)
        guard let eocd = (0...(tailSize - 22)).reversed().first(where: {
            Self.u32(tail, $0) == 0x06054b50 && $0 + 22 + Int(Self.u16(tail, $0 + 20)) == tailSize
        }) else { throw EngineStoreError.invalidArchive }
        let count = Int(Self.u16(tail, eocd + 10))
        let directorySize = Int(Self.u32(tail, eocd + 12))
        let directoryStart = Int(Self.u32(tail, eocd + 16))
        let directoryEnd = tailOffset + eocd
        guard Self.u16(tail, eocd + 4) == 0, Self.u16(tail, eocd + 6) == 0,
              Int(Self.u16(tail, eocd + 8)) == count,
              directoryStart + directorySize == directoryEnd else { throw EngineStoreError.invalidArchive }
        guard count <= Self.maxEntries else { throw EngineStoreError.archiveLimitExceeded }

        var members: [Member] = []
        var ranges: [Range<Int>] = []
        var nextRecord = directoryStart
        var expandedBytes = 0
        var explicitPaths: Set<String> = []
        var files: Set<String> = []
        var directories: Set<String> = []
        for _ in 0..<count {
            try Task.checkCancellation()
            guard nextRecord + 46 <= directoryEnd else { throw EngineStoreError.invalidArchive }
            try archive.seek(toOffset: UInt64(nextRecord))
            let record = try Self.read(archive, 46)
            let flags = Self.u16(record, 8)
            let method = Self.u16(record, 10)
            let crc32 = Self.u32(record, 16)
            let compressed = Int(Self.u32(record, 20))
            let expanded = Int(Self.u32(record, 24))
            let nameLength = Int(Self.u16(record, 28))
            let extrasLength = Int(Self.u16(record, 30))
            let commentLength = Int(Self.u16(record, 32))
            let attrs = Self.u32(record, 38)
            let localOffset = Int(Self.u32(record, 42))
            nextRecord += 46 + nameLength + extrasLength + commentLength

            guard Self.u32(record, 0) == 0x02014b50, nextRecord <= directoryEnd,
                  flags & ~Self.allowedFlags == 0, method == 0 || method == 8,
                  Self.u16(record, 34) == 0, compressed < Int(UInt32.max), expanded < Int(UInt32.max),
                  nameLength > 0, nameLength <= 1_024, localOffset + 30 <= directoryStart,
                  method != 0 || compressed == expanded else { throw EngineStoreError.invalidArchive }

            let name = try Self.read(archive, nameLength)
            let isDirectory = name.last == 0x2f
            let pathBytes = isDirectory ? name.dropLast() : name
            guard let path = String(validating: pathBytes, as: UTF8.self) else { throw EngineStoreError.invalidArchive }
            let type = mode_t(truncatingIfNeeded: attrs >> 16) & S_IFMT
            guard let components = EngineStore.relativePathComponents(pathBytes),
                  type == 0 || type == (isDirectory ? S_IFDIR : S_IFREG),
                  attrs & 0x10 == 0 || isDirectory else { throw EngineStoreError.unsafeArchivePath(path) }
            guard !isDirectory || (method == 0 && expanded == 0 && crc32 == 0) else {
                throw EngineStoreError.invalidArchive
            }
            let normalizedParts = components.map { $0.precomposedStringWithCanonicalMapping.lowercased() }
            let normalized = normalizedParts.joined(separator: "/")
            guard explicitPaths.insert(normalized).inserted else { throw EngineStoreError.unsafeArchivePath(path) }
            if !isDirectory { files.insert(normalized) }
            var prefix = ""
            let directoryParts = isDirectory ? normalizedParts[...] : normalizedParts.dropLast()
            for part in directoryParts {
                if !prefix.isEmpty { prefix.append("/") }
                prefix.append(contentsOf: part)
                directories.insert(prefix)
                guard directories.count <= Self.maxEntries else { throw EngineStoreError.archiveLimitExceeded }
            }
            expandedBytes += expanded
            guard expandedBytes <= Self.maxExpandedBytes else { throw EngineStoreError.archiveLimitExceeded }

            try archive.seek(toOffset: UInt64(localOffset))
            let local = try Self.read(archive, 30)
            let offset = localOffset + 30 + nameLength + Int(Self.u16(local, 28))
            guard Self.u32(local, 0) == 0x04034b50, Self.u16(local, 6) == flags, Self.u16(local, 8) == method,
                  Int(Self.u16(local, 26)) == nameLength, offset + compressed <= directoryStart,
                  Self.u32(local, 14) == crc32, Int(Self.u32(local, 18)) == compressed,
                  Int(Self.u32(local, 22)) == expanded,
                  try Self.read(archive, nameLength) == name else { throw EngineStoreError.invalidArchive }
            ranges.append(localOffset..<(offset + compressed))
            members.append(Member(components: components, isDirectory: isDirectory, method: method, size: expanded,
                                  compressedSize: compressed, offset: offset, crc32: crc32))
        }
        let ordered = ranges.sorted { $0.lowerBound < $1.lowerBound }
        guard nextRecord == directoryEnd,
              !zip(ordered, ordered.dropFirst()).contains(where: { $0.0.upperBound > $0.1.lowerBound }),
              files.isDisjoint(with: directories) else { throw EngineStoreError.invalidArchive }
        guard files.count + directories.count <= Self.maxEntries else { throw EngineStoreError.archiveLimitExceeded }
        return members
    }

    private static func inflate(_ member: Member, from archive: FileHandle, into output: FileHandle, crc: inout CRC32,
                                didExtractChunk: () throws -> Void) throws {
        guard member.compressedSize > 0 else { throw EngineStoreError.invalidArchive }
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK
        else { throw EngineStoreError.invalidArchive }
        defer { _ = compression_stream_destroy(stream) }
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.chunkSize)
        defer { destination.deallocate() }

        var remaining = member.compressedSize
        var bytesWritten = 0
        var ended = false
        while remaining > 0 {
            let chunk = try Self.read(archive, min(remaining, Self.chunkSize))
            remaining -= chunk.count
            let flags = remaining == 0 ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            try chunk.withUnsafeBytes { source in
                stream.pointee.src_ptr = source.bindMemory(to: UInt8.self).baseAddress!
                stream.pointee.src_size = source.count
                repeat {
                    let available = stream.pointee.src_size
                    stream.pointee.dst_ptr = destination
                    stream.pointee.dst_size = Self.chunkSize
                    let status = compression_stream_process(stream, flags)
                    let produced = Self.chunkSize - stream.pointee.dst_size
                    guard status == COMPRESSION_STATUS_OK || status == COMPRESSION_STATUS_END,
                          bytesWritten + produced <= member.size else { throw EngineStoreError.invalidArchive }
                    if produced > 0 {
                        try output.write(contentsOf: Data(bytes: destination, count: produced))
                        crc.update(UnsafeRawBufferPointer(start: destination, count: produced))
                        bytesWritten += produced
                    }
                    try didExtractChunk()
                    if status == COMPRESSION_STATUS_END {
                        guard remaining == 0, stream.pointee.src_size == 0 else { throw EngineStoreError.invalidArchive }
                        ended = true
                        break
                    }
                    guard produced > 0 || stream.pointee.src_size < available else { throw EngineStoreError.invalidArchive }
                } while stream.pointee.src_size > 0 || remaining == 0
            }
        }
        guard ended, bytesWritten == member.size else { throw EngineStoreError.invalidArchive }
    }

    private static func verify(_ directory: EngineDirectory, device: dev_t, depth: Int,
                               entries: inout Int, bytes: inout Int64) throws {
        guard depth <= 32 else { throw EngineStoreError.archiveLimitExceeded }
        try directory.forEachEntry { name in
            try Task.checkCancellation()
            entries += 1
            guard entries <= Self.maxEntries else { throw EngineStoreError.archiveLimitExceeded }
            guard let info = try directory.metadata(name), info.st_dev == device else {
                throw EngineStoreError.unsafeArchivePath(name)
            }
            switch EngineDirectory.type(of: info) {
            case S_IFDIR:
                let child = try directory.directory(name)
                guard try child.isSameDirectory(as: info) else { throw EngineStoreError.unsafeArchivePath(name) }
                try Self.verify(child, device: device, depth: depth + 1, entries: &entries, bytes: &bytes)
            case S_IFREG where info.st_nlink == 1:
                bytes += info.st_size
                guard bytes <= Int64(Self.maxExpandedBytes) else { throw EngineStoreError.archiveLimitExceeded }
            default:
                throw EngineStoreError.unsafeArchivePath(name)
            }
        }
    }

    private static func read(_ handle: FileHandle, _ count: Int) throws -> Data {
        var data = Data()
        while data.count < count {
            guard let bytes = try handle.read(upToCount: count - data.count), !bytes.isEmpty else {
                throw EngineStoreError.invalidArchive
            }
            data.append(bytes)
        }
        return data
    }

    private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(Self.u16(data, offset)) | (UInt32(Self.u16(data, offset + 2)) << 16)
    }
}
