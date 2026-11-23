import CryptoKit
import Foundation
import Testing

@testable import OpenToolboxApp
@testable import OpenToolboxCore

private final class StubEngineDownloader: EngineDownloader, @unchecked Sendable {
    private let lock = NSLock()
    private var payloads: [URL: Data]
    private var failures: [URL: Error]
    private var holdURLs: Set<URL>
    private var continuations: [URL: CheckedContinuation<Void, Error>] = [:]
    private var startedURLs: Set<URL> = []
    private var cancelledURLs: Set<URL> = []

    init(
        payloads: [URL: Data] = [:],
        failures: [URL: Error] = [:],
        holdURLs: Set<URL> = []
    ) {
        self.payloads = payloads
        self.failures = failures
        self.holdURLs = holdURLs
    }

    func download(
        from url: URL,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let lookup = lock.withLock { () -> (Data?, Error?) in
            (payloads[url], failures[url])
        }
        if let failure = lookup.1 {
            throw failure
        }
        guard let data = lookup.0 else {
            throw EngineDownloadError.noFile
        }
        progress(0.5)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enum Action {
                    case resume
                    case cancel
                    case suspend
                }
                let action = lock.withLock { () -> Action in
                    startedURLs.insert(url)
                    if cancelledURLs.contains(url) {
                        return .cancel
                    }
                    if !holdURLs.contains(url) {
                        return .resume
                    }
                    continuations[url] = continuation
                    return .suspend
                }
                switch action {
                case .resume:
                    continuation.resume()
                case .cancel:
                    continuation.resume(throwing: CancellationError())
                case .suspend:
                    break
                }
            }
        } onCancel: {
            let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
                cancelledURLs.insert(url)
                return continuations.removeValue(forKey: url)
            }
            continuation?.resume(throwing: CancellationError())
        }
        try data.write(to: destination)
        progress(1)
    }

    func hasStarted(_ url: URL) -> Bool {
        lock.withLock { startedURLs.contains(url) }
    }

    func release(_ url: URL) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            holdURLs.remove(url)
            return continuations.removeValue(forKey: url)
        }
        continuation?.resume()
    }
}

@MainActor
@Suite("EngineCenter and batch tool enabling", .serialized)
struct EngineCenterTests {
    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func makeManifest(id: EngineID, name: String, payload: Data) -> (EngineManifest, URL) {
        let url = URL(string: "https://example.com/\(id)")!
        let artifact = EngineArtifact(
            architecture: .current,
            url: url,
            sha256: sha256Hex(payload),
            sizeBytes: Int64(payload.count),
            payload: .executable(fileName: id)
        )
        let manifest = EngineManifest(
            id: id,
            displayName: name,
            summary: name,
            license: "MIT",
            homepage: URL(string: "https://example.com")!,
            version: "1.0",
            artifacts: [artifact]
        )
        return (manifest, url)
    }

