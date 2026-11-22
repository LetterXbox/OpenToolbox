import Compression
import Darwin
import Foundation

/// Extracts regular files and directories from pinned `.tar.xz` archives.
/// Only this code creates filesystem entries; symlinks, hardlinks, and special files are refused.
enum EngineTarXZ {
    private static let maxEntries = 4_096
    private static let maxExpandedBytes: Int64 = 2 * 1_024 * 1_024 * 1_024
    private static let chunkSize = 64 * 1_024
    private static let blockSize = 512

    static func extract(
        _ archive: FileHandle,
        size: Int64,
        into directory: EngineDirectory,
        didExtractChunk: () throws -> Void
    ) throws {
        guard size >= 32 else { throw EngineStoreError.invalidArchive }
        var parser = TarParser(root: directory, didExtractChunk: didExtractChunk)

        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_LZMA) == COMPRESSION_STATUS_OK
        else { throw EngineStoreError.invalidArchive }
        defer { _ = compression_stream_destroy(stream) }

        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.chunkSize)
        defer { destination.deallocate() }

        var remaining = size
        var ended = false
        while remaining > 0 {
            try Task.checkCancellation()
            let toRead = Int(min(remaining, Int64(Self.chunkSize)))
            guard let chunk = try archive.read(upToCount: toRead), !chunk.isEmpty else {
                throw EngineStoreError.invalidArchive
            }
            remaining -= Int64(chunk.count)
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
                    guard status == COMPRESSION_STATUS_OK || status == COMPRESSION_STATUS_END else {
                        throw EngineStoreError.invalidArchive
                    }
                    if produced > 0 {
                        try parser.feed(UnsafeBufferPointer(start: destination, count: produced))
                        try didExtractChunk()
                    }
                    if status == COMPRESSION_STATUS_END {
                        guard remaining == 0, stream.pointee.src_size == 0 else {
                            throw EngineStoreError.invalidArchive
                        }
                        ended = true
                        break
                    }
                    guard produced > 0 || stream.pointee.src_size < available else {
                        throw EngineStoreError.invalidArchive
                    }
                } while stream.pointee.src_size > 0 || remaining == 0
            }
        }
        guard ended else { throw EngineStoreError.invalidArchive }
        try parser.finish()

        let device = try directory.metadata().st_dev
        var entries = 0
        var bytes: Int64 = 0
        try Self.verify(directory, device: device, depth: 0, entries: &entries, bytes: &bytes)
    }

    private struct TarParser {
        private enum State {
            case header
            case fileBody(handle: FileHandle, remaining: Int64, padding: Int)
            case metadataBody(kind: UInt8, buffer: Data, remaining: Int, padding: Int)
            case skipPadding(remaining: Int)
            case trailer
        }

        let root: EngineDirectory
        let didExtractChunk: () throws -> Void
        private var state: State = .header
        private var headerBuffer = Data()
        private var nextPAXPath: String?
        private var nextPAXSize: Int64?
        private var nextLongName: String?
        private var explicitPaths: Set<String> = []
        private var files: Set<String> = []
        private var directories: Set<String> = []
        private var totalExpandedBytes: Int64 = 0

        init(root: EngineDirectory, didExtractChunk: @escaping () throws -> Void) {
            self.root = root
            self.didExtractChunk = didExtractChunk
        }

        mutating func feed(_ bytes: UnsafeBufferPointer<UInt8>) throws {
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                switch state {
                case .header:
                    let needed = EngineTarXZ.blockSize - headerBuffer.count
                    let take = min(needed, bytes.count - offset)
                    headerBuffer.append(bytes.baseAddress! + offset, count: take)
                    offset += take
                    if headerBuffer.count == EngineTarXZ.blockSize {
                        let block = headerBuffer
                        headerBuffer.removeAll(keepingCapacity: true)
                        try handleHeader(block)
                    }

                case .fileBody(let handle, var remaining, let padding):
                    let take = Int(min(remaining, Int64(bytes.count - offset)))
                    if take > 0 {
                        let data = Data(bytes: bytes.baseAddress! + offset, count: take)
                        try handle.write(contentsOf: data)
                        offset += take
                        remaining -= Int64(take)
                    }
                    if remaining == 0 {
                        try handle.close()
                        state = padding > 0 ? .skipPadding(remaining: padding) : .header
                    } else {
                        state = .fileBody(handle: handle, remaining: remaining, padding: padding)
                    }

                case .metadataBody(let kind, var buffer, var remaining, let padding):
                    let take = min(remaining, bytes.count - offset)
                    if take > 0 {
                        buffer.append(bytes.baseAddress! + offset, count: take)
                        offset += take
                        remaining -= take
                    }
                    if remaining == 0 {
                        try consumeMetadata(kind: kind, data: buffer)
                        state = padding > 0 ? .skipPadding(remaining: padding) : .header
                    } else {
                        state = .metadataBody(kind: kind, buffer: buffer, remaining: remaining, padding: padding)
                    }

                case .skipPadding(var remaining):
                    let take = min(remaining, bytes.count - offset)
                    offset += take
                    remaining -= take
                    state = remaining == 0 ? .header : .skipPadding(remaining: remaining)

                case .trailer:
                    for index in offset..<bytes.count {
                        guard bytes[index] == 0 else { throw EngineStoreError.invalidArchive }
                    }
                    offset = bytes.count
                }
            }
        }

        mutating func finish() throws {
            switch state {
            case .header:
                guard headerBuffer.isEmpty else { throw EngineStoreError.invalidArchive }
            case .trailer:
                break
            case .fileBody, .metadataBody, .skipPadding:
                throw EngineStoreError.invalidArchive
            }
            guard nextPAXPath == nil, nextPAXSize == nil, nextLongName == nil else {
                throw EngineStoreError.invalidArchive
            }
            guard files.isDisjoint(with: directories) else { throw EngineStoreError.invalidArchive }
        }

        private mutating func handleHeader(_ block: Data) throws {
            if block.allSatisfy({ $0 == 0 }) {
                state = .trailer
                return
            }
            guard let expectedChecksum = Self.parseOctal(block[148..<156]) else {
                throw EngineStoreError.invalidArchive
            }
            var actualChecksum: Int64 = 0
            for index in 0..<EngineTarXZ.blockSize {
                actualChecksum += (148..<156).contains(index) ? 32 : Int64(block[index])
            }
            guard actualChecksum == expectedChecksum else { throw EngineStoreError.invalidArchive }

            guard let headerSize = Self.parseSize(block[124..<136]) else {
                throw EngineStoreError.invalidArchive
            }
            let typeFlag = block[156]
            let size = nextPAXSize ?? headerSize
            guard size >= 0 else { throw EngineStoreError.invalidArchive }
            let padding = Int((Int64(EngineTarXZ.blockSize) - (size % Int64(EngineTarXZ.blockSize))) % Int64(EngineTarXZ.blockSize))

            switch typeFlag {
            case UInt8(ascii: "x"), UInt8(ascii: "g"), UInt8(ascii: "L"):
                guard size <= 64 * 1_024 else { throw EngineStoreError.archiveLimitExceeded }
                if size == 0 {
                    state = .header
                } else {
                    state = .metadataBody(kind: typeFlag, buffer: Data(capacity: Int(size)), remaining: Int(size), padding: padding)
                }
                return
            default:
                break
            }

            let rawPath: String
            if let paxPath = nextPAXPath {
                rawPath = paxPath
            } else if let longName = nextLongName {
                rawPath = longName
            } else {
                let name = Self.cString(block[0..<100])
                let magic = block[257..<262]
                let prefix = magic.elementsEqual("ustar".utf8) ? Self.cString(block[345..<500]) : ""
                rawPath = prefix.isEmpty ? name : "\(prefix)/\(name)"
            }
            nextPAXPath = nil
            nextPAXSize = nil
            nextLongName = nil

            let isDirectory = typeFlag == UInt8(ascii: "5")
            let isRegular = typeFlag == 0 || typeFlag == UInt8(ascii: "0")
            guard isDirectory || isRegular else { throw EngineStoreError.unsafeArchivePath(rawPath) }

            let cleaned = Self.stripLeadingDotSlash(rawPath, stripTrailingSlash: isDirectory)
            if cleaned.isEmpty && isDirectory {
                guard size == 0 else { throw EngineStoreError.invalidArchive }
                state = .header
                return
            }
            guard let components = EngineStore.relativePathComponents(cleaned.utf8) else {
                throw EngineStoreError.unsafeArchivePath(rawPath)
            }

            let normalizedParts = components.map { $0.precomposedStringWithCanonicalMapping.lowercased() }
            let normalized = normalizedParts.joined(separator: "/")
            guard explicitPaths.insert(normalized).inserted else { throw EngineStoreError.unsafeArchivePath(rawPath) }
            if !isDirectory { files.insert(normalized) }
            var prefix = ""
            let directoryParts = isDirectory ? normalizedParts[...] : normalizedParts.dropLast()
            for part in directoryParts {
                if !prefix.isEmpty { prefix.append("/") }
                prefix.append(contentsOf: part)
                directories.insert(prefix)
                guard directories.count <= EngineTarXZ.maxEntries else { throw EngineStoreError.archiveLimitExceeded }
            }
            guard files.count + directories.count <= EngineTarXZ.maxEntries else {
                throw EngineStoreError.archiveLimitExceeded
            }

            let parent = try root.parent(of: components, create: true)
            let name = components[components.count - 1]
            if isDirectory {
                guard size == 0 else { throw EngineStoreError.invalidArchive }
                _ = try parent.directory(name, create: true)
                state = .header
                return
            }

            let (newTotal, overflow) = totalExpandedBytes.addingReportingOverflow(size)
            guard !overflow, newTotal <= EngineTarXZ.maxExpandedBytes else {
                throw EngineStoreError.archiveLimitExceeded
            }
            totalExpandedBytes = newTotal

            let handle = try parent.createFile(name)
            if size == 0 {
                try handle.close()
                state = .header
            } else {
                state = .fileBody(handle: handle, remaining: size, padding: padding)
            }
        }

        private mutating func consumeMetadata(kind: UInt8, data: Data) throws {
            switch kind {
            case UInt8(ascii: "g"):
                return
            case UInt8(ascii: "L"):
                let trimmed = data.last == 0 ? data.dropLast() : data[...]
                guard let path = String(validating: trimmed, as: UTF8.self), !path.isEmpty else {
                    throw EngineStoreError.invalidArchive
                }
                nextLongName = path
            case UInt8(ascii: "x"):
                var cursor = data.startIndex
                while cursor < data.endIndex {
                    guard let space = data[cursor...].firstIndex(of: 0x20),
                          let lengthText = String(validating: data[cursor..<space], as: UTF8.self),
                          let recordLength = Int(lengthText), recordLength > 0,
                          cursor + recordLength <= data.endIndex else {
                        throw EngineStoreError.invalidArchive
                    }
                    let recordEnd = cursor + recordLength
                    guard data[recordEnd - 1] == 0x0a else { throw EngineStoreError.invalidArchive }
                    let body = data[(space + 1)..<(recordEnd - 1)]
                    if let equals = body.firstIndex(of: UInt8(ascii: "=")),
                       let key = String(validating: body[..<equals], as: UTF8.self),
                       let value = String(validating: body[(equals + 1)...], as: UTF8.self)
                    {
                        if key == "path" { nextPAXPath = value }
                        if key == "size" {
                            guard let parsed = Int64(value), parsed >= 0 else {
                                throw EngineStoreError.invalidArchive
                            }
                            nextPAXSize = parsed
                        }
                    }
                    cursor = recordEnd
                }
            default:
                throw EngineStoreError.invalidArchive
            }
        }

        private static func stripLeadingDotSlash(_ path: String, stripTrailingSlash: Bool) -> String {
            var value = path
            while value.hasPrefix("./") { value.removeFirst(2) }
            if value == "." { return "" }
            if stripTrailingSlash {
                while value.hasSuffix("/") { value.removeLast() }
            }
            return value
        }

        private static func cString(_ slice: Data.SubSequence) -> String {
            let end = slice.firstIndex(of: 0) ?? slice.endIndex
            return String(decoding: slice[..<end], as: UTF8.self)
        }

        private static func parseOctal(_ slice: Data.SubSequence) -> Int64? {
            let trimmed = slice.prefix { $0 != 0 }
            let text = String(decoding: trimmed, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return 0 }
            return Int64(text, radix: 8)
        }

        private static func parseSize(_ slice: Data.SubSequence) -> Int64? {
            if let first = slice.first, first & 0x80 != 0 {
                guard first == 0x80 else { return nil }
                var value: UInt64 = 0
                for byte in slice.dropFirst() {
                    if value > (UInt64(Int64.max) >> 8) { return nil }
                    value = (value << 8) | UInt64(byte)
                }
                return Int64(value)
            }
            return parseOctal(slice)
        }
    }

    private static func verify(
        _ directory: EngineDirectory,
        device: dev_t,
        depth: Int,
        entries: inout Int,
        bytes: inout Int64
    ) throws {
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
                guard bytes <= Self.maxExpandedBytes else { throw EngineStoreError.archiveLimitExceeded }
            default:
                throw EngineStoreError.unsafeArchivePath(name)
            }
        }
    }
}
