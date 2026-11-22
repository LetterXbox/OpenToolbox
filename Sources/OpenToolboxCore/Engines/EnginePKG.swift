import Darwin
import Foundation
import zlib

/// Extracts selected regular files and directories from pinned macOS `.pkg` (XAR + gzip odc CPIO) archives.
/// Only this code creates filesystem entries; symlinks and special files in selected paths are refused.
enum EnginePKG {
    private static let maxTOCompressedBytes: Int64 = 16 * 1_024 * 1_024
    private static let maxTOCUncompressedBytes: Int64 = 64 * 1_024 * 1_024
    private static let maxStreamBytes: Int64 = 512 * 1_024 * 1_024
    private static let maxExpandedBytes: Int64 = 512 * 1_024 * 1_024
    private static let maxEntries = 4_096
    private static let chunkSize = 64 * 1_024

    static func extract(
        _ archive: FileHandle,
        size: Int64,
        payloadPath: String,
        includedPrefixes: [String],
        into directory: EngineDirectory,
        didExtractChunk: () throws -> Void
    ) throws {
        guard size >= 28 else { throw EngineStoreError.invalidArchive }
        let payloadComponents = payloadPath.split(separator: "/").map(String.init)
        guard !payloadComponents.isEmpty, !includedPrefixes.isEmpty else {
            throw EngineStoreError.invalidArchive
        }
        let normalizedPrefixes = includedPrefixes.map { Self.stripLeadingDotSlash($0, stripTrailingSlash: true) }
        guard normalizedPrefixes.allSatisfy({ !$0.isEmpty }) else { throw EngineStoreError.invalidArchive }

        try archive.seek(toOffset: 0)
        let header = try Self.readExact(archive, 28)
        guard header[0] == UInt8(ascii: "x"), header[1] == UInt8(ascii: "a"),
              header[2] == UInt8(ascii: "r"), header[3] == UInt8(ascii: "!") else {
            throw EngineStoreError.invalidArchive
        }
        let headerSize = Int64(Self.be16(header, 4))
        let version = Self.be16(header, 6)
        let tocCompressed = Int64(bitPattern: Self.be64(header, 8))
        let tocUncompressed = Int64(bitPattern: Self.be64(header, 16))
        guard version == 1, headerSize >= 28,
              tocCompressed > 0, tocCompressed <= Self.maxTOCompressedBytes,
              tocUncompressed > 0, tocUncompressed <= Self.maxTOCUncompressedBytes,
              headerSize + tocCompressed <= size else {
            throw EngineStoreError.invalidArchive
        }

        try archive.seek(toOffset: UInt64(headerSize))
        let compressedTOC = try Self.readExact(archive, Int(tocCompressed))
        let tocData = try Self.inflateZlib(compressedTOC, expectedSize: Int(tocUncompressed))
        let tocParser = XARTOCParser(targetComponents: payloadComponents)
        guard let payload = tocParser.parse(tocData) else { throw EngineStoreError.invalidArchive }

        let heapOffset = headerSize + tocCompressed
        let (payloadStart, startOverflow) = heapOffset.addingReportingOverflow(payload.offset)
        let (payloadEnd, endOverflow) = payloadStart.addingReportingOverflow(payload.length)
        guard !startOverflow, !endOverflow, payload.offset >= 0, payload.length > 0, payloadEnd <= size else {
            throw EngineStoreError.invalidArchive
        }

        try archive.seek(toOffset: UInt64(payloadStart))
        var cpio = OdcCPIOParser(root: directory, includedPrefixes: normalizedPrefixes)
        try Self.streamGunzip(from: archive, length: payload.length) { chunk in
            try cpio.feed(chunk)
            try didExtractChunk()
        }
        try cpio.finish()

        let device = try directory.metadata().st_dev
        var entries = 0
        var bytes: Int64 = 0
        try Self.verify(directory, device: device, depth: 0, entries: &entries, bytes: &bytes)
    }

