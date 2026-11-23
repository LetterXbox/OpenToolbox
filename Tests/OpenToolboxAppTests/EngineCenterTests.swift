import CryptoKit
import Foundation
import Testing

@testable import OpenToolboxApp
@testable import OpenToolboxCore

private final class StubEngineDownloader: EngineDownloader, @unchecked Sendable {
    private let lock = NSLock()
    private var payloads: [URL: Data]
    private var holdURLs: Set<URL>
    private var continuations: [URL: CheckedContinuation<Void, Error>] = [:]
    private var startedURLs: Set<URL> = []

    init(payloads: [URL: Data], holdURLs: Set<URL> = []) {
        self.payloads = payloads
        self.holdURLs = holdURLs
    }

    func download(
        from url: URL,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let data = lock.withLock({ payloads[url] }) else {
            throw EngineDownloadError.noFile
        }
        progress(0.5)
        let shouldHold = lock.withLock { () -> Bool in
            startedURLs.insert(url)
            return holdURLs.contains(url)
        }
        if shouldHold {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    lock.withLock { continuations[url] = continuation }
                }
            } onCancel: {
                let continuation = lock.withLock { continuations.removeValue(forKey: url) }
                continuation?.resume(throwing: CancellationError())
            }
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
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "OpenToolbox-EngineCenterTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
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

    @Test func appModelBatchSetEnabledPersistsAndClosesDisabledTools() throws {
        let suiteName = "OpenToolbox.EngineCenterTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "OpenToolbox-AppModelTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = EngineStore(rootDirectory: tempDir, downloader: StubEngineDownloader(payloads: [:]))
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
}
