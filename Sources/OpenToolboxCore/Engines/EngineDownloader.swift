import Foundation

/// Downloads an engine artifact to a local file. Injected so tests never touch the network.
public protocol EngineDownloader: Sendable {
    /// Downloads `url` into `destination` (which must not exist yet).
    /// `progress` receives a fraction in `0...1` when the size is known.
    func download(from url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws
}

public enum EngineDownloadError: Error, Equatable, LocalizedError {
    case insecureURL(URL)
    case httpStatus(Int)
    case noFile

    public var errorDescription: String? {
        switch self {
        case .insecureURL(let url): coreLocalized("Refusing to download over an insecure connection: \(url.absoluteString)")
        case .httpStatus(let code): coreLocalized("The server responded with HTTP status \(code).")
        case .noFile: coreLocalized("The download finished without a file.")
        }
    }
}

/// Production downloader backed by `URLSession`. Only HTTPS is allowed.
public struct URLSessionEngineDownloader: EngineDownloader {
    public init() {}

    public func download(
        from url: URL,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard url.scheme?.lowercased() == "https" else { throw EngineDownloadError.insecureURL(url) }

        let delegate = DownloadDelegate(destination: destination, progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.start(session.downloadTask(with: url), continuation: continuation)
            }
        } onCancel: {
            delegate.cancel()
        }
    }
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDownloadTask?
    private var outcome: Result<Void, Error>?

    init(destination: URL, progress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    private var isCancelled = false

    func start(_ task: URLSessionDownloadTask, continuation: CheckedContinuation<Void, Error>) {
        let alreadyCancelled = lock.withLock { () -> Bool in
            self.task = task
            self.continuation = continuation
            return isCancelled
        }
        if alreadyCancelled { task.cancel() }
        task.resume()
    }

    func cancel() {
        let task = lock.withLock { () -> URLSessionDownloadTask? in
            isCancelled = true
            return self.task
        }
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file is deleted when this method returns, so move it now.
        let result: Result<Void, Error>
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            result = .failure(EngineDownloadError.httpStatus(http.statusCode))
        } else {
            do {
                try FileManager.default.moveItem(at: location, to: destination)
                result = .success(())
            } catch {
                result = .failure(error)
            }
        }
        lock.withLock { outcome = result }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (continuation, outcome) = lock.withLock { () -> (CheckedContinuation<Void, Error>?, Result<Void, Error>?) in
            defer { self.continuation = nil }
            return (self.continuation, self.outcome)
        }
        if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume(with: outcome ?? .failure(EngineDownloadError.noFile))
        }
    }
}