    private struct PayloadLocation {
        let offset: Int64
        let length: Int64
    }

    private final class XARTOCParser: NSObject, XMLParserDelegate {
        private let targetComponents: [String]
        private var elementStack: [String] = []
        private var fileStack: [FileFrame] = []
        private var textBuffer = ""
        private var found: PayloadLocation?
        private var invalid = false

        private struct FileFrame {
            var name: String?
            var offset: Int64?
            var length: Int64?
            var inData = false
        }

        init(targetComponents: [String]) {
            self.targetComponents = targetComponents
        }

        func parse(_ data: Data) -> PayloadLocation? {
            let parser = XMLParser(data: data)
            parser.shouldResolveExternalEntities = false
            parser.delegate = self
            guard parser.parse(), !invalid else { return nil }
            return found
        }

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            elementStack.append(elementName)
            textBuffer = ""
            if elementName == "file" {
                fileStack.append(FileFrame())
            } else if elementName == "data", !fileStack.isEmpty {
                fileStack[fileStack.count - 1].inData = true
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            textBuffer.append(string)
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            defer {
                if !elementStack.isEmpty { elementStack.removeLast() }
                textBuffer = ""
            }
            guard !fileStack.isEmpty else { return }
            let lastIndex = fileStack.count - 1
            let trimmed = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if elementName == "name", elementStack.dropLast().last == "file" {
                fileStack[lastIndex].name = trimmed
            } else if elementName == "offset", fileStack[lastIndex].inData {
                fileStack[lastIndex].offset = Int64(trimmed)
            } else if elementName == "length", fileStack[lastIndex].inData {
                fileStack[lastIndex].length = Int64(trimmed)
            } else if elementName == "data" {
                fileStack[lastIndex].inData = false
            } else if elementName == "file" {
                let path = fileStack.compactMap(\.name)
                let frame = fileStack.removeLast()
                if path == targetComponents, let offset = frame.offset, let length = frame.length {
                    found = PayloadLocation(offset: offset, length: length)
                }
            }
        }

