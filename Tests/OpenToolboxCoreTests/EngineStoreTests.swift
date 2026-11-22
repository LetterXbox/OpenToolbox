import Darwin
import Foundation
import Testing
import os

@testable import OpenToolboxCore

@Suite("Engine store")
struct EngineStoreTests {
    static let payload = Data("OpenToolbox engine payload v1\n".utf8)
    static let payloadSHA256 = "ef8ab61a58a080f2c2a53deeda39575cfd0a3ad1c4e79f6bf4f463c13986bed1"
    static let url = URL(string: "https://downloads.example.invalid/demo-engine")!

    static func manifest(sha256: String = payloadSHA256, size: Int64 = 30, version: String? = "1.0", payload: EnginePayload = .executable(fileName: "demo")) -> EngineManifest {
        EngineManifest(
            id: "demo-engine",
            displayName: "Demo",
            summary: "Test engine",
            license: "MIT",
            homepage: URL(string: "https://example.invalid")!,
            version: version,
            artifacts: [
                EngineArtifact(
                    architecture: .current, url: url, sha256: sha256, sizeBytes: size,
                    payload: payload)
            ]
        )
    }

    /// Writes the fixture payload and returns a store rooted in `directory/engines`.
    static func makeStore(in directory: URL) throws -> (EngineStore, LocalFileDownloader) {
        let fixture = directory.appending(path: "fixture.bin")
        try payload.write(to: fixture)
        let downloader = LocalFileDownloader(files: [url: fixture])
        let store = EngineStore(
            rootDirectory: directory.appending(path: "engines", directoryHint: .isDirectory),
            downloader: downloader)
        return (store, downloader)
    }

    @Test func installVerifiesAndMarksExecutable() async throws {
        try await withTemporaryDirectory { directory in
            let (store, _) = try Self.makeStore(in: directory)
            let manifest = Self.manifest()
            #expect(store.status(of: manifest) == .notInstalled(manifest.artifacts[0]))

            let receipt = try await store.install(manifest)
            #expect(receipt.sha256 == Self.payloadSHA256)
            #expect(receipt.sizeBytes == 30)
            #expect(receipt.version == "1.0")

            let executable = try #require(store.executableURL(for: manifest))
            #expect(FileManager.default.isExecutableFile(atPath: executable.path))
            #expect(try Data(contentsOf: executable) == Self.payload)
            #expect(store.status(of: manifest).isInstalled)
            #expect(store.diskUsage(of: "demo-engine") > 0)

            // Staging is cleaned up.
            let staging = store.rootDirectory.appending(path: ".staging")
            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []
            #expect(leftovers.isEmpty)
        }
    }

