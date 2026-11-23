import Compression
import Darwin
import Foundation
import Testing
import zlib

@testable import OpenToolboxCore

@Suite("Engine catalog & archive extractors")
struct EngineArchiveTests {
    @Test func catalogEnginesAreAllPinnedForBothArchitectures() {
        #expect(EngineCatalog.all.count == 5)
        for manifest in EngineCatalog.all {
            #expect(EngineManifest.isValidID(manifest.id))
            #expect(manifest.version != nil)
            for arch in CPUArchitecture.allCases {
                let artifact = manifest.artifact(for: arch)
                #expect(artifact != nil, "Missing \(arch.rawValue) artifact for \(manifest.id)")
                if let artifact {
                    #expect(artifact.url.scheme?.lowercased() == "https")
                    #expect(artifact.sizeBytes > 0)
                    #expect(artifact.sha256.count == 64)
                    #expect(artifact.sha256.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) })
                }
            }
        }
    }

    @Test func tarXzInstallsRegularFilesAndMarksExecutable() async throws {
        try await withTemporaryDirectory { directory in
            let binary = Data("#!/bin/sh\necho ok\n".utf8)
            let tar = Self.makeTar(entries: [
                (name: "docs/", typeFlag: UInt8(ascii: "5"), data: Data()),
                (name: "docs/readme.txt", typeFlag: UInt8(ascii: "0"), data: Data("hello".utf8)),
                (name: "7zz", typeFlag: UInt8(ascii: "0"), data: binary),
            ])
            let compressed = try Self.compressXZ(tar)
            let fixture = directory.appending(path: "test.tar.xz")
            try compressed.write(to: fixture)
            let sha = HashGenerator.hash(compressed, algorithm: .sha256)

            let url = URL(string: "https://downloads.example.invalid/test.tar.xz")!
            let store = EngineStore(
                rootDirectory: directory.appending(path: "engines", directoryHint: .isDirectory),
                downloader: LocalFileDownloader(files: [url: fixture])
            )
            let manifest = EngineManifest(
                id: "tar-test",
                displayName: "TarTest",
                summary: "Test",
                license: "MIT",
                homepage: URL(string: "https://example.invalid")!,
                version: "1.0",
                artifacts: [
                    EngineArtifact(
                        architecture: .current,
                        url: url,
                        sha256: sha,
                        sizeBytes: Int64(compressed.count),
                        payload: .tarXz(executablePath: "7zz")
                    )
                ]
            )
            _ = try await store.install(manifest)
            let exe = try #require(store.executableURL(for: manifest))
            #expect(FileManager.default.isExecutableFile(atPath: exe.path))
            #expect(try Data(contentsOf: exe) == binary)
        }
    }

