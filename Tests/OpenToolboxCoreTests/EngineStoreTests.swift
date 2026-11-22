import Foundation
import Testing

@testable import OpenToolboxCore

@Suite("Engine store")
struct EngineStoreTests {
    static let payload = Data("OpenToolbox engine payload v1\n".utf8)
    static let payloadSHA256 = "ef8ab61a58a080f2c2a53deeda39575cfd0a3ad1c4e79f6bf4f463c13986bed1"
    static let url = URL(string: "https://downloads.example.invalid/demo-engine")!

    static func manifest(sha256: String = payloadSHA256, size: Int64 = 30, version: String? = "1.0") -> EngineManifest {
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
                    payload: .executable(fileName: "demo"))
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

            let executable = try #require(store.executableURL(for: "demo-engine"))
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
            #expect(store.executableURL(for: "demo-engine") == nil)
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
        let tools = [
            ToolDescriptor(id: "a", category: .media, title: "A", summary: "", symbolName: "", requiredEngines: ["x", "y"]),
            ToolDescriptor(id: "b", category: .media, title: "B", summary: "", symbolName: "", requiredEngines: ["y", "x"]),
            ToolDescriptor(id: "c", category: .developer, title: "C", summary: "", symbolName: ""),
        ]
        #expect(ToolCatalog.engines(requiredBy: tools) == ["x", "y"])
        #expect(ToolCatalog.tools(requiring: "y", from: tools).map(\.id) == ["a", "b"])
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
        }
    }

    @Test func unpinnedEngineIsUnavailable() async throws {
        try await withTemporaryDirectory { directory in
            let (store, downloader) = try Self.makeStore(in: directory)
            let manifest = Self.manifest(version: nil)
            #expect(store.status(of: manifest) == .unavailable)
            await #expect(throws: EngineStoreError.unavailable("demo-engine")) {
                try await store.install(manifest)
            }
            #expect(downloader.requests.isEmpty)
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

    @Test func unsafeArchivePathsAreRejected() {
        #expect(!EngineStore.isSafeRelativePath("../bin/ffmpeg"))
        #expect(!EngineStore.isSafeRelativePath("/usr/bin/ffmpeg"))
        #expect(!EngineStore.isSafeRelativePath("bin//ffmpeg"))
        #expect(EngineStore.isSafeRelativePath("bin/ffmpeg"))
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