    @Test func checksumMismatchDiscardsDownload() async throws {
        try await withTemporaryDirectory { directory in
            let (store, _) = try Self.makeStore(in: directory)
            let manifest = Self.manifest(sha256: String(repeating: "0", count: 64))
            await #expect(throws: EngineStoreError.self) {
                try await store.install(manifest)
            }
            #expect(store.receipt(for: "demo-engine") == nil)
            #expect(store.executableURL(for: manifest) == nil)
            #expect(!FileManager.default.fileExists(atPath: store.rootDirectory.appending(path: "demo-engine").path))
        }
    }

    @Test func sizeMismatchIsRejected() async throws {
        try await withTemporaryDirectory { directory in
            let (store, _) = try Self.makeStore(in: directory)
            do {
                try await store.install(Self.manifest(size: 999))
                Issue.record("Expected a size mismatch")
            } catch let error as EngineStoreError {
                #expect(error == .sizeMismatch(expected: 999, actual: 30))
            }
        }
    }

    @Test func reinstallingSameBuildDoesNotDownloadAgain() async throws {
        try await withTemporaryDirectory { directory in
            let (store, downloader) = try Self.makeStore(in: directory)
            let manifest = Self.manifest()
            try await store.install(manifest)
            try await store.install(manifest)
            #expect(downloader.requests.count == 1)
        }
    }

    @Test func sharedEngineIsInstalledOncePerID() async throws {
        try await withTemporaryDirectory { directory in
            let (store, downloader) = try Self.makeStore(in: directory)
            let manifest = Self.manifest()
            let tools = [
                ToolDescriptor(id: "a", category: .media, title: "A", summary: "", symbolName: "", requiredEngines: [manifest.id]),
                ToolDescriptor(id: "b", category: .media, title: "B", summary: "", symbolName: "", requiredEngines: [manifest.id]),
            ]
            let users = ToolCatalog.tools(requiring: manifest.id, from: tools)
            #expect(users.map(\.id) == ["a", "b"])
            let otherStore = EngineStore(rootDirectory: store.rootDirectory, downloader: downloader)
            async let first = store.install(manifest)
            async let second = otherStore.install(manifest)
            let (firstReceipt, secondReceipt) = try await (first, second)
            #expect(firstReceipt == secondReceipt)
            #expect(downloader.requests == [Self.url])
            #expect(ToolCatalog.engines(requiredBy: tools) == [manifest.id])
        }
    }

    @Test(arguments: [false, true])
    func redirectedStoreCannotRemoveAnInstallation(redirectAncestor: Bool) async throws {
        try await withTemporaryDirectory { directory in
            let fm = FileManager.default
            let parent = directory.appending(path: "parent")
            try fm.createDirectory(at: parent, withIntermediateDirectories: false)
            let (store, downloader) = try Self.makeStore(in: parent)
            let manifest = Self.manifest()
            try await store.install(manifest)

            let redirected = redirectAncestor ? parent : store.rootDirectory
            let moved = directory.appending(path: "outside")
            try fm.moveItem(at: redirected, to: moved)
            try fm.createSymbolicLink(at: redirected, withDestinationURL: moved)

            #expect(throws: POSIXError.self) { try store.uninstall(manifest.id) }
            await #expect(throws: POSIXError.self) {
                try await store.install(Self.manifest(version: "2.0"))
            }
            #expect(downloader.requests == [Self.url])
            let outsideRoot = redirectAncestor ? moved.appending(path: "engines") : moved
            let outsideEngine = outsideRoot.appending(path: manifest.id).appending(path: "files/demo")
            #expect(try Data(contentsOf: outsideEngine) == Self.payload)
            #expect(store.executableURL(for: manifest) == nil)
        }
    }

    @Test func installAndUninstallPreserveUnrecognizedDirectory() async throws {
        try await withTemporaryDirectory { directory in
            let (store, downloader) = try Self.makeStore(in: directory)
            let manifest = Self.manifest()
            let engine = store.rootDirectory.appending(path: manifest.id)
            try FileManager.default.createDirectory(at: engine, withIntermediateDirectories: true)
            let unrelated = engine.appending(path: "unrelated")
            try Self.payload.write(to: unrelated)
            #expect(throws: EngineStoreError.unrecognizedInstallation(manifest.id)) {
                try store.uninstall(manifest.id)
            }
            await #expect(throws: EngineStoreError.unrecognizedInstallation(manifest.id)) {
                try await store.install(manifest)
            }
            #expect(try Data(contentsOf: unrelated) == Self.payload)
            #expect(downloader.requests.isEmpty)
        }
    }

    @Test(arguments: ["receiptID", "receiptPath", "receiptSource", "fileSymlink", "directorySymlink", "directory"])
    func executableLookupRequiresMatchingReceiptAndRegularFile(tamper: String) async throws {
        try await withTemporaryDirectory { directory in
            let (store, _) = try Self.makeStore(in: directory)
            let manifest = Self.manifest()
            try await store.install(manifest)
            let engine = store.rootDirectory.appending(path: manifest.id)
            let files = engine.appending(path: "files")
            let executable = try #require(store.executableURL(for: manifest))
            let fm = FileManager.default
            let outside = directory.appending(path: "outside")
            try fm.createDirectory(at: outside, withIntermediateDirectories: false)
            let outsideFile = outside.appending(path: "demo")
            try fm.copyItem(at: executable, to: outsideFile)
            switch tamper {
            case "fileSymlink":
                try fm.removeItem(at: executable)
                try fm.createSymbolicLink(at: executable, withDestinationURL: outsideFile)
            case "directorySymlink":
                try fm.removeItem(at: files)
                try fm.createSymbolicLink(at: files, withDestinationURL: outside)
            case "directory":
                try fm.removeItem(at: executable)
                try fm.createDirectory(at: executable, withIntermediateDirectories: false)
            default:
                let record = engine.appending(path: "receipt.json")
                var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: record)) as? [String: Any])
                if tamper == "receiptID" { json["engineID"] = "another-engine" }
                if tamper == "receiptPath" { json["executableRelativePath"] = "../../../outside/demo" }
                if tamper == "receiptSource" { json["sourceURL"] = "https://example.invalid/other-build" }
                try JSONSerialization.data(withJSONObject: json).write(to: record)
            }
            #expect(store.executableURL(for: manifest) == nil)
            #expect(store.status(of: manifest) == .damaged)
        }
    }

    @Test func failedAtomicUpdateLeavesPreviousBuildInPlace() async throws {
        try await withTemporaryDirectory { directory in
            let (store, _) = try Self.makeStore(in: directory)
            let original = Self.manifest()
            let newer = Self.manifest(version: "2.0")
            let oldReceipt = try await store.install(original)
            let stagingRoot = store.rootDirectory.appending(path: ".staging")
            var immutablePath: String?
            defer {
                if let immutablePath { _ = chflags(immutablePath, 0) }
            }

            do {
                try await store.install(newer, progress: { _ in }) { checkpoint in
                    guard checkpoint == .willPublish else { return }
                    let staging = try #require(FileManager.default.contentsOfDirectory(
                        at: stagingRoot, includingPropertiesForKeys: nil).first)
                    let candidate = staging.appending(path: "engine").path
                    try #require(chflags(candidate, UInt32(UF_IMMUTABLE)) == 0)
                    immutablePath = candidate
                }
                Issue.record("Expected an immutable staging directory to prevent publication")
            } catch let error as POSIXError {
                #expect(error.code == .EPERM || error.code == .EACCES)
            }

            #expect(store.status(of: original) == .installed(oldReceipt))
            let executable = try #require(store.executableURL(for: original))
            #expect(try Data(contentsOf: executable) == Self.payload)
        }
    }

    @Test func uninstallCannotInterleaveWithAnotherStoresInstall() async throws {
        try await withTemporaryDirectory { directory in
            let (store, downloader) = try Self.makeStore(in: directory)
            let otherStore = EngineStore(rootDirectory: store.rootDirectory, downloader: downloader)
            let manifest = Self.manifest()
            try await store.install(manifest, progress: { _ in }) { checkpoint in
                guard checkpoint == .willPublish else { return }
                #expect(throws: EngineStoreError.operationInProgress(manifest.id)) {
                    try otherStore.uninstall(manifest.id)
                }
            }
            #expect(store.status(of: manifest).isInstalled)
            try otherStore.uninstall(manifest.id)
            #expect(store.status(of: manifest) == .notInstalled(manifest.artifacts[0]))
        }
    }

    @Test func uninstallRemovesEverything() async throws {
        try await withTemporaryDirectory { directory in
            let (store, _) = try Self.makeStore(in: directory)
            let manifest = Self.manifest()
            try await store.install(manifest)
            try store.uninstall("demo-engine")
            #expect(store.status(of: manifest) == .notInstalled(manifest.artifacts[0]))
            #expect(store.diskUsage(of: "demo-engine") == 0)
            // Uninstalling twice is harmless.
            try store.uninstall("demo-engine")
        }
    }

    @Test func updateAvailableWhenPinnedBuildChanges() async throws {
        try await withTemporaryDirectory { directory in
            let (store, _) = try Self.makeStore(in: directory)
            try await store.install(Self.manifest())
            let newer = Self.manifest(sha256: String(repeating: "a", count: 64), version: "2.0")
            guard case .updateAvailable(let installed, _) = store.status(of: newer) else {
                Issue.record("Expected updateAvailable")
                return
            }
            #expect(installed.version == "1.0")
            #expect(store.executableURL(for: newer) == nil)
        }
    }

    @Test func unpinnedEngineIsUnavailable() async throws {
        try await withTemporaryDirectory { directory in
            let (store, downloader) = try Self.makeStore(in: directory)
            let pinned = Self.manifest()
            try await store.install(pinned)
            let manifest = Self.manifest(version: nil)
            #expect(store.status(of: manifest) == .unavailable)
            await #expect(throws: EngineStoreError.unavailable("demo-engine")) {
                try await store.install(manifest)
            }
            #expect(store.executableURL(for: manifest) == nil)
            #expect(downloader.requests == [Self.url])
        }
    }

    @Test(arguments: ["../evil", "a/b", "", "Upper", ".hidden", "-dash"])
    func invalidEngineIDsAreRejected(_ id: String) {
        #expect(!EngineManifest.isValidID(id))
    }

    @Test(arguments: ["ffmpeg", "yt-dlp", "7zz", "whisper.cpp"])
    func validEngineIDsAreAccepted(_ id: String) {
        #expect(EngineManifest.isValidID(id))
    }

    @Test func relativePathsSplitOnSlashBytes() {
        #expect(EngineStore.relativePathComponents("a/\u{301}b".utf8) == ["a", "\u{301}b"])
        #expect(EngineStore.relativePathComponents("\u{301}/x".utf8) == ["\u{301}", "x"])
        #expect(EngineStore.relativePathComponents("a\u{301}/\u{301}b".utf8) == ["a\u{301}", "\u{301}b"])
    }

    @Test(arguments: ["", "/a", "a/", "a//b", "a/../\u{301}b", "a/./\u{301}b", "a/\0b", "a\\b"])
    func relativePathsRejectInvalidComponents(_ path: String) {
        #expect(EngineStore.relativePathComponents(path.utf8) == nil)
    }

    @Test(arguments: ["", ".", "..", "a/b", "a/\u{301}b", "\u{301}/x", "a\0b"])
    func directoryPrimitivesRequireOneComponent(_ name: String) async throws {
        try await withTemporaryDirectory { temporary in
            let root = try EngineDirectory.openPath(temporary)
            let directory = try root.makeDirectory("tested")
            let device = try directory.metadata().st_dev
            let file = try directory.createFile("source")
            try file.close()
            let invalid = POSIXError(.EINVAL)
            #expect(throws: invalid) { try directory.directory(name) }
            #expect(throws: invalid) { try directory.directory(name, create: true) }
            #expect(throws: invalid) { try directory.makeDirectory(name) }
            #expect(throws: invalid) { try directory.metadata(name) }
            #expect(throws: invalid) { try directory.regularFile(name) }
            #expect(throws: invalid) { try directory.createFile(name) }
            #expect(throws: invalid) { try directory.removeTree(name, device: device) }
            #expect(throws: invalid) { try directory.rename(name, to: directory, as: "target", flags: 0) }
            #expect(throws: invalid) { try directory.rename("source", to: directory, as: name, flags: 0) }
            let entries = try FileManager.default.contentsOfDirectory(atPath: temporary.appending(path: "tested").path)
            #expect(entries == ["source"])
        }
    }

    static func zipFixture(in directory: URL, outwardLink: Bool = false, extraEntries: Int = 0)
        throws -> (EngineStore, EngineManifest, Data)
    {
        let fm = FileManager.default
        let source = directory.appending(path: "source")
        try fm.createDirectory(at: source.appending(path: "bin"), withIntermediateDirectories: true)
        let contents = Data(repeating: 42, count: 160_000)
        try contents.write(to: source.appending(path: "bin/demo"))
        try Data("README".utf8).write(to: source.appending(path: "README"))
        for index in 0..<extraEntries {
            try Data().write(to: source.appending(path: "extra-\(index)"))
        }
        if outwardLink {
            try fm.createSymbolicLink(atPath: source.appending(path: "outside").path, withDestinationPath: "../outside")
        }
        let archive = try Self.makeZIP(in: directory, from: source, options: ["-r", "-y"], entries: ["."])
        let (store, manifest) = try Self.storeForZIP(archive, in: directory, executablePath: "bin/demo")
        return (store, manifest, contents)
    }

    private static func makeZIP(in directory: URL, from source: URL, options: [String], entries: [String]) throws -> URL {
        let archive = directory.appending(path: "fixture.zip")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = source
        zip.arguments = ["-q"] + options + [archive.path] + entries
        try zip.run()
        zip.waitUntilExit()
        try #require(zip.terminationStatus == 0)
        return archive
    }

    private static func storeForZIP(_ archive: URL, in directory: URL, executablePath: String)
        throws -> (EngineStore, EngineManifest)
    {
        let manifest = Self.manifest(
            sha256: try HashGenerator.hashFile(at: archive, algorithm: .sha256),
            size: Int64(try Data(contentsOf: archive).count),
            payload: .zip(executablePath: executablePath))
        let store = EngineStore(rootDirectory: directory.appending(path: "engines"),
                                downloader: LocalFileDownloader(files: [Self.url: archive]))
        return (store, manifest)
    }

    @Test(arguments: ["a/\u{301}b", "\u{301}/x", "a\u{301}/\u{301}b"])
    func installsRealZIPWithCombiningMarksNearSlashes(_ path: String) async throws {
        try await withTemporaryDirectory { directory in
            let source = directory.appending(path: "source")
            let file = source.appending(path: path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.payload.write(to: file)
            // Archive just the file so the extractor has to create its parent from the entry name.
            let archive = try Self.makeZIP(in: directory, from: source, options: ["-0"], entries: [path])
            let (store, manifest) = try Self.storeForZIP(archive, in: directory, executablePath: path)
            try await store.install(manifest)
            let executable = try #require(store.executableURL(for: manifest))
            let contents = try Data(contentsOf: executable)
            #expect(contents == Self.payload)
            #expect(FileManager.default.isExecutableFile(atPath: executable.path))
        }
    }

    @Test(arguments: [false, true])
    func realZIPWithInvalidCRCDiscardsStagedWrites(deflated: Bool) async throws {
        try await withTemporaryDirectory { directory in
            let payload = Data(repeating: 42, count: 160_000)
            try payload.write(to: directory.appending(path: "demo"))
            let archive = try Self.makeZIP(in: directory, from: directory, options: [deflated ? "-9" : "-0"], entries: ["demo"])
            var bytes = try Data(contentsOf: archive)
            if deflated {
                // Both headers claim the same CRC, but the decoded bytes have a different CRC.
                try #require(bytes[8] == 8)
                let central = try #require(bytes.range(of: Data([0x50, 0x4b, 0x01, 0x02])))
                bytes[14] ^= 1 // Local header CRC.
                bytes[central.lowerBound + 16] ^= 1 // Central header CRC.
            } else {
                // Corrupt a stored payload byte without altering either header.
                let member = try #require(bytes.range(of: payload))
                bytes[member.lowerBound] ^= 1
            }
            try bytes.write(to: archive)
            let (store, manifest) = try Self.storeForZIP(archive, in: directory, executablePath: "demo")
            var wroteChunk = false
            do {
                try await store.install(manifest, progress: { _ in }) { checkpoint in
                    if checkpoint == .didExtractChunk { wroteChunk = true }
                }
                Issue.record("Expected the ZIP member CRC mismatch to fail installation")
            } catch let error as EngineStoreError {
                #expect(error == .invalidArchive)
            }
            #expect(wroteChunk)
            let engine = store.rootDirectory.appending(path: manifest.id)
            #expect(!FileManager.default.fileExists(atPath: engine.path))
            let staging = store.rootDirectory.appending(path: ".staging")
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: staging.path)
            #expect(leftovers.isEmpty)
        }
    }

    @Test func rejectsZIPWithDataDescriptorFlagBeforeExtraction() async throws {
        try await withTemporaryDirectory { directory in
            try Self.payload.write(to: directory.appending(path: "demo"))
            let archive = try Self.makeZIP(in: directory, from: directory, options: ["-0"], entries: ["demo"])
            var bytes = try Data(contentsOf: archive)
            let central = try #require(bytes.range(of: Data([0x50, 0x4b, 0x01, 0x02])))
            bytes[6] |= 0x08 // Local flags.
            bytes[central.lowerBound + 8] |= 0x08 // Central flags.
            try bytes.write(to: archive)
            let (store, manifest) = try Self.storeForZIP(archive, in: directory, executablePath: "demo")
            await #expect(throws: EngineStoreError.invalidArchive) {
                try await store.install(manifest, progress: { _ in }) { checkpoint in
                    #expect(checkpoint != .didExtractChunk)
                }
            }
        }
    }

    @Test func installsStoredAndDeflatedFilesFromRealZIP() async throws {
        try await withTemporaryDirectory { directory in
            let (store, manifest, contents) = try Self.zipFixture(in: directory)
            try await store.install(manifest)
            let executable = try #require(store.executableURL(for: manifest))
            #expect(try Data(contentsOf: executable) == contents)
            let readme = executable.deletingLastPathComponent().deletingLastPathComponent().appending(path: "README")
            #expect(try Data(contentsOf: readme) == Data("README".utf8))
        }
    }

    @Test func rejectsRealZIPWithUnrelatedOutwardSymlink() async throws {
        try await withTemporaryDirectory { directory in
            let (store, manifest, _) = try Self.zipFixture(in: directory, outwardLink: true)
            await #expect(throws: EngineStoreError.unsafeArchivePath("outside")) {
                try await store.install(manifest)
            }
            #expect(store.status(of: manifest) == .notInstalled(manifest.artifacts[0]))
        }
    }

    @Test func rejectsRealZIPOverEntryLimit() async throws {
        try await withTemporaryDirectory { directory in
            let (store, manifest, _) = try Self.zipFixture(in: directory, extraEntries: 4_097)
            await #expect(throws: EngineStoreError.archiveLimitExceeded) {
                try await store.install(manifest)
            }
            #expect(store.status(of: manifest) == .notInstalled(manifest.artifacts[0]))
        }
    }

    @Test(arguments: EngineStore.InstallationCheckpoint.allCases)
    func cancelledInstallDoesNotPublish(checkpoint: EngineStore.InstallationCheckpoint) async throws {
        try await withTemporaryDirectory { directory in
            let (store, manifest, _) = try Self.zipFixture(in: directory)
            // Cancel a child so cancellation doesn't propagate to the test runner.
            let installation = Task {
                try await store.install(manifest, progress: { _ in }) { reached in
                    if reached == checkpoint { withUnsafeCurrentTask { $0?.cancel() } }
                }
            }
            await #expect(throws: CancellationError.self) { try await installation.value }
            #expect(store.status(of: manifest) == .notInstalled(manifest.artifacts[0]))
            let staging = store.rootDirectory.appending(path: ".staging")
            #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
        }
    }

    @Test func downloaderRejectsDowngradeRedirectAndInsecureFinalResponse() throws {
        let insecure = try #require(URL(string: "http://example.invalid/engine"))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.downloadTask(with: Self.url)
        let observation = RedirectObservation()
        let delegate = EngineDownloadDelegate(destination: insecure, progress: { _ in })
        let redirect = try #require(HTTPURLResponse(url: Self.url, statusCode: 302, httpVersion: nil, headerFields: nil))
        delegate.urlSession(session, task: task, willPerformHTTPRedirection: redirect,
                            newRequest: URLRequest(url: insecure)) { observation.record($0) }
        #expect(observation.wasRejected)
        let received = try #require(HTTPURLResponse(url: insecure, statusCode: 200, httpVersion: nil, headerFields: nil))
        #expect(throws: EngineDownloadError.insecureURL(insecure)) {
            try EngineDownloadDelegate.validateResponse(received)
        }
        try EngineDownloadDelegate.validateResponse(HTTPURLResponse(
            url: Self.url, statusCode: 200, httpVersion: nil, headerFields: nil))
    }

    @Test func manifestRoundTripsThroughJSON() throws {
        let manifest = Self.manifest()
        let data = try JSONEncoder().encode(manifest)
        #expect(try JSONDecoder().decode(EngineManifest.self, from: data) == manifest)
    }

    @Test func builtInCatalogIsConsistent() {
        let engineIDs = Set(EngineCatalog.all.map(\.id))
        #expect(engineIDs.count == EngineCatalog.all.count)
        for engine in EngineCatalog.all {
            #expect(EngineManifest.isValidID(engine.id))
            // Phase 2 engines stay non-installable until a verified build is pinned.
            if engine.version == nil { #expect(engine.artifact() == nil) }
            for artifact in engine.artifacts {
                #expect(artifact.url.scheme == "https")
                #expect(artifact.sha256.count == 64)
            }
        }
        for tool in ToolCatalog.all {
            for engine in tool.requiredEngines {
                #expect(engineIDs.contains(engine), "\(tool.id) requires unknown engine \(engine)")
            }
        }
    }
}

private final class RedirectObservation: Sendable {
    private let result = OSAllocatedUnfairLock(initialState: false)

    var wasRejected: Bool { self.result.withLock { $0 } }

    func record(_ request: URLRequest?) {
        self.result.withLock { $0 = request == nil }
    }
}