    private static func makeTempDir(_ prefix: String) throws -> URL {
        let dir = try EngineDirectory.systemTemporaryDirectory()
            .appending(path: "\(prefix)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func waitUntil(
        timeout: Duration = .seconds(5),
        condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now >= deadline {
                Issue.record("Timed out waiting for condition")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func missingEnginesDeduplicateAndTrackInstallAndDiskUsage() async throws {
        let tempDir = try Self.makeTempDir("OpenToolbox-EngineCenterTests")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let alphaData = Data(repeating: 0x41, count: 4096)
        let betaData = Data(repeating: 0x42, count: 8192)
        let (alpha, alphaURL) = Self.makeManifest(id: "alpha", name: "Alpha", payload: alphaData)
        let (beta, betaURL) = Self.makeManifest(id: "beta", name: "Beta", payload: betaData)

        let downloader = StubEngineDownloader(payloads: [alphaURL: alphaData, betaURL: betaData], holdURLs: [betaURL])
        let store = EngineStore(rootDirectory: tempDir, downloader: downloader)
        let center = EngineCenter(manifests: [alpha, beta], store: store)

        let toolA = ToolDescriptor(
            id: "test.a",
            category: .media,
            title: "Tool A",
            summary: "Uses Alpha",
            symbolName: "film",
            requiredEngines: ["alpha"]
        )
        let toolAB = ToolDescriptor(
            id: "test.ab",
            category: .media,
            title: "Tool AB",
            summary: "Uses Alpha and Beta",
            symbolName: "film",
            requiredEngines: ["alpha", "beta"]
        )

        #expect(!center.allEnginesInstalled(for: toolA))
        #expect(!center.allEnginesInstalled(for: toolAB))
        #expect(center.missingEngines(for: [toolA, toolAB]).map(\.id) == ["alpha", "beta"])
        #expect(center.downloadSize(of: [alpha, beta, alpha]) == Int64(alphaData.count + betaData.count))

        center.install([alpha, beta, alpha])
        try await Self.waitUntil { center.allEnginesInstalled(for: toolA) && downloader.hasStarted(betaURL) }

        #expect(center.allEnginesInstalled(for: toolA))
        #expect(center.installedDiskUsage(for: toolA) > 0)
        #expect(!center.allEnginesInstalled(for: toolAB))
        #expect(center.missingEngines(for: toolAB).map(\.id) == ["beta"])
        #expect(center.downloadableMissingEngines(for: [toolA, toolAB]).isEmpty)
        let midProgress = try #require(center.downloadProgress(for: toolAB))
        #expect(midProgress >= 0.5 && midProgress < 1.0)

        downloader.release(betaURL)
        try await Self.waitUntil { center.allEnginesInstalled(for: toolAB) && !center.isInstalling("beta") }

        #expect(center.allEnginesInstalled(for: toolAB))
        #expect(center.missingEngines(for: [toolA, toolAB]).isEmpty)
        #expect(center.downloadProgress(for: toolAB) == nil)
        #expect(center.installedDiskUsage(for: toolAB) > center.installedDiskUsage(for: toolA))
    }

    @Test func batchDownloadFailuresReportEveryEngineName() async throws {
        let tempDir = try Self.makeTempDir("OpenToolbox-EngineCenterErrors")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let (alpha, alphaURL) = Self.makeManifest(id: "alpha", name: "Alpha", payload: Data([1]))
        let (beta, betaURL) = Self.makeManifest(id: "beta", name: "Beta", payload: Data([2]))
        let downloader = StubEngineDownloader(
            failures: [
                alphaURL: EngineDownloadError.httpStatus(503),
                betaURL: EngineDownloadError.httpStatus(404),
            ]
        )
        let store = EngineStore(rootDirectory: tempDir, downloader: downloader)
        let center = EngineCenter(manifests: [alpha, beta], store: store)

        center.install([alpha, beta])
        try await Self.waitUntil { !center.isInstalling("alpha") && !center.isInstalling("beta") }

        let first = try #require(center.errorMessage)
        let firstIDs = center.activeErrorIDs
        center.dismissErrors(ids: firstIDs)
        try await Self.waitUntil { center.errorMessage != nil }

        let second = try #require(center.errorMessage)
        let combined = first + "\n" + second
        #expect(combined.contains("Alpha"))
        #expect(combined.contains("Beta"))
        #expect(combined.contains("503"))
        #expect(combined.contains("404"))

        center.dismissErrors(ids: center.activeErrorIDs)
        #expect(center.errorMessage == nil)
    }

    @Test func nilStoreDisablesDownloadsAndSurfacesStorageError() {
        let (alpha, _) = Self.makeManifest(id: "alpha", name: "Alpha", payload: Data([1]))
        let toolA = ToolDescriptor(
            id: "test.a",
            category: .media,
            title: "Tool A",
            summary: "Uses Alpha",
            symbolName: "film",
            requiredEngines: ["alpha"]
        )
        let center = EngineCenter(manifests: [alpha], store: nil, storeError: "Storage unavailable")

        #expect(!center.canDownload(alpha))
        #expect(center.downloadableMissingEngines(for: [toolA]).isEmpty)
        #expect(center.downloadableMissingEngines().isEmpty)

        center.install(alpha)
        #expect(center.errorMessage == "Storage unavailable")
    }

    @Test func appModelBatchSetEnabledPersistsAndClosesDisabledTools() throws {
        let suiteName = "OpenToolbox.EngineCenterTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let tempDir = try Self.makeTempDir("OpenToolbox-AppModelTests")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = EngineStore(rootDirectory: tempDir, downloader: StubEngineDownloader())
        let model = AppModel(defaults: defaults, engines: EngineCenter(manifests: [], store: store))

        let compressPDF = try #require(ToolCatalog.tool("pdf.compress"))
        let convertVideo = try #require(ToolCatalog.tool("media.convert"))
        #expect(!model.isEnabled(compressPDF))
        #expect(!model.isEnabled(convertVideo))

        model.setEnabled(true, for: [compressPDF, convertVideo])
        #expect(model.isEnabled(compressPDF))
        #expect(model.isEnabled(convertVideo))

        let reloaded = AppModel(defaults: defaults, engines: EngineCenter(manifests: [], store: store))
        #expect(reloaded.isEnabled(compressPDF))
        #expect(reloaded.isEnabled(convertVideo))

        let window = WindowModel()
        model.register(window) {}
        window.open(.tool(convertVideo.id))
        #expect(window.openedTools.contains(convertVideo.id))

        model.setEnabled(false, for: [compressPDF, convertVideo])
        #expect(!model.isEnabled(compressPDF))
        #expect(!model.isEnabled(convertVideo))
        #expect(!window.openedTools.contains(convertVideo.id))
    }

    @Test func removeEngineDisablesOnlyDependentToolsWhenUninstallSucceeds() async throws {
        let suiteName = "OpenToolbox.RemoveEngineTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let tempDir = try Self.makeTempDir("OpenToolbox-RemoveEngineTests")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let ffmpegData = Data(repeating: 0x50, count: 2048)
        let (ffmpeg, ffmpegURL) = Self.makeManifest(id: EngineCatalog.ffmpegID, name: "FFmpeg", payload: ffmpegData)
        let downloader = StubEngineDownloader(payloads: [ffmpegURL: ffmpegData])
        let store = EngineStore(rootDirectory: tempDir, downloader: downloader)
        let center = EngineCenter(manifests: [ffmpeg], store: store)
        center.install(ffmpeg)
        try await Self.waitUntil { !center.isInstalling(EngineCatalog.ffmpegID) && center.status(of: EngineCatalog.ffmpegID).isInstalled }

        let model = AppModel(defaults: defaults, engines: center)
        let compressVideo = try #require(ToolCatalog.tool("media.compress-video"))
        let muteVideo = try #require(ToolCatalog.tool("media.mute-video"))
        let mediaInfo = try #require(ToolCatalog.tool("media.info"))
        let jsonFormatter = try #require(ToolCatalog.tool("dev.json-formatter"))
        model.setEnabled(true, for: [compressVideo, muteVideo, mediaInfo])

        let window = WindowModel()
        model.register(window) {}
        window.open(.tool(compressVideo.id))
        #expect(window.selection == .tool(compressVideo.id))

        #expect(model.removeEngine(EngineCatalog.ffmpegID))
        #expect(!center.status(of: EngineCatalog.ffmpegID).isInstalled)
        #expect(!model.isEnabled(compressVideo))
        #expect(!model.isEnabled(muteVideo))
        #expect(model.isEnabled(mediaInfo))
        #expect(model.isEnabled(jsonFormatter))
        #expect(!window.openedTools.contains(compressVideo.id))
        #expect(window.selection == .catalog)

        let failingModel = AppModel(
            defaults: defaults,
            engines: EngineCenter(manifests: [ffmpeg], store: nil, storeError: "Storage unavailable")
        )
        failingModel.setEnabled(true, for: [muteVideo])
        #expect(!failingModel.removeEngine(EngineCatalog.ffmpegID))
        #expect(failingModel.isEnabled(muteVideo))
    }
}