    @Test func tarXzRejectsSymlinksAndTraversal() async throws {
        for badEntry in [
            (name: "link", typeFlag: UInt8(ascii: "2"), data: Data()),
            (name: "../escape", typeFlag: UInt8(ascii: "0"), data: Data("x".utf8)),
        ] {
            try await withTemporaryDirectory { directory in
                let tar = Self.makeTar(entries: [
                    badEntry,
                    (name: "7zz", typeFlag: UInt8(ascii: "0"), data: Data("bin".utf8)),
                ])
                let compressed = try Self.compressXZ(tar)
                let fixture = directory.appending(path: "bad.tar.xz")
                try compressed.write(to: fixture)
                let sha = HashGenerator.hash(compressed, algorithm: .sha256)
                let url = URL(string: "https://downloads.example.invalid/bad.tar.xz")!
                let store = EngineStore(
                    rootDirectory: directory.appending(path: "engines", directoryHint: .isDirectory),
                    downloader: LocalFileDownloader(files: [url: fixture])
                )
                let manifest = EngineManifest(
                    id: "tar-bad",
                    displayName: "Bad",
                    summary: "Test",
                    license: "MIT",
                    homepage: URL(string: "https://example.invalid")!,
                    version: "1.0",
                    artifacts: [
                        EngineArtifact(
                            architecture: .current,
                            url: url,
                            sha256: sha,
                            sizeBytes: Int64(compressed.count),
                            payload: .tarXz(executablePath: "7zz")
                        )
                    ]
                )
                await #expect(throws: EngineStoreError.self) {
                    try await store.install(manifest)
                }
            }
        }
    }

    @Test func pkgExtractsOnlySelectedPrefixesAndIgnoresOtherEntries() async throws {
        try await withTemporaryDirectory { directory in
            let gsBinary = Data("#!/bin/sh\necho gs\n".utf8)
            let cpio = Self.makeOdcCPIO(entries: [
                (name: ".", mode: S_IFDIR | 0o755, data: Data()),
                (name: "./usr/local/bin/other-link", mode: S_IFLNK | 0o777, data: Data("/etc/passwd".utf8)),
                (name: "./usr/local/bin/gs-noX11", mode: S_IFREG | 0o755, data: gsBinary),
                (name: "./usr/local/bin/._gs-noX11", mode: S_IFREG | 0o644, data: Data([0x00, 0x05, 0x16, 0x07])),
                (name: "./usr/local/bin/gs-X11", mode: S_IFREG | 0o755, data: Data("ignored".utf8)),
            ])
            let pkgData = try Self.makePKG(payloadPath: "Sub.pkg/Payload", cpioData: cpio)
            let fixture = directory.appending(path: "gs.pkg")
            try pkgData.write(to: fixture)
            let sha = HashGenerator.hash(pkgData, algorithm: .sha256)

            let url = URL(string: "https://downloads.example.invalid/gs.pkg")!
            let store = EngineStore(
                rootDirectory: directory.appending(path: "engines", directoryHint: .isDirectory),
                downloader: LocalFileDownloader(files: [url: fixture])
            )
            let manifest = EngineManifest(
                id: "pkg-test",
                displayName: "PkgTest",
                summary: "Test",
                license: "AGPL-3.0-or-later",
                homepage: URL(string: "https://example.invalid")!,
                version: "1.0",
                artifacts: [
                    EngineArtifact(
                        architecture: .current,
                        url: url,
                        sha256: sha,
                        sizeBytes: Int64(pkgData.count),
                        payload: .pkg(
                            payloadPath: "Sub.pkg/Payload",
                            executablePath: "usr/local/bin/gs-noX11",
                            includedPrefixes: ["usr/local/bin/gs-noX11"]
                        )
                    )
                ]
            )
            _ = try await store.install(manifest)
            let exe = try #require(store.executableURL(for: manifest))
            #expect(FileManager.default.isExecutableFile(atPath: exe.path))
            #expect(try Data(contentsOf: exe) == gsBinary)
            let ignored = exe.deletingLastPathComponent().appending(path: "gs-X11")
            #expect(!FileManager.default.fileExists(atPath: ignored.path))
        }
    }

    @Test func pkgRejectsSymlinkInsideSelectedPrefix() async throws {
        try await withTemporaryDirectory { directory in
            let cpio = Self.makeOdcCPIO(entries: [
                (name: "./usr/local/bin/gs-noX11", mode: S_IFLNK | 0o777, data: Data("/bin/sh".utf8)),
            ])
            let pkgData = try Self.makePKG(payloadPath: "Sub.pkg/Payload", cpioData: cpio)
            let fixture = directory.appending(path: "bad.pkg")
            try pkgData.write(to: fixture)
            let sha = HashGenerator.hash(pkgData, algorithm: .sha256)

            let url = URL(string: "https://downloads.example.invalid/bad.pkg")!
            let store = EngineStore(
                rootDirectory: directory.appending(path: "engines", directoryHint: .isDirectory),
                downloader: LocalFileDownloader(files: [url: fixture])
            )
            let manifest = EngineManifest(
                id: "pkg-bad",
                displayName: "PkgBad",
                summary: "Test",
                license: "AGPL-3.0-or-later",
                homepage: URL(string: "https://example.invalid")!,
                version: "1.0",
                artifacts: [
                    EngineArtifact(
                        architecture: .current,
                        url: url,
                        sha256: sha,
                        sizeBytes: Int64(pkgData.count),
                        payload: .pkg(
                            payloadPath: "Sub.pkg/Payload",
                            executablePath: "usr/local/bin/gs-noX11",
                            includedPrefixes: ["usr/local/bin/gs-noX11"]
                        )
                    )
                ]
            )
            await #expect(throws: EngineStoreError.self) {
                try await store.install(manifest)
            }
        }
    }

    @Test func engineProcessStreamsLinesAndCancelsProcessGroup() async throws {
        let lines = LineRecorder()
        let result = try await EngineProcess.run(
            URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'one\\ntwo\\rthree\\n'"],
            onStdoutLine: { lines.append($0) }
        )
        #expect(result.exitCode == 0)
        #expect(lines.values == ["one", "two", "three"])

        let pidBox = LineRecorder()
        let task = Task {
            try await EngineProcess.run(
                URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "sh -c 'trap \"\" TERM; echo $$; exec sleep 30' & wait"],
                killGraceDelay: .milliseconds(250),
                onStdoutLine: { pidBox.append($0) }
            )
        }
        var childPID: pid_t?
        for _ in 0..<80 {
            if let first = pidBox.values.first, let parsed = pid_t(first.trimmingCharacters(in: .whitespacesAndNewlines)) {
                childPID = parsed
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        let spawnedPID = try #require(childPID)
        let started = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        let elapsed = ContinuousClock.now - started
        #expect(elapsed < .seconds(5))
        try await Task.sleep(for: .milliseconds(150))
        #expect(kill(spawnedPID, 0) != 0)
    }

    @Test func engineProcessIgnoresBrokenStdinPipe() async throws {
        let largeInput = Data(repeating: 0x41, count: 256 * 1_024)
        let result = try await EngineProcess.run(
            URL(fileURLWithPath: "/usr/bin/true"),
            arguments: [],
            standardInput: largeInput
        )
        #expect(result.exitCode == 0)
    }

    @Test func tarXzRejectsMalformedPAXLengthWithoutTrapping() async throws {
        try await withTemporaryDirectory { directory in
            let paxData = Data("11 path=ok\n9223372036854775807 path=x\n".utf8)
            let tar = Self.makeTar(entries: [
                (name: "pax", typeFlag: UInt8(ascii: "x"), data: paxData),
                (name: "7zz", typeFlag: UInt8(ascii: "0"), data: Data("bin".utf8)),
            ])
            let compressed = try Self.compressXZ(tar)
            let fixture = directory.appending(path: "badpax.tar.xz")
            try compressed.write(to: fixture)
            let sha = HashGenerator.hash(compressed, algorithm: .sha256)
            let url = URL(string: "https://downloads.example.invalid/badpax.tar.xz")!
            let store = EngineStore(
                rootDirectory: directory.appending(path: "engines", directoryHint: .isDirectory),
                downloader: LocalFileDownloader(files: [url: fixture])
            )
            let manifest = EngineManifest(
                id: "tar-pax",
                displayName: "BadPAX",
                summary: "Test",
                license: "MIT",
                homepage: URL(string: "https://example.invalid")!,
                version: "1.0",
                artifacts: [
                    EngineArtifact(
                        architecture: .current,
                        url: url,
                        sha256: sha,
                        sizeBytes: Int64(compressed.count),
                        payload: .tarXz(executablePath: "7zz")
                    )
                ]
            )
            await #expect(throws: EngineStoreError.invalidArchive) {
                try await store.install(manifest)
            }
        }
    }

    @Test func pkgRejectsNegativeOctalModeWithoutTrapping() async throws {
        try await withTemporaryDirectory { directory in
            let badHeader = Data("070707000000000001-000010000000000000000010000000000000000000001300000000000".utf8)
            let body = Data("./a\0".utf8)
            let cpio = badHeader + body
            let pkgData = try Self.makePKG(payloadPath: "Sub.pkg/Payload", cpioData: cpio)
            let fixture = directory.appending(path: "badmode.pkg")
            try pkgData.write(to: fixture)
            let sha = HashGenerator.hash(pkgData, algorithm: .sha256)
            let url = URL(string: "https://downloads.example.invalid/badmode.pkg")!
            let store = EngineStore(
                rootDirectory: directory.appending(path: "engines", directoryHint: .isDirectory),
                downloader: LocalFileDownloader(files: [url: fixture])
            )
            let manifest = EngineManifest(
                id: "pkg-mode",
                displayName: "BadMode",
                summary: "Test",
                license: "AGPL-3.0-or-later",
                homepage: URL(string: "https://example.invalid")!,
                version: "1.0",
                artifacts: [
                    EngineArtifact(
                        architecture: .current,
                        url: url,
                        sha256: sha,
                        sizeBytes: Int64(pkgData.count),
                        payload: .pkg(
                            payloadPath: "Sub.pkg/Payload",
                            executablePath: "a",
                            includedPrefixes: ["a"]
                        )
                    )
                ]
            )
            await #expect(throws: EngineStoreError.invalidArchive) {
                try await store.install(manifest)
            }
        }
    }

    private final class LineRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        var values: [String] { lock.withLock { items } }
        func append(_ line: String) { lock.withLock { items.append(line) } }
    }

    private static func makeTar(entries: [(name: String, typeFlag: UInt8, data: Data)]) -> Data {
        var out = Data()
        for entry in entries {
            var header = Data(count: 512)
            let nameBytes = Array(entry.name.utf8)
            header.replaceSubrange(0..<min(nameBytes.count, 100), with: nameBytes.prefix(100))
            writeOctal(0o644, width: 8, into: &header, at: 100)
            writeOctal(0, width: 8, into: &header, at: 108)
            writeOctal(0, width: 8, into: &header, at: 116)
            writeOctal(entry.data.count, width: 12, into: &header, at: 124)
            writeOctal(0, width: 12, into: &header, at: 136)
            header.replaceSubrange(148..<156, with: repeatElement(UInt8(0x20), count: 8))
            header[156] = entry.typeFlag
            header.replaceSubrange(257..<263, with: Data("ustar\0".utf8))
            header.replaceSubrange(263..<265, with: Data("00".utf8))

            let checksum = header.reduce(0) { $0 + Int($1) }
            writeOctal(checksum, width: 7, into: &header, at: 148)
            header[155] = 0x20
            out.append(header)
            out.append(entry.data)
            let remainder = entry.data.count % 512
            if remainder != 0 {
                out.append(Data(count: 512 - remainder))
            }
        }
        out.append(Data(count: 1024))
        return out
    }

    private static func writeOctal(_ value: Int, width: Int, into data: inout Data, at offset: Int) {
        let octal = String(value, radix: 8)
        let padded = String(repeating: "0", count: max(0, width - 1 - octal.count)) + octal
        let bytes = Array(padded.utf8.prefix(width - 1)) + [0]
        data.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
    }

    private static func compressXZ(_ input: Data) throws -> Data {
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_LZMA) == COMPRESSION_STATUS_OK else {
            throw EngineStoreError.invalidArchive
        }
        defer { _ = compression_stream_destroy(stream) }
        let chunkSize = 64 * 1024
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { dst.deallocate() }
        var output = Data()
        input.withUnsafeBytes { src in
            stream.pointee.src_ptr = src.bindMemory(to: UInt8.self).baseAddress!
            stream.pointee.src_size = src.count
            while true {
                stream.pointee.dst_ptr = dst
                stream.pointee.dst_size = chunkSize
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunkSize - stream.pointee.dst_size
                if produced > 0 { output.append(dst, count: produced) }
                if status == COMPRESSION_STATUS_END { break }
            }
        }
        return output
    }

    private static func makeOdcCPIO(entries: [(name: String, mode: mode_t, data: Data)]) -> Data {
        var out = Data()
        let all = entries + [(name: "TRAILER!!!", mode: 0, data: Data())]
        for (index, entry) in all.enumerated() {
            let nameBytes = Data(entry.name.utf8) + Data([0])
            let header = String(
                format: "070707%06o%06o%06o%06o%06o%06o%06o%011o%06o%011o",
                0,
                index + 1,
                Int(entry.mode),
                0,
                0,
                1,
                0,
                0,
                nameBytes.count,
                entry.data.count
            )
            out.append(Data(header.utf8))
            out.append(nameBytes)
            out.append(entry.data)
        }
        return out
    }

    private static func makePKG(payloadPath: String, cpioData: Data) throws -> Data {
        let gzipped = try deflate(cpioData, windowBits: 15 + 16)
        let components = payloadPath.split(separator: "/").map(String.init)
        let tocXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <xar>
          <toc>
            <file id="1">
              <name>\(components[0])</name>
              <type>directory</type>
              <file id="2">
                <name>\(components[1])</name>
                <type>file</type>
                <data>
                  <offset>0</offset>
                  <length>\(gzipped.count)</length>
                  <size>\(gzipped.count)</size>
                </data>
              </file>
            </file>
          </toc>
        </xar>
        """
        let tocBytes = Data(tocXML.utf8)
        let compressedTOC = try deflate(tocBytes, windowBits: 15)

        var pkg = Data()
        pkg.append(Data("xar!".utf8))
        pkg.append(contentsOf: be16(28))
        pkg.append(contentsOf: be16(1))
        pkg.append(contentsOf: be64(UInt64(compressedTOC.count)))
        pkg.append(contentsOf: be64(UInt64(tocBytes.count)))
        pkg.append(contentsOf: be32(1))
        pkg.append(compressedTOC)
        pkg.append(gzipped)
        return pkg
    }

    private static func deflate(_ input: Data, windowBits: Int32) throws -> Data {
        var stream = z_stream()
        guard deflateInit2_(
            &stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, windowBits, 8, Z_DEFAULT_STRATEGY,
            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)
        ) == Z_OK else {
            throw EngineStoreError.invalidArchive
        }
        defer { deflateEnd(&stream) }
        let chunkSize = 64 * 1024
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { dst.deallocate() }
        var output = Data()
        input.withUnsafeBytes { src in
            stream.next_in = UnsafeMutablePointer(mutating: src.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(src.count)
            while true {
                stream.next_out = dst
                stream.avail_out = uInt(chunkSize)
                let status = zlib.deflate(&stream, Z_FINISH)
                let produced = chunkSize - Int(stream.avail_out)
                if produced > 0 { output.append(dst, count: produced) }
                if status == Z_STREAM_END { break }
            }
        }
        return output
    }

    private static func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xff)] }
    private static func be32(_ v: UInt32) -> [UInt8] {
        [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
    }
    private static func be64(_ v: UInt64) -> [UInt8] {
        (0..<8).reversed().map { UInt8((v >> ($0 * 8)) & 0xff) }
    }
}