        func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
            invalid = true
        }
    }

    private struct OdcCPIOParser {
        private enum State {
            case header
            case name(mode: UInt32, nameSize: Int, fileSize: Int64)
            case fileBody(handle: FileHandle, remaining: Int64)
            case skipBody(remaining: Int64)
            case done
        }

        let root: EngineDirectory
        let includedPrefixes: [String]
        private var state: State = .header
        private var buffer = Data()
        private var totalStreamBytes: Int64 = 0
        private var totalExpandedBytes: Int64 = 0
        private var explicitPaths: Set<String> = []
        private var files: Set<String> = []
        private var directories: Set<String> = []

        init(root: EngineDirectory, includedPrefixes: [String]) {
            self.root = root
            self.includedPrefixes = includedPrefixes
        }

        mutating func feed(_ bytes: UnsafeBufferPointer<UInt8>) throws {
            let (streamTotal, streamOverflow) = totalStreamBytes.addingReportingOverflow(Int64(bytes.count))
            guard !streamOverflow, streamTotal <= EnginePKG.maxStreamBytes else {
                throw EngineStoreError.archiveLimitExceeded
            }
            totalStreamBytes = streamTotal

            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                switch state {
                case .header:
                    let needed = 76 - buffer.count
                    let take = min(needed, bytes.count - offset)
                    buffer.append(bytes.baseAddress! + offset, count: take)
                    offset += take
                    if buffer.count == 76 {
                        let header = buffer
                        buffer.removeAll(keepingCapacity: true)
                        try handleHeader(header)
                    }

                case .name(let mode, let nameSize, let fileSize):
                    let needed = nameSize - buffer.count
                    let take = min(needed, bytes.count - offset)
                    buffer.append(bytes.baseAddress! + offset, count: take)
                    offset += take
                    if buffer.count == nameSize {
                        let rawName = buffer
                        buffer.removeAll(keepingCapacity: true)
                        try handleEntry(rawName: rawName, mode: mode, fileSize: fileSize)
                    }

                case .fileBody(let handle, var remaining):
                    let take = Int(min(remaining, Int64(bytes.count - offset)))
                    if take > 0 {
                        try handle.write(contentsOf: Data(bytes: bytes.baseAddress! + offset, count: take))
                        offset += take
                        remaining -= Int64(take)
                    }
                    if remaining == 0 {
                        try handle.close()
                        state = .header
                    } else {
                        state = .fileBody(handle: handle, remaining: remaining)
                    }

                case .skipBody(var remaining):
                    let take = Int(min(remaining, Int64(bytes.count - offset)))
                    offset += take
                    remaining -= Int64(take)
                    state = remaining == 0 ? .header : .skipBody(remaining: remaining)

                case .done:
                    offset = bytes.count
                }
            }
        }

        mutating func finish() throws {
            guard case .done = state else { throw EngineStoreError.invalidArchive }
            guard files.isDisjoint(with: directories) else { throw EngineStoreError.invalidArchive }
        }

        private mutating func handleHeader(_ header: Data) throws {
            guard header[0..<6].elementsEqual("070707".utf8),
                  let mode = Self.parseOctal(header[18..<24]),
                  let nameSize = Self.parseOctal(header[59..<65]),
                  let fileSize = Self.parseOctal(header[65..<76]),
                  nameSize > 0, nameSize <= 4_096, fileSize >= 0 else {
                throw EngineStoreError.invalidArchive
            }
            state = .name(mode: UInt32(mode), nameSize: Int(nameSize), fileSize: fileSize)
        }

        private mutating func handleEntry(rawName: Data, mode: UInt32, fileSize: Int64) throws {
            guard rawName.last == 0 else { throw EngineStoreError.invalidArchive }
            guard let name = String(validating: rawName.dropLast(), as: UTF8.self) else {
                throw EngineStoreError.invalidArchive
            }
            if name == "TRAILER!!!" {
                state = .done
                return
            }

            let fileType = mode_t(mode) & S_IFMT
            let isDirectory = fileType == S_IFDIR
            let cleaned = EnginePKG.stripLeadingDotSlash(name, stripTrailingSlash: isDirectory)
            guard matchesIncludedPrefix(cleaned) else {
                state = fileSize > 0 ? .skipBody(remaining: fileSize) : .header
                return
            }

            let isRegular = fileType == S_IFREG
            guard isDirectory || isRegular else { throw EngineStoreError.unsafeArchivePath(name) }
            guard let components = EngineStore.relativePathComponents(cleaned.utf8) else {
                throw EngineStoreError.unsafeArchivePath(name)
            }

            let normalizedParts = components.map { $0.precomposedStringWithCanonicalMapping.lowercased() }
            let normalized = normalizedParts.joined(separator: "/")
            guard explicitPaths.insert(normalized).inserted else { throw EngineStoreError.unsafeArchivePath(name) }
            if !isDirectory { files.insert(normalized) }
            var prefix = ""
            let directoryParts = isDirectory ? normalizedParts[...] : normalizedParts.dropLast()
            for part in directoryParts {
                if !prefix.isEmpty { prefix.append("/") }
                prefix.append(contentsOf: part)
                directories.insert(prefix)
                guard directories.count <= EnginePKG.maxEntries else { throw EngineStoreError.archiveLimitExceeded }
            }
            guard files.count + directories.count <= EnginePKG.maxEntries else {
                throw EngineStoreError.archiveLimitExceeded
            }

            let parent = try root.parent(of: components, create: true)
            let entryName = components[components.count - 1]
            if isDirectory {
                guard fileSize == 0 else { throw EngineStoreError.invalidArchive }
                _ = try parent.directory(entryName, create: true)
                state = .header
                return
            }

            let (newTotal, overflow) = totalExpandedBytes.addingReportingOverflow(fileSize)
            guard !overflow, newTotal <= EnginePKG.maxExpandedBytes else {
                throw EngineStoreError.archiveLimitExceeded
            }
            totalExpandedBytes = newTotal

            let handle = try parent.createFile(entryName)
            if fileSize == 0 {
                try handle.close()
                state = .header
            } else {
                state = .fileBody(handle: handle, remaining: fileSize)
            }
        }

        private func matchesIncludedPrefix(_ path: String) -> Bool {
            guard !path.isEmpty else { return false }
            return includedPrefixes.contains { prefix in
                path == prefix || path.hasPrefix(prefix + "/")
            }
        }

        private static func parseOctal(_ slice: Data.SubSequence) -> Int64? {
            guard let text = String(validating: slice, as: UTF8.self) else { return nil }
            return Int64(text, radix: 8)
        }
    }

    private static func inflateZlib(_ input: Data, expectedSize: Int) throws -> Data {
        var stream = z_stream()
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw EngineStoreError.invalidArchive
        }
        defer { inflateEnd(&stream) }

        var output = Data(count: expectedSize)
        var status: Int32 = Z_OK
        let produced: Int = input.withUnsafeBytes { src in
            output.withUnsafeMutableBytes { dst in
                stream.next_in = UnsafeMutablePointer(mutating: src.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(src.count)
                stream.next_out = dst.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(dst.count)
                status = inflate(&stream, Z_FINISH)
                return Int(stream.total_out)
            }
        }
        guard status == Z_STREAM_END, produced == expectedSize else { throw EngineStoreError.invalidArchive }
        return output
    }

    private static func streamGunzip(
        from archive: FileHandle,
        length: Int64,
        receive: (UnsafeBufferPointer<UInt8>) throws -> Void
    ) throws {
        var stream = z_stream()
        guard inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw EngineStoreError.invalidArchive
        }
        defer { inflateEnd(&stream) }

        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.chunkSize)
        defer { destination.deallocate() }

        var remaining = length
        var ended = false
        while remaining > 0 {
            try Task.checkCancellation()
            let toRead = Int(min(remaining, Int64(Self.chunkSize)))
            guard let chunk = try archive.read(upToCount: toRead), !chunk.isEmpty else {
                throw EngineStoreError.invalidArchive
            }
            remaining -= Int64(chunk.count)
            try chunk.withUnsafeBytes { src in
                stream.next_in = UnsafeMutablePointer(mutating: src.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(src.count)
                while stream.avail_in > 0 && !ended {
                    stream.next_out = destination
                    stream.avail_out = uInt(Self.chunkSize)
                    let status = inflate(&stream, Z_NO_FLUSH)
                    let produced = Self.chunkSize - Int(stream.avail_out)
                    guard status == Z_OK || status == Z_STREAM_END else {
                        throw EngineStoreError.invalidArchive
                    }
                    if produced > 0 {
                        try receive(UnsafeBufferPointer(start: destination, count: produced))
                    }
                    if status == Z_STREAM_END {
                        ended = true
                    }
                }
            }
            if ended {
                guard remaining == 0, stream.avail_in == 0 else { throw EngineStoreError.invalidArchive }
                break
            }
        }
        guard ended else { throw EngineStoreError.invalidArchive }
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

    private static func readExact(_ handle: FileHandle, _ count: Int) throws -> Data {
        var data = Data()
        while data.count < count {
            guard let chunk = try handle.read(upToCount: count - data.count), !chunk.isEmpty else {
                throw EngineStoreError.invalidArchive
            }
            data.append(chunk)
        }
        return data
    }

    private static func be16(_ data: Data, _ offset: Int) -> UInt16 {
        (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    private static func be64(_ data: Data, _ offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 {
            value = (value << 8) | UInt64(data[offset + index])
        }
        return value
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
