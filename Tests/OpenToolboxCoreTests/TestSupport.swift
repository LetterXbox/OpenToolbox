import Foundation

@testable import OpenToolboxCore

/// Runs `body` with a fresh temporary directory that is removed afterwards.
func withTemporaryDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "OpenToolboxTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try await body(directory)
}

/// Serves downloads by copying local fixture files. Never touches the network.
final class LocalFileDownloader: EngineDownloader, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [URL: URL]
    private var _requests: [URL] = []

    init(files: [URL: URL]) {
        self.files = files
    }

    var requests: [URL] { lock.withLock { _requests } }

    func download(from url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let source = lock.withLock { () -> URL? in
            _requests.append(url)
            return files[url]
        }
        guard let source else { throw EngineDownloadError.httpStatus(404) }
        try FileManager.default.copyItem(at: source, to: destination)
        progress(1)
    }
}
